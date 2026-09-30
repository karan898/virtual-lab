#!/usr/bin/env bash
# topo-builder.sh — Builds a network topology from a JSON template
#
# JSON schema:
#   {
#     "name": "ospf",
#     "routers": [{ "name": "r1", "loopback": "10.0.0.1/32" }],
#     "hosts":   [{ "name": "h1", "ip": "192.168.1.2/24", "gateway": "192.168.1.1" }],
#     "links":   [{ "a": "r1", "b": "r2", "a_ip": "10.1.1.1/30", "b_ip": "10.1.1.2/30" }],
#     "bridges": [{ "name": "sw1", "datapath": "netdev", "ports": [...] }],
#     "frr_configs": { "r1": "..frr config text.." }
#   }
#
# Node types determined by prefix: r=router, h=host, sw=OVS switch
# Routers get FRR; hosts get a shell only.
#
# FRR uses -N <name> pathspace to allow multiple instances per pod.

set -euo pipefail

TOPO_JSON="${1:?Usage: topo-builder.sh <topology.json>}"
LOG_PREFIX="[topo-builder]"
log()  { echo "${LOG_PREFIX} $*" >&2; }
die()  { log "FATAL: $*"; exit 1; }

[[ -f "${TOPO_JSON}" ]] || die "Template not found: ${TOPO_JSON}"

# ── Parse JSON with jq ────────────────────────────────────────────────────────
TOPO_NAME=$(jq -r '.name' "${TOPO_JSON}")
log "Building topology: ${TOPO_NAME}"

# ── Helper: create a network namespace ───────────────────────────────────────
create_netns() {
    local name="$1"
    ip netns add "${name}" 2>/dev/null && log "  netns created: ${name}" || {
        # Already exists (e.g. after reset) — flush it
        ip netns del "${name}" 2>/dev/null || true
        ip netns add "${name}"
        log "  netns recreated: ${name}"
    }
    # Bring up loopback inside the namespace
    ip netns exec "${name}" ip link set lo up
}

# ── Helper: create a veth pair between two namespaces ────────────────────────
# veth name is auto-generated: <a>-<b> and <b>-<a>, truncated to 15 chars
create_veth_link() {
    local ns_a="$1" ns_b="$2" ip_a="$3" ip_b="$4"
    # Interface names: first 7 chars of each ns name + "-eth"
    local if_a="${ns_a:0:6}-${ns_b:0:6}"
    local if_b="${ns_b:0:6}-${ns_a:0:6}"
    # Linux IFNAMSIZ is 16 (15 usable)
    if_a="${if_a:0:15}"
    if_b="${if_b:0:15}"

    log "  veth: ${ns_a}(${if_a} ${ip_a}) <-> ${ns_b}(${if_b} ${ip_b})"

    # Delete existing if present
    ip link del "${if_a}" 2>/dev/null || true

    # Create the veth pair in the root namespace first
    ip link add "${if_a}" type veth peer name "${if_b}"

    # Move each end into its namespace
    ip link set "${if_a}" netns "${ns_a}"
    ip link set "${if_b}" netns "${ns_b}"

    # Configure IP addresses and bring up
    ip netns exec "${ns_a}" ip addr add "${ip_a}" dev "${if_a}"
    ip netns exec "${ns_a}" ip link set "${if_a}" up

    ip netns exec "${ns_b}" ip addr add "${ip_b}" dev "${if_b}"
    ip netns exec "${ns_b}" ip link set "${if_b}" up
}

