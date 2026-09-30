#!/usr/bin/env bash
set -euo pipefail

TEMP_WIN_PATH="/mnt/c/Users/ASUS/AppData/Local/Temp"

echo "=== Installing kind and kubectl from Windows Temp ==="
sudo install -m 0755 "${TEMP_WIN_PATH}/kind"    /usr/local/bin/kind
sudo install -m 0755 "${TEMP_WIN_PATH}/kubectl" /usr/local/bin/kubectl

echo "kind version:"
kind version

echo "kubectl version:"
kubectl version --client

echo ""
echo "=== Starting Docker daemon ==="
sudo service docker start 2>&1 || true
sleep 3

echo "Docker status:"
docker info --format 'Server version: {{.ServerVersion}}' 2>&1 || echo "WARNING: Docker daemon not running"

echo ""
echo "=== Existing lab-node image ==="
docker images netlab/lab-node --format "ID={{.ID}} Size={{.Size}}" 2>/dev/null || echo "Image not found — need to rebuild"
