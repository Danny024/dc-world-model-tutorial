#!/usr/bin/env bash
# Pull usd-viewer 106.0.0 from NGC (Python 3.10 — avoids ImGui/Python 3.12 segfault in 109.0.2)
# Requires NGC_API_KEY to be set, or NGC login already done on this VM.

NGC_IMAGE="nvcr.io/nvidia/omniverse/usd-viewer:106.0.0"
AR_IMAGE="us-central1-docker.pkg.dev/hmth391/omniverse-kit/usd-viewer:latest"

echo "=== Pulling usd-viewer 106.0.0 from NGC ==="
docker pull "${NGC_IMAGE}"

echo "=== Tagging for Artifact Registry ==="
docker tag "${NGC_IMAGE}" "${AR_IMAGE}"

echo "=== Pushing to Artifact Registry ==="
gcloud auth configure-docker us-central1-docker.pkg.dev --quiet
docker push "${AR_IMAGE}"

echo "=== Restarting Kit container ==="
docker stop datacenter-kit 2>/dev/null || true
docker rm datacenter-kit 2>/dev/null || true
docker run -d \
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
echo "=== Done ==="
docker inspect datacenter-kit --format="Privileged: {{.HostConfig.Privileged}} | Image: {{.Config.Image}}"
