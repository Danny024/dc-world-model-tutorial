#!/usr/bin/env bash
# Usage: bash restart_kit.sh <NGC_API_KEY>
# Pull usd-viewer 106.0.0 from NGC (Python 3.10 — avoids ImGui/Python 3.12 segfault in 109.0.2)

NGC_API_KEY="${1:-${NGC_API_KEY:-}}"
NGC_IMAGE="nvcr.io/nvidia/omniverse/usd-viewer:106.0.0"
AR_IMAGE="us-central1-docker.pkg.dev/hmth391/omniverse-kit/usd-viewer:latest"

if [[ -z "${NGC_API_KEY}" ]]; then
  echo "ERROR: pass NGC API key as first argument"
  echo "  bash restart_kit.sh nvapi-xxxx..."
  exit 1
fi

echo "=== Logging into NGC ==="
echo "${NGC_API_KEY}" | sudo docker login nvcr.io \
  --username='$oauthtoken' \
  --password-stdin

echo "=== Pulling usd-viewer 106.0.0 from NGC (~8 GB) ==="
sudo docker pull "${NGC_IMAGE}"

echo "=== Tagging for Artifact Registry ==="
sudo docker tag "${NGC_IMAGE}" "${AR_IMAGE}"

echo "=== Authenticating with Artifact Registry ==="
gcloud auth configure-docker us-central1-docker.pkg.dev --quiet

echo "=== Pushing to Artifact Registry ==="
sudo docker push "${AR_IMAGE}"

echo "=== Restarting Kit container ==="
sudo docker stop datacenter-kit 2>/dev/null || true
sudo docker rm   datacenter-kit 2>/dev/null || true
sudo docker run -d \
  --name datacenter-kit \
  --privileged \
  --device nvidia.com/gpu=all \
  --restart unless-stopped \
  -e ACCEPT_EULA=Y \
  -e NVIDIA_DRIVER_CAPABILITIES=all \
  -e NVIDIA_VISIBLE_DEVICES=all \
  -e "USD_PATH=/mnt/assets/Assets/Datacenter/Facilities/Stages/Data_Hall/DataHall_Full_01.usd" \
  -p 49100:49100/tcp \
  -p 49100-49200:49100-49200/udp \
  -v /mnt/local-assets/DigitalTwin:/mnt/assets:ro \
  -v /usr/share/vulkan:/usr/share/vulkan:ro \
  -v /etc/vulkan:/etc/vulkan:ro \
  "${AR_IMAGE}"

echo "=== Done — waiting 10s for container to start ==="
sleep 10
sudo docker inspect datacenter-kit \
  --format="Privileged: {{.HostConfig.Privileged}} | Restarts: {{.RestartCount}} | Image: {{.Config.Image}}"
sudo docker logs datacenter-kit --tail 10 2>&1
