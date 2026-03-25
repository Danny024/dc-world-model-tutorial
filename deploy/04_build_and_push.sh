#!/usr/bin/env bash
# Phase 4 — Build ML Inference Container and Push to Artifact Registry
# ─────────────────────────────────────────────────────────────────────
# Builds the lightweight Python inference server (Dockerfile in repo root)
# and pushes it to Artifact Registry. No NVIDIA SDK or NGC account required.
#
# Prerequisites:
#   - Docker running locally
#   - gcloud authenticated  (gcloud auth login)
#   - Phase 2 complete (Artifact Registry repository created)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/config.env"

echo "=== Phase 4: Build and Push ML Inference Container ==="
echo "  Image : ${IMAGE_URI}"
echo "  Source: ${REPO_ROOT}/Dockerfile"
echo ""

# ── 1. Build ──────────────────────────────────────────────────────────────────
echo "Building Docker image..."
docker build -t "datacenter-inference:latest" "${REPO_ROOT}"
echo "Build complete."

# ── 2. Tag for Artifact Registry ──────────────────────────────────────────────
echo ""
echo "Tagging image for Artifact Registry..."
docker tag "datacenter-inference:latest" "${IMAGE_URI}"
echo "Tagged: ${IMAGE_URI}"

# ── 3. Authenticate Docker with Artifact Registry ─────────────────────────────
echo ""
echo "Authenticating with Artifact Registry..."
gcloud auth configure-docker "${GCP_REGION}-docker.pkg.dev" --quiet

# ── 4. Push ───────────────────────────────────────────────────────────────────
echo ""
echo "Pushing to Artifact Registry..."
docker push "${IMAGE_URI}"

echo ""
echo "=== Phase 4 complete ==="
echo "Image pushed: ${IMAGE_URI}"
echo ""
echo "Test locally:"
echo "  docker run -p 8080:8080 \\"
echo "    -v \$(pwd)/model_output:/app/model_output \\"
echo "    datacenter-inference:latest"
echo ""
echo "Deploy to Cloud Run (serverless, scales to zero):"
echo "  gcloud run deploy datacenter-inference \\"
echo "    --image ${IMAGE_URI} \\"
echo "    --region ${GCP_REGION} \\"
echo "    --platform managed \\"
echo "    --set-env-vars MODEL_GCS_URI=${MODEL_ARTEFACT_GCS}/best_model.pt \\"
echo "    --allow-unauthenticated"
echo ""
echo "Next step: bash deploy/05_deploy_vm.sh"
