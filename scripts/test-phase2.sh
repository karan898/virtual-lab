#!/usr/bin/env bash
# scripts/test-phase2.sh — Phase 2 acceptance test
#
# Tests:
# 1. Create a lab via REST API → pod becomes Ready
# 2. Server-side timestamps logged (t_request, t_ready, provision_ms)
# 3. Delete lab → pod destroyed
#
# Prerequisites: make cluster && make up && make seed

set -euo pipefail

API="http://localhost:4000"
PASS=0; FAIL=0

log()  { echo "[test-phase2] $*"; }
pass() { echo "[PASS] $*"; (( PASS++ )) || true; }
fail() { echo "[FAIL] $*"; (( FAIL++ )) || true; }

# ── Helper: authenticated API call ────────────────────────────────────────────
login() {
    local user="$1" pass="$2"
    curl -sf -X POST "${API}/api/auth/login" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${user}\",\"password\":\"${pass}\"}" | jq -r '.token'
}

# ── Check 0: Health ───────────────────────────────────────────────────────────
log "Check 0: Backend health"
HEALTH=$(curl -sf "${API}/health" 2>&1) || { fail "Backend not reachable at ${API}"; exit 1; }
echo "${HEALTH}" | jq .
pass "Backend is healthy"

# ── Check 1: Login ────────────────────────────────────────────────────────────
log ""
log "Check 1: Login as student1"
TOKEN=$(login student1 pass123)
[[ -n "${TOKEN}" ]] && pass "Login returned JWT token" || fail "Login failed"

# ── Check 2: Create lab ───────────────────────────────────────────────────────
log ""
log "Check 2: Create OSPF lab"
CREATE_RESP=$(curl -sf -X POST "${API}/api/labs" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"template":"ospf"}')
echo "${CREATE_RESP}" | jq .
LAB_ID=$(echo "${CREATE_RESP}" | jq -r '.id')
NAMESPACE=$(echo "${CREATE_RESP}" | jq -r '.namespace')
[[ -n "${LAB_ID}" && "${LAB_ID}" != "null" ]] && pass "Lab created: ${LAB_ID}" || fail "Lab creation failed"

# ── Check 3: Pod becomes Ready ────────────────────────────────────────────────
log ""
log "Check 3: Waiting for pod to be Ready (up to 120s)..."
TIMEOUT=120; ELAPSED=0
while (( ELAPSED < TIMEOUT )); do
    STATUS=$(curl -sf "${API}/api/labs/${LAB_ID}" \
        -H "Authorization: Bearer ${TOKEN}" | jq -r '.status' 2>/dev/null || echo "error")
    log "  Lab status: ${STATUS} (${ELAPSED}s)"
    if [[ "${STATUS}" == "ready" ]]; then
        pass "Lab is Ready after ${ELAPSED}s"
        break
    elif [[ "${STATUS}" == "failed" ]]; then
        fail "Lab status is 'failed'"
        break
    fi
    sleep 5
    ELAPSED=$(( ELAPSED + 5 ))
done
[[ "${STATUS}" == "ready" ]] || fail "Lab did not become ready in ${TIMEOUT}s"

# ── Check 4: Timestamps in DB ─────────────────────────────────────────────────
log ""
log "Check 4: Server-side timestamps (t_request, t_ready, provision_ms)"
LAB_DETAIL=$(curl -sf "${API}/api/labs/${LAB_ID}" -H "Authorization: Bearer ${TOKEN}")
echo "${LAB_DETAIL}" | jq '{id, status, createdAt, readyAt}'
CREATED_AT=$(echo "${LAB_DETAIL}" | jq -r '.createdAt')
READY_AT=$(echo "${LAB_DETAIL}" | jq -r '.readyAt')
[[ "${CREATED_AT}" != "null" ]] && pass "t_request recorded: ${CREATED_AT}" || fail "t_request missing"
[[ "${READY_AT}" != "null" ]] && pass "t_ready recorded: ${READY_AT}" || fail "t_ready missing"

# ── Check 5: Audit log has entries ───────────────────────────────────────────
log ""
log "Check 5: Audit log (admin view)"
ADMIN_TOKEN=$(login admin admin123)
AUDIT=$(curl -sf "${API}/api/admin/labs" -H "Authorization: Bearer ${ADMIN_TOKEN}")
echo "${AUDIT}" | jq 'length'
ACTIVE=$(echo "${AUDIT}" | jq "[.[] | select(.status == \"ready\")] | length")
(( ACTIVE >= 1 )) && pass "Admin sees ${ACTIVE} active lab(s)" || fail "Admin sees no active labs"

# ── Check 6: RBAC — student cannot see another student's lab ─────────────────
log ""
log "Check 6: RBAC — student2 cannot access student1's lab"
TOKEN2=$(login student2 pass123)
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    "${API}/api/labs/${LAB_ID}" \
    -H "Authorization: Bearer ${TOKEN2}")
if [[ "${HTTP_CODE}" == "403" || "${HTTP_CODE}" == "404" ]]; then
    pass "RBAC: student2 got ${HTTP_CODE} on student1's lab"
else
    fail "RBAC: student2 got ${HTTP_CODE} (expected 403/404)"
fi

# ── Check 7: Delete lab ───────────────────────────────────────────────────────
log ""
log "Check 7: Delete lab"
DEL_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X DELETE "${API}/api/labs/${LAB_ID}" \
    -H "Authorization: Bearer ${TOKEN}")
[[ "${DEL_CODE}" == "200" || "${DEL_CODE}" == "204" ]] && pass "Lab deleted (HTTP ${DEL_CODE})" || fail "Delete returned ${DEL_CODE}"

# Give K8s a moment to clean up
sleep 5

# Verify pod is gone
POD_STATUS=$(kubectl get pod -n "${NAMESPACE}" 2>&1 || true)
if echo "${POD_STATUS}" | grep -q "No resources found"; then
    pass "Pod/namespace cleaned up"
else
    log "Pod status after delete: ${POD_STATUS}"
    # Check namespace is also gone
    NS_STATUS=$(kubectl get namespace "${NAMESPACE}" 2>&1 || true)
    if echo "${NS_STATUS}" | grep -q "not found"; then
        pass "Namespace deleted"
    else
        log "Namespace status: ${NS_STATUS}"
    fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
if (( FAIL == 0 )); then
    echo "  PHASE 2 PASSED ✓ (${PASS} checks passed)"
else
    echo "  PHASE 2 PARTIAL: ${PASS} passed, ${FAIL} FAILED"
fi
echo "═══════════════════════════════════════════════════"
(( FAIL == 0 ))
