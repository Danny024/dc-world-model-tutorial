#!/usr/bin/env bash
# Phase 5 — Deploy Container on GPU VM and Launch Kit Streaming
# Prerequisites: VM running, image pushed, config.env sourced
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

echo "=== Phase 5: Deploy to GPU VM ==="
echo "  VM   : ${VM_NAME} (${GCP_ZONE})"
echo "  Image: ${IMAGE_URI}"
echo ""

# ── 1. Get VM external IP ─────────────────────────────────────────────────────
VM_IP=$(gcloud compute instances describe "${VM_NAME}" \
    --zone="${GCP_ZONE}" \
    --project="${GCP_PROJECT_ID}" \
    --format="get(networkInterfaces[0].accessConfigs[0].natIP)")

echo "VM external IP: ${VM_IP}"

# ── 2. Inline script to run on the VM ────────────────────────────────────────
REMOTE_SCRIPT=$(cat <<REMOTE
set -euo pipefail

# Authenticate Docker with Artifact Registry
gcloud auth configure-docker ${GCP_REGION}-docker.pkg.dev --quiet

# Pull the latest image
docker pull ${IMAGE_URI}

# Mount GCS bucket via gcsfuse
MOUNT_DIR=/mnt/omniverse-assets
mkdir -p \${MOUNT_DIR}
if ! mountpoint -q "\${MOUNT_DIR}"; then
    gcsfuse --implicit-dirs ${GCS_BUCKET} \${MOUNT_DIR}
    echo "GCS bucket mounted at \${MOUNT_DIR}"
fi

# Stop any previous container
docker stop datacenter-kit 2>/dev/null || true
docker rm   datacenter-kit 2>/dev/null || true

# Launch Kit streaming container
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

echo "Container started. Waiting for Kit to initialize..."
sleep 10
docker logs datacenter-kit --tail 30
REMOTE
)

# ── 3. SSH and execute ────────────────────────────────────────────────────────
echo "Connecting to VM and deploying..."
gcloud compute ssh "${VM_NAME}" \
    --zone="${GCP_ZONE}" \
    --project="${GCP_PROJECT_ID}" \
    --command="${REMOTE_SCRIPT}"

echo ""
echo "=== Phase 5 complete ==="
echo ""
echo "Kit streaming is live. Open in your browser:"
echo ""
echo "  WebRTC stream : http://${VM_IP}:8011"
echo "  WebSocket API : ws://${VM_IP}:8012"
echo ""
echo "If the page doesn't load immediately, wait 60 seconds for Kit to fully start."
echo "Check container logs with:"
echo "  gcloud compute ssh ${VM_NAME} --zone=${GCP_ZONE} -- docker logs -f datacenter-kit"
