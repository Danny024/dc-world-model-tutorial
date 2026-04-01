#!/usr/bin/env bash
# ============================================================
# dry_run_handshake.sh — Codespaces → Jetson Nano connectivity test
# ============================================================
# Run this from GitHub Codespaces (or Cloud Shell) to verify that
# the inference bridge can reach the Jetson Nano before April 30.
#
# Scheduled dry run: April 23, 2026 (one week before the workshop).
#
# What this tests:
#   Step 1 — HTTP health check (curl → Jetson :8080/health)
#   Step 2 — Single /predict POST (12-timestep window)
#   Step 3 — 5-cycle bridge dry-run (09_inference_bridge.py --dry-run)
#   Step 4 — 10-request latency measurement
#   Step 5 — Print final connection summary for copy-paste on April 30
#
# Prerequisites:
#   On Jetson Nano:
#     1. Inference container running: docker ps | grep datacenter-inference
#     2. Port 8080 reachable: sudo ufw allow 8080/tcp
#     3. Get IP: hostname -I | awk '{print $1}'
#
#   In Codespaces:
#     1. sensor_timeseries.csv generated (Phase 6):
#          python3 deploy/06_generate_failure_data.py
#     2. Python deps installed: bash deploy/student_setup.sh
#
# Usage:
#   JETSON_IP=192.168.1.42 bash deploy/dry_run_handshake.sh
#
#   # Custom port (default: 8080):
#   JETSON_IP=192.168.1.42 JETSON_PORT=9090 bash deploy/dry_run_handshake.sh
# ============================================================
set -uo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; FAILED=$((FAILED+1)); }
step()  { echo -e "\n${YELLOW}▶ $*${NC}"; }
info()  { echo -e "${CYAN}[i]${NC}    $*"; }
FAILED=0

# ── Configuration ─────────────────────────────────────────────────────────────
JETSON_IP="${JETSON_IP:-}"
JETSON_PORT="${JETSON_PORT:-8080}"
SERVICE_URL="http://${JETSON_IP}:${JETSON_PORT}"
BRIDGE_SCRIPT="deploy/09_inference_bridge.py"
CONFIG_FILE="deploy/09_inference_config.toml"
CSV_FILE="${CSV_FILE:-sensor_timeseries.csv}"
HTTP_TIMEOUT=10    # seconds for curl requests
LATENCY_RUNS=10    # number of requests for latency measurement

# ── Require JETSON_IP ─────────────────────────────────────────────────────────
if [ -z "${JETSON_IP}" ]; then
    echo ""
    echo "Usage: JETSON_IP=<nano-ip> bash deploy/dry_run_handshake.sh"
    echo ""
    echo "  Find the Jetson IP address on the Nano:"
    echo "    hostname -I | awk '{print \$1}'"
    echo ""
    echo "  Example:"
    echo "    JETSON_IP=192.168.1.42 bash deploy/dry_run_handshake.sh"
    echo ""
    exit 1
fi

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║   Codespaces → Jetson Nano Handshake Dry Run             ║"
echo "║   Scheduled: April 23, 2026                              ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Jetson target : ${SERVICE_URL}"
echo "  CSV file      : ${CSV_FILE}"
echo ""

# ── Step 1: HTTP health check ─────────────────────────────────────────────────
step "Step 1/5 — HTTP health check"

HEALTH_RESP=$(curl -sf --max-time "${HTTP_TIMEOUT}" \
    "${SERVICE_URL}/health" 2>&1) && CURL_OK=0 || CURL_OK=$?

if [ "${CURL_OK}" -ne 0 ]; then
    fail "Cannot reach Jetson at ${SERVICE_URL}/health (exit: ${CURL_OK})"
    echo ""
    echo "  Fixes:"
    echo "    On Jetson: docker ps           (confirm container is running)"
    echo "    On Jetson: sudo ufw allow 8080/tcp"
    echo "    Verify JETSON_IP=${JETSON_IP} is correct: hostname -I | awk '{print \$1}'"
    echo "    If on restricted network: SSH tunnel may be required"
    echo "      ssh -L 8080:localhost:8080 user@<jetson-ip>"
    echo "      Then use JETSON_IP=127.0.0.1 JETSON_PORT=8080"
else
    ok "Health check passed: ${HEALTH_RESP}"
fi

# ── Step 2: Single /predict POST ──────────────────────────────────────────────
step "Step 2/5 — Single prediction POST (/predict)"

# A 12-timestep window showing an overheating pattern (temp rising)
WINDOW_JSON='{"window": [
  [42.1,8.3,0.97,0.61],[42.4,8.4,0.97,0.63],[42.8,8.5,0.96,0.65],
  [43.2,8.6,0.96,0.67],[43.7,8.7,0.95,0.69],[44.2,8.8,0.95,0.71],
  [44.8,8.9,0.94,0.73],[45.4,9.0,0.93,0.75],[46.1,9.1,0.93,0.77],
  [46.8,9.2,0.92,0.79],[47.6,9.3,0.91,0.81],[48.5,9.4,0.90,0.83]
]}'

PRED_RESP=$(curl -sf --max-time "${HTTP_TIMEOUT}" \
    -H "Content-Type: application/json" \
    -d "${WINDOW_JSON}" \
    "${SERVICE_URL}/predict" 2>&1) && PRED_OK=0 || PRED_OK=$?

