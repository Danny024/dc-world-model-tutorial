#!/usr/bin/env bash
# restart_kit.sh — Stop, rebuild, and restart the Kit streaming container
# Run on the GPU VM via:
#   bash /tmp/restart_kit.sh
set -e

AR_IMAGE="us-central1-docker.pkg.dev/hmth391/omniverse-kit/usd-viewer:latest"
USD_PATH="/mnt/assets/Assets/Datacenter/Facilities/Stages/Data_Hall/DataHall_Full_01.usd"

# ── 1. Create nvidia-persistenced socket (required by CDI spec) ───────────────
echo "=== Creating nvidia-persistenced socket ==="
sudo mkdir -p /run/nvidia-persistenced
sudo chmod 0755 /run/nvidia-persistenced

# Kill any previous listener
sudo pkill -f "nvidia-persistenced-socket-listener" 2>/dev/null || true
sleep 1

# Start a persistent background socket listener
sudo nohup python3 -c "
import socket, os, threading, time, sys
sys.argv[0] = 'nvidia-persistenced-socket-listener'
sp = '/run/nvidia-persistenced/socket'
try: os.unlink(sp)
except: pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sp)
s.listen(10)
os.chmod(sp, 0o777)
print('persistenced socket ready', flush=True)
def loop():
    while True:
        try: s.accept()[0].close()
        except: pass
threading.Thread(target=loop, daemon=True).start()
while True: time.sleep(3600)
" > /tmp/persistenced.log 2>&1 &

sleep 2
ls -la /run/nvidia-persistenced/socket && echo "Socket created OK" || echo "ERROR: socket not created"

# ── 2. Find the NVIDIA Vulkan library ─────────────────────────────────────────
LIBGLX=$(find /usr/lib/x86_64-linux-gnu -name "libGLX_nvidia.so.*" \
  ! -name "*.so.0" 2>/dev/null | head -1)
if [[ -z "${LIBGLX}" ]]; then
  echo "WARNING: libGLX_nvidia not found — Vulkan may not work"
  LIBGLX_MOUNT=""
else
  echo "Vulkan library: ${LIBGLX}"
  LIBGLX_MOUNT="-v ${LIBGLX}:${LIBGLX}:ro"
fi

# ── 3. Stop old container ─────────────────────────────────────────────────────
echo "=== Stopping old container ==="
sudo docker stop datacenter-kit 2>/dev/null || true
sudo docker rm   datacenter-kit 2>/dev/null || true

# ── 4. Start new container ────────────────────────────────────────────────────
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

echo "=== Container started — waiting 20s for Kit to initialise ==="
sleep 20

echo "=== Status ==="
sudo docker inspect datacenter-kit \
  --format="Restarts: {{.RestartCount}} | Status: {{.State.Status}}"
sudo ss -tlnp | grep 49100 \
  && echo ">>> Port 49100 OPEN — Kit is ready. Refresh your browser. <<<" \
  || echo "Port 49100 not yet open — Kit still starting or crashed"
echo "--- Last 15 log lines ---"
sudo docker logs datacenter-kit --tail 15 2>&1
