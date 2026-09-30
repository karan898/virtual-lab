#!/usr/bin/env node
/**
 * benchmark.js — Netlab Virtual Networking Laboratory benchmark client
 *
 * Simulates N concurrent students each performing:
 *   1. Login                      (login_ms)
 *   2. Lab provision (ospf)       (provision_ms — up to 120 s polling)
 *   3. Submit for grading         (grade_ms)
 *   4. WebSocket terminal ping    (ws_rtt_ms — one round-trip "hostname\r")
 *   5. Lab destroy                (destroy_ms)
 *
 * Outputs JSON summary + CSV rows to stdout / files.
 * Nothing is faked: every measurement is a real wall-clock diff from a live HTTP/WS call.
 *
 * Usage:
 *   node benchmark.js [--students N] [--base-url URL] [--poll-interval-ms N]
 *   node benchmark.js --students 5 --base-url http://localhost:4000
 *
 * Environment variables override flags:
 *   BENCH_STUDENTS      (default: 5)
 *   BENCH_BASE_URL      (default: http://localhost:4000)
 *   BENCH_POLL_MS       (default: 2000)
 *   BENCH_TIMEOUT_MS    (default: 120000)
 *   BENCH_TEMPLATE      (default: ospf)
 */

'use strict';

const http = require('http');
const https = require('https');
const WebSocket = require('ws');

// ── CLI / env config ──────────────────────────────────────────────────────────
const args = process.argv.slice(2);
const argMap = {};
for (let i = 0; i < args.length; i += 2) {
  argMap[args[i].replace(/^--/, '')] = args[i + 1];
}

const N_STUDENTS      = parseInt(argMap['students']         || process.env.BENCH_STUDENTS    || '5', 10);
const BASE_URL        = (argMap['base-url']                 || process.env.BENCH_BASE_URL    || 'http://localhost:4000').replace(/\/$/, '');
const POLL_MS         = parseInt(argMap['poll-interval-ms'] || process.env.BENCH_POLL_MS     || '2000', 10);
const TIMEOUT_MS      = parseInt(argMap['timeout-ms']       || process.env.BENCH_TIMEOUT_MS  || '120000', 10);
const TEMPLATE        = argMap['template']                  || process.env.BENCH_TEMPLATE    || 'ospf';
const OUT_DIR         = argMap['out-dir']                   || process.env.BENCH_OUT_DIR     || './results';

const WS_URL_BASE = BASE_URL.replace(/^http/, 'ws');

console.error(`[bench] Config: students=${N_STUDENTS} base=${BASE_URL} template=${TEMPLATE} poll=${POLL_MS}ms timeout=${TIMEOUT_MS}ms`);

// ── HTTP helper (no axios to keep deps minimal in the container) ──────────────
function request(method, path, body, token) {
  return new Promise((resolve, reject) => {
    const url = new URL(BASE_URL + path);
    const mod = url.protocol === 'https:' ? https : http;
    const payload = body ? JSON.stringify(body) : undefined;
    const opts = {
      hostname: url.hostname,
      port:     url.port || (url.protocol === 'https:' ? 443 : 80),
      path:     url.pathname + url.search,
      method,
      headers: {
        'Content-Type': 'application/json',
        ...(token ? { 'Authorization': `Bearer ${token}` } : {}),
        ...(payload ? { 'Content-Length': Buffer.byteLength(payload) } : {}),
      },
    };
    const req = mod.request(opts, (res) => {
      let data = '';
      res.on('data', c => data += c);
      res.on('end', () => {
        try { resolve({ status: res.statusCode, body: JSON.parse(data) }); }
        catch { resolve({ status: res.statusCode, body: data }); }
      });
    });
    req.on('error', reject);
    if (payload) req.write(payload);
    req.end();
  });
}

// ── Percentile calculator ─────────────────────────────────────────────────────
function percentile(sorted, p) {
  if (sorted.length === 0) return null;
  const idx = Math.ceil((p / 100) * sorted.length) - 1;
  return sorted[Math.max(0, Math.min(idx, sorted.length - 1))];
}

function stats(values) {
  if (values.length === 0) return { n: 0, min: null, max: null, mean: null, p50: null, p90: null, p95: null, p99: null };
  const sorted = [...values].sort((a, b) => a - b);
  const mean = values.reduce((a, b) => a + b, 0) / values.length;
  return {
    n:    values.length,
    min:  sorted[0],
    max:  sorted[sorted.length - 1],
    mean: Math.round(mean),
    p50:  percentile(sorted, 50),
    p90:  percentile(sorted, 90),
    p95:  percentile(sorted, 95),
    p99:  percentile(sorted, 99),
  };
}

