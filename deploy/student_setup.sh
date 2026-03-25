#!/usr/bin/env bash
# ============================================================
# STUDENT SETUP SCRIPT
# Atlanta Robotics — Data Center Digital Twin Tutorial
# ============================================================
# Run this ONCE when you first clone the repo.
# Works on:
#   - Google Cloud Shell (recommended — nothing to install)
#   - Ubuntu / Debian / WSL
#   - macOS
#   - Git Bash on Windows
#
# Usage:
#   bash deploy/student_setup.sh
#
# You will need:
#   - A Google account (Gmail is fine) already added by your instructor
#   - The GCS_BUCKET value provided by your instructor
#     (default: hmth391-omniverse-assets — already set for this class)
# ============================================================
set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}  $*"; }
warn() { echo -e "${YELLOW}[!!]${NC}  $*"; }
fail() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step() { echo -e "\n${YELLOW}▶ $*${NC}"; }
info() { echo -e "${CYAN}[i]${NC}  $*"; }

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║   Atlanta Robotics — Digital Twin Tutorial Setup         ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── Detect Google Cloud Shell ─────────────────────────────────────────────────
IN_CLOUD_SHELL=false
if [ "${CLOUD_SHELL:-}" = "true" ] || [ -n "${DEVSHELL_PROJECT_ID:-}" ]; then
    IN_CLOUD_SHELL=true
    echo ""
    echo "  ☁  Google Cloud Shell detected."
    echo "     gcloud is pre-installed and you are already authenticated."
    echo "     The 9.6 GB USD assets live on the GPU VM — no download needed here."
    echo ""
fi

# ── 0. Get instructor's bucket name ───────────────────────────────────────────
GCS_BUCKET="${GCS_BUCKET:-hmth391-omniverse-assets}"
USD_GCS_DIR="gs://${GCS_BUCKET}/DigitalTwin"

echo "  Bucket : gs://${GCS_BUCKET}"
echo ""

# ── 1. Install gcloud CLI ─────────────────────────────────────────────────────
step "Step 1/5 — Check gcloud CLI"

if command -v gcloud &>/dev/null; then
    ok "gcloud already installed: $(gcloud --version | head -1)"
else
    if [ "$IN_CLOUD_SHELL" = "true" ]; then
        fail "gcloud not found in Cloud Shell — this should not happen. Try opening a new tab."
    fi

    warn "gcloud not found — installing..."

    if [[ "$(uname)" == "Darwin" ]]; then
        # macOS
        if command -v brew &>/dev/null; then
            brew install --cask google-cloud-sdk
        else
            fail "Homebrew not found. Install it first: https://brew.sh"
        fi
    else
        # Linux / WSL / Debian
        sudo apt-get update -y -qq
        sudo apt-get install -y -qq apt-transport-https ca-certificates gnupg curl

        curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
            | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg 2>/dev/null

        echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] \
https://packages.cloud.google.com/apt cloud-sdk main" \
            | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list >/dev/null

        sudo apt-get update -y -qq
        sudo apt-get install -y -qq google-cloud-cli
    fi
    ok "gcloud installed: $(gcloud --version | head -1)"
fi

# ── 2. Authenticate ───────────────────────────────────────────────────────────
step "Step 2/5 — Authenticate with Google Cloud"

if gcloud auth list --format="value(account)" 2>/dev/null | grep -q "@"; then
    ACCOUNT=$(gcloud auth list --format="value(account)" 2>/dev/null | head -1)
    ok "Already authenticated as: ${ACCOUNT}"

    # Application Default Credentials (ADC) — needed for Python SDKs
    # Cloud Shell sets ADC automatically; other environments need explicit login
    if [ "$IN_CLOUD_SHELL" = "true" ]; then
        info "Cloud Shell: Application Default Credentials are set automatically."
    else
        if ! gcloud auth application-default print-access-token &>/dev/null; then
            warn "Application Default Credentials not set — running login..."
            gcloud auth application-default login
        else
            ok "Application Default Credentials already configured."
        fi
    fi
else
    if [ "$IN_CLOUD_SHELL" = "true" ]; then
        fail "Not authenticated in Cloud Shell. Click your account icon (top-right) and sign in."
    fi

    echo ""
    echo "  A browser window will open. Sign in with the Google account your instructor"
    echo "  gave access to. Use the same email you provided to your instructor."
    echo ""
    gcloud auth login
    gcloud auth application-default login
fi

# ── 3. Verify bucket access ───────────────────────────────────────────────────
step "Step 3/5 — Verify access to the asset bucket"

