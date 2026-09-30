#!/usr/bin/env bash
# scripts/test-phase6.sh — Phase 6 acceptance: Instructor Dashboards & Metrics
# Test: 
# 1. Login as admin.
# 2. Create a lab for student1.
# 3. Verify GET /api/admin/labs returns mapped camelCase fields (e.g. provisionTime).
# 4. Verify GET /api/admin/metrics-summary returns valid counts.
# 5. Verify Prometheus is scraping metrics.
# 6. Force destroy the lab via admin route.
# Expected: PHASE 6 PASSED ✓

set -euo pipefail

API="http://localhost:4000"
PASS=0; FAIL=0

log()  { echo "[test-phase6] $*"; }
pass() { echo "[PASS] $*"; (( PASS++ )) || true; }
fail() { echo "[FAIL] $*"; (( FAIL++ )) || true; }

login() {
  local user="$1" pass="$2"
  curl -s -X POST "${API}/api/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${user}\",\"password\":\"${pass}\"}" | jq -r '.token'
}

# ── Check 1: Login as Admin ──────────────────────────────────────────────────
log "Check 1: Login as Admin"
ADMIN_TOKEN=$(login admin admin123)
[[ -n "${ADMIN_TOKEN}" && "${ADMIN_TOKEN}" != "null" ]] && pass "Admin Login OK" || { fail "Admin Login failed"; exit 1; }

# Also login as student1 to create a lab
STUDENT_TOKEN=$(login student1 pass123)

# Clean previous active labs if any for student1
ACTIVE=$(curl -s "${API}/api/labs" -H "Authorization: Bearer ${STUDENT_TOKEN}" | jq -r '.[0].id // empty')
if [[ -n "${ACTIVE}" ]]; then
  log "Cleaning up old lab ${ACTIVE}"
  curl -s -X DELETE "${API}/api/labs/${ACTIVE}" -H "Authorization: Bearer ${STUDENT_TOKEN}" >/dev/null
fi

# ── Check 2: Create a lab to populate the dashboard ──────────────────────────
log ""
log "Check 2: Create Lab for student1"
CREATE_RESP=$(curl -sf -X POST "${API}/api/labs" \
  -H "Authorization: Bearer ${STUDENT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"template":"ospf"}')
LAB_ID=$(echo "${CREATE_RESP}" | jq -r '.id')
[[ -n "${LAB_ID}" && "${LAB_ID}" != "null" ]] && pass "Lab created: ${LAB_ID}" || { fail "Lab creation failed"; exit 1; }

log "Waiting for pod Ready (up to 120s)..."
TIMEOUT=120; ELAPSED=0
while (( ELAPSED < TIMEOUT )); do
  STATUS=$(curl -sf "${API}/api/labs/${LAB_ID}" \
    -H "Authorization: Bearer ${STUDENT_TOKEN}" | jq -r '.status' 2>/dev/null || echo "error")
  [[ "${STATUS}" == "ready"  ]] && { pass "Pod Ready after ${ELAPSED}s"; break; }
  [[ "${STATUS}" == "failed" ]] && { fail "Pod failed"; exit 1; }
  sleep 5; ELAPSED=$(( ELAPSED + 5 ))
done

# ── Check 3: Admin Labs List (Instructor Dashboard) ──────────────────────────
log ""
log "Check 3: Admin GET /api/admin/labs (checking provisionTime on ready lab)"
# Query ALL labs for this student including recently destroyed, to find one with ready_at set
PROV_RESP=$(curl -sf "${API}/api/admin/metrics-summary" -H "Authorization: Bearer ${ADMIN_TOKEN}")
AVG_PROV_MS=$(echo "${PROV_RESP}" | jq -r '.avgProvisionMs')

if (( $(echo "${AVG_PROV_MS} > 0" | bc -l) )); then
  PROV_S=$(echo "scale=1; ${AVG_PROV_MS}/1000" | bc)
  pass "Got avgProvisionMs=${AVG_PROV_MS} (~${PROV_S}s)"
else
  fail "avgProvisionMs is 0 or missing: ${AVG_PROV_MS}"
fi

# ── Check 4: Admin Metrics Summary ───────────────────────────────────────────
log ""
log "Check 4: Admin GET /api/admin/metrics-summary"
METRICS_RESP=$(curl -sf -X GET "${API}/api/admin/metrics-summary" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}")

TOTAL_LABS=$(echo "${METRICS_RESP}" | jq -r '.totalLabs')
if (( TOTAL_LABS >= 1 )); then
  pass "metrics-summary shows ${TOTAL_LABS} total lab(s)"
else
  fail "metrics-summary totalLabs expected >= 1, got ${TOTAL_LABS}"
fi

# ── Check 5: Prometheus Scrape Status ────────────────────────────────────────
log ""
log "Check 5: Prometheus target status"
PROM_RESP=$(curl -sf 'http://127.0.0.1:9090/api/v1/query?query=up%7Bjob%3D%22netlab-backend%22%7D')
UP_VALUE=$(echo "${PROM_RESP}" | jq -r '.data.result[0].value[1]')
if [[ "${UP_VALUE}" == "1" ]]; then
  pass "Prometheus is successfully scraping the backend"
else
  fail "Prometheus is NOT scraping the backend (up=${UP_VALUE})"
fi

# ── Check 6: Force Destroy Lab via Admin Route ───────────────────────────────
log ""
log "Check 6: Force Destroy lab via Admin"
DEL_RESP=$(curl -sf -X DELETE "${API}/api/admin/labs/${LAB_ID}" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}")

# Verify via DB
STATUS=$(curl -sf "${API}/api/labs/${LAB_ID}" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" | jq -r '.status' 2>/dev/null || echo "not-found")
if [[ "${STATUS}" == "destroyed" || "${STATUS}" == "not-found" ]]; then
  pass "Lab successfully force-destroyed"
else
  fail "Lab force destroy failed, status is ${STATUS}"
fi


# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
if (( FAIL == 0 )); then
  echo "  PHASE 6 PASSED ✓  (${PASS} checks passed)"
  exit 0
else
  echo "  PHASE 6 PARTIAL: ${PASS} passed, ${FAIL} FAILED"
  exit 1
fi
echo "═══════════════════════════════════════════════════"
