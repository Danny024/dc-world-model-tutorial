#!/usr/bin/env bash
# ============================================================
# STUDENT SETUP SCRIPT
# Atlanta Robotics — Data Center Digital Twin Tutorial
# ============================================================
# Run this ONCE when you first clone the repo.
# It will:
#   1. Install gcloud CLI (if missing)
#   2. Authenticate you with Google Cloud
#   3. Download the USD assets from the instructor's GCS bucket
#   4. Install Python dependencies
#   5. Verify everything is ready
#
# Usage:
#   bash deploy/student_setup.sh
#
# You will need:
#   - A Google account (Gmail is fine)
#   - The GCS_BUCKET value provided by your instructor
# ============================================================
set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}  $*"; }
warn() { echo -e "${YELLOW}[!!]${NC}  $*"; }
fail() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step() { echo -e "\n${YELLOW}▶ $*${NC}"; }

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║   Atlanta Robotics — Digital Twin Tutorial Setup         ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── 0. Get instructor's bucket name ───────────────────────────────────────────
if [ -z "${GCS_BUCKET:-}" ]; then
    echo "Your instructor should have given you a GCS bucket name."
    echo "It looks like:  my-project-id-omniverse-assets"
    echo ""
    read -rp "Enter the GCS bucket name: " GCS_BUCKET
fi
USD_GCS_DIR="gs://${GCS_BUCKET}/Datacenter_NVD@10012"
LOCAL_ASSET_DIR="${HOME}/datacenter_assets"

echo ""
echo "  Bucket : gs://${GCS_BUCKET}"
echo "  Assets will be saved to: ${LOCAL_ASSET_DIR}"
echo ""

# ── 1. Install gcloud CLI ─────────────────────────────────────────────────────
step "Step 1/5 — Check gcloud CLI"

if command -v gcloud &>/dev/null; then
    ok "gcloud already installed: $(gcloud --version | head -1)"
else
    warn "gcloud not found — installing..."
    sudo apt-get update -y -qq
    sudo apt-get install -y -qq apt-transport-https ca-certificates gnupg curl

    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
        | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg 2>/dev/null

    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] \
https://packages.cloud.google.com/apt cloud-sdk main" \
        | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list >/dev/null

    sudo apt-get update -y -qq
    sudo apt-get install -y -qq google-cloud-cli
    ok "gcloud installed: $(gcloud --version | head -1)"
fi

# ── 2. Authenticate ───────────────────────────────────────────────────────────
step "Step 2/5 — Authenticate with Google Cloud"

if gcloud auth list --format="value(account)" 2>/dev/null | grep -q "@"; then
    ACCOUNT=$(gcloud auth list --format="value(account)" 2>/dev/null | head -1)
    ok "Already authenticated as: ${ACCOUNT}"
else
    echo ""
    echo "  A browser window will open. Sign in with your Google account."
    echo "  (Use the account your instructor granted access to the bucket.)"
    echo ""
    gcloud auth login
    gcloud auth application-default login
fi

# ── 3. Verify bucket access ───────────────────────────────────────────────────
step "Step 3/5 — Verify access to the USD asset bucket"

if ! gsutil ls "${USD_GCS_DIR}/" &>/dev/null; then
    fail "Cannot access ${USD_GCS_DIR}

  Possible causes:
    - The bucket name is wrong (ask your instructor)
    - Your Google account has not been granted access yet
      → Ask your instructor to run:
        gcloud storage buckets add-iam-policy-binding gs://${GCS_BUCKET} \\
          --member='user:YOUR_EMAIL@gmail.com' \\
          --role='roles/storage.objectViewer'
"
fi

ok "Bucket accessible. Checking asset size..."
gsutil du -sh "${USD_GCS_DIR}/" 2>/dev/null || true

# ── 4. Download USD assets ────────────────────────────────────────────────────
step "Step 4/5 — Download USD assets (~9.6 GB)"

mkdir -p "${LOCAL_ASSET_DIR}"

STAGE_LOCAL="${LOCAL_ASSET_DIR}/Datacenter_NVD@10012/Assets/DigitalTwin/Assets/Datacenter/Facilities/Stages/Data_Hall/DataHall_Full_01.usd"

if [ -f "${STAGE_LOCAL}" ]; then
    ok "USD assets already downloaded at ${LOCAL_ASSET_DIR}"
    warn "To re-download, delete ${LOCAL_ASSET_DIR} and re-run this script."
else
    echo ""
    echo "  Downloading 9.6 GB — this will take 5–20 minutes depending on your connection."
    echo "  Progress is shown below. You can safely Ctrl-C and re-run — gsutil resumes."
    echo ""
    gsutil -m cp -r \
        "${USD_GCS_DIR}" \
        "${LOCAL_ASSET_DIR}/"
    ok "Download complete."
fi

# ── 5. Install Python dependencies ────────────────────────────────────────────
step "Step 5/5 — Install Python dependencies"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if command -v pip3 &>/dev/null; then
    pip3 install -q -r "${REPO_ROOT}/requirements.txt"
    ok "Python packages installed."
else
    warn "pip3 not found. Install manually: pip install -r requirements.txt"
fi

# Check PyTorch + CUDA
python3 - <<'PYCHECK'
import sys
try:
    import torch
    cuda = torch.cuda.is_available()
    print(f"  PyTorch {torch.__version__} | CUDA: {cuda}")
    if cuda:
        print(f"  GPU: {torch.cuda.get_device_name(0)}")
    else:
        print("  WARNING: No GPU detected — training will be slow on CPU.")
        print("  For GPU support: pip install torch --index-url https://download.pytorch.org/whl/cu121")
except ImportError:
    print("  ERROR: PyTorch not installed. Run: pip install torch")
    sys.exit(1)
PYCHECK

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║              Setup complete! You are ready.              ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  USD assets   : ${LOCAL_ASSET_DIR}/Datacenter_NVD@10012/"
echo "  Stage file   : ${STAGE_LOCAL}"
echo ""
echo "  Next steps:"
echo ""
echo "  1. Generate sensor data:"
echo "     python3 deploy/06_generate_failure_data.py"
echo ""
echo "  2. Train the world model:"
echo "     python3 deploy/07_world_model.py \\"
echo "       --csv ~/sensor_timeseries.csv \\"
echo "       --output-dir ./model_output \\"
echo "       --epochs 15"
echo ""
echo "  Happy building!"
echo ""
