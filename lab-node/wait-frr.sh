#!/usr/bin/env bash
# wait-frr.sh — Wait for all FRR router instances to be ready
# Used by: entrypoint.sh and the K8s readiness probe
#
# Reads the active topology JSON (stored at /lab/current-topo.json by topo-builder)
# and checks that vtysh -N <router> -c "show version" succeeds for each router.
# Exits 0 if all ready, 1 if any are not ready.

set -euo pipefail

TOPO_JSON="${TOPO_JSON:-/lab/current-topo.json}"
MAX_WAIT=120  # seconds
INTERVAL=3

log() { echo "[wait-frr] $*" >&2; }

# If no topology is built yet, just check for the ready file
if [[ ! -f "${TOPO_JSON}" ]]; then
    [[ -f /tmp/lab-ready ]] && exit 0 || exit 1
fi

readarray -t ROUTERS < <(jq -r '.routers[].name' "${TOPO_JSON}" 2>/dev/null || echo "")

if [[ ${#ROUTERS[@]} -eq 0 || "${ROUTERS[0]}" == "" ]]; then
    log "No routers in topology — marking ready"
    exit 0
fi

check_all_ready() {
    for r in "${ROUTERS[@]}"; do
        # vtysh -N <pathspace> connects to the right FRR instance
        if ! vtysh -N "${r}" -c "show version" > /dev/null 2>&1; then
            return 1
        fi
    done
    return 0
}

elapsed=0
while (( elapsed < MAX_WAIT )); do
    if check_all_ready; then
        log "All FRR instances ready (${#ROUTERS[@]} routers)"
        exit 0
    fi
    log "Waiting for FRR... (${elapsed}s / ${MAX_WAIT}s)"
    sleep "${INTERVAL}"
    elapsed=$(( elapsed + INTERVAL ))
done

log "TIMEOUT: FRR instances not ready after ${MAX_WAIT}s"
# Log which routers failed
for r in "${ROUTERS[@]}"; do
    if ! vtysh -N "${r}" -c "show version" > /dev/null 2>&1; then
        log "  FAILED: ${r}"
    fi
done
exit 1
