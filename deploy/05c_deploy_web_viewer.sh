#!/usr/bin/env bash
# Phase 5c — Deploy NVIDIA Web Viewer (browser WebRTC client) on GPU VM
# ────────────────────────────────────────────────────────────────────────
# Clones the NVIDIA web-viewer-sample, configures it to connect to the
# Kit streaming container's WebRTC signaling server (port 49100), builds
# the static site, and serves it on port 8080.
#
# The Kit streaming container (Phase 5b) must already be running before
# opening the browser.  Allow ~60 s for the USD scene to fully load.
#
# Prerequisites:
#   - Phase 5b complete (Kit streaming container running on the VM)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

echo "=== Phase 5c: Deploy Web Viewer on GPU VM ==="
echo "  VM : ${VM_NAME} (${GCP_ZONE})"
echo ""

# ── 1. Get VM external IP ─────────────────────────────────────────────────────
VM_IP=$(gcloud compute instances describe "${VM_NAME}" \
    --zone="${GCP_ZONE}" \
    --project="${GCP_PROJECT_ID}" \
    --format="get(networkInterfaces[0].accessConfigs[0].natIP)")

echo "VM external IP: ${VM_IP}"

# ── 2. Firewall rule for port 8080 (web viewer) ───────────────────────────────
if gcloud compute firewall-rules describe "allow-kit-webviewer" \
    --project="${GCP_PROJECT_ID}" &>/dev/null; then
    echo "Firewall rule 'allow-kit-webviewer' already exists — skipping."
else
    echo "Creating firewall rule for port 8080..."
    gcloud compute firewall-rules create "allow-kit-webviewer" \
        --project="${GCP_PROJECT_ID}" \
        --direction=INGRESS \
        --action=ALLOW \
        --rules=tcp:8080 \
        --source-ranges=0.0.0.0/0 \
        --target-tags="omniverse-kit" \
        --description="NVIDIA web viewer HTTP port"
    echo "Firewall rule created."
fi

# Also ensure TCP 49100 (WebRTC signaling) is open
if gcloud compute firewall-rules describe "allow-kit-signaling" \
    --project="${GCP_PROJECT_ID}" &>/dev/null; then
    echo "Firewall rule 'allow-kit-signaling' already exists — skipping."
else
    echo "Creating firewall rule for WebRTC signaling port 49100 TCP..."
    gcloud compute firewall-rules create "allow-kit-signaling" \
        --project="${GCP_PROJECT_ID}" \
        --direction=INGRESS \
        --action=ALLOW \
        --rules=tcp:49100 \
        --source-ranges=0.0.0.0/0 \
        --target-tags="omniverse-kit" \
        --description="Kit WebRTC signaling WebSocket"
    echo "Firewall rule created."
fi

# ── 3. Inline script executed on the VM via SSH ───────────────────────────────
REMOTE_SCRIPT=$(cat <<REMOTE
set -euo pipefail

# Install Node.js 20 LTS if not present
if ! command -v node &>/dev/null || [[ "\$(node --version | cut -d. -f1 | tr -d v)" -lt 18 ]]; then
    echo "Installing Node.js 20 LTS..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt-get install -y nodejs
fi
echo "Node.js: \$(node --version)  npm: \$(npm --version)"

# Clone or update web-viewer-sample
WEB_DIR="\$HOME/web-viewer-sample"
if [ -d "\${WEB_DIR}/.git" ]; then
    echo "Updating web-viewer-sample..."
    git -C "\${WEB_DIR}" pull --ff-only || true
else
    echo "Cloning NVIDIA web-viewer-sample..."
    git clone --depth 1 https://github.com/NVIDIA-Omniverse/web-viewer-sample.git "\${WEB_DIR}"
fi

cd "\${WEB_DIR}"

# Configure the signaling server URL.
# The web-viewer-sample reads VITE_SERVER_URL (or SERVER_URL) at build time.
# Set it to the Kit container's WebRTC signaling WebSocket.
cat > .env.local <<EOF
VITE_SERVER_URL=ws://${VM_IP}:49100
SERVER_URL=ws://${VM_IP}:49100
EOF

# Also patch any hardcoded localhost references in common config locations
for cfg in src/stream/config.ts src/streaming/config.ts src/AppStreaming.ts src/stream/AppStreaming.ts; do
    if [ -f "\$cfg" ]; then
        sed -i "s|localhost:49100|${VM_IP}:49100|g" "\$cfg"
        sed -i "s|127\\.0\\.0\\.1:49100|${VM_IP}:49100|g" "\$cfg"
        echo "Patched \$cfg"
    fi
done

echo "Installing npm dependencies..."
npm ci --prefer-offline || npm install

echo "Building web viewer..."
npm run build

# Install as a systemd user service so it persists across SSH sessions
# and restarts automatically if the process crashes.
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/webviewer.service <<EOF
[Unit]
Description=NVIDIA Web Viewer
After=network.target

[Service]
Type=simple
WorkingDirectory=\$(pwd)
ExecStart=/usr/bin/npx serve dist -p 8080 --no-clipboard
Restart=always

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable webviewer
# Kill any leftover stale listener on 8080 before restarting
fuser -k 8080/tcp 2>/dev/null || true
sleep 1
systemctl --user restart webviewer
sleep 3
systemctl --user status webviewer --no-pager | head -15

echo "Web viewer service started."
REMOTE
)

# ── 4. SSH into VM and execute ────────────────────────────────────────────────
echo "Connecting to VM..."
gcloud compute ssh "${VM_NAME}" \
    --zone="${GCP_ZONE}" \
    --project="${GCP_PROJECT_ID}" \
    --command="${REMOTE_SCRIPT}"

echo ""
echo "=== Phase 5c complete ==="
echo ""
echo "Open the 3D data center viewer in Chrome or Firefox:"
echo ""
echo "  http://${VM_IP}:8080"
echo ""
echo "The scene may take up to 60 seconds to fully load after first launch."
echo "If the screen is black, wait 60 s and refresh."
echo ""
echo "The viewer connects to the Kit streaming backend at:"
echo "  ws://${VM_IP}:49100  (WebRTC signaling)"
echo ""
echo "Check web viewer logs on VM:"
echo "  gcloud compute ssh ${VM_NAME} --zone=${GCP_ZONE} -- tail -f /tmp/web-viewer.log"
echo ""
echo "Check Kit container logs:"
echo "  gcloud compute ssh ${VM_NAME} --zone=${GCP_ZONE} -- docker logs -f datacenter-kit"
echo ""
echo "Stop the VM when done to avoid charges (~\$0.40/hr):"
echo "  gcloud compute instances stop ${VM_NAME} --zone=${GCP_ZONE}"
echo ""
echo "Next step: python3 deploy/06_generate_failure_data.py"