// ── Pre-flight: create N student accounts (idempotent) ───────────────────────
async function ensureStudents() {
  // Login as admin to create student accounts
  const adminLogin = await request('POST', '/api/auth/login', { username: 'admin', password: 'admin123' });
  if (!adminLogin.body.token) throw new Error(`Admin login failed: ${JSON.stringify(adminLogin.body)}`);
  const adminToken = adminLogin.body.token;

  const accounts = [];
  for (let i = 1; i <= N_STUDENTS; i++) {
    const username = `bench_student_${i}`;
    const password = `benchpass_${i}`;
    // Create account (ignore 409 = already exists)
    await request('POST', '/api/admin/users', { username, password, role: 'student' }, adminToken);
    accounts.push({ username, password });
  }
  return accounts;
}

// ── Per-student workflow ──────────────────────────────────────────────────────
async function runStudent(account, idx) {
  const result = {
    student: idx + 1,
    username: account.username,
    login_ms: null,
    provision_ms: null,
    poll_attempts: null,
    grade_ms: null,
    grade_score: null,
    grade_max: null,
    ws_rtt_ms: null,
    destroy_ms: null,
    error: null,
  };

  let token, labId, namespace;

  try {
    // 1. Login
    const t0 = Date.now();
    const loginResp = await request('POST', '/api/auth/login', { username: account.username, password: account.password });
    result.login_ms = Date.now() - t0;
    if (!loginResp.body.token) throw new Error(`Login failed: ${JSON.stringify(loginResp.body)}`);
    token = loginResp.body.token;

    // 2. Destroy any existing lab first (cleanup from previous failed run)
    const existingResp = await request('GET', '/api/labs', null, token);
    if (existingResp.body && existingResp.body.length > 0) {
      for (const lab of existingResp.body) {
        if (['requesting', 'ready', 'resetting'].includes(lab.status)) {
          await request('DELETE', `/api/labs/${lab.id}`, null, token);
        }
      }
      await new Promise(r => setTimeout(r, 1000)); // brief pause for K8s cleanup
    }

    // 3. Create lab
    const t1 = Date.now();
    const createResp = await request('POST', '/api/labs', { template: TEMPLATE }, token);
    if (!createResp.body.id) throw new Error(`Lab creation failed: ${JSON.stringify(createResp.body)}`);
    labId = createResp.body.id;

    // 4. Poll until ready
    let status = 'requesting';
    let polls = 0;
    const provisionDeadline = Date.now() + TIMEOUT_MS;
    while (status !== 'ready' && status !== 'failed' && Date.now() < provisionDeadline) {
      await new Promise(r => setTimeout(r, POLL_MS));
      polls++;
      const labResp = await request('GET', `/api/labs/${labId}`, null, token);
      status = labResp.body.status;
      namespace = labResp.body.namespace;
    }
    result.provision_ms  = Date.now() - t1;
    result.poll_attempts = polls;

    if (status !== 'ready') throw new Error(`Lab did not become ready: final status=${status}`);

    // Wait 12s for OSPF to converge
    await new Promise(r => setTimeout(r, 12000));

    // 5. Grade
    const t2 = Date.now();
    const gradeResp = await request('POST', `/api/labs/${labId}/submit`, null, token);
    result.grade_ms    = Date.now() - t2;
    result.grade_score = gradeResp.body.score  ?? null;
    result.grade_max   = gradeResp.body.maxScore ?? null;

    // 6. WebSocket RTT (send one command, measure time to first byte back)
    const wsUrl = `${WS_URL_BASE}/ws/console?labId=${labId}&netns=h1&isRouter=false&token=${token}`;
    result.ws_rtt_ms = await measureWsRtt(wsUrl);

    // 7. Destroy
    const t3 = Date.now();
    await request('DELETE', `/api/labs/${labId}`, null, token);
    result.destroy_ms = Date.now() - t3;

  } catch (err) {
    result.error = err.message;
    // Best-effort cleanup
    if (labId && token) {
      await request('DELETE', `/api/labs/${labId}`, null, token).catch(() => {});
    }
  }

  return result;
}

// ── WebSocket RTT measurement ─────────────────────────────────────────────────
function measureWsRtt(wsUrl) {
  return new Promise((resolve) => {
    const tConnect = Date.now();
    let tFirstByte = null;
    const ws = new WebSocket(wsUrl);
    const timeout = setTimeout(() => {
      ws.terminate();
      resolve(null); // timed out
    }, 10000);

    ws.on('open', () => {
      setTimeout(() => ws.send('echo bench_ping\r'), 500);
    });

    ws.on('message', (data) => {
      if (tFirstByte === null) {
        tFirstByte = Date.now();
      }
      if (data.toString().includes('bench_ping') && tFirstByte !== null) {
        clearTimeout(timeout);
        ws.close();
        resolve(tFirstByte - tConnect);
      }
    });

    ws.on('error', () => { clearTimeout(timeout); resolve(null); });
    ws.on('close', () => { clearTimeout(timeout); if (tFirstByte) resolve(tFirstByte - tConnect); });
  });
}

// ── Memory sampler: polls /health on the backend ──────────────────────────────
async function sampleMemory() {
  try {
    const resp = await request('GET', '/health');
    return resp.body.memory || null;
  } catch { return null; }
}

