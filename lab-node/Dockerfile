# lab-node: Networking lab runtime image
# Base: Ubuntu 24.04 (Noble) pinned by digest
# Contains: FRRouting 10.1, Open vSwitch 3.3, iproute2, tcpdump, iputils
#
# OVS NOTE: The openvswitch kernel module is NOT available under the Microsoft
# WSL2 kernel (6.6.x-microsoft-standard-WSL2). We use OVS userspace netdev
# datapath exclusively. This is documented in docs/DEVIATIONS.md.

FROM ubuntu:24.04@sha256:b59d21599a2b151e23eea5f6602f4af4d7d31c4e236d22bf0b62b86d2e386b8f

# Prevent interactive prompts during apt
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# ── System packages ────────────────────────────────────────────────────────────
# Pin versions where apt allows; record them in docs/VERSIONS.md
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Networking tools
    iproute2 \
    iputils-ping \
    iputils-tracepath \
    tcpdump \
    net-tools \
    ethtool \
    ncat \
    # Open vSwitch (userspace only — kernel module absent in WSL2)
    openvswitch-switch \
    openvswitch-common \
    # FRRouting
    frr \
    frr-pythontools \
    # Runtime helpers
    jq \
    curl \
    bash \
    procps \
    psmisc \
    # Python3 for vtysh helper scripts
    python3 \
    python3-pip \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# ── OVS userspace configuration ────────────────────────────────────────────────
# Force OVS to use userspace netdev datapath (no kernel module needed)
# The ovsdb-server and ovs-vswitchd run in userspace mode
RUN mkdir -p /var/run/openvswitch /var/log/openvswitch /etc/openvswitch

# ── FRR configuration ──────────────────────────────────────────────────────────
# Enable daemons we need: zebra, ospfd, staticd
# The -N (pathspace) option allows multiple FRR instances per pod
RUN sed -i \
    -e 's/^zebra=no/zebra=yes/' \
    -e 's/^ospfd=no/ospfd=yes/' \
    -e 's/^staticd=no/staticd=yes/' \
    /etc/frr/daemons

# Disable vtysh pager (hangs in scripts)
RUN echo "no service integrated-vtysh-config" >> /etc/frr/frr.conf || true

# ── Scripts ────────────────────────────────────────────────────────────────────
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY topo-builder.sh /usr/local/bin/topo-builder.sh
COPY wait-frr.sh /usr/local/bin/wait-frr.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
              /usr/local/bin/topo-builder.sh \
              /usr/local/bin/wait-frr.sh

# ── Health check ──────────────────────────────────────────────────────────────
# Pod is Ready only when all FRR daemons answer vtysh for all routers
HEALTHCHECK --interval=5s --timeout=10s --start-period=60s --retries=12 \
    CMD /usr/local/bin/wait-frr.sh

# Working directory for topology JSON
WORKDIR /lab

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
