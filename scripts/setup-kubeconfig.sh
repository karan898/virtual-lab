#!/usr/bin/env bash
# scripts/setup-kubeconfig.sh
# Extracts the kind cluster kubeconfig and patches the server address
# to be reachable from inside the Docker Compose network.
#
# Problem: kind's kubeconfig has server: https://127.0.0.1:<port>
# The backend container runs in Docker, so 127.0.0.1 points to the container.
# We must replace it with the kind container's Docker-internal IP.
#
# Solution:
# 1. Get the kind control-plane container IP on the Docker bridge network
# 2. Patch the kubeconfig server URL to use that IP
# 3. Create a Docker volume named 'kind_kubeconfig' and copy the patched config into it

set -euo pipefail

CLUSTER_NAME="${1:-netlab}"
VOLUME_NAME="kind_kubeconfig"

echo "=== Setting up kubeconfig for kind cluster '${CLUSTER_NAME}' ==="

# Get the kind control-plane container name
CONTAINER_NAME="${CLUSTER_NAME}-control-plane"

# Get the container's IP on the 'bridge' Docker network (or the kind network)
KIND_IP=$(docker inspect "${CONTAINER_NAME}" \
    --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null | head -1)

if [[ -z "${KIND_IP}" ]]; then
    echo "ERROR: Could not get IP for kind container '${CONTAINER_NAME}'"
    echo "       Is the cluster running? Run: kind get clusters"
    exit 1
fi
echo "kind control-plane IP: ${KIND_IP}"

# Get the API server port from the kubeconfig
KUBE_PORT=$(kind get kubeconfig --name "${CLUSTER_NAME}" 2>/dev/null | \
    grep "server:" | sed 's|.*https://[^:]*:\([0-9]*\).*|\1|')

if [[ -z "${KUBE_PORT}" ]]; then
    KUBE_PORT=6443
fi
echo "API server port: ${KUBE_PORT}"

# The internal kind API server port is always 6443.
# The host-mapped port (KUBE_PORT) cannot be used from inside the kind Docker network.
KIND_INTERNAL_PORT=6443

# Export patched kubeconfig to a temp file
TMPFILE=$(mktemp /tmp/kubeconfig-XXXXXX.yaml)
kind get kubeconfig --name "${CLUSTER_NAME}" 2>/dev/null | \
    sed "s|https://127.0.0.1:${KUBE_PORT}|https://${KIND_IP}:${KIND_INTERNAL_PORT}|g" \
    > "${TMPFILE}"

echo "Patched server URL: https://${KIND_IP}:${KIND_INTERNAL_PORT}"

# Create Docker volume if it doesn't exist
docker volume inspect "${VOLUME_NAME}" > /dev/null 2>&1 || \
    docker volume create "${VOLUME_NAME}"

# Copy the patched kubeconfig into the volume
# We use a temporary Alpine container to do the copy
docker run --rm \
    -v "${VOLUME_NAME}:/kube" \
    -v "${TMPFILE}:/config-in:ro" \
    alpine:3.20 \
    sh -c "mkdir -p /kube && cp /config-in /kube/config && chmod 644 /kube/config"

rm -f "${TMPFILE}"

echo ""
echo "=== Kubeconfig volume '${VOLUME_NAME}' is ready ==="
echo "    Backend will mount it at /root/.kube/config"
echo "    Test: docker run --rm -v ${VOLUME_NAME}:/root/.kube alpine/k8s:1.30.2 kubectl cluster-info"
