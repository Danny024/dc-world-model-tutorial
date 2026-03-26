#!/usr/bin/env bash
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
  us-central1-docker.pkg.dev/hmth391/omniverse-kit/usd-viewer:latest
echo "=== Done ==="
docker inspect datacenter-kit --format="Privileged: {{.HostConfig.Privileged}}"
