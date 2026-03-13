# ── ML Inference Service ──────────────────────────────────────────────────────
# Serves the Temporal Transformer world model as a REST API.
#
# Endpoints:
#   GET  /health              → {"status": "ok", "model_loaded": true}
#   POST /predict             → {"window": [[12 × 4 sensor values]]}
#                             ← {"1h": 0.12, "6h": 0.34, "24h": 0.67}
#   POST /predict/batch       → {"windows": [...]}
#                             ← [{"1h": ..., "6h": ..., "24h": ...}, ...]
#
# Build:
#   docker build -t datacenter-inference:latest .
#
# Run — local model on disk:
#   docker run -p 8080:8080 \
#     -v $(pwd)/model_output:/app/model_output \
#     datacenter-inference:latest
#
# Run — auto-download model from GCS:
#   docker run -p 8080:8080 \
#     -e MODEL_GCS_URI=gs://YOUR_BUCKET/models/best_model.pt \
#     datacenter-inference:latest
# ─────────────────────────────────────────────────────────────────────────────

FROM python:3.11-slim

WORKDIR /app

# Install CPU-only PyTorch first (separate layer for better cache reuse),
# then the remaining lightweight packages.
RUN pip install --no-cache-dir \
        torch --index-url https://download.pytorch.org/whl/cpu

COPY requirements.txt .
RUN pip install --no-cache-dir \
        numpy \
        pandas \
        flask>=3.0.0 \
        google-cloud-storage

# Copy model source and inference server
COPY deploy/07_world_model.py  ./world_model.py
COPY deploy/inference_server.py ./inference_server.py

# Placeholder directory — model is provided at runtime via:
#   -v /host/model_output:/app/model_output   (local mount)
#   -e MODEL_GCS_URI=gs://...                  (auto-download)
#   -e MODEL_PATH=/custom/path/best_model.pt   (explicit path)
RUN mkdir -p model_output

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
    CMD python -c \
        "import urllib.request; urllib.request.urlopen('http://localhost:8080/health')" \
        || exit 1

CMD ["python", "inference_server.py"]
