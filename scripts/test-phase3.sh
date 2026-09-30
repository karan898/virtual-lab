#!/usr/bin/env bash
# scripts/test-phase3.sh — Phase 3 acceptance: WebSocket terminal console
# Test: open WS → send command → receive output → exit
# Expected: PHASE 3 PASSED ✓

set -euo pipefail

API="http://localhost:4000"
WS_HOST="localhost:4000"
PASS=0; FAIL=0

log()  { echo "[test-phase3] $*"; }
pass() { echo "[PASS] $*"; (( PASS++ )) || true; }
fail() { echo "[FAIL] $*"; (( FAIL++ )) || true; }

# Helper to run the node WS check inside the backend container
# (backend has 'ws' library installed)
ws_check() {
  local url="$1" cmd="$2" expect="$3"
  cat /mnt/d/Research_Paper/model/scripts/ws-check.js | docker compose exec -T backend node - "$url" "$cmd" "$expect"
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

# ── Check 4: WebSocket to host (h1 — bash) ───────────────────────────────────
log ""
log "Check 4: WebSocket terminal — netns h1 (bash)"
# Use internal docker host to connect since we run in backend container
WS_URL="ws://localhost:4000/ws/console?labId=${LAB_ID}&netns=h1&isRouter=false&token=${TOKEN}"

if ws_check "${WS_URL}" "ip addr show lo" "127.0.0.1"; then
  pass "h1 bash: got loopback addr in ip addr output"
else
  fail "h1 bash: expected '127.0.0.1' in output"
fi

# ── Check 5: WebSocket to router (r1 — vtysh) ────────────────────────────────
log ""
log "Check 5: WebSocket terminal — netns r1 (vtysh)"
WS_URL_R="ws://localhost:4000/ws/console?labId=${LAB_ID}&netns=r1&isRouter=true&token=${TOKEN}"

if ws_check "${WS_URL_R}" "show version" "FRRouting"; then
  pass "r1 vtysh: got FRRouting version string"
else
  fail "r1 vtysh: expected FRRouting output"
fi

# ── Check 6: RBAC — student2 cannot open student1 console ────────────────────
log ""
log "Check 6: RBAC — student2 cannot open student1 console"
S2_TOKEN=$(login student2 pass123)
WS_URL_S2="ws://localhost:4000/ws/console?labId=${LAB_ID}&netns=h1&isRouter=false&token=${S2_TOKEN}"

# If node script exits with 2, it was 4003 Forbidden
ws_check "${WS_URL_S2}" "ls" "anything" > /dev/null 2>&1 || S2_EXIT=$?
if [[ "${S2_EXIT:-0}" == "2" ]]; then
  pass "RBAC: student2 denied (WS closed 4003)"
else
  fail "RBAC: student2 should have been denied, got exit code ${S2_EXIT:-0}"
fi

# ── Check 7: Prometheus metrics record ───────────────────────────────────────
log ""
log "Check 7: Prometheus /metrics endpoint"
METRICS=$(curl -sf "${API}/metrics")
echo "${METRICS}" | grep -q "process_cpu_seconds_total" \
  && pass "Prometheus metrics served" \
  || fail "Prometheus metrics endpoint failed"

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
  echo "  PHASE 3 PASSED ✓  (${PASS} checks passed)"
  exit 0
else
  echo "  PHASE 3 PARTIAL: ${PASS} passed, ${FAIL} FAILED"
  exit 1
fi
echo "═══════════════════════════════════════════════════"