# ── Helper: create veth between netns and OVS bridge (in root ns) ────────────
create_veth_to_ovs() {
    local ns="$1" bridge="$2" ip_addr="$3" vlan_tag="${4:-}"
    local if_ns="${ns:0:6}-${bridge:0:6}"
    local if_ovs="${bridge:0:6}-${ns:0:6}"
    if_ns="${if_ns:0:15}"
    if_ovs="${if_ovs:0:15}"

    log "  veth-to-ovs: ${ns}(${if_ns} ${ip_addr}) <-> bridge ${bridge}(${if_ovs})"

    ip link del "${if_ns}" 2>/dev/null || true
    ip link add "${if_ns}" type veth peer name "${if_ovs}"
    ip link set "${if_ns}" netns "${ns}"
    # The OVS side stays in root namespace — OVS will manage it
    ip link set "${if_ovs}" up

    ip netns exec "${ns}" ip addr add "${ip_addr}" dev "${if_ns}"
    ip netns exec "${ns}" ip link set "${if_ns}" up

    # Add to OVS bridge
    ovs-vsctl add-port "${bridge}" "${if_ovs}"

    # Apply VLAN tag if specified
    if [[ -n "${vlan_tag}" ]]; then
        ovs-vsctl set port "${if_ovs}" tag="${vlan_tag}"
        log "    VLAN tag ${vlan_tag} on ${if_ovs}"
    fi
}

# ── Step 1: Create network namespaces for all nodes ──────────────────────────
log "Step 1: Creating network namespaces..."

# Routers
readarray -t ROUTERS < <(jq -r '.routers[].name' "${TOPO_JSON}")
for r in "${ROUTERS[@]}"; do
    create_netns "${r}"
done

# Hosts
readarray -t HOSTS < <(jq -r '.hosts[].name' "${TOPO_JSON}")
for h in "${HOSTS[@]}"; do
    create_netns "${h}"
done

# ── Step 2: Create OVS bridges ────────────────────────────────────────────────
log "Step 2: Creating OVS bridges..."
BRIDGE_COUNT=$(jq '.bridges | length' "${TOPO_JSON}")
for i in $(seq 0 $((BRIDGE_COUNT - 1))); do
    BRIDGE_NAME=$(jq -r ".bridges[${i}].name" "${TOPO_JSON}")
    DATAPATH=$(jq -r ".bridges[${i}].datapath // \"netdev\"" "${TOPO_JSON}")
    log "  OVS bridge: ${BRIDGE_NAME} (datapath=${DATAPATH})"
    ovs-vsctl --may-exist add-br "${BRIDGE_NAME}" \
        -- set bridge "${BRIDGE_NAME}" datapath_type="${DATAPATH}"
    ip link set "${BRIDGE_NAME}" up
done

# ── Step 3: Create veth links between namespaces ──────────────────────────────
log "Step 3: Creating veth links..."
LINK_COUNT=$(jq '.links | length' "${TOPO_JSON}")
for i in $(seq 0 $((LINK_COUNT - 1))); do
    A=$(jq -r ".links[${i}].a" "${TOPO_JSON}")
    B=$(jq -r ".links[${i}].b" "${TOPO_JSON}")
    A_IP=$(jq -r ".links[${i}].a_ip" "${TOPO_JSON}")
    B_IP=$(jq -r ".links[${i}].b_ip" "${TOPO_JSON}")
    create_veth_link "${A}" "${B}" "${A_IP}" "${B_IP}"
done

# ── Step 4: Connect hosts/routers to OVS bridges ─────────────────────────────
log "Step 4: Connecting nodes to OVS bridges..."
BRIDGE_COUNT=$(jq '.bridges | length' "${TOPO_JSON}")
for i in $(seq 0 $((BRIDGE_COUNT - 1))); do
    BRIDGE_NAME=$(jq -r ".bridges[${i}].name" "${TOPO_JSON}")
    PORT_COUNT=$(jq ".bridges[${i}].ports | length" "${TOPO_JSON}")
    for j in $(seq 0 $((PORT_COUNT - 1))); do
        NS=$(jq -r ".bridges[${i}].ports[${j}].ns" "${TOPO_JSON}")
        IP=$(jq -r ".bridges[${i}].ports[${j}].ip" "${TOPO_JSON}")
        VLAN=$(jq -r ".bridges[${i}].ports[${j}].vlan // \"\"" "${TOPO_JSON}")
        create_veth_to_ovs "${NS}" "${BRIDGE_NAME}" "${IP}" "${VLAN}"
    done
done

