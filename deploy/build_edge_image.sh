#!/usr/bin/env bash
# =============================================================
# Phase 8c — Build & Push Jetson Nano Edge Inference Image
# =============================================================
# Uses Docker buildx to cross-compile a linux/arm64 image on an
# x86 machine and push it to Artifact Registry.
#
# Prerequisites (one-time setup):
#   1. gcloud auth login && gcloud auth configure-docker us-central1-docker.pkg.dev
#   2. docker buildx create --name jetson-builder --driver docker-container --use
#   3. docker buildx inspect --bootstrap
#
# Usage:
#   source deploy/config.env
#   bash deploy/build_edge_image.sh
# =============================================================

set -euo pipefail

# ── Configuration (overridable via env) ───────────────────────────────────────
GCP_PROJECT_ID="${GCP_PROJECT_ID:-hmth391}"
AR_REPO_MODELS="${AR_REPO_MODELS:-world-model-repo}"
GCP_REGION="${GCP_REGION:-us-central1}"
IMAGE_NAME="datacenter-inference"
IMAGE_TAG="jetson-latest"

REGISTRY="${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT_ID}/${AR_REPO_MODELS}"
FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"

echo "============================================================"
echo "  Building Jetson edge image"
echo "  Target : ${FULL_IMAGE}"
echo "  Platform: linux/arm64"
echo "============================================================"

# ── Authenticate Artifact Registry ───────────────────────────────────────────
echo "Authenticating Artifact Registry..."
gcloud auth configure-docker "${GCP_REGION}-docker.pkg.dev" --quiet

# ── Ensure buildx builder exists ─────────────────────────────────────────────
if ! docker buildx inspect jetson-builder &>/dev/null; then
    echo "Creating multi-arch buildx builder..."
    docker buildx create --name jetson-builder --driver docker-container --use
    docker buildx inspect --bootstrap
else
    echo "Using existing buildx builder: jetson-builder"
    docker buildx use jetson-builder
fi

# ── Build and push ────────────────────────────────────────────────────────────
echo "Building and pushing (this may take 10–20 min on first run)..."
docker buildx build \
    --platform linux/arm64 \
    --file Dockerfile.jetson \
    --tag "${FULL_IMAGE}" \
    --push \
    .

echo ""
echo "============================================================"
echo "  Image pushed successfully!"
echo "  ${FULL_IMAGE}"
echo "============================================================"
echo ""
echo "On Jetson Nano, run:"
echo ""
echo "  # Pull the image"
echo "  docker pull ${FULL_IMAGE}"
echo ""
echo "  # Download ONNX model from GCS"
echo "  mkdir -p /opt/models/edge"
echo "  gcloud storage cp -r gs://${GCP_PROJECT_ID}-omniverse-assets/models/edge/ /opt/models/"
echo ""
echo "  # Start the inference server"
echo "  docker run -d \\"
echo "    --runtime nvidia \\"
echo "    -p 8080:8080 \\"
echo "    -e MODEL_ONNX_PATH=/app/models/edge/world_model.onnx \\"
echo "    -v /opt/models:/app/models \\"
echo "    --restart unless-stopped \\"
echo "    ${FULL_IMAGE}"
