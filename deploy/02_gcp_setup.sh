#!/usr/bin/env bash
# Phase 2 — GCP Infrastructure Setup
# Creates: GCS bucket, Artifact Registry repo, GPU VM, firewall rules
# Prerequisites: gcloud authenticated, config.env sourced
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

echo "=== Phase 2: GCP Infrastructure Setup ==="
echo "  Project : ${GCP_PROJECT_ID}"
echo "  Region  : ${GCP_REGION}"
echo "  Zone    : ${GCP_ZONE}"
echo ""

# ── 1. Set active project ────────────────────────────────────────────────────
gcloud config set project "${GCP_PROJECT_ID}"

# ── 2. Enable required APIs ──────────────────────────────────────────────────
echo "Enabling GCP APIs (this may take a few minutes)..."
gcloud services enable \
    compute.googleapis.com \
    artifactregistry.googleapis.com \
    aiplatform.googleapis.com \
    storage.googleapis.com \
    --project="${GCP_PROJECT_ID}"

echo "APIs enabled."

# ── 3. GCS bucket ────────────────────────────────────────────────────────────
if gsutil ls -b "gs://${GCS_BUCKET}" &>/dev/null; then
    echo "GCS bucket gs://${GCS_BUCKET} already exists — skipping creation."
else
    echo "Creating GCS bucket gs://${GCS_BUCKET}..."
    gsutil mb -p "${GCP_PROJECT_ID}" -l "${GCP_REGION}" "gs://${GCS_BUCKET}"
    echo "Bucket created."
fi

# ── 4. Artifact Registry repositories ───────────────────────────────────────
# Kit streaming repo (Phase 4b — NVIDIA usd-viewer image)
if gcloud artifacts repositories describe "${AR_REPO_KIT}" \
    --location="${GCP_REGION}" --project="${GCP_PROJECT_ID}" &>/dev/null; then
    echo "Artifact Registry repo '${AR_REPO_KIT}' already exists — skipping."
else
    echo "Creating Artifact Registry repository '${AR_REPO_KIT}'..."
    gcloud artifacts repositories create "${AR_REPO_KIT}" \
        --repository-format=docker \
        --location="${GCP_REGION}" \
        --description="NVIDIA Omniverse Kit Streaming containers" \
        --project="${GCP_PROJECT_ID}"
    echo "Repository '${AR_REPO_KIT}' created."
fi

# World model inference repo (Phase 4 — CPU inference image + edge artefacts)
if gcloud artifacts repositories describe "${AR_REPO_MODELS}" \
    --location="${GCP_REGION}" --project="${GCP_PROJECT_ID}" &>/dev/null; then
    echo "Artifact Registry repo '${AR_REPO_MODELS}' already exists — skipping."
else
    echo "Creating Artifact Registry repository '${AR_REPO_MODELS}'..."
    gcloud artifacts repositories create "${AR_REPO_MODELS}" \
        --repository-format=docker \
        --location="${GCP_REGION}" \
        --description="World model inference image and edge artefacts" \
        --project="${GCP_PROJECT_ID}"
    echo "Repository '${AR_REPO_MODELS}' created."
fi

# Configure Docker auth for Artifact Registry
gcloud auth configure-docker "${GCP_REGION}-docker.pkg.dev" --quiet

# ── 5. GPU VM ────────────────────────────────────────────────────────────────
if gcloud compute instances describe "${VM_NAME}" \
    --zone="${GCP_ZONE}" --project="${GCP_PROJECT_ID}" &>/dev/null; then
    echo "VM '${VM_NAME}' already exists — skipping creation."
else
    echo "Creating GPU VM '${VM_NAME}' (${VM_MACHINE_TYPE}, NVIDIA L4)..."
    # Deep Learning VM image: NVIDIA drivers + CUDA pre-installed, no startup script needed
    gcloud compute instances create "${VM_NAME}" \
        --project="${GCP_PROJECT_ID}" \
        --zone="${GCP_ZONE}" \
        --machine-type="${VM_MACHINE_TYPE}" \
        --accelerator="count=1,type=nvidia-l4" \
        --maintenance-policy=TERMINATE \
        --image-family=common-cu128-ubuntu-2204-nvidia-570 \
        --image-project=deeplearning-platform-release \
        --boot-disk-size="${VM_DISK_SIZE}GB" \
        --boot-disk-type=pd-ssd \
        --scopes=cloud-platform \
        --metadata="install-nvidia-driver=True" \
        --tags=omniverse-kit
    echo "VM created with NVIDIA drivers pre-installed."
    echo "Installing Docker and gcsfuse (~2 min)..."
    # Wait for SSH to become available
    sleep 30
    gcloud compute ssh "${VM_NAME}" --zone="${GCP_ZONE}" --project="${GCP_PROJECT_ID}" \
        --command='
set -e
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER

# Install missing NVIDIA libraries needed by the container toolkit
# (Deep Learning VMs ship the -server driver variant which omits some libs)
sudo apt-get install -y nvidia-compute-utils-570 libnvidia-cfg1-570 libnvidia-nscq-570