# ── Step 5: Set up default gateways on hosts ──────────────────────────────────
log "Step 5: Setting up host gateways..."
HOST_COUNT=$(jq '.hosts | length' "${TOPO_JSON}")
for i in $(seq 0 $((HOST_COUNT - 1))); do
    H=$(jq -r ".hosts[${i}].name" "${TOPO_JSON}")
    GW=$(jq -r ".hosts[${i}].gateway // \"\"" "${TOPO_JSON}")
    if [[ -n "${GW}" ]]; then
        ip netns exec "${H}" ip route add default via "${GW}" 2>/dev/null || \
        ip netns exec "${H}" ip route replace default via "${GW}"
        log "  ${H} default gw -> ${GW}"
    fi

    # Set loopback IP if specified
    LO_IP=$(jq -r ".hosts[${i}].loopback // \"\"" "${TOPO_JSON}")
    if [[ -n "${LO_IP}" ]]; then
        ip netns exec "${H}" ip addr add "${LO_IP}" dev lo 2>/dev/null || true
    fi
done

# ── Step 6: Set up router loopbacks ──────────────────────────────────────────
log "Step 6: Setting up router loopbacks..."
ROUTER_COUNT=$(jq '.routers | length' "${TOPO_JSON}")
for i in $(seq 0 $((ROUTER_COUNT - 1))); do
    R=$(jq -r ".routers[${i}].name" "${TOPO_JSON}")
    LO=$(jq -r ".routers[${i}].loopback // \"\"" "${TOPO_JSON}")
    if [[ -n "${LO}" ]]; then
        ip netns exec "${R}" ip addr add "${LO}" dev lo 2>/dev/null || true
        ip netns exec "${R}" ip link set lo up
        log "  ${R} loopback: ${LO}"
    fi
done

# ── Step 7: Enable IP forwarding in router namespaces ────────────────────────
log "Step 7: Enabling IP forwarding in router namespaces..."
for r in "${ROUTERS[@]}"; do
    ip netns exec "${r}" sysctl -w net.ipv4.ip_forward=1 > /dev/null
    ip netns exec "${r}" sysctl -w net.ipv4.conf.all.forwarding=1 > /dev/null
    log "  IP forwarding enabled in ${r}"
done

# ── Step 8: Write FRR configs and start FRR instances ────────────────────────
log "Step 8: Starting FRR instances per router..."

# FRR path: /etc/frr/
# Each router gets its own pathspace directory: /etc/frr/<routername>/
for r in "${ROUTERS[@]}"; do
    FRR_DIR="/etc/frr/${r}"
    mkdir -p "${FRR_DIR}"

    # Get FRR config for this router from JSON
    FRR_CONF=$(jq -r ".frr_configs.${r} // \"\"" "${TOPO_JSON}")

    # Write frr.conf for this router
    # NOTE: frr version header must match the installed FRR version (8.4.4 in Ubuntu 24.04)
    # A version mismatch causes FRR to log a warning but still loads the config.
    cat > "${FRR_DIR}/frr.conf" <<EOF
! FRR config for router ${r} (pathspace: ${r})
frr version 8.4.4
frr defaults traditional
hostname ${r}
!
${FRR_CONF}
!
end
EOF

    # Write daemons file for this router (only the ones we need)
    cat > "${FRR_DIR}/daemons" <<EOF
zebra=yes
bgpd=no
ospfd=yes
ospf6d=no
ripd=no
ripngd=no
isisd=no
pimd=no
nhrpd=no
eigrpd=no
babeld=no
sharpd=no
staticd=yes
pbrd=no
bfdd=no
fabricd=no
vrrpd=no
pathd=no
EOF

    # Write vtysh.conf for pathspace
    cat > "${FRR_DIR}/vtysh.conf" <<EOF
