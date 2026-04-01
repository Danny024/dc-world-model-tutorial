#!/usr/bin/env bash
# ============================================================
# compile_trt_engine.sh — Compile ONNX → TensorRT engine on Jetson Nano
# ============================================================
# Run this script ON the Jetson Nano itself (not cross-compiled on x86).
# It converts master_v1.onnx into a device-specific TensorRT engine
# for 3–5× faster inference, then uploads the result to GCS as a
# backup for other students whose compilation may hang.
#
# If compilation times out (default: 15 min), the script falls back to
# pulling a pre-compiled engine from GCS, or instructs the student to
# use the ONNX Runtime path directly.
#
# Prerequisites on Jetson:
#   - JetPack installed (TensorRT ships with JetPack)
#   - gcloud CLI authenticated (for GCS upload/download)
#
# Usage:
#   # JetPack 5.x (default):
#   ONNX_PATH=/opt/models/public/master_v1.onnx bash deploy/compile_trt_engine.sh
#
#   # JetPack 4.6 — use the opset-13 model:
#   JETPACK_VERSION=4.6 \
#   ONNX_PATH=/opt/models/public/master_v1_jp46.onnx \
#   TRT_OUTPUT=/opt/models/public/master_v1_jp46.trt \
#   bash deploy/compile_trt_engine.sh
#
# Environment variables (all optional — defaults shown):
#   JETPACK_VERSION   4.6 or 5 (default: 5)
#   ONNX_PATH         Path to ONNX file (default: /opt/models/public/master_v1.onnx)
#   TRT_OUTPUT        Where to save the compiled engine (default: /opt/models/public/master_v1.trt)
#   GCS_TRT_PREFIX    GCS path for GCS backup upload (default: gs://hmth391-omniverse-assets/models/public)
#   TIMEOUT_SECS      Max compile time in seconds (default: 900 = 15 min)
# ============================================================
set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step() { echo -e "\n${YELLOW}▶ $*${NC}"; }
info() { echo -e "${CYAN}[i]${NC}  $*"; }

# ── Configuration ─────────────────────────────────────────────────────────────
JETPACK_VERSION="${JETPACK_VERSION:-5}"
ONNX_PATH="${ONNX_PATH:-/opt/models/public/master_v1.onnx}"
TRT_OUTPUT="${TRT_OUTPUT:-/opt/models/public/master_v1.trt}"
GCS_TRT_PREFIX="${GCS_TRT_PREFIX:-gs://hmth391-omniverse-assets/models/public}"
TIMEOUT_SECS="${TIMEOUT_SECS:-900}"   # 15 min — Nano Maxwell can take 8–12 min
TRTEXEC_PATH="${TRTEXEC_PATH:-/usr/src/tensorrt/bin/trtexec}"
LOG_FILE="/tmp/trtexec_compile.log"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║   TensorRT Engine Compilation — Jetson Nano              ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  JetPack  : ${JETPACK_VERSION}"
echo "  ONNX     : ${ONNX_PATH}"
echo "  Output   : ${TRT_OUTPUT}"
echo "  Timeout  : ${TIMEOUT_SECS}s"
echo ""

# ── Step 1: Validate inputs ───────────────────────────────────────────────────
step "1/5 — Validate environment"

if [ ! -f "${ONNX_PATH}" ]; then
    fail "ONNX file not found: ${ONNX_PATH}
  Download with:
    mkdir -p \$(dirname ${ONNX_PATH})
    wget -O ${ONNX_PATH} \\
      https://storage.googleapis.com/hmth391-omniverse-assets/models/public/master_v1.onnx"
fi
ok "ONNX file found: ${ONNX_PATH}"

if [ ! -f "${TRTEXEC_PATH}" ]; then
    # Try common alternative locations
    for alt in /usr/bin/trtexec /usr/local/bin/trtexec; do
        if [ -f "${alt}" ]; then
            TRTEXEC_PATH="${alt}"
            break
        fi
    done
fi
if [ ! -f "${TRTEXEC_PATH}" ]; then
    fail "trtexec not found. Expected: /usr/src/tensorrt/bin/trtexec
  Install TensorRT: sudo apt-get install -y tensorrt
  Or check your JetPack installation."
fi
ok "trtexec found: ${TRTEXEC_PATH}"

# ── Step 2: JetPack 4.6 opset sanity check ───────────────────────────────────
step "2/5 — Opset compatibility check"

if [ "${JETPACK_VERSION}" = "4" ] || [ "${JETPACK_VERSION}" = "4.6" ]; then
    info "JetPack 4.6 detected. TensorRT 8.2.x supports ONNX opset ≤ 13."
    # Check opset using Python if onnx package is available
    OPSET=$(python3 - <<'PYCHECK' 2>/dev/null || echo "unknown"
import sys
try:
    import onnx
    import os
    m = onnx.load(os.environ.get("ONNX_PATH", ""))
    print(m.opset_import[0].version)
except Exception:
    print("unknown")
PYCHECK
    )
    if [ "${OPSET}" != "unknown" ] && [ "${OPSET}" -gt 13 ] 2>/dev/null; then
        fail "ONNX model uses opset ${OPSET}, but TensorRT 8.2.x (JetPack 4.6) only supports ≤ 13.
  Export a JetPack 4.6 compatible model from the instructor machine:
    python deploy/export_edge.py \\
        --model-ckpt model_output/best_model.pt \\
        --output-name master_v1_jp46.onnx \\
        --opset 13 --public
  Then download:
    wget -O ${ONNX_PATH} \\
      https://storage.googleapis.com/hmth391-omniverse-assets/models/public/master_v1_jp46.onnx"
    fi
    if [ "${OPSET}" != "unknown" ]; then
        ok "ONNX opset ${OPSET} is compatible with JetPack 4.6."
    else
        warn "Could not verify opset (onnx package not installed). Proceeding."
    fi
