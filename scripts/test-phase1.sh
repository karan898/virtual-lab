#!/usr/bin/env bash
# scripts/test-phase1.sh — Phase 1 acceptance test
#
# Runs the lab-node container with the OSPF template,
# then verifies:
#   1. h1 can ping h2 (end-to-end through 3 routers)
#   2. vtysh -N r1 -c "show ip ospf neighbor" shows Full neighbours
#
# Must be run inside WSL2 with Docker available.
# Usage: bash scripts/test-phase1.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"

IMAGE="netlab/lab-node:latest"
CONTAINER="netlab-phase1-test"
TEMPLATE="/templates/ospf.json"
TIMEOUT=120  # seconds to wait for lab ready

log()  { echo "[test-phase1] $*"; }
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; exit 1; }

# ── Cleanup on exit ──────────────────────────────────────────────────────────
cleanup() {
    log "Cleaning up test container..."
    docker rm -f "${CONTAINER}" 2>/dev/null || true
}
trap cleanup EXIT

# ── Ensure image exists ──────────────────────────────────────────────────────
log "Checking image ${IMAGE}..."
docker image inspect "${IMAGE}" > /dev/null 2>&1 || {
    log "Image not found. Build it first with:"
    log "  docker build -t ${IMAGE} ./lab-node/"
    exit 1
}

# ── Start container ──────────────────────────────────────────────────────────
log "Starting test container with OSPF template..."
docker run -d \
    --name "${CONTAINER}" \
    --privileged \
    --cap-add=NET_ADMIN \
    --cap-add=NET_RAW \
    --cap-add=SYS_ADMIN \
    -e TOPO_TEMPLATE="${TEMPLATE}" \
    -e LAB_ID="phase1-test" \
    -v "${REPO_ROOT}/templates:/templates:ro" \
    "${IMAGE}"

# ── Wait for lab-ready file ───────────────────────────────────────────────────
log "Waiting for lab to be ready (up to ${TIMEOUT}s)..."
elapsed=0
while (( elapsed < TIMEOUT )); do
    if docker exec "${CONTAINER}" test -f /tmp/lab-ready 2>/dev/null; then
        log "Lab ready after ${elapsed}s"
        break
    fi
    sleep 3
    elapsed=$(( elapsed + 3 ))
    # Show progress
    docker logs --tail 3 "${CONTAINER}" 2>&1 | grep -v "^$" | sed 's/^/  |/' || true
done

if ! docker exec "${CONTAINER}" test -f /tmp/lab-ready 2>/dev/null; then
    log "TIMEOUT: Lab did not become ready in ${TIMEOUT}s"
    log "Container logs:"
    docker logs "${CONTAINER}" 2>&1 | tail -40
    fail "Lab failed to become ready"
fi

# ── Wait for OSPF convergence ─────────────────────────────────────────────────
# OSPF Hello interval is 10s; Dead interval 40s. Full adjacency is typically
# reached within 2 Hello intervals (20s). We wait 35s to be safe.
log "Waiting 35s for OSPF convergence (Hello=10s, Dead=40s)..."
sleep 35

# ── Check 1: OSPF neighbor adjacency ─────────────────────────────────────────
log ""
log "═══════════════════════════════════════════════════"
log "Check 1: OSPF neighbor state on r1"
log "═══════════════════════════════════════════════════"
OSPF_OUT=$(docker exec "${CONTAINER}" vtysh -N r1 -c "show ip ospf neighbor" 2>&1)
echo "${OSPF_OUT}"

# Must contain "Full" state
FULL_COUNT=$(echo "${OSPF_OUT}" | grep -c "Full" || true)
if (( FULL_COUNT >= 2 )); then
    pass "OSPF: r1 has ${FULL_COUNT} Full neighbor(s) ✓"
else
    log "Expected ≥2 Full OSPF neighbors on r1, got:"
    echo "${OSPF_OUT}"
    fail "OSPF neighbors not Full"
fi

# ── Check 2: OSPF neighbor adjacency on r2 ───────────────────────────────────
log ""
log "═══════════════════════════════════════════════════"
log "Check 2: OSPF neighbor state on r2"
log "═══════════════════════════════════════════════════"
OSPF_R2=$(docker exec "${CONTAINER}" vtysh -N r2 -c "show ip ospf neighbor" 2>&1)
echo "${OSPF_R2}"
FULL_R2=$(echo "${OSPF_R2}" | grep -c "Full" || true)
if (( FULL_R2 >= 2 )); then
    pass "OSPF: r2 has ${FULL_R2} Full neighbor(s) ✓"
else
    fail "r2 OSPF neighbors not Full (found ${FULL_R2})"
fi

# ── Check 3: Route propagation ────────────────────────────────────────────────
log ""
log "═══════════════════════════════════════════════════"
log "Check 3: r1 routing table contains 192.168.3.0/24 (OSPF)"
log "═══════════════════════════════════════════════════"
ROUTE_OUT=$(docker exec "${CONTAINER}" vtysh -N r1 -c "show ip route" 2>&1)
echo "${ROUTE_OUT}" | grep -E "O|192.168" || true
if echo "${ROUTE_OUT}" | grep -q "192.168.3.0/24"; then
    pass "Route: r1 has 192.168.3.0/24 via OSPF ✓"
else
    fail "r1 missing 192.168.3.0/24 in routing table"
fi

# ── Check 4: End-to-end ping h1 -> h2 ────────────────────────────────────────
log ""
log "═══════════════════════════════════════════════════"
log "Check 4: h1 ping h2 (192.168.3.2)"
log "═══════════════════════════════════════════════════"
PING_OUT=$(docker exec "${CONTAINER}" ip netns exec h1 ping -c 3 -W 2 192.168.3.2 2>&1)
echo "${PING_OUT}"
if echo "${PING_OUT}" | grep -q "3 received"; then
    pass "Ping: h1 → h2 (192.168.3.2) — 3/3 packets received ✓"
else
    fail "Ping h1→h2 failed"
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
echo "  PHASE 1 PASSED ✓"
echo "  All checks passed:"
echo "    ✓ OSPF Full adjacency on r1 (≥2 neighbors)"
echo "    ✓ OSPF Full adjacency on r2 (≥2 neighbors)"
echo "    ✓ Route 192.168.3.0/24 propagated to r1"
echo "    ✓ End-to-end ping h1 → h2 (3/3 packets)"
echo "═══════════════════════════════════════════════════"
