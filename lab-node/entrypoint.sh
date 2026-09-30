#!/usr/bin/env bash
# entrypoint.sh — Lab-node container entrypoint
# 1. Starts OVS in userspace (netdev) mode
# 2. Reads TOPO_TEMPLATE env var (path to JSON topology file)
# 3. Calls topo-builder.sh to build the topology
# 4. Waits forever (pod stays alive for console access)
set -euo pipefail

LOG_PREFIX="[entrypoint]"
log() { echo "${LOG_PREFIX} $*" >&2; }

# ── Validate required env ──────────────────────────────────────────────────────
: "${TOPO_TEMPLATE:?TOPO_TEMPLATE env var must be set to a JSON topology file path}"
: "${LAB_ID:?LAB_ID env var must be set}"

log "Starting lab-node for LAB_ID=${LAB_ID}, template=${TOPO_TEMPLATE}"

# ── OVS startup (userspace netdev datapath) ────────────────────────────────────
# We do NOT load the openvswitch kernel module (unavailable in WSL2).
# Instead we configure OVS to use the 'netdev' (userspace DPDK-free) datapath.
log "Starting OVS database server (userspace mode)..."

# Initialize OVS DB if not already done
if [ ! -f /etc/openvswitch/conf.db ]; then
    ovsdb-tool create /etc/openvswitch/conf.db /usr/share/openvswitch/vswitch.ovsschema
fi

# Start ovsdb-server
ovsdb-server --remote=punix:/var/run/openvswitch/db.sock \
             --remote=db:Open_vSwitch,Open_vSwitch,manager_options \
             --pidfile=/var/run/openvswitch/ovsdb-server.pid \
             --detach \
             --log-file=/var/log/openvswitch/ovsdb-server.log

# Initialize OVS tables
ovs-vsctl --no-wait init

# Start ovs-vswitchd in userspace netdev mode
# --mlockall disabled (not needed for userspace; also may fail in container)
log "Starting ovs-vswitchd (netdev/userspace datapath)..."
ovs-vswitchd --pidfile=/var/run/openvswitch/ovs-vswitchd.pid \
             --detach \
             --log-file=/var/log/openvswitch/ovs-vswitchd.log

# Verify OVS is up
ovs-vsctl show > /dev/null 2>&1 && log "OVS started OK" || {
    log "ERROR: OVS failed to start"; exit 1
}

# ── Build topology ────────────────────────────────────────────────────────────
log "Building topology from ${TOPO_TEMPLATE}..."
# Ensure /lab exists and copy template there for all scripts to access
mkdir -p /lab
cp "${TOPO_TEMPLATE}" /lab/current-topo.json
export TOPO_JSON=/lab/current-topo.json
/usr/local/bin/topo-builder.sh "${TOPO_TEMPLATE}"
log "Topology built successfully"

# ── Wait for FRR readiness ────────────────────────────────────────────────────
log "Waiting for all FRR instances to be ready..."
/usr/local/bin/wait-frr.sh
log "All FRR instances ready — lab is READY"

# Signal readiness (write file that the K8s readiness probe checks)
touch /tmp/lab-ready

# ── Keep container alive ──────────────────────────────────────────────────────
log "Lab is ready. Container staying alive for console access."
# Trap signals for graceful shutdown
cleanup() {
    log "Shutting down lab..."
    # Kill all FRR instances
    pkill -f "zebra --pathspace" 2>/dev/null || true
    pkill -f "ospfd --pathspace" 2>/dev/null || true
    pkill -f "staticd --pathspace" 2>/dev/null || true
    # Stop OVS
    ovs-appctl -t ovs-vswitchd exit 2>/dev/null || true
    ovsdb-server --pidfile=/var/run/openvswitch/ovsdb-server.pid stop 2>/dev/null || true
    log "Shutdown complete."
    exit 0
}
trap cleanup SIGTERM SIGINT

# Sleep loop so signals are handled promptly
while true; do sleep 5; done
