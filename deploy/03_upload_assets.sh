#!/usr/bin/env bash
# Phase 3 — Upload USD Assets to GCS
# Uploads the full DataHall digital twin (9.6 GB) to GCS.
# Prerequisites: gcloud authenticated, config.env sourced
#
# Cross-platform note:
#   Windows users: run this inside Git Bash (MSYS2) — the path in
#   config.env uses forward slashes which Git Bash understands.
#   Alternatively, use 03_upload_assets.ps1 from PowerShell.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

echo "=== Phase 3: Upload USD Assets to GCS ==="
echo "  Source : ${USD_ASSETS_LOCAL}"
echo "  Dest   : ${USD_ASSETS_GCS}"
echo ""

if [ ! -d "${USD_ASSETS_LOCAL}" ]; then
    echo "ERROR: Asset directory not found: ${USD_ASSETS_LOCAL}"
    echo ""
    echo "Expected the DigitalTwin folder at that path."
    echo "Update USD_ASSETS_LOCAL in deploy/config.env to match your system."
    exit 1
fi

if [ ! -f "${USD_STAGE_LOCAL}" ]; then
    echo "ERROR: Stage file not found: ${USD_STAGE_LOCAL}"
    echo "The DigitalTwin folder exists but DataHall_Full_01.usd is missing."
    exit 1
fi

# Show size estimate
echo "Calculating source size (may take a moment)..."
du -sh "${USD_ASSETS_LOCAL}" || true
echo ""

# Check if already uploaded (idempotent)
if gcloud storage ls "${USD_STAGE_GCS}" > /dev/null 2>&1; then
    echo "[OK] Stage file already exists in GCS: ${USD_STAGE_GCS}"
    echo "     Skipping upload. To force re-upload, delete it first:"
    echo "     gcloud storage rm -r ${USD_ASSETS_GCS}"
    echo ""
    echo "Next step: bash deploy/04_build_and_push.sh"
    exit 0
fi

echo "Starting upload (this may take 10-30 min depending on bandwidth)..."
# Do NOT use --gzip-in-flight — gcsfuse serves raw GCS bytes without
# decompressing, so USD files must be stored uncompressed for Kit to read them.
gcloud storage cp -r \
    "${USD_ASSETS_LOCAL}" \
    "${USD_ASSETS_GCS}"

echo ""
echo "=== Upload complete ==="
echo ""
echo "Verifying top-level structure in GCS:"
gcloud storage ls "${USD_ASSETS_GCS}/" | head -20

echo ""
echo "Stage file GCS path:"
echo "  ${USD_STAGE_GCS}"
echo ""
echo "Next step: bash deploy/04_build_and_push.sh"
