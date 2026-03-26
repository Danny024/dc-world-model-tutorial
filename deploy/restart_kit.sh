#!/usr/bin/env bash
# restart_kit.sh — Stop, rebuild, and restart the Kit streaming container
# Run on the GPU VM via:
#   bash /tmp/restart_kit.sh
set -e

AR_IMAGE="us-central1-docker.pkg.dev/hmth391/omniverse-kit/usd-viewer:latest"
USD_PATH="/mnt/assets/Assets/Datacenter/Facilities/Stages/Data_Hall/DataHall_Full_01.usd"

# ── 1. Create nvidia-persistenced socket ─────────────────────────────────────
echo "=== Creating nvidia-persistenced socket ==="
sudo mkdir -p /run/nvidia-persistenced
sudo chmod 0755 /run/nvidia-persistenced
sudo pkill -f "nvidia-persistenced-socket-listener" 2>/dev/null || true
sleep 1
sudo nohup python3 -c "
import socket, os, threading, time, sys
sys.argv[0] = 'nvidia-persistenced-socket-listener'
sp = '/run/nvidia-persistenced/socket'
try: os.unlink(sp)
except: pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sp); s.listen(10); os.chmod(sp, 0o777)
print('socket ready', flush=True)
threading.Thread(target=lambda: [s.accept()[0].close() for _ in iter(int,1)], daemon=True).start()
while True: time.sleep(3600)
" > /tmp/persistenced.log 2>&1 &
sleep 2
echo "Persistenced socket: $(ls -la /run/nvidia-persistenced/socket 2>/dev/null || echo MISSING)"

# ── 2. Clean CDI spec — remove entries for files that don't exist ─────────────
echo "=== Cleaning CDI spec of missing file references ==="
sudo python3 - << 'PYEOF'
import os, sys

def clean_spec(path):
    try:
        with open(path) as f:
            content = f.read()
    except FileNotFoundError:
        print(f"  {path}: not found, skipping")
        return

    lines = content.splitlines()
    cleaned = []
    skip_next = False
    removed = 0

    for i, line in enumerate(lines):
        # Look for hostPath entries pointing to non-existent files
        stripped = line.strip()
        if stripped.startswith('hostPath:'):
            path_val = stripped.split(':', 1)[1].strip().strip('"').strip("'")
            if path_val and not os.path.exists(path_val):
                removed += 1
                continue  # drop this line
        cleaned.append(line)

    with open(path, 'w') as f:
        f.write('\n'.join(cleaned) + '\n')
    print(f"  {path}: removed {removed} missing-path entries")

clean_spec('/etc/cdi/nvidia.yaml')
clean_spec('/run/cdi/nvidia.yaml')
print("CDI spec cleaned.")
PYEOF

# ── 3. Find NVIDIA Vulkan library ─────────────────────────────────────────────
LIBGLX=$(find /usr/lib/x86_64-linux-gnu -name "libGLX_nvidia.so.*" \
  ! -name "*.so.0" 2>/dev/null | head -1)
if [[ -n "${LIBGLX}" ]]; then
  echo "Vulkan library: ${LIBGLX}"
  LIBGLX_MOUNT="-v ${LIBGLX}:${LIBGLX}:ro"
else
  echo "WARNING: libGLX_nvidia not found"
  LIBGLX_MOUNT=""
fi

# ── 4. Stop old container ─────────────────────────────────────────────────────
echo "=== Stopping old container ==="
sudo docker stop datacenter-kit 2>/dev/null || true
sudo docker rm   datacenter-kit 2>/dev/null || true

# ── 5. Start container ────────────────────────────────────────────────────────
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

echo "=== Waiting 20s for Kit to initialise ==="
sleep 20

echo "=== Status ==="
sudo docker inspect datacenter-kit \
  --format="Restarts: {{.RestartCount}} | Status: {{.State.Status}}"
sudo ss -tlnp | grep 49100 \
  && echo ">>> Port 49100 OPEN — Kit is ready. Refresh your browser. <<<" \
  || echo "Port 49100 not yet open"
echo "--- Last 15 log lines ---"
sudo docker logs datacenter-kit --tail 15 2>&1