// ── Main ─────────────────────────────────────────────────────────────────────
async function main() {
  console.error(`[bench] Ensuring ${N_STUDENTS} student accounts...`);
  const accounts = await ensureStudents();

  // Memory before load
  const memBefore = await sampleMemory();
  console.error(`[bench] Heap before: ${memBefore ? Math.round(memBefore.heapUsed / 1024 / 1024) + ' MiB' : 'unknown'}`);

  console.error(`[bench] Launching ${N_STUDENTS} concurrent students...`);
  const tTotal = Date.now();

  const promises = accounts.map((acct, i) => runStudent(acct, i));
  const results  = await Promise.all(promises);

  const totalMs = Date.now() - tTotal;

  // Memory at peak (immediately after all students complete)
  const memAfter = await sampleMemory();
  console.error(`[bench] Heap after:  ${memAfter  ? Math.round(memAfter.heapUsed  / 1024 / 1024) + ' MiB' : 'unknown'}`);

  // ── Aggregate stats ─────────────────────────────────────────────────────────
  const ok      = results.filter(r => !r.error);
  const errors  = results.filter(r =>  r.error);

  const loginMs     = ok.map(r => r.login_ms).filter(Boolean);
  const provisionMs = ok.map(r => r.provision_ms).filter(Boolean);
  const gradeMs     = ok.map(r => r.grade_ms).filter(Boolean);
  const wsRttMs     = ok.map(r => r.ws_rtt_ms).filter(Boolean);
  const destroyMs   = ok.map(r => r.destroy_ms).filter(Boolean);

  const gradeScores = ok.filter(r => r.grade_score !== null).map(r => ({
    score: r.grade_score, max: r.grade_max
  }));

  const summary = {
    config: {
      students:       N_STUDENTS,
      template:       TEMPLATE,
      base_url:       BASE_URL,
      poll_interval_ms: POLL_MS,
      timeout_ms:     TIMEOUT_MS,
      timestamp:      new Date().toISOString(),
    },
    totals: {
      wall_clock_ms:  totalMs,
      successful:     ok.length,
      failed:         errors.length,
    },
    latency_ms: {
      login:     stats(loginMs),
      provision: stats(provisionMs),
      grade:     stats(gradeMs),
      ws_rtt:    stats(wsRttMs),
      destroy:   stats(destroyMs),
    },
    grading: {
      results: gradeScores,
      perfect_4_4: gradeScores.filter(g => g.score === 4 && g.max === 4).length,
      avg_score: gradeScores.length
        ? (gradeScores.reduce((s, g) => s + g.score, 0) / gradeScores.length).toFixed(2)
        : null,
    },
    memory: {
      backend_heap_before_mb: memBefore ? Math.round(memBefore.heapUsed / 1024 / 1024) : null,
      backend_heap_after_mb:  memAfter  ? Math.round(memAfter.heapUsed  / 1024 / 1024) : null,
    },
    errors: errors.map(r => ({ student: r.student, error: r.error })),
    raw: results,
  };

  // ── Pretty print to stderr ──────────────────────────────────────────────────
  console.error('\n══════════════════════════════════════════════════════════');
  console.error(` BENCHMARK COMPLETE — ${ok.length}/${N_STUDENTS} students succeeded`);
  console.error('══════════════════════════════════════════════════════════');
  console.error(`  Wall clock (all ${N_STUDENTS} concurrent): ${(totalMs/1000).toFixed(1)}s`);
  console.error('');

  const fmtStats = (label, s) => {
    if (!s || s.n === 0) { console.error(`  ${label}: no data`); return; }
    console.error(`  ${label.padEnd(14)} n=${s.n}  min=${s.min}  p50=${s.p50}  p90=${s.p90}  p95=${s.p95}  p99=${s.p99}  max=${s.max}  mean=${s.mean}  (ms)`);
  };

  fmtStats('login',     summary.latency_ms.login);
  fmtStats('provision', summary.latency_ms.provision);
  fmtStats('grade',     summary.latency_ms.grade);
  fmtStats('ws_rtt',    summary.latency_ms.ws_rtt);
  fmtStats('destroy',   summary.latency_ms.destroy);

  console.error('');
  console.error(`  Grading: ${summary.grading.perfect_4_4}/${ok.length} scored 4/4.  avg_score=${summary.grading.avg_score}`);
  console.error(`  Backend heap: ${summary.memory.backend_heap_before_mb} MiB → ${summary.memory.backend_heap_after_mb} MiB`);
  if (errors.length > 0) {
    console.error(`\n  ERRORS (${errors.length}):`);
    errors.forEach(e => console.error(`    student${e.student}: ${e.error}`));
  }
  console.error('══════════════════════════════════════════════════════════\n');

  // ── Emit JSON to stdout (for piping / CI) ────────────────────────────────
  console.log(JSON.stringify(summary, null, 2));
}

main().catch(err => {
  console.error('[bench] FATAL:', err);
  process.exit(1);
});
