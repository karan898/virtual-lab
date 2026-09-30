// src/services/grader.ts — Lab grading service
// Runs grading checks inside the lab pod by executing commands via K8s exec
// and evaluating results against the topology's grading_checks spec.
import * as k8s from '@kubernetes/client-node';
import { query } from '../db/client';
import { emitGradeEvent } from './kafka';
import { v4 as uuidv4 } from 'uuid';

interface GradingCheck {
  id: string;
  description: string;
  type: 'ping' | 'vtysh' | 'ovs_check';
  // ping fields
  from_ns?: string;
  target_ip?: string;
  count?: number;
  expect_success?: boolean;
  // vtysh / ovs_check fields
  router?: string;
  command?: string;
  expect_contains?: string;
}

interface CheckResult {
  id: string;
  description: string;
  passed: boolean;
  output: string;
  error?: string;
}

const kc = new k8s.KubeConfig();
let execClient: k8s.Exec | null = null;

export function initGrader(): void {
  const kubeconfigPath = process.env.KUBECONFIG || '/root/.kube/config';
  kc.loadFromFile(kubeconfigPath);
  execClient = new k8s.Exec(kc);
}

function getExecClient(): k8s.Exec {
  if (!execClient) initGrader();
  return execClient!;
}

async function runCommandInPod(
  namespace: string,
  podName: string,
  command: string[]
): Promise<{ stdout: string; stderr: string; exitCode: number }> {
  return new Promise((resolve) => {
    let stdout = '';
    let stderr = '';

    const outStream = new (require('stream').PassThrough)();
    const errStream = new (require('stream').PassThrough)();
    outStream.on('data', (d: Buffer) => { stdout += d.toString(); });
    errStream.on('data', (d: Buffer) => { stderr += d.toString(); });

    getExecClient().exec(
      namespace,
      podName,
      'lab-node',  // container name in pod
      command,
      outStream,
      errStream,
      null,
      false,
      (status) => {
        const exitCode = status.status === 'Success' ? 0 : 1;
        resolve({ stdout: stdout.trim(), stderr: stderr.trim(), exitCode });
      }
    ).catch((err: Error) => {
      resolve({ stdout: '', stderr: err.message, exitCode: 1 });
    });
  });
}

async function runCheck(
  check: GradingCheck,
  namespace: string,
  podName: string
): Promise<CheckResult> {
  const result: CheckResult = {
    id: check.id,
    description: check.description,
    passed: false,
    output: '',
  };

  try {
    if (check.type === 'ping') {
      const count = check.count ?? 3;
      const cmd = [
        'ip', 'netns', 'exec', check.from_ns!,
        'ping', '-c', String(count), '-W', '2', check.target_ip!
      ];
      const { stdout, exitCode } = await runCommandInPod(namespace, podName, cmd);
      result.output = stdout;
      const gotPackets = stdout.includes(`${count} received`);
      if (check.expect_success) {
        result.passed = exitCode === 0 && gotPackets;
      } else {
        // Negative test: expect ping to FAIL (cross-VLAN isolation)
        result.passed = exitCode !== 0 || stdout.includes('0 received');
      }

    } else if (check.type === 'vtysh') {
      const cmd = ['vtysh', '-N', check.router!, '-c', check.command!];
      const { stdout } = await runCommandInPod(namespace, podName, cmd);
      result.output = stdout;
      result.passed = stdout.includes(check.expect_contains!);

    } else if (check.type === 'ovs_check') {
      const { stdout } = await runCommandInPod(namespace, podName, ['ovs-vsctl', 'show']);
      result.output = stdout;
      result.passed = stdout.includes(check.expect_contains!);
    }
  } catch (err) {
    result.error = String(err);
    result.passed = false;
  }

  return result;
}

export async function gradeSubmission(
  labId: string,
  userId: string,
  namespace: string,
  podName: string,
  topoJson: object
): Promise<{ submissionId: string; score: number; maxScore: number; results: CheckResult[] }> {
  const topo = topoJson as { grading_checks: GradingCheck[] };
  const checks = topo.grading_checks ?? [];
  const maxScore = checks.length;

  const results: CheckResult[] = [];
  for (const check of checks) {
    const r = await runCheck(check, namespace, podName);
    results.push(r);
    console.log(`  [grade] ${r.passed ? 'PASS' : 'FAIL'} ${r.id}`);
  }

  const score = results.filter(r => r.passed).length;
  const submissionId = uuidv4();

  // Store in DB
  await query(
    `INSERT INTO submissions (id, lab_id, user_id, submitted_at, score, max_score, results)
     VALUES ($1, $2, $3, now(), $4, $5, $6)`,
    [submissionId, labId, userId, score, maxScore, JSON.stringify(results)]
  );

  // Emit Kafka grade event
  await emitGradeEvent(submissionId, labId, score, maxScore);

  return { submissionId, score, maxScore, results };
}
