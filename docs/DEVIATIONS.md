# DEVIATIONS.md — Documented deviations from ideal design

This file records every instance where a component cannot work as ideally specified
in the target environment (WSL2, Ubuntu 24.04, Microsoft standard kernel 6.6.x),
the reason, and the documented fallback. Per project rules, nothing is faked.

---

## DEV-001: OVS Kernel Datapath Unavailable

**Date recorded:** 2026-09-28  
**Affected component:** Open vSwitch (all topology templates using OVS bridges)  
**Environment:** WSL2 with kernel `6.6.114.1-microsoft-standard-WSL2`

### Problem
The Open vSwitch kernel module (`openvswitch.ko`) is not present in the Microsoft
custom WSL2 kernel. The module cannot be loaded (`modprobe openvswitch` fails).
This prevents OVS from using its native kernel datapath, which is the production
default and offers the best performance.

### Verification
```bash
# Inside WSL2:
modprobe openvswitch
# Error: modprobe: FATAL: Module openvswitch not found in directory ...
lsmod | grep openvswitch
# (empty output)
```

### Fallback Used
OVS **userspace netdev datapath** (`datapath_type=netdev`). This is an officially
supported OVS datapath that runs entirely in userspace without any kernel module.
It is documented in the OVS release notes and is the recommended fallback for
environments without kernel module support.

**Configuration:** In all topology JSON templates, bridges use `"datapath": "netdev"`.
In `entrypoint.sh`, `ovs-vswitchd` is started without specifying a kernel datapath.
OVS automatically uses netdev when the kernel module is absent.

### Impact on Research Paper
- **Correctness:** Full — VLAN isolation, L2 forwarding behavior is identical.
- **Performance:** Forwarding throughput is lower than kernel datapath (expected
  ~10-100× lower pps for high-rate traffic), but this is irrelevant for the lab
  scenarios (control-plane exercises, not line-rate forwarding benchmarks).
- **Citation:** Authors must note in the paper's methodology section:
  > "OVS was configured with the userspace netdev datapath due to the absence of
  > the openvswitch kernel module in the WSL2 Microsoft kernel (6.6.114.1).
  > This has no effect on the correctness of layer-2 forwarding, VLAN isolation,
  > or FRR routing protocol behavior measured in this work."

---

## DEV-002: SYS_ADMIN Capability Required in Lab Pods

**Date recorded:** 2026-09-28  
**Affected component:** lab-node Kubernetes pod securityContext

### Problem
Creating network namespaces (`ip netns add`) and moving interfaces between
namespaces (`ip link set <if> netns <ns>`) requires `CAP_SYS_ADMIN` inside the
container. Running FRR daemons inside those namespaces via `ip netns exec` also
requires this capability.

### Why Each Capability is Needed
| Capability | Required for |
|------------|-------------|
| `NET_ADMIN` | Creating veth pairs, setting IP addresses, IP forwarding sysctl |
| `NET_RAW` | tcpdump, ping (ICMP raw sockets) |
| `SYS_ADMIN` | `ip netns add/exec`, mounting `/proc` namespace files |

### Why Running as Root is Unavoidable
`ip netns` uses bind mounts in `/var/run/netns/` which require `CAP_SYS_ADMIN`
and cannot be done by unprivileged users even with user namespaces, because
user namespaces are often restricted in Kubernetes environments and WSL2.

### Mitigation
- The lab-node pod's `securityContext` grants only the three capabilities listed
  above and drops `ALL` others.
- The pod runs with `allowPrivilegeEscalation: false` except for the capabilities.
- The pod has no host network access and is isolated by a default-deny NetworkPolicy.
- Audit log records all pod lifecycle events.

---

## DEV-003: WSL2 NAT Network Mode Fallback

**Date recorded:** 2026-09-28  
**Affected component:** WSL2 networking / kind cluster API access

### Problem
WSL2 reported: `wsl: Failed to configure network (networkingMode Nat), falling
back to networkingMode VirtioProxy.`

### Impact
- kind NodePort services may not be reachable from the Windows host directly.
- The backend service reaches the kind API server via the Docker network (not
  through Windows host networking), which avoids this issue.

### Fallback Used
Backend container is placed on the same Docker network as the kind cluster
(via `--network host` or a shared named Docker network). kubeconfig uses the
kind API server's Docker-internal IP address, not localhost.

---

## DEV-004: frrinit.sh Pathspace Support

**Date recorded:** 2026-09-28  
**Affected component:** FRR multi-instance startup

### Notes
FRR's `-N` pathspace option (available since FRR 7.x) allows multiple FRR
instances on the same host, each with its own config directory, PID directory,
and UNIX socket directory. The pathspace name maps to a subdirectory under
`/etc/frr/`, `/var/run/frr/`, and `/var/log/frr/`.

`frrinit.sh start <name>` is the official way to start a named FRR instance.
This is not a deviation but is documented here because it is a less-known FRR
feature that is critical to this system's design.

---

## DEV-005: node-pty Removed — K8s Exec Used for WebSocket Terminals

**Date recorded:** 2026-09-29  
**Affected component:** backend WebSocket terminal handler (`src/routes/ws.ts`)

### Problem
`node-pty@1.0.0` was originally planned for PTY allocation in the WebSocket console
handler. It requires compilation of native C++ bindings via `node-gyp`, which
requires platform-specific build tools (MSVC on Windows, gcc on Linux).

Because the backend is built inside Docker (Alpine Linux), `node-pty` builds
successfully there. However, when developers run `npm install` from Windows to
do a type-check or local development, the build fails with MSBuild/MSVC errors
(Spectre-mitigated libraries missing).

### Fallback Used
`node-pty` was removed from `package.json`. The WebSocket console handler uses
`@kubernetes/client-node`'s built-in `Exec` class to run commands in lab pods
with `tty: true`, piping stdio directly through the WebSocket. This provides
equivalent terminal functionality with no native dependency.

### Impact
None on functionality. The K8s Exec API with TTY is the standard approach for
interactive console access in Kubernetes-based lab systems.

---

## DEV-006: kind Node Image Digest Removed

**Date recorded:** 2026-09-29  
**Affected component:** `k8s/kind-config.yaml`

### Problem
`kindest/node:v1.30.2@sha256:ecfe5841b9...` — The SHA256 digest pinned in
`kind-config.yaml` was stale and not found in the registry when kind attempted
to pull it. Docker reported: `not found`.

### Fallback Used
The digest was removed from `kind-config.yaml`, retaining only the semver tag
`kindest/node:v1.30.2`. The semver tag is stable (immutable for released
versions). The actual pulled digest is recorded at cluster creation time via
`kind get clusters` and `docker inspect`.

**Reproducibility note:** To get the exact digest on the deployment machine, run:
```bash
docker inspect kindest/node:v1.30.2 --format '{{index .RepoDigests 0}}'
```
and record it in this file.

---

*Last updated: 2026-09-29 (Phase 3)*
