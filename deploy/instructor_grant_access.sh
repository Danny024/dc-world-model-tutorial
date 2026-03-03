#!/usr/bin/env bash
# ============================================================
# INSTRUCTOR SCRIPT — Grant Students Access to GCS Assets
# ============================================================
# Run this once per student (or use a Google Group for the class).
#
# Usage — add a single student:
#   bash deploy/instructor_grant_access.sh student@gmail.com
#
# Usage — add a whole class at once (one email per line in a file):
#   bash deploy/instructor_grant_access.sh --file class_roster.txt
#
# Usage — create a shared Google Group and add the group:
#   bash deploy/instructor_grant_access.sh --group atlanta-robotics-class@googlegroups.com
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}  $*"; }
step() { echo -e "\n${YELLOW}▶ $*${NC}"; }

BUCKET="gs://${GCS_BUCKET}"
ROLE="roles/storage.objectViewer"   # read-only: list + download, no upload/delete

grant_member() {
    local MEMBER=$1
    echo "  Granting ${ROLE} to ${MEMBER} on ${BUCKET}..."
    gcloud storage buckets add-iam-policy-binding "${BUCKET}" \
        --member="${MEMBER}" \
        --role="${ROLE}" \
        --project="${GCP_PROJECT_ID}"
    ok "Access granted to ${MEMBER}"
}

# ── Parse arguments ───────────────────────────────────────────────────────────
if [ $# -eq 0 ]; then
    echo "Usage:"
    echo "  Single student : bash deploy/instructor_grant_access.sh student@gmail.com"
    echo "  Class roster   : bash deploy/instructor_grant_access.sh --file class_roster.txt"
    echo "  Google Group   : bash deploy/instructor_grant_access.sh --group group@googlegroups.com"
    exit 0
fi

step "Granting read-only access to ${BUCKET}"

if [ "${1}" = "--file" ]; then
    # Read emails from a file (one per line, # lines are comments)
    ROSTER_FILE="${2:-class_roster.txt}"
    [ -f "${ROSTER_FILE}" ] || { echo "File not found: ${ROSTER_FILE}"; exit 1; }
    while IFS= read -r line || [ -n "${line}" ]; do
        [[ "${line}" =~ ^#.*$ || -z "${line}" ]] && continue
        EMAIL="${line// /}"
        grant_member "user:${EMAIL}"
    done < "${ROSTER_FILE}"

elif [ "${1}" = "--group" ]; then
    # Grant access to an entire Google Group (easiest for large classes)
    GROUP="${2}"
    grant_member "group:${GROUP}"
    echo ""
    echo "  Students join at: https://groups.google.com/g/$(echo ${GROUP} | cut -d@ -f1)"

else
    # Single email address
    EMAIL="${1}"
    grant_member "user:${EMAIL}"
fi

echo ""
step "Current bucket IAM policy (read-only members):"
gcloud storage buckets get-iam-policy "${BUCKET}" \
    --project="${GCP_PROJECT_ID}" \
    --format="table(bindings.role, bindings.members)" 2>/dev/null || \
gcloud storage buckets describe "${BUCKET}" --format=json | \
    python3 -c "import json,sys; p=json.load(sys.stdin); [print(b) for b in p.get('iamConfiguration',{}).get('bindings',[])]" 2>/dev/null || true

echo ""
echo "Share these two things with each student:"
echo ""
echo "  1. Bucket name  : ${GCS_BUCKET}"
echo "  2. Setup command:"
echo ""
echo "     git clone https://github.com/YOUR_USERNAME/dc-world-model-tutorial"
echo "     cd dc-world-model-tutorial"
echo "     GCS_BUCKET=${GCS_BUCKET} bash deploy/student_setup.sh"
echo ""
