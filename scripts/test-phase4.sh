#!/usr/bin/env bash
# scripts/test-phase4.sh — Phase 4 acceptance: Grading & Kafka Events
# Test: 
# 1. Create lab -> verify it's ready.
# 2. Submit lab for grading -> expect 4/4 (since ospf is pre-configured).
# 3. Break the config (no router ospf on r1).
# 4. Submit lab for grading -> expect score < 4.
# 5. Check audit_log DB table to ensure Kafka events were consumed and written.
# Expected: PHASE 4 PASSED ✓

set -euo pipefail

API="http://localhost:4000"
PASS=0; FAIL=0

log()  { echo "[test-phase4] $*"; }
pass() { echo "[PASS] $*"; (( PASS++ )) || true; }
fail() { echo "[FAIL] $*"; (( FAIL++ )) || true; }

# Helper to run a command via WebSocket stream using the Node.js ws helper
ws_exec() {
  local url="$1" cmd="$2" expect="$3"
  cat /mnt/d/Research_Paper/model/scripts/ws-check.js | docker compose exec -T backend node - "$url" "$cmd" "$expect" >/dev/null 2>&1
}

login() {
  local user="$1" pass="$2"
  curl -s -X POST "${API}/api/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${user}\",\"password\":\"${pass}\"}" | jq -r '.token'
}

# ── Check 0: Backend health ───────────────────────────────────────────────────
log "Check 0: Backend health"
HEALTH=$(curl -sf "${API}/health")
echo "${HEALTH}" | jq .
pass "Backend is healthy"

# ── Check 1: Login ────────────────────────────────────────────────────────────
log ""
log "Check 1: Login"
TOKEN=$(login student1 pass123)
[[ -n "${TOKEN}" && "${TOKEN}" != "null" ]] && pass "Login OK" || { fail "Login failed"; exit 1; }

# Clean previous active labs if any
ACTIVE=$(curl -s "${API}/api/labs" -H "Authorization: Bearer ${TOKEN}" | jq -r '.[0].id // empty')
if [[ -n "${ACTIVE}" ]]; then
  log "Cleaning up old lab ${ACTIVE}"
  curl -s -X DELETE "${API}/api/labs/${ACTIVE}" -H "Authorization: Bearer ${TOKEN}" >/dev/null
fi

# ── Check 2: Create lab ───────────────────────────────────────────────────────
log ""
log "Check 2: Create OSPF lab"
CREATE_RESP=$(curl -sf -X POST "${API}/api/labs" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"template":"ospf"}')
LAB_ID=$(echo "${CREATE_RESP}" | jq -r '.id')
[[ -n "${LAB_ID}" && "${LAB_ID}" != "null" ]] && pass "Lab created: ${LAB_ID}" || { fail "Lab creation failed"; exit 1; }

# ── Check 3: Wait for Ready ───────────────────────────────────────────────────
log ""
log "Check 3: Waiting for pod Ready (up to 120s)..."
TIMEOUT=120; ELAPSED=0
while (( ELAPSED < TIMEOUT )); do
  STATUS=$(curl -sf "${API}/api/labs/${LAB_ID}" \
    -H "Authorization: Bearer ${TOKEN}" | jq -r '.status' 2>/dev/null || echo "error")
  log "  Status: ${STATUS} (${ELAPSED}s)"
  [[ "${STATUS}" == "ready"  ]] && { pass "Pod Ready after ${ELAPSED}s"; break; }
  [[ "${STATUS}" == "failed" ]] && { fail "Pod failed"; exit 1; }
  sleep 5; ELAPSED=$(( ELAPSED + 5 ))
done
[[ "${STATUS}" == "ready" ]] || { fail "Pod did not become ready"; exit 1; }

# Give OSPF a few seconds to form adjacencies
log "Waiting 10s for OSPF adjacencies to form..."
sleep 10

# ── Check 4: Initial Grading (Should be 4/4) ──────────────────────────────────
log ""
log "Check 4: Submit lab for grading (Expect 4/4)"
GRADE1_RESP=$(curl -sf -X POST "${API}/api/labs/${LAB_ID}/submit" \
  -H "Authorization: Bearer ${TOKEN}")
SCORE1=$(echo "${GRADE1_RESP}" | jq -r '.score')
MAX_SCORE1=$(echo "${GRADE1_RESP}" | jq -r '.maxScore')

if [[ "${SCORE1}" == "4" && "${MAX_SCORE1}" == "4" ]]; then
  pass "Initial grading scored ${SCORE1}/${MAX_SCORE1}"
else
  fail "Initial grading scored ${SCORE1}/${MAX_SCORE1}, expected 4/4"
fi

# ── Check 5: Break Config & Regrade ───────────────────────────────────────────
log ""
log "Check 5: Break OSPF config on r1 and submit again"
WS_URL_R1="ws://localhost:4000/ws/console?labId=${LAB_ID}&netns=r1&isRouter=true&token=${TOKEN}"

# Execute command to remove OSPF from r1
# Using the ws helper. Send: conf t \n no router ospf \n end
cat /mnt/d/Research_Paper/model/scripts/ws-check.js | docker compose exec -T backend node - "${WS_URL_R1}" "conf t
no router ospf
end" "anything" >/dev/null 2>&1 || true

log "Waiting 5s for OSPF teardown..."
sleep 5

GRADE2_RESP=$(curl -sf -X POST "${API}/api/labs/${LAB_ID}/submit" \
  -H "Authorization: Bearer ${TOKEN}")
SCORE2=$(echo "${GRADE2_RESP}" | jq -r '.score')

if (( SCORE2 < 4 )); then
  pass "Broken grading scored ${SCORE2}/${MAX_SCORE1} (less than 4)"
else
  fail "Broken grading still scored ${SCORE2}/${MAX_SCORE1}"
fi

# ── Check 6: Verify Kafka Events in DB ────────────────────────────────────────
log ""
log "Check 6: Verify Kafka events reached audit_log"
# Wait a moment for Kafka consumer to process messages
sleep 3

# Query postgres container directly
AUDIT_LOG_COUNT=$(docker compose exec postgres psql -U netlab -d netlab -t -c "SELECT count(*) FROM audit_log WHERE resource_id='${LAB_ID}' OR resource='submission';")
AUDIT_LOG_COUNT=$(echo "${AUDIT_LOG_COUNT}" | xargs)

if (( AUDIT_LOG_COUNT >= 3 )); then
  pass "Found ${AUDIT_LOG_COUNT} audit_log entries via Kafka"
else
  fail "Expected at least 3 audit_log entries, found ${AUDIT_LOG_COUNT}"
fi

# ── Cleanup ───────────────────────────────────────────────────────────────────
log ""
log "Cleanup: deleting lab ${LAB_ID}"
DEL_RESP=$(curl -sf -X DELETE "${API}/api/labs/${LAB_ID}" \
  -H "Authorization: Bearer ${TOKEN}")
echo "${DEL_RESP}" | jq -r '.message' | grep -q "destroyed" \
  && pass "Lab deleted" \
  || fail "Lab delete failed: ${DEL_RESP}"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
if (( FAIL == 0 )); then
  echo "  PHASE 4 PASSED ✓  (${PASS} checks passed)"
  exit 0
else
  echo "  PHASE 4 PARTIAL: ${PASS} passed, ${FAIL} FAILED"
  exit 1
fi
echo "═══════════════════════════════════════════════════"
