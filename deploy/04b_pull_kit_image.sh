#!/usr/bin/env bash
# Phase 4b — Pull NVIDIA Kit Streaming image from NGC and push to Artifact Registry
# ──────────────────────────────────────────────────────────────────────────────────
# Prerequisites:
#   - NGC_API_KEY set in deploy/config.env  (ngc.nvidia.com → Setup → Generate API Key)
#   - Phase 2 complete (Artifact Registry created)
#   - gcloud authenticated
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

NVIDIA_KIT_IMAGE="nvcr.io/nvidia/omniverse/usd-viewer:109.0.2"

echo "=== Phase 4b: Pull Kit Streaming Image and Push to Artifact Registry ==="
echo "  Source : ${NVIDIA_KIT_IMAGE}"
echo "  Target : ${IMAGE_URI}"
echo ""

# ── 1. Validate NGC API key ───────────────────────────────────────────────────
if [[ -z "${NGC_API_KEY:-}" ]]; then
    echo "ERROR: NGC_API_KEY is not set in deploy/config.env."
    echo ""
    echo "  1. Go to https://ngc.nvidia.com and sign in"
    echo "  2. Click your avatar → Setup → Generate API Key"
    echo "  3. Add to deploy/config.env:"
    echo "       export NGC_API_KEY=\"your-key-here\""
    exit 1
fi

# ── 2. Authenticate with NGC ──────────────────────────────────────────────────
echo "Authenticating with NGC..."
echo "${NGC_API_KEY}" | docker login nvcr.io \
    --username='$oauthtoken' \
    --password-stdin
echo "NGC login successful."

# ── 3. Pull Kit Streaming image ───────────────────────────────────────────────
echo ""
echo "Pulling NVIDIA Kit Streaming image (~10 GB, uses layer cache on repeat runs)..."
echo ""
echo "NOTE: If you see 'Access Denied', accept the EULA at:"
echo "  https://catalog.ngc.nvidia.com/orgs/nvidia/containers/usd-viewer"
echo "  → click 'Get Container' → accept the licence → then re-run this script."
echo ""
docker pull "${NVIDIA_KIT_IMAGE}"
echo "Pull complete."

# ── 4. Tag for Artifact Registry ──────────────────────────────────────────────
echo ""
echo "Tagging for Artifact Registry..."
docker tag "${NVIDIA_KIT_IMAGE}" "${IMAGE_URI}"
echo "Tagged: ${IMAGE_URI}"

# ── 5. Authenticate with Artifact Registry and push ───────────────────────────
echo ""
echo "Authenticating with Artifact Registry..."
gcloud auth configure-docker "${GCP_REGION}-docker.pkg.dev" --quiet

echo ""
echo "Pushing to Artifact Registry..."
docker push "${IMAGE_URI}"

echo ""
echo "=== Phase 4b complete ==="
echo "Kit Streaming image pushed: ${IMAGE_URI}"
echo ""
echo "Next step: bash deploy/05b_deploy_kit_vm.sh"
