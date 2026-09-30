#!/usr/bin/env bash
set -euo pipefail
echo "=== Checking current state ==="
echo "kind: $(kind version 2>/dev/null || echo NOT_INSTALLED)"
echo "kubectl: $(kubectl version --client 2>/dev/null || echo NOT_INSTALLED)"
echo ""
echo "=== Docker status ==="
docker version --format 'Client: {{.Client.Version}} Server: {{.Server.Engine.Version}}' 2>/dev/null || echo "Docker not running?"
echo ""
echo "=== Existing kind clusters ==="
kind get clusters 2>/dev/null || echo "none"
