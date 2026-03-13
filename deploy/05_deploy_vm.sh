#!/usr/bin/env bash
# Phase 5 — Deploy ML Inference Service to Cloud Run
# ────────────────────────────────────────────────────
# Deploys the datacenter-inference container as a managed Cloud Run service.
# No VM, no GPU, no NGC account required. Scales to zero when idle.
#
# Prerequisites:
#   - Phase 4 complete (image in Artifact Registry)
#   - Phase 7 or 8 complete (best_model.pt uploaded to GCS)
#   - gcloud authenticated with project set
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

SERVICE_NAME="datacenter-inference"
MODEL_GCS_URI="${MODEL_ARTEFACT_GCS}/best_model.pt"

echo "=== Phase 5: Deploy Inference Service to Cloud Run ==="
echo "  Service : ${SERVICE_NAME}"
echo "  Image   : ${INFERENCE_IMAGE_URI}"
echo "  Model   : ${MODEL_GCS_URI}"
echo "  Region  : ${GCP_REGION}"
echo ""

# ── 1. Enable Cloud Run API if not already enabled ────────────────────────────
echo "Enabling Cloud Run API..."
gcloud services enable run.googleapis.com \
    --project="${GCP_PROJECT_ID}" --quiet

# ── 2. Deploy to Cloud Run ────────────────────────────────────────────────────
echo ""
echo "Deploying to Cloud Run (this takes ~2 minutes on first deploy)..."
gcloud run deploy "${SERVICE_NAME}" \
    --image="${INFERENCE_IMAGE_URI}" \
    --region="${GCP_REGION}" \
    --project="${GCP_PROJECT_ID}" \
    --platform=managed \
    --set-env-vars="MODEL_GCS_URI=${MODEL_GCS_URI}" \
    --memory=2Gi \
    --cpu=2 \
    --timeout=60 \
    --min-instances=0 \
    --max-instances=10 \
    --allow-unauthenticated \
    --quiet

# ── 3. Get service URL ────────────────────────────────────────────────────────
SERVICE_URL=$(gcloud run services describe "${SERVICE_NAME}" \
    --region="${GCP_REGION}" \
    --project="${GCP_PROJECT_ID}" \
    --format="get(status.url)")

echo ""
echo "=== Phase 5 complete ==="
echo ""
echo "Inference service is live:"
echo ""
echo "  Health check : ${SERVICE_URL}/health"
echo "  Predict      : POST ${SERVICE_URL}/predict"
echo "  Batch predict: POST ${SERVICE_URL}/predict/batch"
echo ""
echo "Quick test:"
echo "  curl ${SERVICE_URL}/health"
echo ""
echo "Example prediction (replace with real sensor values):"
cat <<EXAMPLE
  curl -X POST ${SERVICE_URL}/predict \\
    -H "Content-Type: application/json" \\
    -d '{
      "window": [
        [23.4, 5.82, 0.97, 0.42],
        [24.1, 5.90, 0.96, 0.44],
        [25.0, 6.10, 0.95, 0.51],
        [26.2, 6.30, 0.94, 0.55],
        [27.8, 6.60, 0.93, 0.60],
        [29.5, 6.90, 0.91, 0.65],
        [31.2, 7.10, 0.89, 0.70],
        [33.0, 7.40, 0.87, 0.74],
        [35.1, 7.70, 0.84, 0.78],
        [37.4, 8.00, 0.81, 0.82],
        [40.0, 8.40, 0.77, 0.86],
        [43.2, 8.90, 0.72, 0.90]
      ]
    }'
EXAMPLE
echo ""
echo "Stop billing when done:"
echo "  gcloud run services delete ${SERVICE_NAME} --region=${GCP_REGION}"
echo ""
echo "Next step: python3 deploy/06_generate_failure_data.py"
