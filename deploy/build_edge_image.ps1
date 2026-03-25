# =============================================================
# Phase 8c — Build & Push Jetson Nano Edge Inference Image
# =============================================================
# Uses Docker buildx to cross-compile a linux/arm64 image on an
# x86 machine and push it to Artifact Registry.
#
# Prerequisites (one-time setup):
#   1. gcloud auth login
#   2. gcloud auth configure-docker us-central1-docker.pkg.dev
#   3. docker buildx create --name jetson-builder --driver docker-container --use
#   4. docker buildx inspect --bootstrap
#
# Usage:
#   . deploy\config.ps1
#   .\deploy\build_edge_image.ps1
# =============================================================

$ErrorActionPreference = "Stop"

# ── Configuration (overridable via env) ───────────────────────────────────────
$GCP_PROJECT_ID = if ($env:GCP_PROJECT_ID) { $env:GCP_PROJECT_ID } else { "hmth391" }
$AR_REPO_MODELS = if ($env:AR_REPO_MODELS) { $env:AR_REPO_MODELS } else { "world-model-repo" }
$GCP_REGION     = if ($env:GCP_REGION)     { $env:GCP_REGION }     else { "us-central1" }
$IMAGE_NAME     = "datacenter-inference"
$IMAGE_TAG      = "jetson-latest"

$REGISTRY   = "${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT_ID}/${AR_REPO_MODELS}"
$FULL_IMAGE = "${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"

Write-Host "============================================================"
Write-Host "  Building Jetson edge image"
Write-Host "  Target  : $FULL_IMAGE"
Write-Host "  Platform: linux/arm64"
Write-Host "============================================================"

# ── Authenticate Artifact Registry ───────────────────────────────────────────
Write-Host "Authenticating Artifact Registry..."
gcloud auth configure-docker "${GCP_REGION}-docker.pkg.dev" --quiet
if ($LASTEXITCODE -ne 0) { throw "gcloud auth configure-docker failed" }

# ── Ensure buildx builder exists ─────────────────────────────────────────────
$builderCheck = docker buildx inspect jetson-builder 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "Creating multi-arch buildx builder..."
    docker buildx create --name jetson-builder --driver docker-container --use
    if ($LASTEXITCODE -ne 0) { throw "docker buildx create failed" }
    docker buildx inspect --bootstrap
    if ($LASTEXITCODE -ne 0) { throw "docker buildx inspect --bootstrap failed" }
} else {
    Write-Host "Using existing buildx builder: jetson-builder"
    docker buildx use jetson-builder
}

# ── Build and push ────────────────────────────────────────────────────────────
Write-Host "Building and pushing (this may take 10-20 min on first run)..."
docker buildx build `
    --platform linux/arm64 `
    --file Dockerfile.jetson `
    --tag $FULL_IMAGE `
    --push `
    .
if ($LASTEXITCODE -ne 0) { throw "docker buildx build failed" }

Write-Host ""
Write-Host "============================================================"
Write-Host "  Image pushed successfully!"
Write-Host "  $FULL_IMAGE"
Write-Host "============================================================"
Write-Host ""
Write-Host "On Jetson Nano, run:"
Write-Host ""
Write-Host "  # Pull the image"
Write-Host "  docker pull $FULL_IMAGE"
Write-Host ""
Write-Host "  # Download ONNX model from GCS"
Write-Host "  mkdir -p /opt/models/edge"
Write-Host "  gcloud storage cp -r gs://${GCP_PROJECT_ID}-omniverse-assets/models/edge/ /opt/models/"
Write-Host ""
Write-Host "  # Start the inference server"
Write-Host "  docker run -d ``"
Write-Host "    --runtime nvidia ``"
Write-Host "    -p 8080:8080 ``"
Write-Host "    -e MODEL_ONNX_PATH=/app/models/edge/world_model.onnx ``"
Write-Host "    -v /opt/models:/app/models ``"
Write-Host "    --restart unless-stopped ``"
Write-Host "    $FULL_IMAGE"