else
    ok "JetPack 5.x — opset check not required."
fi

# ── Step 3: Compile ───────────────────────────────────────────────────────────
step "3/5 — Compile ONNX → TensorRT engine (this can take 5–15 min)"
info "Output: ${TRT_OUTPUT}"
info "Log:    ${LOG_FILE}"
info "Press Ctrl-C to cancel and fall back to ONNX Runtime."
echo ""

mkdir -p "$(dirname "${TRT_OUTPUT}")"

timeout "${TIMEOUT_SECS}" "${TRTEXEC_PATH}" \
    --onnx="${ONNX_PATH}" \
    --saveEngine="${TRT_OUTPUT}" \
    --fp16 \
    --workspace=512 \
    2>&1 | tee "${LOG_FILE}"
COMPILE_EXIT=${PIPESTATUS[0]}

# ── Step 4: Handle result ─────────────────────────────────────────────────────
step "4/5 — Check compile result"

if [ "${COMPILE_EXIT}" -eq 124 ]; then
    warn "trtexec timed out after ${TIMEOUT_SECS}s."
    echo ""
    echo "  Attempting to pull a pre-compiled engine from GCS..."
    if command -v gcloud &>/dev/null && \
       gcloud storage cp "${GCS_TRT_PREFIX}/$(basename "${TRT_OUTPUT}")" \
           "${TRT_OUTPUT}" 2>/dev/null; then
        ok "Pre-compiled engine downloaded from GCS: ${TRT_OUTPUT}"
        echo ""
        info "Note: This engine was compiled on a different Jetson."
        info "If it fails to load, set MODEL_ONNX_PATH to the ONNX file instead:"
        info "  MODEL_ONNX_PATH=${ONNX_PATH} python3 inference_server.py"
    else
        warn "No pre-compiled engine in GCS yet."
        echo ""
        echo "  Use the ONNX Runtime fallback (slightly slower, works on all Jetsons):"
        echo "    MODEL_ONNX_PATH=${ONNX_PATH} python3 inference_server.py"
        echo ""
        echo "  Or use the PyTorch fallback (slowest, always works):"
        echo "    MODEL_GCS_URI=gs://hmth391-omniverse-assets/models/best_model.pt \\"
        echo "    python3 inference_server.py"
        exit 0
    fi

elif [ "${COMPILE_EXIT}" -ne 0 ]; then
    fail "trtexec failed (exit code ${COMPILE_EXIT}).
  See ${LOG_FILE} for details.
  Common causes:
    - Opset mismatch (JP4.6 requires ≤ 13): re-run with ONNX_PATH pointing to master_v1_jp46.onnx
    - Out of memory: reduce --workspace=512 to --workspace=256
    - Unsupported layer: check log for 'ModelImporter' errors"
else
    ok "TRT engine compiled successfully: ${TRT_OUTPUT}"
fi

# ── Step 5: Upload to GCS as backup ──────────────────────────────────────────
step "5/5 — Upload compiled engine to GCS (backup for other students)"

if [ -f "${TRT_OUTPUT}" ] && command -v gcloud &>/dev/null; then
    GCS_DEST="${GCS_TRT_PREFIX}/$(basename "${TRT_OUTPUT}")"
    echo "  Uploading to ${GCS_DEST} ..."
    if gcloud storage cp "${TRT_OUTPUT}" "${GCS_DEST}" 2>/dev/null; then
        ok "Uploaded: ${GCS_DEST}"
        info "Other students can pull it with:"
        info "  gcloud storage cp ${GCS_DEST} ${TRT_OUTPUT}"
    else
        warn "GCS upload failed (not authenticated or no write access)."
        info "This is OK — the engine is compiled locally and will still run."
    fi
else
    info "Skipping GCS upload (gcloud not available or engine missing)."
fi

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║              Compilation complete!                       ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  TRT engine  : ${TRT_OUTPUT}"
echo ""
echo "  Run inference server with TRT:"
echo "    MODEL_ONNX_PATH=${TRT_OUTPUT} python3 inference_server.py"
echo ""
echo "  Or in Docker:"
echo "    docker run -d --runtime nvidia -p 8080:8080 \\"
echo "      -e MODEL_ONNX_PATH=${TRT_OUTPUT} \\"
echo "      -v \$(dirname ${TRT_OUTPUT}):\$(dirname ${TRT_OUTPUT}) \\"
echo "      us-central1-docker.pkg.dev/hmth391/world-model-repo/datacenter-inference:jetson-latest"
echo ""
