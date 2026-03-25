#!/usr/bin/env bash
# ============================================================
# Scholar Workstation Setup — e2-micro VM
# David Mykel Taylor Scholars Program
# ============================================================
# Run this ONCE on each Scholar's e2-micro workstation VM.
# The instructor runs this via gcloud compute ssh or as a
# startup script when provisioning the 20 VMs.
#
# What this installs:
#   - Python 3.11, pip, git (if not present)
#   - gcloud SDK (pre-installed on GCP VMs — just configures it)
#   - Repo clone + Python dependencies (no PyTorch — e2-micro
#     has only 1 GB RAM; training runs on Vertex AI A100)
#   - Environment file so config.env is sourced on login
#
# Usage:
#   # From instructor's machine, run on all 20 workstations:
#   for i in $(seq -w 1 20); do
#     gcloud compute ssh scholar-workstation-${i} \
#       --zone=us-central1-a \
#       --command="bash /tmp/scholar_workstation_setup.sh" &
#   done
#   wait
#
#   # Or copy and run manually on one machine:
#   gcloud compute scp deploy/scholar_workstation_setup.sh \
#     scholar-workstation-01:/tmp/ --zone=us-central1-a
#   gcloud compute ssh scholar-workstation-01 --zone=us-central1-a \
#     --command="bash /tmp/scholar_workstation_setup.sh"
# ============================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}  $*"; }
step() { echo -e "\n${YELLOW}▶ $*${NC}"; }

GCP_PROJECT="hmth391"
REPO_URL="https://github.com/Danny024/dc-world-model-tutorial.git"
REPO_DIR="${HOME}/dc-world-model-tutorial"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║   Scholar Workstation Setup — e2-micro                   ║"
echo "║   David Mykel Taylor Scholars Program                    ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── 1. System packages ────────────────────────────────────────────────────────
step "1/5 — System packages"
sudo apt-get update -y -qq
sudo apt-get install -y -qq git python3.11 python3.11-venv python3-pip curl
ok "System packages ready."

# ── 2. Configure gcloud ───────────────────────────────────────────────────────
step "2/5 — Configure gcloud (pre-installed on GCP VMs)"
gcloud config set project "${GCP_PROJECT}" --quiet
gcloud config set compute/region us-central1 --quiet
gcloud config set compute/zone us-central1-a --quiet
ok "gcloud configured for project ${GCP_PROJECT}."

# ── 3. Clone / update repo ────────────────────────────────────────────────────
step "3/5 — Clone tutorial repo"
if [ -d "${REPO_DIR}/.git" ]; then
    git -C "${REPO_DIR}" pull --ff-only
    ok "Repo updated: ${REPO_DIR}"
else
    git clone "${REPO_URL}" "${REPO_DIR}"
    ok "Repo cloned: ${REPO_DIR}"
fi

# ── 4. Install Python dependencies (lightweight — no PyTorch) ─────────────────
step "4/5 — Install Python dependencies"
# e2-micro has 1 GB RAM — skip PyTorch (too large for local install)
# Training runs on Vertex AI A100, not here
grep -v "^torch" "${REPO_DIR}/requirements.txt" \
    | pip3 install -q -r /dev/stdin
ok "Python packages installed (PyTorch excluded — use Vertex AI for training)."

# ── 5. Configure environment ─────────────────────────────────────────────────
step "5/5 — Configure login environment"

PROFILE="${HOME}/.bashrc"

# Auto-cd to repo on login
grep -qF "dc-world-model-tutorial" "${PROFILE}" || \
    echo "cd ${REPO_DIR} 2>/dev/null || true" >> "${PROFILE}"

# Source config.env on login
grep -qF "config.env" "${PROFILE}" || \
    echo "[ -f ${REPO_DIR}/deploy/config.env ] && source ${REPO_DIR}/deploy/config.env" >> "${PROFILE}"

source "${REPO_DIR}/deploy/config.env"
ok "Login environment configured."

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║          Workstation ready for the session!              ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Repo     : ${REPO_DIR}"
echo "  Project  : ${GCP_PROJECT}"
echo "  Region   : us-central1-a"
echo ""
echo "  Student first steps:"
echo "    1. gcloud auth login"
echo "    2. gcloud auth application-default login"
echo "    3. python3 deploy/06_generate_failure_data.py"
echo ""
echo "  Note: PyTorch training runs on Vertex AI A100, not this VM."
echo "        This workstation is for gcloud ops, data gen, and bridge script."
echo ""
