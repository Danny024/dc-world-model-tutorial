#!/usr/bin/env bash
# Phase 5b — Deploy Kit Streaming Container on GPU VM
# ─────────────────────────────────────────────────────
# SSHes into the GPU VM, pulls the Kit Streaming image from Artifact Registry,
# mounts the GCS USD assets via gcsfuse, and launches the container.
# The 3D data center scene streams to your browser via WebRTC on port 8011.
#
# Prerequisites:
#   - Phase 2 complete  (GPU VM created)
#   - Phase 3 complete  (USD assets in GCS)
#   - Phase 4b complete (Kit image in Artifact Registry)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

echo "=== Phase 5b: Deploy Kit Streaming on GPU VM ==="
echo "  VM   : ${VM_NAME} (${GCP_ZONE})"
echo "  Image: ${IMAGE_URI}"
echo ""

# ── 1. Get VM external IP ─────────────────────────────────────────────────────
VM_IP=$(gcloud compute instances describe "${VM_NAME}" \
    --zone="${GCP_ZONE}" \
    --project="${GCP_PROJECT_ID}" \
    --format="get(networkInterfaces[0].accessConfigs[0].natIP)")

echo "VM external IP: ${VM_IP}"

# ── 2. Inline script executed on the VM via SSH ───────────────────────────────
REMOTE_SCRIPT=$(cat <<REMOTE
set -euo pipefail

# Authenticate Docker with Artifact Registry
gcloud auth configure-docker ${GCP_REGION}-docker.pkg.dev --quiet

# Pull the Kit Streaming image
docker pull ${IMAGE_URI}

# Mount GCS bucket via gcsfuse so the USD stage is accessible inside the container
MOUNT_DIR=/mnt/omniverse-assets
mkdir -p \${MOUNT_DIR}
if ! mountpoint -q "\${MOUNT_DIR}"; then
    gcsfuse --implicit-dirs ${GCS_BUCKET} \${MOUNT_DIR}
    echo "GCS bucket mounted at \${MOUNT_DIR}"
fi

# Stop any previous container
docker stop datacenter-kit 2>/dev/null || true
docker rm   datacenter-kit 2>/dev/null || true

# Launch Kit streaming container with GPU, WebRTC on 8011, WebSocket on 8012
docker run -d \
    --name datacenter-kit \
    --gpus all \
    --restart unless-stopped \
    -p 8011:8011 \
    -p 8012:8012 \
    -p 49100-49200:49100-49200/udp \
    -v \${MOUNT_DIR}:/mnt/assets:ro \
    -e OMNI_SERVER="" \
    -e ACCEPT_EULA=Y \
    ${IMAGE_URI} \
    --/app/auto_load_usd="/mnt/assets/Datacenter_NVD@10012/Assets/DigitalTwin/Assets/Datacenter/Facilities/Stages/Data_Hall/DataHall_Full_01.usd" \
    --/app/streaming/enabled=true \
    --/app/streaming/webrtc/enabled=true \
    --/app/streaming/webrtc/port=8012 \
    --/app/streaming/http/port=8011

echo "Container started. Waiting for Kit to initialise (~60 seconds)..."
sleep 10
docker logs datacenter-kit --tail 30
REMOTE
)

# ── 3. SSH into VM and execute ────────────────────────────────────────────────
echo "Connecting to VM..."
gcloud compute ssh "${VM_NAME}" \
    --zone="${GCP_ZONE}" \
    --project="${GCP_PROJECT_ID}" \
    --command="${REMOTE_SCRIPT}"

echo ""
echo "=== Phase 5b complete ==="
echo ""
echo "Kit streaming is live. Open in Chrome or Firefox:"
echo ""
echo "  http://${VM_IP}:8011"
echo ""
echo "The scene may take up to 60 seconds to fully load on first launch."
echo ""
echo "Check container logs:"
echo "  gcloud compute ssh ${VM_NAME} --zone=${GCP_ZONE} -- docker logs -f datacenter-kit"
echo ""
echo "Stop the VM when done to avoid charges (~\$0.40/hr):"
echo "  gcloud compute instances stop ${VM_NAME} --zone=${GCP_ZONE}"
echo ""
echo "Next step: python3 deploy/06_generate_failure_data.py"
