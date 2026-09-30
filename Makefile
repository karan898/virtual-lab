# ── Variables ────────────────────────────────────────────────────────────────
SHELL           := /usr/bin/env bash
LAB_IMAGE       := netlab/lab-node:latest
KIND_CLUSTER    := netlab
KIND_VERSION    := 0.23.0
KUBECTL_VERSION := 1.30.2
WSL             := wsl -e bash -c

.PHONY: help install-deps cluster build-image load-image up down seed \
        test test-phase1 test-phase2 bench clean versions check-env

# ── Default target ────────────────────────────────────────────────────────────
help:
	@echo "Virtual Networking Lab — Makefile targets"
	@echo ""
	@echo "  make install-deps   Install kind + kubectl into WSL2 /usr/local/bin"
	@echo "  make cluster        Create kind cluster + build + load lab-node image"
	@echo "  make build-image    Build netlab/lab-node:latest docker image"
	@echo "  make load-image     Load image into kind cluster"
	@echo "  make up             Start docker-compose services (postgres, redis, kafka, backend, frontend)"
	@echo "  make down           Stop docker-compose services"
	@echo "  make seed           Insert demo users into postgres"
	@echo "  make test           Run unit + integration tests"
	@echo "  make test-phase1    Phase 1 acceptance test (OSPF topology)"
	@echo "  make bench          Run benchmark loadgen (N=1,5,10,20 students)"
	@echo "  make versions       Print all installed package versions"
	@echo "  make clean          Remove containers, volumes, kind cluster"
	@echo "  make check-env      Verify environment prerequisites"

# ── Prerequisites check ───────────────────────────────────────────────────────
check-env:
	@$(WSL) " \
		echo '=== Environment Check ===' && \
		docker --version || (echo 'ERROR: Docker not found'; exit 1) && \
		kind version 2>/dev/null || echo 'WARNING: kind not installed — run make install-deps' && \
		kubectl version --client 2>/dev/null || echo 'WARNING: kubectl not installed — run make install-deps' && \
		echo 'Kernel:' \$$(uname -r) && \
		echo 'RAM:' \$$(free -h | awk '/Mem:/{print \$$2}') && \
		echo 'CPUs:' \$$(nproc) && \
		echo '=== OK ==='"

# ── Install dependencies into WSL2 ───────────────────────────────────────────
install-deps:
	@echo "Installing kind $(KIND_VERSION) and kubectl $(KUBECTL_VERSION) into WSL2..."
	@$(WSL) " \
		set -euo pipefail && \
		echo '--- Installing kind $(KIND_VERSION)...' && \
		curl -Lo /tmp/kind https://kind.sigs.k8s.io/dl/v$(KIND_VERSION)/kind-linux-amd64 && \
		chmod +x /tmp/kind && \
		sudo mv /tmp/kind /usr/local/bin/kind && \
		kind version && \
		echo '--- Installing kubectl $(KUBECTL_VERSION)...' && \
		curl -Lo /tmp/kubectl https://dl.k8s.io/release/v$(KUBECTL_VERSION)/bin/linux/amd64/kubectl && \
		chmod +x /tmp/kubectl && \
		sudo mv /tmp/kubectl /usr/local/bin/kubectl && \
		kubectl version --client && \
		echo 'Dependencies installed successfully.'"

# ── Build lab-node image ──────────────────────────────────────────────────────
build-image:
	@echo "Building $(LAB_IMAGE)..."
	@$(WSL) "cd /mnt/d/Research_Paper/model && \
		docker build -t $(LAB_IMAGE) ./lab-node/ && \
		echo 'Build complete.'"

# ── Create kind cluster ───────────────────────────────────────────────────────
cluster: build-image
	@echo "Creating kind cluster '$(KIND_CLUSTER)' + kubeconfig volume..."
	@$(WSL) "bash /mnt/d/Research_Paper/model/scripts/create-cluster.sh $(KIND_CLUSTER)"

# ── Load image into existing kind cluster (for rebuilds) ─────────────────────
load-image:
	@$(WSL) "kind load docker-image $(LAB_IMAGE) --name $(KIND_CLUSTER)"

# ── Docker Compose up ─────────────────────────────────────────────────────────
up:
	@echo "Starting services..."
	@$(WSL) "cd /mnt/d/Research_Paper/model && \
		docker compose --env-file .env up -d --wait && \
		echo 'Services running. Frontend: http://localhost:3000, API: http://localhost:4000'"

# ── Docker Compose down ───────────────────────────────────────────────────────
down:
	@$(WSL) "cd /mnt/d/Research_Paper/model && \
		docker compose down && \
		echo 'Services stopped.'"

# ── Seed demo users ───────────────────────────────────────────────────────────
seed:
	@echo "Seeding demo users..."
	@$(WSL) "cd /mnt/d/Research_Paper/model && \
		docker compose exec backend node dist/scripts/seed.js && \
		echo 'Seeded: admin/admin123, instructor1/pass123, student1..5/pass123'"

# ── Phase 1 acceptance test ───────────────────────────────────────────────────
test-phase1:
	@echo "Running Phase 1 acceptance test..."
	@$(WSL) "bash /mnt/d/Research_Paper/model/scripts/test-phase1.sh"

# ── Phase 2 acceptance test ───────────────────────────────────────────────────
test-phase2:
	@echo "Running Phase 2 acceptance test (requires: make cluster && make up && make seed)..."
	@$(WSL) "bash /mnt/d/Research_Paper/model/scripts/test-phase2.sh"

# ── Full test suite ───────────────────────────────────────────────────────────
test:
	@echo "Running test suite..."
	@$(WSL) "cd /mnt/d/Research_Paper/model && \
		docker compose exec backend npm test && \
		bash /mnt/d/Research_Paper/model/scripts/test-phase1.sh"

# ── Benchmark ─────────────────────────────────────────────────────────────────
bench:
	@echo "Running benchmark (concurrency: 1 5 10 20, repetitions: 3)..."
	@$(WSL) "cd /mnt/d/Research_Paper/model && \
		npx tsx bench/loadgen.ts --concurrency 1,5,10,20 --repetitions 3"

# ── Print versions ────────────────────────────────────────────────────────────
versions:
	@$(WSL) " \
		echo '=== Host ===' && \
		uname -r && docker --version && \
		kind version 2>/dev/null || echo 'kind: not installed' && \
		kubectl version --client 2>/dev/null || echo 'kubectl: not installed' && \
		echo '=== lab-node packages ===' && \
		docker run --rm $(LAB_IMAGE) dpkg-query -W -f='\$${Package}\t\$${Version}\n' \
			frr frr-pythontools openvswitch-switch openvswitch-common \
			iproute2 iputils-ping tcpdump 2>/dev/null || echo '(build image first)'"

# ── Clean everything ──────────────────────────────────────────────────────────
clean:
	@echo "Cleaning up..."
	@$(WSL) " \
		cd /mnt/d/Research_Paper/model && \
		docker compose down -v 2>/dev/null || true && \
		kind delete cluster --name $(KIND_CLUSTER) 2>/dev/null || true && \
		docker rmi $(LAB_IMAGE) 2>/dev/null || true && \
		echo 'Clean complete.'"
