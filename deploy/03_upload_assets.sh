#!/usr/bin/env bash
# Phase 3 — Upload USD Assets to GCS
# Uploads the full DataHall digital twin (9.6 GB) using parallel gsutil.
# Prerequisites: gcloud authenticated, config.env sourced
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

USD_SOURCE_DIR="/data/Datacenter_NVD@10012"

echo "=== Phase 3: Upload USD Assets to GCS ==="
echo "  Source : ${USD_SOURCE_DIR}"
echo "  Dest   : gs://${GCS_BUCKET}/"
echo ""

if [ ! -d "${USD_SOURCE_DIR}" ]; then
    echo "ERROR: Source directory not found: ${USD_SOURCE_DIR}"
    echo "Make sure the DataHall USD stage is accessible at that path."
    exit 1
fi

# Show size estimate
echo "Calculating source size..."
du -sh "${USD_SOURCE_DIR}" || true
echo ""

echo "Starting parallel upload (this may take 10-30 min depending on bandwidth)..."
# Do NOT use -z (gzip content encoding) — gcsfuse serves raw GCS bytes
# without decompressing Content-Encoding:gzip, so USD files must be stored
# uncompressed for NVIDIA Kit to read them correctly.
gsutil -m cp -r \
    "${USD_SOURCE_DIR}" \
    "gs://${GCS_BUCKET}/"

echo ""
echo "=== Upload complete ==="
echo ""
echo "Verifying top-level structure in GCS:"
gsutil ls "gs://${GCS_BUCKET}/Datacenter_NVD@10012/" | head -20

echo ""
echo "DataHall USD GCS path:"
echo "  ${USD_STAGE_GCS}"
echo ""
echo "Next step: bash deploy/04_build_and_push.sh"
