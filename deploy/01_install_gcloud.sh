#!/usr/bin/env bash
# Phase 1 — Install gcloud CLI via APT (Debian/Ubuntu)
# Run once on the local machine. Requires sudo.
set -euo pipefail

echo "=== Phase 1: Installing Google Cloud CLI ==="

# 1. Add the Cloud SDK package source
if ! grep -q "packages.cloud.google.com" /etc/apt/sources.list.d/google-cloud-sdk.list 2>/dev/null; then
    echo "Adding Google Cloud SDK APT repository..."
    sudo apt-get update -y
    sudo apt-get install -y apt-transport-https ca-certificates gnupg curl

    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
        | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg

    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] \
https://packages.cloud.google.com/apt cloud-sdk main" \
        | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list
fi

# 2. Install gcloud, gsutil, and core components
sudo apt-get update -y
sudo apt-get install -y google-cloud-cli google-cloud-cli-gke-gcloud-auth-plugin

echo ""
echo "=== gcloud CLI installed successfully ==="
gcloud --version

echo ""
echo "=== MANUAL STEPS REQUIRED ==="
echo ""
echo "1. Authenticate with your Google account:"
echo "   gcloud auth login"
echo ""
echo "2. Set your project (replace YOUR_PROJECT_ID):"
echo "   gcloud config set project YOUR_PROJECT_ID"
echo ""
echo "3. Set application default credentials (needed by Python SDKs):"
echo "   gcloud auth application-default login"
echo ""
echo "4. Verify:"
echo "   gcloud config list"
echo ""
echo "Then run: source deploy/config.env && bash deploy/02_gcp_setup.sh"
