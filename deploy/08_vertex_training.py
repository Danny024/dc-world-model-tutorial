"""
Phase 8 — Vertex AI Custom Training Job
========================================
Submits the world model (07_world_model.py) as a Vertex AI custom training job
using an A100 GPU, then creates a Vertex AI endpoint for real-time inference.

Usage:
    source deploy/config.env
    python deploy/08_vertex_training.py

Prerequisites:
    pip install google-cloud-aiplatform torch
"""

from __future__ import annotations

import os
import pathlib
import subprocess
import textwrap

from google.cloud import aiplatform
from google.cloud.aiplatform import CustomTrainingJob

# ── Configuration ─────────────────────────────────────────────────────────────
PROJECT_ID          = os.environ["GCP_PROJECT_ID"]
REGION              = os.environ.get("VERTEX_REGION", "us-central1")
GCS_BUCKET          = os.environ["GCS_BUCKET"]
TRAINING_DATA_GCS   = os.environ.get("TRAINING_DATA_GCS",
                                     f"gs://{GCS_BUCKET}/training-data")
MODEL_ARTEFACT_GCS  = os.environ.get("MODEL_ARTEFACT_GCS",
                                     f"gs://{GCS_BUCKET}/models")

JOB_DISPLAY_NAME    = "datacenter-world-model-training"
ENDPOINT_DISPLAY    = "datacenter-failure-predictor"

# Vertex AI pre-built PyTorch training container
TRAIN_IMAGE         = "us-docker.pkg.dev/vertex-ai/training/pytorch-gpu.2-1:latest"
SERVE_IMAGE         = "us-docker.pkg.dev/vertex-ai/prediction/pytorch-gpu.2-1:latest"

MACHINE_TYPE        = "a2-highgpu-1g"   # A100 GPU
ACCELERATOR_TYPE    = "NVIDIA_TESLA_A100"
ACCELERATOR_COUNT   = 1


# ── Package the training script ───────────────────────────────────────────────

def build_training_package(staging_dir: pathlib.Path) -> pathlib.Path:
    """
    Creates a minimal Python package for Vertex AI custom training.
    Structure:
        trainer/
            __init__.py
            task.py          <- thin wrapper that calls world_model.train()
        setup.py
    """
    pkg_dir = staging_dir / "trainer_pkg"
    trainer = pkg_dir / "trainer"
    trainer.mkdir(parents=True, exist_ok=True)

    (trainer / "__init__.py").write_text("")

    # task.py — reads env vars set by Vertex AI, then delegates to world_model
    (trainer / "task.py").write_text(textwrap.dedent("""\
        import os, sys, subprocess, pathlib

        # Install extra deps not in the base image
        subprocess.check_call([sys.executable, "-m", "pip", "install",
                               "pandas", "numpy", "google-cloud-storage"])

        import google.cloud.storage as gcs

        # ── Download training data from GCS ──────────────────────────────────
        DATA_GCS     = os.environ["AIP_TRAINING_DATA_URI"]   # gs://…/sensor_timeseries.csv
        OUTPUT_DIR   = os.environ.get("AIP_MODEL_DIR", "/tmp/model_output")
        LOCAL_CSV    = "/tmp/sensor_timeseries.csv"

        print(f"Downloading training data from {DATA_GCS} ...")
        client = gcs.Client()
        blob_path = DATA_GCS.replace("gs://", "")
        bucket_name, blob_name = blob_path.split("/", 1)
        client.bucket(bucket_name).blob(blob_name).download_to_filename(LOCAL_CSV)
        print("Download complete.")

        # ── Add repo to path so we can import world_model ────────────────────
        repo_root = pathlib.Path(__file__).resolve().parent.parent.parent
        sys.path.insert(0, str(repo_root / "deploy"))

        from world_model import train   # noqa: E402
        train(
            csv_path   = LOCAL_CSV,
            output_dir = OUTPUT_DIR,
            epochs     = int(os.environ.get("EPOCHS", "50")),
        )

        # ── Upload model artefact to GCS ──────────────────────────────────────
        MODEL_GCS = os.environ.get("AIP_MODEL_DIR", "")
        model_pt  = pathlib.Path(OUTPUT_DIR) / "best_model.pt"
        if model_pt.exists() and MODEL_GCS:
            import subprocess as sp
            sp.run(["gsutil", "cp", str(model_pt), MODEL_GCS], check=True)
            print(f"Model uploaded to {MODEL_GCS}")
    """))

    (pkg_dir / "setup.py").write_text(textwrap.dedent("""\
        from setuptools import setup, find_packages
        setup(
            name="trainer",
            version="0.1",
            packages=find_packages(),
        )
    """))

    # Build the source distribution
    dist_dir = staging_dir / "dist"
    dist_dir.mkdir(exist_ok=True)
    subprocess.run(
        ["python", "setup.py", "sdist", "--dist-dir", str(dist_dir)],
        cwd=pkg_dir,
        check=True,
    )
    tarballs = list(dist_dir.glob("trainer-*.tar.gz"))
    assert tarballs, "setup.py sdist produced no tarball"
    return tarballs[0]


