#!/usr/bin/env bash
# scripts/create-cluster.sh — Create kind cluster and set up everything for Phase 2
# Run this INSIDE WSL2 (called by 'make cluster')
set -euo pipefail

CLUSTER_NAME="netlab"
IMAGE="netlab/lab-node:latest"
TEMPLATES_PATH="/mnt/d/Research_Paper/model/templates"
KIND_CONFIG="/mnt/d/Research_Paper/model/k8s/kind-config.yaml"

echo "=== Phase 2: Creating kind cluster '${CLUSTER_NAME}' ==="

# Check kind is installed
kind version || { echo "ERROR: kind not found. Run: make install-deps"; exit 1; }

# Check if cluster already exists
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    echo "Cluster '${CLUSTER_NAME}' already exists."
else
    echo "Creating cluster..."
    kind create cluster \
        --name "${CLUSTER_NAME}" \
        --config "${KIND_CONFIG}" \
        --wait 120s
    echo "Cluster created."
fi

# Verify cluster is working
echo "Verifying cluster..."
kubectl cluster-info --context "kind-${CLUSTER_NAME}"
kubectl get nodes -o wide

# Load lab-node image into kind (avoids ImagePullBackOff)
echo ""
echo "=== Loading lab-node image into kind ==="
kind load docker-image "${IMAGE}" --name "${CLUSTER_NAME}"
echo "Image loaded."

# Verify image is available
kubectl --context "kind-${CLUSTER_NAME}" get nodes -o jsonpath='{.items[0].status.images[*].names[*]}' | \
    tr ' ' '\n' | grep "lab-node" && echo "Image confirmed in cluster." || echo "WARNING: image not found in node images list (normal for loaded images)"

# Set up kubeconfig volume for backend
echo ""
echo "=== Setting up kubeconfig Docker volume ==="
bash /mnt/d/Research_Paper/model/scripts/setup-kubeconfig.sh "${CLUSTER_NAME}"

echo ""
echo "=== Kind cluster ready ==="
echo "  kubectl get nodes:"
kubectl get nodes
echo ""
echo "Next: run 'make up' to start the docker-compose stack"
