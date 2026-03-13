"""
Inference Server — Data Center World Model
==========================================
Lightweight Flask API that serves the trained Temporal Transformer.

Endpoints:
    GET  /health              → {"status": "ok", "model_loaded": true}
    POST /predict             → {"window": [[12 × 4 floats]]}
                              ← {"1h": 0.12, "6h": 0.34, "24h": 0.67}
    POST /predict/batch       → {"windows": [[[12 × 4 floats]], ...]}
                              ← [{"1h": ..., "6h": ..., "24h": ...}, ...]

Model input:  12 timesteps × 4 features [temp_c, power_kw, disk_health, cpu_load]
Model output: failure probability per horizon (1 h / 6 h / 24 h ahead)

Usage:
    # Local (model on disk)
    MODEL_PATH=model_output/best_model.pt python deploy/inference_server.py

    # Docker with local volume mount
    docker run -p 8080:8080 \\
        -v $(pwd)/model_output:/app/model_output \\
        datacenter-inference:latest

    # Docker with GCS auto-download
    docker run -p 8080:8080 \\
        -e MODEL_GCS_URI=gs://YOUR_BUCKET/models/best_model.pt \\
        datacenter-inference:latest
"""

from __future__ import annotations

import logging
import os
import pathlib
import sys

import numpy as np
from flask import Flask, jsonify, request

# Allow running as `python deploy/inference_server.py` from the repo root
sys.path.insert(0, str(pathlib.Path(__file__).parent))

from world_model import (  # noqa: E402
    DataCenterWorldModel,
    FEATURE_COLS,
    NUM_FEATURES,
    WINDOW_SIZE,
    load_model,
    predict,
)

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)

app = Flask(__name__)

_model: DataCenterWorldModel | None = None
_device = "cpu"


# ── Model loading ─────────────────────────────────────────────────────────────

def _resolve_model_path() -> pathlib.Path:
    """Return path to best_model.pt, downloading from GCS if necessary."""

    # 1. Explicit env var
    env_path = os.environ.get("MODEL_PATH")
    if env_path:
        p = pathlib.Path(env_path)
        if p.exists():
            return p
        log.warning("MODEL_PATH=%s not found, trying other sources.", env_path)

    # 2. Default location inside the container / repo
    default = pathlib.Path("/app/model_output/best_model.pt")
    if not default.exists():
        default = pathlib.Path(__file__).parent.parent / "model_output" / "best_model.pt"
    if default.exists():
        return default

    # 3. Download from GCS
    gcs_uri = os.environ.get("MODEL_GCS_URI")
    if gcs_uri:
        log.info("Downloading model from GCS: %s", gcs_uri)
        try:
            from google.cloud import storage as gcs_lib  # noqa: PLC0415

            dest = pathlib.Path("/app/model_output/best_model.pt")
            dest.parent.mkdir(parents=True, exist_ok=True)
            blob_path = gcs_uri.removeprefix("gs://")
            bucket_name, blob_name = blob_path.split("/", 1)
            gcs_lib.Client().bucket(bucket_name).blob(blob_name).download_to_filename(str(dest))
            log.info("Model saved to %s", dest)
            return dest
        except Exception:
            log.exception("GCS download failed.")

    raise FileNotFoundError(
        "Model checkpoint not found. Provide it via one of:\n"
        "  -e MODEL_PATH=/path/to/best_model.pt\n"
        "  -v /host/model_output:/app/model_output\n"
        "  -e MODEL_GCS_URI=gs://bucket/path/best_model.pt"
    )


def get_model() -> DataCenterWorldModel:
    global _model
    if _model is None:
        ckpt_path = _resolve_model_path()
        log.info("Loading model from %s ...", ckpt_path)
        _model = load_model(str(ckpt_path), device=_device)
        log.info("Model loaded. Ready to serve predictions.")
    return _model


# ── Routes ────────────────────────────────────────────────────────────────────

@app.get("/health")
def health():
    try:
        get_model()
        return jsonify({"status": "ok", "model_loaded": True})
    except Exception as exc:
        return jsonify({"status": "error", "message": str(exc)}), 503


@app.post("/predict")
def predict_single():
    """
    Request body:
        {"window": [[temp_c, power_kw, disk_health, cpu_load], ...]}  # 12 rows
    Response:
        {"1h": 0.12, "6h": 0.34, "24h": 0.67}
    """
    data = request.get_json(force=True)
    if "window" not in data:
        return jsonify({"error": "Missing required field: 'window'"}), 400

    window = np.array(data["window"], dtype=np.float32)
    if window.shape != (WINDOW_SIZE, NUM_FEATURES):
        return jsonify({
            "error": (
                f"'window' must have shape ({WINDOW_SIZE}, {NUM_FEATURES}). "
                f"Got {list(window.shape)}. "
                f"Features must be: {FEATURE_COLS}"
            )
        }), 400

    try:
        probs = predict(get_model(), window, device=_device)
        return jsonify(probs)
    except Exception as exc:
        log.exception("Prediction error")
        return jsonify({"error": str(exc)}), 500


@app.post("/predict/batch")
def predict_batch():
    """
    Request body:
        {"windows": [<window>, <window>, ...]}  # each window is 12×4
    Response:
        [{"1h": ..., "6h": ..., "24h": ...}, ...]
    """
    data = request.get_json(force=True)
    if "windows" not in data:
        return jsonify({"error": "Missing required field: 'windows'"}), 400

    results = []
    for i, w in enumerate(data["windows"]):
        window = np.array(w, dtype=np.float32)
        if window.shape != (WINDOW_SIZE, NUM_FEATURES):
            return jsonify({
                "error": (
                    f"windows[{i}] must have shape ({WINDOW_SIZE}, {NUM_FEATURES}). "
                    f"Got {list(window.shape)}."
                )
            }), 400
        results.append(predict(get_model(), window, device=_device))

    return jsonify(results)


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    # Eagerly load the model so the first request doesn't stall
    try:
        get_model()
    except FileNotFoundError as exc:
        log.warning("Model not loaded at startup: %s", exc)

    port = int(os.environ.get("PORT", 8080))
    log.info("Starting inference server on port %d", port)
    app.run(host="0.0.0.0", port=port)