if ! gcloud storage ls "${USD_GCS_DIR}/" &>/dev/null; then
    fail "Cannot access ${USD_GCS_DIR}

  Possible causes:
    - Your Google account has not been granted access yet.
      Ask your instructor to run:
        bash deploy/instructor_grant_access.sh YOUR_EMAIL@gmail.com

    - The bucket name is wrong (ask your instructor for the correct name).

  Current bucket: gs://${GCS_BUCKET}
"
fi

ASSET_SIZE=$(gcloud storage du -s "${USD_GCS_DIR}/" 2>/dev/null | awk '{print $1}' || echo "unknown")
ok "Bucket accessible. GCS path: ${USD_GCS_DIR}"

# ── 4. Download USD assets (skip in Cloud Shell) ──────────────────────────────
step "Step 4/5 — USD assets"

if [ "$IN_CLOUD_SHELL" = "true" ]; then
    info "Cloud Shell: Skipping USD download."
    info "  The 9.6 GB USD assets are already on GCS and will be downloaded"
    info "  automatically to the GPU VM (200 GB disk) when your instructor"
    info "  starts the 3D viewer in Phase 5b."
    info "  You access the 3D twin via your browser — nothing to download here."
    LOCAL_ASSET_DIR="(on GPU VM only)"
    STAGE_LOCAL="(on GPU VM only)"
else
    LOCAL_ASSET_DIR="${HOME}/datacenter_assets"
    STAGE_LOCAL="${LOCAL_ASSET_DIR}/DigitalTwin/${USD_STAGE_RELATIVE:-Assets/Datacenter/Facilities/Stages/Data_Hall/DataHall_Full_01.usd}"

    if [ -f "${STAGE_LOCAL}" ]; then
        ok "USD assets already downloaded at ${LOCAL_ASSET_DIR}"
        warn "To re-download, delete ${LOCAL_ASSET_DIR} and re-run this script."
    else
        echo ""
        echo "  Downloading ~9.6 GB — this will take 5–20 min depending on your connection."
        echo "  Progress is shown below. Ctrl-C and re-run safely — download resumes."
        echo ""
        mkdir -p "${LOCAL_ASSET_DIR}"
        gcloud storage cp -r \
            "${USD_GCS_DIR}" \
            "${LOCAL_ASSET_DIR}/"
        ok "Download complete: ${LOCAL_ASSET_DIR}/DigitalTwin/"
    fi
fi

# ── 5. Install Python dependencies ────────────────────────────────────────────
step "Step 5/5 — Install Python dependencies"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# In Cloud Shell, use --user to avoid permission issues; elsewhere try directly
PIP_FLAGS="-q"
if [ "$IN_CLOUD_SHELL" = "true" ]; then
    PIP_FLAGS="-q --user"
fi

if command -v pip3 &>/dev/null; then
    pip3 install ${PIP_FLAGS} -r "${REPO_ROOT}/requirements.txt"
    ok "Python packages installed."
elif command -v pip &>/dev/null; then
    pip install ${PIP_FLAGS} -r "${REPO_ROOT}/requirements.txt"
    ok "Python packages installed."
else
    warn "pip not found. Install manually:"
    warn "  pip install -r requirements.txt"
fi

# Verify PyTorch
python3 - <<'PYCHECK'
import sys
try:
    import torch
    cuda = torch.cuda.is_available()
    print(f"  PyTorch {torch.__version__} | CUDA available: {cuda}")
    if cuda:
        print(f"  GPU: {torch.cuda.get_device_name(0)}")
    else:
        print("  No local GPU — training runs on Vertex AI A100 (Phase 8). That's expected.")
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

if [ "$IN_CLOUD_SHELL" = "true" ]; then
    echo "  Running in: Google Cloud Shell"
    echo "  USD assets: GPU VM downloads automatically (Phase 5b)"
else
    echo "  USD assets : ${LOCAL_ASSET_DIR}/DigitalTwin/"
fi
echo ""
echo "  Next steps:"
echo ""
echo "  Phase 6 — Generate synthetic sensor data:"
echo "    python3 deploy/06_generate_failure_data.py"
echo ""
echo "  Phase 7 — Train the world model (5 epochs, CPU demo):"
echo "    python3 deploy/07_world_model.py \\"
echo "      --csv sensor_timeseries.csv \\"
echo "      --output-dir ./model_output \\"
echo "      --epochs 5"
echo ""
echo "  Phase 9 — Run inference bridge (dry-run, no Cloud Run needed):"
echo "    python3 deploy/09_inference_bridge.py \\"
echo "      --config deploy/09_inference_config.toml \\"
echo "      --csv sensor_timeseries.csv \\"
echo "      --service-url https://placeholder \\"
echo "      --dry-run --no-kit"
echo ""
echo "  Open the 3D viewer in your browser (once instructor starts the VM):"
echo "    http://VM_IP:8080   (your instructor will give you this IP)"
echo ""
echo "  Happy building!"
echo ""
