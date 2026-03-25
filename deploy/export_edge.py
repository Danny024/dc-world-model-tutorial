"""
Phase 8b — Export World Model to ONNX for Jetson Edge Deployment
=================================================================
Converts the trained PyTorch checkpoint to ONNX format and uploads it to GCS.
Jetson Nano devices then pull the ONNX file and run it with ONNX Runtime + TensorRT.

Why ONNX / TensorRT?
  - TensorRT compiles the model for the Jetson's specific GPU (Ampere or Maxwell)
  - Achieves 3–5× lower latency than PyTorch on Jetson
  - Reduces memory footprint (INT8 or FP16 quantisation optional)
  - Same ONNX file runs on Cloud CPU (onnxruntime) and Jetson GPU (onnxruntime-gpu)

Optionally also exports the DINO encoder if a --dino-ckpt is provided.
The bridge script on Jetson can then run the full encoder+predictor pipeline locally
without any Cloud Run dependency.

Usage
-----
    # Export world model only:
    python deploy/export_edge.py \\
        --model-ckpt model_output/best_model.pt \\
        --output-dir model_output/edge/ \\
        --gcs-upload

    # Export world model + DINO encoder together:
    python deploy/export_edge.py \\
        --model-ckpt  model_output/best_model.pt \\
        --dino-ckpt   model_output/dino_encoder.pt \\
        --output-dir  model_output/edge/ \\
        --gcs-upload

Output files
------------
    model_output/edge/world_model.onnx
    model_output/edge/dino_encoder.onnx    (if --dino-ckpt provided)
    model_output/edge/metadata.json        (window_size, features, horizons, versions)

GCS upload path:
    gs://hmth391-omniverse-assets/models/edge/
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import pathlib
import sys

import numpy as np
import torch

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("export_edge")

# Allow running from repo root
sys.path.insert(0, str(pathlib.Path(__file__).parent))


# ── ONNX export helpers ───────────────────────────────────────────────────────

def export_world_model_onnx(
    ckpt_path:  str,
    output_dir: pathlib.Path,
    opset:      int = 17,
) -> pathlib.Path:
    """Export the PyTorch world model to ONNX."""
    from world_model import load_model, WINDOW_SIZE, HORIZONS  # noqa: PLC0415

    log.info("Loading world model from %s ...", ckpt_path)
    ckpt      = torch.load(ckpt_path, map_location="cpu")
    model     = load_model(ckpt_path, device="cpu")
    num_feats = ckpt.get("num_features", 4)
    win_size  = ckpt.get("window_size",  WINDOW_SIZE)

    model.eval()
    dummy_input = torch.zeros(1, win_size, num_feats)

    onnx_path = output_dir / "world_model.onnx"
    log.info("Exporting world model to ONNX: %s", onnx_path)

    torch.onnx.export(
        model,
        dummy_input,
        str(onnx_path),
        opset_version = opset,
        input_names   = ["sensor_window"],
        # Each horizon head is a separate output
        output_names  = list(HORIZONS.keys()),
        dynamic_axes  = {
            "sensor_window": {0: "batch_size"},
            **{name: {0: "batch_size"} for name in HORIZONS},
        },
        export_params = True,
        do_constant_folding = True,
    )
    log.info("World model exported: %s  (%.1f KB)", onnx_path,
             onnx_path.stat().st_size / 1024)
    return onnx_path


def export_dino_encoder_onnx(
    ckpt_path:  str,
    output_dir: pathlib.Path,
    opset:      int = 17,
) -> pathlib.Path:
    """Export the DINO encoder to ONNX (patch-token output mode)."""
    from dino_encoder import load_encoder, WINDOW_SIZE, NUM_FEATURES  # noqa: PLC0415

    log.info("Loading DINO encoder from %s ...", ckpt_path)
    encoder = load_encoder(ckpt_path, device="cpu")
    encoder.eval()

    dummy_input = torch.zeros(1, WINDOW_SIZE, NUM_FEATURES)

    onnx_path = output_dir / "dino_encoder.onnx"
    log.info("Exporting DINO encoder to ONNX: %s", onnx_path)

    # Export get_patch_tokens() output (not the CLS-only forward())
    # Wrap in a thin module to select the correct output
    class PatchTokenWrapper(torch.nn.Module):
        def __init__(self, enc):
            super().__init__()
            self.enc = enc
        def forward(self, x):
            return self.enc.get_patch_tokens(x)

    wrapper = PatchTokenWrapper(encoder)
    torch.onnx.export(
        wrapper,
        dummy_input,
        str(onnx_path),
        opset_version = opset,
        input_names   = ["raw_sensor_window"],
        output_names  = ["patch_tokens"],
        dynamic_axes  = {
            "raw_sensor_window": {0: "batch_size"},
            "patch_tokens":      {0: "batch_size"},
        },
        export_params       = True,
        do_constant_folding = True,
    )
    log.info("DINO encoder exported: %s  (%.1f KB)", onnx_path,
             onnx_path.stat().st_size / 1024)
    return onnx_path


def verify_onnx(onnx_path: pathlib.Path):
    """Run a basic shape-check with onnxruntime to catch export errors early."""
    try:
        import onnxruntime as ort   # noqa: PLC0415
        sess = ort.InferenceSession(str(onnx_path), providers=["CPUExecutionProvider"])
        inputs  = {i.name: np.zeros([1] + list(i.shape[1:]), dtype=np.float32)
                   for i in sess.get_inputs()}
        outputs = sess.run(None, inputs)
        log.info("  ONNX verification OK — %d output(s), shapes: %s",
                 len(outputs), [list(o.shape) for o in outputs])
    except ImportError:
        log.warning("  onnxruntime not installed — skipping verification. "
                    "Run: pip install onnxruntime")


def write_metadata(
    output_dir: pathlib.Path,
    model_ckpt: str,
    dino_ckpt:  str | None,
):
    """Write a JSON metadata file for the Jetson edge deployment."""
    from world_model import WINDOW_SIZE, FEATURE_COLS, HORIZONS  # noqa: PLC0415

    project   = os.environ.get("GCP_PROJECT_ID", "hmth391")
    ar_models = os.environ.get("AR_REPO_MODELS", "world-model-repo")
    region    = os.environ.get("GCP_REGION",     "us-central1")
    gcs_bucket = os.environ.get("GCS_BUCKET",    f"{project}-omniverse-assets")

    ckpt = torch.load(model_ckpt, map_location="cpu")
    meta = {
        "window_size":   ckpt.get("window_size",  WINDOW_SIZE),
        "feature_cols":  ckpt.get("feature_cols", FEATURE_COLS),
        "num_features":  ckpt.get("num_features", len(FEATURE_COLS)),
        "horizons":      ckpt.get("horizons",     list(HORIZONS.keys())),
        "val_loss":      ckpt.get("val_loss"),
        "epoch":         ckpt.get("epoch"),
        "dino_encoder":  dino_ckpt is not None,
        "gcs_edge_path": f"gs://{gcs_bucket}/models/edge/",
        "ar_image":      f"{region}-docker.pkg.dev/{project}/{ar_models}/"
                         "datacenter-inference:jetson-latest",
    }
    meta_path = output_dir / "metadata.json"
    with open(meta_path, "w") as f:
        json.dump(meta, f, indent=2)
    log.info("Metadata written: %s", meta_path)


def upload_to_gcs(local_dir: pathlib.Path, gcs_prefix: str):
    """Upload all files in local_dir to GCS."""
    from google.cloud import storage  # noqa: PLC0415
    client = storage.Client()

    no_scheme  = gcs_prefix.removeprefix("gs://")
    bucket_name, prefix = no_scheme.split("/", 1)
    bucket = client.bucket(bucket_name)

    for file_path in local_dir.iterdir():
        blob_name = f"{prefix.rstrip('/')}/{file_path.name}"
        blob = bucket.blob(blob_name)
        blob.upload_from_filename(str(file_path))
        log.info("Uploaded: gs://%s/%s", bucket_name, blob_name)


# ── CLI ───────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Phase 8b — Export World Model to ONNX for Jetson edge deployment"
    )
    parser.add_argument("--model-ckpt",  required=True,
                        help="Path to best_model.pt (Phase 7 output)")
    parser.add_argument("--dino-ckpt",   default=None,
                        help="Path to dino_encoder.pt (Phase 7a output, optional)")
    parser.add_argument("--output-dir",  default="model_output/edge",
                        help="Local directory to write ONNX files")
    parser.add_argument("--opset",       type=int, default=17,
                        help="ONNX opset version (default: 17)")
    parser.add_argument("--gcs-upload",  action="store_true",
                        help="Upload exported files to "
                             "gs://hmth391-omniverse-assets/models/edge/")
    parser.add_argument("--gcs-prefix",
                        default="gs://hmth391-omniverse-assets/models/edge",
                        help="GCS path to upload artefacts to")
    args = parser.parse_args()

    out_dir = pathlib.Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    # Export world model
    wm_onnx = export_world_model_onnx(args.model_ckpt, out_dir, opset=args.opset)
    verify_onnx(wm_onnx)

    # Export DINO encoder (optional)
    if args.dino_ckpt:
        dino_onnx = export_dino_encoder_onnx(args.dino_ckpt, out_dir, opset=args.opset)
        verify_onnx(dino_onnx)

    # Metadata
    write_metadata(out_dir, args.model_ckpt, args.dino_ckpt)

    # GCS upload
    if args.gcs_upload:
        log.info("Uploading edge artefacts to %s ...", args.gcs_prefix)
        upload_to_gcs(out_dir, args.gcs_prefix)
        log.info("Upload complete.")
        log.info("")
        log.info("Jetson Nano pull command:")
        log.info("  gcloud storage cp -r %s /opt/models/", args.gcs_prefix)
        log.info("")
        log.info("Run inference on Jetson:")
        log.info("  MODEL_ONNX_PATH=/opt/models/edge/world_model.onnx "
                 "python3 inference_server.py")
    else:
        log.info("")
        log.info("Exported files are in: %s", out_dir)
        log.info("Add --gcs-upload to push to GCS for Jetson deployment.")
