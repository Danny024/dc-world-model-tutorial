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

import json
import os
import pathlib
import subprocess
import textwrap
import time

from google.cloud import aiplatform

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

# ── A100 40GB (confirmed quota: 16x in us-central1-a) ────────────────────────
# Use a2-highgpu-1g  + NVIDIA_TESLA_A100  → A100 40GB  ✓  (quota confirmed)
# Do NOT use a2-ultragpu-1g + NVIDIA_A100_80GB          → 80GB still pending
MACHINE_TYPE        = "a2-highgpu-1g"
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

    # Bundle world_model.py inside the trainer package so Vertex AI can find it
    # without needing the full repo on the worker node.
    deploy_dir = pathlib.Path(__file__).parent
    (trainer / "world_model.py").write_bytes((deploy_dir / "07_world_model.py").read_bytes())

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

        # ── world_model.py is bundled alongside this file in the trainer package
        sys.path.insert(0, str(pathlib.Path(__file__).parent))

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
            sp.run(["gcloud", "storage", "cp", str(model_pt), MODEL_GCS], check=True)
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

def submit_training_job(tarball_path: pathlib.Path) -> str:
    """Upload package to GCS and submit via gcloud CLI. Returns the job name."""

    # 1. Upload tarball to GCS
    tarball_gcs_uri = f"gs://{GCS_BUCKET}/vertex-staging/trainer-0.1.tar.gz"
    print(f"\nUploading training package to {tarball_gcs_uri}...")
    subprocess.run(
        ["gcloud", "storage", "cp", str(tarball_path), tarball_gcs_uri],
        check=True,
    )

    training_csv_gcs = f"{TRAINING_DATA_GCS}/sensor_timeseries.csv"
    print(f"Training data: {training_csv_gcs}")
    print(f"Model output : {MODEL_ARTEFACT_GCS}/")

    # 2. Build worker pool spec as JSON
    job_spec = {
        "displayName": JOB_DISPLAY_NAME,
        "jobSpec": {
            "workerPoolSpecs": [{
                "machineSpec": {
                    "machineType":      MACHINE_TYPE,
                    "acceleratorType":  ACCELERATOR_TYPE,
                    "acceleratorCount": ACCELERATOR_COUNT,
                },
                "replicaCount": 1,
                "pythonPackageSpec": {
                    "executorImageUri": TRAIN_IMAGE,
                    "packageUris":      [tarball_gcs_uri],
                    "pythonModule":     "trainer.task",
                    "env": [
                        {"name": "AIP_TRAINING_DATA_URI", "value": training_csv_gcs},
                        {"name": "AIP_MODEL_DIR",         "value": f"{MODEL_ARTEFACT_GCS}/"},
                        {"name": "EPOCHS",                "value": "50"},
                        {"name": "GCS_BUCKET",            "value": GCS_BUCKET},
                    ],
                },
            }],
            "baseOutputDirectory": {"outputUriPrefix": MODEL_ARTEFACT_GCS},
        },
    }

    # 3. Write spec to temp file and submit
    import tempfile
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".json", delete=False
    ) as f:
        json.dump(job_spec, f, indent=2)
        spec_file = f.name

    print(f"\nSubmitting Vertex AI custom training job...")
    result = subprocess.run(
        [
            "gcloud", "ai", "custom-jobs", "create",
            f"--display-name={JOB_DISPLAY_NAME}",
            f"--region={REGION}",
            f"--project={PROJECT_ID}",
            f"--config={spec_file}",
            "--format=json",
        ],
        capture_output=True, text=True,
    )
    os.unlink(spec_file)
    if result.returncode != 0:
        print("gcloud stderr:", result.stderr)
        print("gcloud stdout:", result.stdout)
        raise RuntimeError(f"gcloud custom-jobs create failed (exit {result.returncode})")

    job_info = json.loads(result.stdout)
    job_name  = job_info["name"]          # projects/.../locations/.../customJobs/ID
    job_id    = job_name.split("/")[-1]
    print(f"Job submitted: {job_name}")

    # 4. Poll until complete
    print("Waiting for training to complete (~15-20 min on A100)...")
    while True:
        poll = subprocess.run(
            [
                "gcloud", "ai", "custom-jobs", "describe", job_id,
                f"--region={REGION}", f"--project={PROJECT_ID}", "--format=json",
            ],
            capture_output=True, text=True, check=True,
        )
        info  = json.loads(poll.stdout)
        state = info.get("state", "")
        print(f"  {state}", flush=True)
        if state in ("JOB_STATE_SUCCEEDED", "JOB_STATE_FAILED", "JOB_STATE_CANCELLED"):
            break
        time.sleep(30)

    if state != "JOB_STATE_SUCCEEDED":
        raise RuntimeError(f"Training job ended with state: {state}. "
                           f"Check logs: gcloud ai custom-jobs describe {job_id} "
                           f"--region={REGION}")

    print(f"\nTraining complete. Model saved to: {MODEL_ARTEFACT_GCS}/")
    return job_name


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
        machine_type         = "n1-standard-4",   # CPU-only — inference uses Cloud Run
        min_replica_count    = 0,                 # scale to zero when idle
        max_replica_count    = 1,
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

        job_name = submit_training_job(tarball)

    print("\n=== Phase 8 complete ===")
    print(f"Model artefacts: {MODEL_ARTEFACT_GCS}/")
    print(f"Job: {job_name}")
    print("")
    print("Next step: python3 deploy/09_inference_bridge.py")
    print("  The Cloud Run service (Phase 5) is the inference endpoint.")
    print("  Upload the trained model to GCS for Cloud Run to serve:")
    print(f"    gcloud storage ls {MODEL_ARTEFACT_GCS}/")
