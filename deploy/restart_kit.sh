#!/usr/bin/env bash
# restart_kit.sh — Stop, rebuild, and restart the Kit streaming container
# Run on the GPU VM via:
#   bash /tmp/restart_kit.sh [NGC_API_KEY]
set -e

AR_IMAGE="us-central1-docker.pkg.dev/hmth391/omniverse-kit/usd-viewer:latest"
USD_PATH="/mnt/assets/Assets/Datacenter/Facilities/Stages/Data_Hall/DataHall_Full_01.usd"

# ── Find the NVIDIA Vulkan / GLX library on this host ─────────────────────────
LIBGLX=$(find /usr/lib/x86_64-linux-gnu -name "libGLX_nvidia.so.*" \
  ! -name "*.so.0" 2>/dev/null | head -1)
if [[ -z "${LIBGLX}" ]]; then
  echo "WARNING: libGLX_nvidia not found — Vulkan may not work inside container"
  LIBGLX_MOUNT=""
else
  echo "Found Vulkan library: ${LIBGLX}"
  LIBGLX_MOUNT="-v ${LIBGLX}:${LIBGLX}:ro"
fi

# ── Stop and remove old container ─────────────────────────────────────────────
echo "=== Stopping old container ==="
sudo docker stop datacenter-kit 2>/dev/null || true
sudo docker rm   datacenter-kit 2>/dev/null || true

# ── Start new container ───────────────────────────────────────────────────────
echo "=== Starting Kit container ==="
sudo docker run -d \
  --name datacenter-kit \
  --device nvidia.com/gpu=all \
  --restart unless-stopped \
  -e ACCEPT_EULA=Y \
  -e NVIDIA_DRIVER_CAPABILITIES=all \
  -e NVIDIA_VISIBLE_DEVICES=all \
  -e "USD_PATH=${USD_PATH}" \
  -p 49100:49100/tcp \
  -p 49100-49200:49100-49200/udp \
  -v /mnt/local-assets/DigitalTwin:/mnt/assets:ro \
  -v /usr/share/vulkan:/usr/share/vulkan:ro \
  -v /etc/vulkan:/etc/vulkan:ro \
  ${LIBGLX_MOUNT} \
  "${AR_IMAGE}"

echo "=== Container started — waiting 15s ==="
sleep 15

echo "=== Status ==="
sudo docker inspect datacenter-kit \
  --format="Restarts: {{.RestartCount}} | Status: {{.State.Status}}"
sudo ss -tlnp | grep 49100 && echo "Port 49100 is OPEN — Kit is ready" \
  || echo "Port 49100 not yet open — Kit still starting"
sudo docker logs datacenter-kit --tail 15 2>&1
