#!/usr/bin/env bash
# scripts/run-benchmark.sh — Phase 7 benchmark runner (PATCHED)
#
# Fix applied: was calling `node.exe` (a Windows binary) from inside WSL2
# bash, which fails with "node: command not found". Now calls the Linux
# `node` binary that ships with the benchmark/node_modules setup.
#
# Everything else is unchanged from the original script.

set -euo pipefail

STUDENTS="${1:-5}"
TEMPLATE="${2:-ospf}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS_BASE="${REPO_ROOT}/benchmark/results"
TS=$(date +%Y%m%dT%H%M%S)
OUT_DIR="${RESULTS_BASE}/run_${TS}_n${STUDENTS}"

log() { echo "[run-bench] $*"; }

mkdir -p "${OUT_DIR}"

log "Benchmark run: students=${STUDENTS} template=${TEMPLATE}"
log "Output dir: ${OUT_DIR}"

# ── Sanity: backend must be reachable before we start ─────────────────────────
if ! curl -sf http://localhost:4000/health > /dev/null; then
  log "ERROR: backend not reachable at http://localhost:4000/health"
  log "       Run 'make up' (and 'make cluster' first) before benchmarking."
  exit 1
fi

# ── Pre-run memory snapshot ───────────────────────────────────────────────────
log "Snapshot: memory before"
docker stats --no-stream --format \
  'table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.CPUPerc}}' \
  > "${OUT_DIR}/mem_before.txt"
cat "${OUT_DIR}/mem_before.txt"

# ── Run the benchmark ─────────────────────────────────────────────────────────
log "Starting benchmark with ${STUDENTS} concurrent students..."

pushd "${REPO_ROOT}/benchmark" > /dev/null
if [[ ! -d node_modules ]]; then
  log "Installing benchmark dependencies..."
  npm install --silent
fi

if ! command -v node > /dev/null; then
  log "ERROR: 'node' not found on PATH inside WSL2."
  log "       Install Node.js inside WSL2 (not just on Windows):"
  log "         curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -"
  log "         sudo apt-get install -y nodejs"
  exit 1
fi

node benchmark.js \
    --students "${STUDENTS}" \
    --template "${TEMPLATE}" \
    --base-url "http://localhost:4000" \
    --poll-interval-ms 2000 \
    --timeout-ms 150000 \
    > "${OUT_DIR}/results.json" 2> >(tee "${OUT_DIR}/summary.txt" >&2) \
  || true

popd > /dev/null

# ── Post-run memory snapshot ──────────────────────────────────────────────────
log "Snapshot: memory after"
docker stats --no-stream --format \
  'table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.CPUPerc}}' \
  > "${OUT_DIR}/mem_after.txt"
cat "${OUT_DIR}/mem_after.txt"

# ── K8s namespace count ───────────────────────────────────────────────────────
log "K8s: active lab namespaces"
kubectl get namespaces --no-headers | grep '^lab-' | wc -l | tee "${OUT_DIR}/k8s_lab_ns.txt" || echo 0 > "${OUT_DIR}/k8s_lab_ns.txt"

# ── Print results path ────────────────────────────────────────────────────────
log "Results written to: ${OUT_DIR}/"

# ── Phase 7 acceptance check ──────────────────────────────────────────────────
echo ""
if [[ -f "${OUT_DIR}/results.json" ]]; then
  SUCCESSFUL=$(jq -r '.totals.successful' "${OUT_DIR}/results.json" 2>/dev/null || echo "0")
  FAILED=$(jq -r '.totals.failed' "${OUT_DIR}/results.json" 2>/dev/null || echo "${STUDENTS}")
  P95_PROV=$(jq -r '.latency_ms.provision.p95' "${OUT_DIR}/results.json" 2>/dev/null || echo "null")

  echo "═══════════════════════════════════════════════════"
  echo "  BENCHMARK RESULTS"
  echo "  Students: ${STUDENTS}  Successful: ${SUCCESSFUL}  Failed: ${FAILED}"
  echo "  Provision P95: ${P95_PROV} ms"

  if (( SUCCESSFUL >= 1 )); then
    echo "  RUN OK ✓"
    exit 0
  else
    echo "  RUN FAILED — no successful students"
    exit 1
  fi
else
  echo "  RUN FAILED — no results.json produced"
  exit 1
fi