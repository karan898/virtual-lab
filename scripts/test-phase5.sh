#!/usr/bin/env bash
# scripts/test-phase5.sh — Phase 5 acceptance: Frontend UI
# Test: 
# 1. Verify Nginx is serving the index.html page on port 3000.
# 2. Extract asset URLs (JS/CSS) from index.html and verify they return HTTP 200.
# 3. Verify Nginx proxying is working by logging in via port 3000.
# 4. Verify xterm.js is present in the main JS bundle.
# Expected: PHASE 5 PASSED ✓

set -euo pipefail

FRONTEND_URL="http://localhost:3000"
PASS=0; FAIL=0

log()  { echo "[test-phase5] $*"; }
pass() { echo "[PASS] $*"; (( PASS++ )) || true; }
fail() { echo "[FAIL] $*"; (( FAIL++ )) || true; }

# ── Check 1: Fetch index.html ────────────────────────────────────────────────
log "Check 1: Fetching index.html from Nginx"
INDEX_HTML=$(curl -sf "${FRONTEND_URL}/")
if echo "${INDEX_HTML}" | grep -q 'id="root"'; then
  pass "index.html contains <div id=\"root\">"
else
  fail "index.html did not contain root div"
fi

# ── Check 2: Verify Assets ───────────────────────────────────────────────────
log ""
log "Check 2: Verifying JS and CSS assets"
JS_ASSET=$(echo "${INDEX_HTML}" | grep -oE '/assets/index-[a-zA-Z0-9_-]+\.js')
CSS_ASSET=$(echo "${INDEX_HTML}" | grep -oE '/assets/index-[a-zA-Z0-9_-]+\.css')

if [[ -n "${JS_ASSET}" ]]; then
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${FRONTEND_URL}${JS_ASSET}")
  if [[ "${HTTP_STATUS}" == "200" ]]; then
    pass "JS asset ${JS_ASSET} is reachable (HTTP 200)"
  else
    fail "JS asset ${JS_ASSET} returned HTTP ${HTTP_STATUS}"
  fi
else
  fail "Could not find JS asset in index.html"
fi

if [[ -n "${CSS_ASSET}" ]]; then
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${FRONTEND_URL}${CSS_ASSET}")
  if [[ "${HTTP_STATUS}" == "200" ]]; then
    pass "CSS asset ${CSS_ASSET} is reachable (HTTP 200)"
  else
    fail "CSS asset ${CSS_ASSET} returned HTTP ${HTTP_STATUS}"
  fi
else
  fail "Could not find CSS asset in index.html"
fi

# ── Check 3: Check Nginx Proxy to Backend ────────────────────────────────────
log ""
log "Check 3: Nginx Proxy to Backend (/api/auth/login)"
LOGIN_RESP=$(curl -s -X POST "${FRONTEND_URL}/api/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"username":"student1","password":"pass123"}')

TOKEN=$(echo "${LOGIN_RESP}" | jq -r '.token // empty')
if [[ -n "${TOKEN}" ]]; then
  pass "Nginx successfully proxied API request (got JWT)"
else
  fail "Nginx proxy failed. Response: ${LOGIN_RESP}"
fi

# ── Check 4: Verify xterm is in the JS Bundle ────────────────────────────────
log ""
log "Check 4: Verifying xterm.js is bundled"
if curl -sf "${FRONTEND_URL}${JS_ASSET}" | grep -cai 'xterm' > /dev/null; then
  pass "xterm.js code found in the bundled JS file"
else
  fail "xterm.js not found in bundle"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
if (( FAIL == 0 )); then
  echo "  PHASE 5 PASSED ✓  (${PASS} checks passed)"
  exit 0
else
  echo "  PHASE 5 PARTIAL: ${PASS} passed, ${FAIL} FAILED"
  exit 1
fi
echo "═══════════════════════════════════════════════════"