service integrated-vtysh-config
EOF

    # Set ownership (FRR runs as frr user)
    chown -R frr:frr "${FRR_DIR}"
    chmod 750 "${FRR_DIR}"
    chmod 640 "${FRR_DIR}"/*.conf "${FRR_DIR}/daemons" 2>/dev/null || true

    # Create runtime + log directories for this pathspace
    # With -N <name>, FRR uses /var/run/frr/<name>/ for sockets/pids
    mkdir -p "/var/run/frr/${r}" "/var/log/frr/${r}"
    chown -R frr:frr "/var/run/frr/${r}" "/var/log/frr/${r}"

    log "  Starting FRR daemons in pathspace ${r} (netns: ${r})..."

    # ── zebra (routing table manager, must start first) ──────────────────────
    # -d daemonizes: ip netns exec returns immediately after fork.
    # Redirect stderr to a start log for post-mortem diagnosis.
    ip netns exec "${r}" \
        /usr/lib/frr/zebra \
            -N "${r}" \
            -d \
            -f "${FRR_DIR}/frr.conf" \
            -i "/var/run/frr/${r}/zebra.pid" \
            -z "/var/run/frr/${r}/zserv.api" \
            --log-level info \
            --log "file:/var/log/frr/${r}/zebra.log" \
        2>"/var/log/frr/${r}/zebra-start.log" \
    && log "    zebra forked OK in ${r}" \
    || log "    WARNING: zebra exit non-zero in ${r} — check /var/log/frr/${r}/zebra-start.log"

    # Wait for zebra to create its zserv API socket
    for _t in 1 2 3 4 5; do
        [[ -S "/var/run/frr/${r}/zserv.api" ]] && break || sleep 1
    done
    if [[ ! -S "/var/run/frr/${r}/zserv.api" ]]; then
        log "    WARNING: zebra socket absent after 5s in ${r}"
        cat "/var/log/frr/${r}/zebra-start.log" >&2 2>/dev/null || true
    else
        log "    zebra socket ready in ${r}"
    fi

    # ── ospfd (only if this router has 'router ospf' in its config) ──────────
    HAS_OSPF=$(jq -r ".frr_configs.${r} // \"\"" "${TOPO_JSON}" | grep -c "router ospf" || true)
    if (( HAS_OSPF > 0 )); then
        ip netns exec "${r}" \
            /usr/lib/frr/ospfd \
                -N "${r}" \
                -d \
                -f "${FRR_DIR}/frr.conf" \
                -i "/var/run/frr/${r}/ospfd.pid" \
                -z "/var/run/frr/${r}/zserv.api" \
                --log-level info \
                --log "file:/var/log/frr/${r}/ospfd.log" \
            2>"/var/log/frr/${r}/ospfd-start.log" \
        && log "    ospfd started in ${r}" \
        || log "    WARNING: ospfd exit non-zero in ${r}"
    fi

    # ── staticd (always start — handles static routes) ───────────────────────
    ip netns exec "${r}" \
        /usr/lib/frr/staticd \
            -N "${r}" \
            -d \
            -f "${FRR_DIR}/frr.conf" \
            -i "/var/run/frr/${r}/staticd.pid" \
            -z "/var/run/frr/${r}/zserv.api" \
            --log-level info \
            --log "file:/var/log/frr/${r}/staticd.log" \
        2>"/var/log/frr/${r}/staticd-start.log" \
    && log "    staticd started in ${r}" \
    || log "    WARNING: staticd exit non-zero in ${r}"

    sleep 1
done

log "Topology build complete: ${TOPO_NAME}"
log "Network namespaces:"
ip netns list | while IFS= read -r line; do log "  ${line}"; done

# ── Persist the topology JSON so wait-frr.sh and the grader can find it ──────
mkdir -p /lab
cp "${TOPO_JSON}" /lab/current-topo.json
log "Topology JSON saved to /lab/current-topo.json"

# ── For VLAN topology: configure OVS ARP proxy / disable MAC learning flood ──
# On netdev datapath, normal ARP works via flooding within the same VLAN.
# No extra config needed; OVS port VLAN tags enforce isolation automatically.

# Write topology summary for console access
jq -r '
    "Topology: " + .name + "\n" +
    "Routers: " + (if (.routers | length) > 0 then [.routers[].name] | join(", ") else "none" end) + "\n" +
    "Hosts: "   + ([.hosts[].name]   | join(", "))
' "${TOPO_JSON}" > /tmp/topo-summary.txt
cat /tmp/topo-summary.txt >&2
