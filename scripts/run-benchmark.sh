#!/usr/bin/env bash
# scripts/run-benchmark.sh — Phase 7 benchmark runner
#
# Runs the benchmark client (N students, configurable), captures:
#   - JSON results from benchmark.js
#   - docker stats snapshot before and after
#   - K8s pod count during run
# Output: benchmark/results/run_<timestamp>/

set -euo pipefail

STUDENTS="${1:-5}"
TEMPLATE="${2:-ospf}"
RESULTS_BASE="/mnt/d/Research_Paper/model/benchmark/results"
TS=$(date +%Y%m%dT%H%M%S)
OUT_DIR="${RESULTS_BASE}/run_${TS}_n${STUDENTS}"

log() { echo "[run-bench] $*"; }

mkdir -p "${OUT_DIR}"

log "Benchmark run: students=${STUDENTS} template=${TEMPLATE}"
log "Output dir: ${OUT_DIR}"

# ── Pre-run memory snapshot ───────────────────────────────────────────────────
log "Snapshot: memory before"
docker stats --no-stream --format \
  'table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.CPUPerc}}' \
  > "${OUT_DIR}/mem_before.txt"
cat "${OUT_DIR}/mem_before.txt"

# ── Run the benchmark ─────────────────────────────────────────────────────────
log "Starting benchmark with ${STUDENTS} concurrent students..."

# Install deps inside benchmark dir if needed
pushd /mnt/d/Research_Paper/model/benchmark > /dev/null
if [[ ! -d node_modules ]]; then
  log "Installing benchmark dependencies..."
  npm install --silent
fi

  node.exe benchmark.js \
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
kubectl get namespaces --no-headers | grep '^lab-' | wc -l | tee "${OUT_DIR}/k8s_lab_ns.txt"

# ── Print results path ────────────────────────────────────────────────────────
log "Results written to: ${OUT_DIR}/"
log "  summary.txt   — human-readable percentile table"
log "  results.json  — full JSON for post-processing"
log "  mem_before/after.txt — container memory snapshots"

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
    echo "  PHASE 7 PASSED ✓"
    exit 0
  else
    echo "  PHASE 7 FAILED — no successful runs"
    exit 1
  fi
  echo "═══════════════════════════════════════════════════"
else
  echo "  PHASE 7 FAILED — no results.json produced"
  exit 1
fi
