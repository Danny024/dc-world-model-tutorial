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

# ── 4. Artifact Registry repository ─────────────────────────────────────────
if gcloud artifacts repositories describe "${AR_REPO}" \
    --location="${GCP_REGION}" --project="${GCP_PROJECT_ID}" &>/dev/null; then
    echo "Artifact Registry repo '${AR_REPO}' already exists — skipping."
else
    echo "Creating Artifact Registry repository '${AR_REPO}'..."
    gcloud artifacts repositories create "${AR_REPO}" \
        --repository-format=docker \
        --location="${GCP_REGION}" \
        --description="NVIDIA Omniverse Kit containers" \
        --project="${GCP_PROJECT_ID}"
    echo "Repository created."
fi

# Configure Docker auth for Artifact Registry
gcloud auth configure-docker "${GCP_REGION}-docker.pkg.dev" --quiet

# ── 5. GPU VM ────────────────────────────────────────────────────────────────
if gcloud compute instances describe "${VM_NAME}" \
    --zone="${GCP_ZONE}" --project="${GCP_PROJECT_ID}" &>/dev/null; then
    echo "VM '${VM_NAME}' already exists — skipping creation."
else
    echo "Creating GPU VM '${VM_NAME}' (${VM_MACHINE_TYPE}, NVIDIA L4)..."
    gcloud compute instances create "${VM_NAME}" \
        --project="${GCP_PROJECT_ID}" \
        --zone="${GCP_ZONE}" \
        --machine-type="${VM_MACHINE_TYPE}" \
        --accelerator="count=1,type=nvidia-l4" \
        --maintenance-policy=TERMINATE \
        --image-family=ubuntu-2204-lts \
        --image-project=ubuntu-os-cloud \
        --boot-disk-size="${VM_DISK_SIZE}GB" \
        --boot-disk-type=pd-ssd \
        --scopes=cloud-platform \
        --metadata=startup-script='#!/bin/bash
# Install NVIDIA drivers + Container Toolkit on first boot
set -euo pipefail
apt-get update -y
apt-get install -y linux-headers-$(uname -r)

# NVIDIA driver (550 series)
curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb \
  -o /tmp/cuda-keyring.deb
dpkg -i /tmp/cuda-keyring.deb
apt-get update -y
apt-get install -y cuda-drivers-550

# NVIDIA Container Toolkit
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed "s#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#" \
  | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
apt-get update -y
apt-get install -y nvidia-container-toolkit
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker

# GCS Fuse for mounting the asset bucket
export GCSFUSE_REPO=gcsfuse-jammy
echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt ${GCSFUSE_REPO} main" \
  | tee /etc/apt/sources.list.d/gcsfuse.list
apt-get update -y
apt-get install -y gcsfuse
'
    echo "VM created. NVIDIA drivers will install on first boot (~5 min)."
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

echo ""
echo "=== Phase 2 complete ==="
echo ""
echo "Next steps:"
echo "  3. Upload assets : bash deploy/03_upload_assets.sh"
echo "  4. Build + push  : bash deploy/04_build_and_push.sh"
echo "  5. Deploy VM     : bash deploy/05_deploy_vm.sh"