if [ "${PRED_OK}" -ne 0 ]; then
    fail "/predict POST failed (exit: ${PRED_OK})"
    echo "  Response: ${PRED_RESP}"
    echo "  Fixes:"
    echo "    - Confirm model is loaded: curl ${SERVICE_URL}/health | grep model_loaded"
    echo "    - Check MODEL_ONNX_PATH is set in the container"
elif ! echo "${PRED_RESP}" | grep -q '"1h"'; then
    fail "/predict response missing '1h' field"
    echo "  Response: ${PRED_RESP}"
else
    ok "Single prediction OK: ${PRED_RESP}"
fi

# ── Step 3: Bridge dry-run ────────────────────────────────────────────────────
step "Step 3/5 — Inference bridge dry-run (5 poll cycles)"

if [ ! -f "${CSV_FILE}" ]; then
    warn "CSV file not found: ${CSV_FILE}"
    info "Generate it first: python3 deploy/06_generate_failure_data.py"
    info "Skipping bridge dry-run."
elif [ ! -f "${BRIDGE_SCRIPT}" ]; then
    warn "Bridge script not found: ${BRIDGE_SCRIPT}"
    info "Run from repo root: cd dc-world-model-tutorial"
    info "Skipping bridge dry-run."
else
    BRIDGE_OUTPUT=$(python3 "${BRIDGE_SCRIPT}" \
        --config "${CONFIG_FILE}" \
        --csv "${CSV_FILE}" \
        --service-url "${SERVICE_URL%/}" \
        --no-kit \
        --dry-run \
        2>&1 | head -40) && BRIDGE_OK=0 || BRIDGE_OK=$?

    if echo "${BRIDGE_OUTPUT}" | grep -q "Traceback\|ImportError\|ModuleNotFoundError"; then
        fail "Bridge dry-run failed with Python error"
        echo "  Output:"
        echo "${BRIDGE_OUTPUT}" | sed 's/^/    /'
        echo ""
        info "Fixes: bash deploy/student_setup.sh  (re-install deps)"
    elif [ "${BRIDGE_OK}" -ne 0 ] && echo "${BRIDGE_OUTPUT}" | grep -q "ERROR"; then
        fail "Bridge dry-run returned errors"
        echo "${BRIDGE_OUTPUT}" | grep "ERROR" | sed 's/^/    /'
    else
        ok "Bridge dry-run passed."
        info "Sample output (first 5 lines):"
        echo "${BRIDGE_OUTPUT}" | head -5 | sed 's/^/    /'
    fi
fi

# ── Step 4: Latency measurement ───────────────────────────────────────────────
step "Step 4/5 — Latency measurement (${LATENCY_RUNS} requests)"

if [ "${CURL_OK}" -ne 0 ]; then
    warn "Skipping latency test — Jetson not reachable (Step 1 failed)."
else
    TOTAL_MS=0
    MIN_MS=99999
    MAX_MS=0

    for i in $(seq 1 "${LATENCY_RUNS}"); do
        START=$(date +%s%3N)
        curl -sf --max-time 5 \
            -H "Content-Type: application/json" \
            -d "${WINDOW_JSON}" \
            "${SERVICE_URL}/predict" > /dev/null 2>&1 || true
        END=$(date +%s%3N)
        MS=$((END - START))
        TOTAL_MS=$((TOTAL_MS + MS))
        [ "${MS}" -lt "${MIN_MS}" ] && MIN_MS="${MS}"
        [ "${MS}" -gt "${MAX_MS}" ] && MAX_MS="${MS}"
    done

    AVG_MS=$((TOTAL_MS / LATENCY_RUNS))
    ok "${LATENCY_RUNS} requests complete"
    echo "    Avg: ${AVG_MS}ms   Min: ${MIN_MS}ms   Max: ${MAX_MS}ms"

    if [ "${AVG_MS}" -gt 2000 ]; then
        warn "Avg latency ${AVG_MS}ms is high (>2s). On April 30 this may delay live updates."
        info "Consider: pre-compiling TRT engine on Nano (bash deploy/compile_trt_engine.sh)"
    fi
fi

# ── Step 5: Summary ───────────────────────────────────────────────────────────
step "Step 5/5 — Dry run summary"

if [ "${FAILED}" -eq 0 ]; then
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║        Handshake PASSED — ready for April 30!           ║"
    echo "╚══════════════════════════════════════════════════════════╝"
else
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║    ${FAILED} check(s) FAILED — resolve before April 30   ║"
    echo "╚══════════════════════════════════════════════════════════╝"
fi

echo ""
echo "  Jetson target    : ${SERVICE_URL}"
echo "  Health URL       : ${SERVICE_URL}/health"
echo "  Predict URL      : ${SERVICE_URL}/predict"
echo "  Predict/batch URL: ${SERVICE_URL}/predict/batch"
echo ""
echo "  Copy-paste for April 30 full run (remove --dry-run and --no-kit):"
echo ""
echo "    python3 ${BRIDGE_SCRIPT} \\"
echo "      --config ${CONFIG_FILE} \\"
echo "      --csv ${CSV_FILE} \\"
echo "      --service-url ${SERVICE_URL%/}"
echo ""
if [ "${FAILED}" -gt 0 ]; then
    echo "  See docs/dry_run_checklist.md for the full troubleshooting guide."
    echo ""
    exit 1
fi
