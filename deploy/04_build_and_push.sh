#!/usr/bin/env bash
# Phase 4 — Build Kit App Docker Container and Push to Artifact Registry
# Prerequisites: Docker running locally, gcloud authenticated, config.env sourced
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/config.env"

echo "=== Phase 4: Build and Push Docker Container ==="
echo "  Image  : ${IMAGE_URI}"
echo "  Repo   : ${REPO_ROOT}"
echo ""

cd "${REPO_ROOT}"

# ── 1. Build the Kit application ─────────────────────────────────────────────
echo "Building Kit application..."
./repo.sh build
echo "Build complete."

# ── 2. Package into container ─────────────────────────────────────────────────
echo ""
echo "Packaging into Docker image..."
./repo.sh package_container --image-tag "datacenter-kit:latest"
echo "Packaging complete."

# ── 3. Tag for Artifact Registry ──────────────────────────────────────────────
echo ""
echo "Tagging image for Artifact Registry..."
docker tag "datacenter-kit:latest" "${IMAGE_URI}"
echo "Tagged: ${IMAGE_URI}"

# ── 4. Push ───────────────────────────────────────────────────────────────────
echo ""
echo "Pushing to Artifact Registry..."
docker push "${IMAGE_URI}"

echo ""
echo "=== Phase 4 complete ==="
echo "Image pushed: ${IMAGE_URI}"
echo ""
echo "Next step: bash deploy/05_deploy_vm.sh"