# ── Submit training job ───────────────────────────────────────────────────────

def submit_training_job(tarball_path: pathlib.Path) -> aiplatform.Model:
    print(f"\nInitialising Vertex AI (project={PROJECT_ID}, region={REGION})...")
    aiplatform.init(project=PROJECT_ID, location=REGION,
                    staging_bucket=f"gs://{GCS_BUCKET}/vertex-staging")

    job = CustomTrainingJob(
        display_name       = JOB_DISPLAY_NAME,
        script_path        = None,              # using a package instead
        container_uri      = TRAIN_IMAGE,
        requirements       = [],
        model_serving_container_image_uri = SERVE_IMAGE,
    )

    training_csv_gcs = f"{TRAINING_DATA_GCS}/sensor_timeseries.csv"
    print(f"Training data: {training_csv_gcs}")
    print(f"Model output : {MODEL_ARTEFACT_GCS}/")

    model = job.run(
        model_display_name = ENDPOINT_DISPLAY,
        args               = [],
        environment_variables = {
            "AIP_TRAINING_DATA_URI": training_csv_gcs,
            "EPOCHS":                "50",
            "GCS_BUCKET":            GCS_BUCKET,
        },
        replica_count      = 1,
        machine_type       = MACHINE_TYPE,
        accelerator_type   = ACCELERATOR_TYPE,
        accelerator_count  = ACCELERATOR_COUNT,
        base_output_dir    = MODEL_ARTEFACT_GCS,
        sync               = True,             # block until complete
    )

    print(f"\nTraining job completed. Model resource name: {model.resource_name}")
    return model


# ── Deploy endpoint ───────────────────────────────────────────────────────────

def deploy_endpoint(model: aiplatform.Model) -> aiplatform.Endpoint:
    print("\nCreating Vertex AI endpoint...")
    endpoint = aiplatform.Endpoint.create(
        display_name = ENDPOINT_DISPLAY,
        project      = PROJECT_ID,
        location     = REGION,
    )

    print(f"Deploying model to endpoint {endpoint.display_name}...")
    model.deploy(
        endpoint             = endpoint,
        deployed_model_display_name = "datacenter-failure-predictor-v1",
        machine_type         = "n1-standard-4",
        accelerator_type     = "NVIDIA_TESLA_T4",
        accelerator_count    = 1,
        traffic_percentage   = 100,
        sync                 = True,
    )

    print(f"\nEndpoint deployed: {endpoint.resource_name}")
    print(f"Endpoint ID: {endpoint.name}")
    return endpoint


# ── Sample prediction test ────────────────────────────────────────────────────

def test_inference(endpoint: aiplatform.Endpoint):
    import numpy as np

    print("\nTesting inference with random sensor window...")
    dummy_window = np.random.rand(12, 4).tolist()   # WINDOW_SIZE × NUM_FEATURES

    response = endpoint.predict(instances=[{"window": dummy_window}])
    print("Prediction response:")
    for pred in response.predictions:
        print(f"  {pred}")


# ── Main ──────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    import tempfile

    with tempfile.TemporaryDirectory() as tmpdir:
        staging = pathlib.Path(tmpdir)
        print("Building training package...")
        tarball = build_training_package(staging)
        print(f"Package: {tarball}")

        model    = submit_training_job(tarball)
        endpoint = deploy_endpoint(model)
        test_inference(endpoint)

    print("\n=== Phase 8 complete ===")
    print(f"Endpoint resource name: {endpoint.resource_name}")
    print("Update deploy/09_inference_config.toml with the endpoint ID above.")
