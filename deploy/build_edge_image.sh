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

# ── JetPack version selector ──────────────────────────────────────────────────
# Set JETPACK_VERSION=4.6 (or 4) for students running JetPack 4.6 (Legacy).
# Default is JetPack 5.x.
#
# JetPack 5.x (default):  L4T R35.4.1, CUDA 12.x, TRT 8.5+, Python 3.8+
#   → Dockerfile.jetson, tag: jetson-latest
#
# JetPack 4.6 (legacy):   L4T R32.7.1, CUDA 10.2, TRT 8.2.x, Python 3.6
#   → Dockerfile.jetson46, tag: jetson-jp46-latest
#   → ONNX model must be exported at --opset 13 (not 17) for trtexec compat
#
JETPACK_VERSION="${JETPACK_VERSION:-5}"

if [ "${JETPACK_VERSION}" = "4" ] || [ "${JETPACK_VERSION}" = "4.6" ]; then
    DOCKERFILE="Dockerfile.jetson46"
    IMAGE_TAG="jetson-jp46-latest"
    JP_LABEL="4.6 (L4T R32.7.1, CUDA 10.2, TRT 8.2.x)"
    ONNX_HINT="Use --opset 13 when exporting: --output-name master_v1_jp46.onnx --opset 13"
else
    DOCKERFILE="Dockerfile.jetson"
    IMAGE_TAG="jetson-latest"
    JP_LABEL="5.x (L4T R35.4.1, CUDA 12.x, TRT 8.5+)"
    ONNX_HINT="Use --output-name master_v1.onnx --opset 17 (default)"
fi

REGISTRY="${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT_ID}/${AR_REPO_MODELS}"
FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"

echo "============================================================"
echo "  Building Jetson edge image"
echo "  JetPack  : ${JP_LABEL}"
echo "  Target   : ${FULL_IMAGE}"
echo "  Platform : linux/arm64"
echo "  ONNX note: ${ONNX_HINT}"
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
    --file "${DOCKERFILE}" \
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

if [ "${JETPACK_VERSION}" = "4" ] || [ "${JETPACK_VERSION}" = "4.6" ]; then
    echo "  # Download opset-13 ONNX model (JetPack 4.6 — no auth required)"
    echo "  mkdir -p /opt/models/public"
    BUCKET="${GCP_PROJECT_ID}-omniverse-assets"
    echo "  wget -O /opt/models/public/master_v1_jp46.onnx \\"
    echo "    https://storage.googleapis.com/${BUCKET}/models/public/master_v1_jp46.onnx"
    echo ""
    echo "  # (Optional) Compile TRT engine on the Nano"
    echo "  ONNX_PATH=/opt/models/public/master_v1_jp46.onnx \\"
    echo "  JETPACK_VERSION=4.6 bash deploy/compile_trt_engine.sh"
    echo ""
    echo "  # Start the inference server"
    echo "  docker run -d \\"
    echo "    --runtime nvidia \\"
    echo "    -p 8080:8080 \\"
    echo "    -e MODEL_ONNX_PATH=/opt/models/public/master_v1_jp46.onnx \\"
    echo "    -v /opt/models:/opt/models \\"
    echo "    --restart unless-stopped \\"
    echo "    ${FULL_IMAGE}"
else
    BUCKET="${GCP_PROJECT_ID}-omniverse-assets"
    echo "  # Download ONNX model — no auth required"
    echo "  mkdir -p /opt/models/public"
    echo "  wget -O /opt/models/public/master_v1.onnx \\"
    echo "    https://storage.googleapis.com/${BUCKET}/models/public/master_v1.onnx"
    echo ""
    echo "  # (Optional) Compile TRT engine on the Nano for 3-5x faster inference"
    echo "  ONNX_PATH=/opt/models/public/master_v1.onnx bash deploy/compile_trt_engine.sh"
    echo ""
    echo "  # Start the inference server"
    echo "  docker run -d \\"
    echo "    --runtime nvidia \\"
    echo "    -p 8080:8080 \\"
    echo "    -e MODEL_ONNX_PATH=/opt/models/public/master_v1.onnx \\"
    echo "    -v /opt/models:/opt/models \\"
    echo "    --restart unless-stopped \\"
    echo "    ${FULL_IMAGE}"
fi
