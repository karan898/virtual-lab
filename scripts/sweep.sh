#!/usr/bin/env bash
# scripts/sweep.sh — Run the full benchmark ladder for the paper.
#
# Runs N = 1, 5, 10 (edit LEVELS below; add 20 only if your laptop keeps up)
# x REPS repetitions each, with a cooldown between runs so the rate limiter
# and Kubernetes cleanup don't interfere with the next run (this is exactly
# what caused the "Too many requests" failure in an earlier run).
#
# Usage: bash scripts/sweep.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LEVELS=(5 10)     # add 20 here only after 1/5/10 succeed comfortably
REPS=3
TEMPLATE="ospf"
COOLDOWN_SEC=60      # wait between runs

ALL_DIR="${REPO_ROOT}/benchmark/results/sweep_$(date +%Y%m%dT%H%M%S)"
mkdir -p "${ALL_DIR}"
echo "N,rep,successful,failed,wall_clock_ms,provision_mean_ms,provision_p95_ms,grade_avg_score,backend_heap_before_mb,backend_heap_after_mb" \
  > "${ALL_DIR}/consolidated.csv"

for n in "${LEVELS[@]}"; do
  for rep in $(seq 1 "${REPS}"); do
    echo ""
    echo "════════════════════════════════════════════════════"
    echo " SWEEP: N=${n} rep=${rep}/${REPS}"
    echo "════════════════════════════════════════════════════"

    bash "${REPO_ROOT}/scripts/run-benchmark.sh" "${n}" "${TEMPLATE}" || {
      echo "[sweep] run failed for N=${n} rep=${rep} — recording as failed and continuing"
    }

    # Find the just-created output dir (newest run_*_n${n})
    RUN_DIR=$(ls -dt "${REPO_ROOT}/benchmark/results"/run_*_n"${n}" 2>/dev/null | head -1)
    if [[ -n "${RUN_DIR}" && -f "${RUN_DIR}/results.json" ]]; then
      python3 - "$RUN_DIR/results.json" "$n" "$rep" >> "${ALL_DIR}/consolidated.csv" <<'PY'
import json, sys
path, n, rep = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(path))
t = d.get("totals", {})
lat = d.get("latency_ms", {}).get("provision", {})
grading = d.get("grading", {})
mem = d.get("memory", {})
print(f"{n},{rep},{t.get('successful')},{t.get('failed')},{t.get('wall_clock_ms')},"
      f"{lat.get('mean')},{lat.get('p95')},{grading.get('avg_score')},"
      f"{mem.get('backend_heap_before_mb')},{mem.get('backend_heap_after_mb')}")
PY
      cp "${RUN_DIR}/results.json" "${ALL_DIR}/N${n}_rep${rep}_results.json"
    else
      echo "${n},${rep},0,${n},,,,,," >> "${ALL_DIR}/consolidated.csv"
    fi

    echo "[sweep] cooling down ${COOLDOWN_SEC}s before next run..."
    sleep "${COOLDOWN_SEC}"
  done
done

echo ""
echo "════════════════════════════════════════════════════"
echo " SWEEP COMPLETE — consolidated results:"
echo "   ${ALL_DIR}/consolidated.csv"
echo "════════════════════════════════════════════════════"
column -s, -t "${ALL_DIR}/consolidated.csv"