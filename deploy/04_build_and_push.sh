#!/usr/bin/env bash
# Phase 4 — Build ML Inference Container and Push to Artifact Registry
# ─────────────────────────────────────────────────────────────────────
# Builds the lightweight Python inference server (Dockerfile in repo root)
# and pushes it to Artifact Registry. No NVIDIA SDK or NGC account required.
#
# In Google Cloud Shell: uses Cloud Build (avoids Docker networking issues).
# On a local machine with Docker: builds locally and pushes.
#
# Prerequisites:
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

# ── Detect Google Cloud Shell ─────────────────────────────────────────────────
if [ "${CLOUD_SHELL:-}" = "true" ] || [ -n "${DEVSHELL_PROJECT_ID:-}" ]; then
    # ── Cloud Shell: use Cloud Build (avoids local Docker networking issues) ──
    echo "Cloud Shell detected — using Cloud Build."
    echo "Submitting build to Google Cloud Build..."
    echo "(Build happens on GCP infrastructure — typically 5–8 minutes)"
    echo ""

    gcloud builds submit \
        --tag "${IMAGE_URI}" \
        --project "${GCP_PROJECT_ID}" \
        "${REPO_ROOT}"

    echo ""
    echo "=== Phase 4 complete ==="
    echo "Image pushed via Cloud Build: ${IMAGE_URI}"
else
    # ── Local machine: build with Docker and push ─────────────────────────────
    echo "Local machine detected — using Docker."

    # 1. Build
    echo "Building Docker image..."
    docker build -t "datacenter-inference:latest" "${REPO_ROOT}"
    echo "Build complete."

    # 2. Tag
    echo ""
    echo "Tagging for Artifact Registry..."
    docker tag "datacenter-inference:latest" "${IMAGE_URI}"

    # 3. Auth
    echo "Authenticating with Artifact Registry..."
    gcloud auth configure-docker "${GCP_REGION}-docker.pkg.dev" --quiet

    # 4. Push
    echo "Pushing to Artifact Registry..."
    docker push "${IMAGE_URI}"

    echo ""
    echo "=== Phase 4 complete ==="
    echo "Image pushed: ${IMAGE_URI}"
fi

echo ""
echo "Test locally (if Docker available):"
echo "  docker run -p 8080:8080 \\"
echo "    -v \$(pwd)/model_output:/app/model_output \\"
echo "    datacenter-inference:latest"
echo ""
echo "Next step: bash deploy/05_deploy_vm.sh"