# Configure NVIDIA CTK and enable CDI mode (avoids missing-library errors
# from the legacy nvidia-container-cli on server-driver VMs)
sudo nvidia-ctk runtime configure --runtime=docker
sudo mkdir -p /etc/cdi
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml

# Disable the systemd CDI-refresh service that overwrites /run/cdi/nvidia.yaml
# with a spec referencing libnvidia-nscq (not installed on server-driver VMs)
sudo systemctl disable --now nvidia-cdi-refresh.path nvidia-cdi-refresh.service 2>/dev/null || true

# Configure Docker to enable CDI device selection
sudo bash -c '"'"'cat > /etc/docker/daemon.json <<EOF
{
  "runtimes": {
    "nvidia": {
      "path": "nvidia-container-runtime",
      "runtimeArgs": []
    }
  },
  "features": {
    "cdi": true
  }
}
EOF'"'"'
sudo systemctl restart docker
# Copy clean CDI spec to /run/cdi so Docker finds it
sudo mkdir -p /run/cdi
sudo cp /etc/cdi/nvidia.yaml /run/cdi/nvidia.yaml

# Set up Vulkan ICD symlink for GPU rendering inside containers
sudo mkdir -p /etc/vulkan/icd.d
sudo ln -sf /usr/share/vulkan/icd.d/nvidia_icd.json /etc/vulkan/icd.d/nvidia_icd.json

# Start nvidia-persistenced socket (needed by CTK inside containers)
# Use a lightweight Python listener as the server driver does not start it
python3 -c "
import socket, os, threading
p = '/run/nvidia-persistenced'
os.makedirs(p, exist_ok=True)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sp = p + '/socket'
try: os.unlink(sp)
except: pass
s.bind(sp)
s.listen(1)
os.chmod(sp, 0o777)
print('persistenced socket ready')
threading.Thread(target=lambda: [s.accept()[0].close() for _ in iter(int, 1)], daemon=True).start()
import time; time.sleep(5)  # hand off to systemd
" &

curl https://packages.cloud.google.com/apt/doc/apt-key.gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt gcsfuse-jammy main" \
  | sudo tee /etc/apt/sources.list.d/gcsfuse.list
sudo apt-get update -y -qq
sudo apt-get install -y gcsfuse
echo "Docker, gcsfuse, and GPU CDI ready."
'
fi

# ── 6. Firewall rules for Kit streaming ──────────────────────────────────────
FIREWALL_TAG="omniverse-kit"

add_firewall_rule () {
    local NAME=$1; shift
    if gcloud compute firewall-rules describe "${NAME}" \
        --project="${GCP_PROJECT_ID}" &>/dev/null; then
        echo "Firewall rule '${NAME}' already exists — skipping."
    else
        gcloud compute firewall-rules create "${NAME}" "$@" \
            --project="${GCP_PROJECT_ID}" \
            --target-tags="${FIREWALL_TAG}"
        echo "Firewall rule '${NAME}' created."
    fi
}

# Apply the streaming tag to our VM
gcloud compute instances add-tags "${VM_NAME}" \
    --tags="${FIREWALL_TAG}" \
    --zone="${GCP_ZONE}" \
    --project="${GCP_PROJECT_ID}"

add_firewall_rule "allow-kit-tcp" \
    --direction=INGRESS \
    --action=ALLOW \
    --rules=tcp:8011,tcp:8012 \
    --source-ranges=0.0.0.0/0 \
    --description="Kit streaming TCP ports"

add_firewall_rule "allow-kit-webrtc-udp" \
    --direction=INGRESS \
    --action=ALLOW \
    --rules=udp:49100-49200 \
    --source-ranges=0.0.0.0/0 \
    --description="Kit WebRTC UDP media ports"

# ── 7. IAM grants for Cloud Build ────────────────────────────────────────────
# Cloud Build needs Artifact Registry write access to push images.
# The Compute Engine default SA is what Cloud Build runs as when the
# Cloud Build SA is not explicitly configured.
echo "Configuring Cloud Build IAM permissions..."
PROJECT_NUMBER=$(gcloud projects describe "${GCP_PROJECT_ID}" \
    --format="value(projectNumber)")

# Cloud Build service account
gcloud projects add-iam-policy-binding "${GCP_PROJECT_ID}" \
    --member="serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com" \
    --role="roles/artifactregistry.writer" --quiet 2>/dev/null || true

# Compute Engine default service account (fallback SA used by Cloud Build)
gcloud projects add-iam-policy-binding "${GCP_PROJECT_ID}" \
    --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
    --role="roles/artifactregistry.writer" --quiet 2>/dev/null || true

gcloud projects add-iam-policy-binding "${GCP_PROJECT_ID}" \
    --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
    --role="roles/logging.logWriter" --quiet 2>/dev/null || true

echo "Cloud Build IAM configured."

echo ""
echo "=== Phase 2 complete ==="
echo ""
echo "Next steps:"
echo "  3. Upload assets : bash deploy/03_upload_assets.sh"
echo "  4. Build + push  : bash deploy/04_build_and_push.sh"
echo "  5. Deploy VM     : bash deploy/05_deploy_vm.sh"
