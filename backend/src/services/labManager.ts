import { randomUUID } from 'crypto';
import * as k8s from './k8s';
import { labProvisionSeconds, labProvisionFailures, activeLabsGauge, labResetSeconds, labDestroySeconds } from './metrics';
import { emitLabEvent } from './kafka';
import { query } from '../db/client';

export interface Lab {
  id: string;
  userId: string;
  template: string;
  status: string;
  namespace: string;
  podName: string;
  createdAt: Date;
  readyAt?: Date;
  lastActivity: Date;
}

const LAB_IDLE_TIMEOUT_SEC = parseInt(process.env.LAB_IDLE_TIMEOUT_SEC ?? '3600', 10);

export async function createLab(userId: string, template: string): Promise<Lab> {
  // 1. Enforce 1-active-lab-per-user limit
  const activeLab = await query(
    `SELECT id FROM labs WHERE user_id = $1 AND status IN ('requesting','ready','resetting') LIMIT 1`,
    [userId]
  );
  if ((activeLab.rowCount ?? 0) > 0) {
    const err = new Error('User already has an active lab') as any;
    err.statusCode = 409;
    throw err;
  }

  const labId = randomUUID();
  const now = new Date();
  const t_request = Date.now();

  // 2. Insert lab row
  await query(
    `INSERT INTO labs (id, user_id, template, status, created_at, last_activity)
     VALUES ($1, $2, $3, 'requesting', $4, $5)`,
    [labId, userId, template, now, now]
  );

  // 3. Emit requested event
  await emitLabEvent(labId, userId, 'requested');

  let namespace = '';
  let podName = '';

  try {
    // 4. Provision K8s resources
    namespace = await k8s.createLabNamespace(labId, template);
    podName   = await k8s.createLabPod(labId, namespace, template, userId);

    await query(
      `UPDATE labs SET namespace = $1, pod_name = $2 WHERE id = $3`,
      [namespace, podName, labId]
    );

    // 5. Wait for pod ready asynchronously — don't block the HTTP response
    k8s.waitForPodReady(namespace, podName).then(async () => {
      const readyAt = new Date();
      const provisionMs = Date.now() - t_request;

      await query(
        `UPDATE labs SET status = 'ready', ready_at = $1 WHERE id = $2`,
        [readyAt, labId]
      );

      // 6. Emit ready event with timing
      await emitLabEvent(labId, userId, 'ready', { provision_ms: provisionMs });

      // 7. Record Prometheus histogram
      labProvisionSeconds.observe(provisionMs / 1000);
      activeLabsGauge.inc();

    }).catch(async (err: Error) => {
      await query(`UPDATE labs SET status = 'failed' WHERE id = $1`, [labId]);
      await emitLabEvent(labId, userId, 'failed', { error: err.message });
      labProvisionFailures.inc({ template });
    });

  } catch (error: any) {
    await query(`UPDATE labs SET status = 'failed' WHERE id = $1`, [labId]);
    await emitLabEvent(labId, userId, 'failed', { error: error.message });
    labProvisionFailures.inc({ template });
    throw error;
  }

  return { id: labId, userId, template, status: 'requesting', namespace, podName, createdAt: now, lastActivity: now };
}

export async function resetLab(labId: string, userId: string): Promise<void> {
  const result = await query(
    `SELECT namespace, template, pod_name FROM labs WHERE id = $1 AND user_id = $2`,
    [labId, userId]
  );
  if ((result.rowCount ?? 0) === 0) {
    const err = new Error('Lab not found') as any;
    err.statusCode = 404;
    throw err;
  }

  const { namespace, template } = result.rows[0];
  const t_reset = Date.now();

  await query(`UPDATE labs SET status = 'resetting' WHERE id = $1`, [labId]);
  await emitLabEvent(labId, userId, 'reset');

  try {
    // Delete the namespace (and pod) and recreate fresh
    await k8s.destroyLab(namespace);
    const newNamespace = await k8s.createLabNamespace(labId, template);
    const newPodName   = await k8s.createLabPod(labId, newNamespace, template, userId);

    await query(
      `UPDATE labs SET namespace = $1, pod_name = $2 WHERE id = $3`,
      [newNamespace, newPodName, labId]
    );

    k8s.waitForPodReady(newNamespace, newPodName).then(async () => {
      const resetMs = Date.now() - t_reset;
      await query(`UPDATE labs SET status = 'ready', last_activity = now() WHERE id = $1`, [labId]);
      labResetSeconds?.observe(resetMs / 1000);
    }).catch(async () => {
      await query(`UPDATE labs SET status = 'failed' WHERE id = $1`, [labId]);
    });
  } catch (error) {
    await query(`UPDATE labs SET status = 'failed' WHERE id = $1`, [labId]);
    throw error;
  }
}

export async function destroyLab(labId: string, userId: string): Promise<void> {
  const result = await query(
    `SELECT namespace FROM labs WHERE id = $1 AND user_id = $2`,
    [labId, userId]
  );
  if ((result.rowCount ?? 0) === 0) {
    const err = new Error('Lab not found') as any;
    err.statusCode = 404;
    throw err;
  }

  const t_destroy = Date.now();
  const { namespace } = result.rows[0];

  await query(`UPDATE labs SET status = 'destroying' WHERE id = $1`, [labId]);

  if (namespace) {
    await k8s.destroyLab(namespace);
  }

  const destroyMs = Date.now() - t_destroy;
  await query(
    `UPDATE labs SET status = 'destroyed', destroyed_at = now() WHERE id = $1`,
    [labId]
  );
  await emitLabEvent(labId, userId, 'destroyed', { destroy_ms: destroyMs });
  labDestroySeconds?.observe(destroyMs / 1000);
  activeLabsGauge.dec();
}

export async function touchLabActivity(labId: string): Promise<void> {
  await query(`UPDATE labs SET last_activity = now() WHERE id = $1`, [labId]);
}

export async function checkIdleLabs(): Promise<void> {
  const cutoff = new Date(Date.now() - LAB_IDLE_TIMEOUT_SEC * 1000);
  const idleLabs = await query(
    `SELECT id, user_id FROM labs WHERE status = 'ready' AND last_activity < $1`,
    [cutoff]
  );

  for (const row of idleLabs.rows) {
    console.log(`[idle-cleanup] Destroying idle lab ${row.id} for user ${row.user_id}`);
    try {
      await destroyLab(row.id, row.user_id);
    } catch (err) {
      console.error(`[idle-cleanup] Failed to destroy lab ${row.id}:`, err);
    }
  }
}
