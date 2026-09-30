import WebSocket from 'ws';
import jwt from 'jsonwebtoken';
import { parse } from 'url';
import { Exec } from '@kubernetes/client-node';
import stream from 'stream';
import { query } from '../db/client';
import { getKubeConfig } from '../services/k8s';
import { touchLabActivity } from '../services/labManager';

const JWT_SECRET = process.env.JWT_SECRET || 'secret';

export const wsHandler = (wss: WebSocket.Server): void => {
  wss.on('connection', async (ws: WebSocket, request: any) => {
    const { query: qs } = parse(request.url || '', true);

    const token    = qs.token    as string;
    const labId    = qs.labId    as string;
    const netns    = qs.netns    as string;
    const isRouter = qs.isRouter === 'true';

    if (!token || !labId || !netns) {
      ws.close(4000, 'Missing required query parameters');
      return;
    }

    // ── Auth ────────────────────────────────────────────────────────────────
    let decoded: any;
    try {
      decoded = jwt.verify(token, JWT_SECRET);
    } catch {
      ws.close(4001, 'Invalid token');
      return;
    }

    const userId = decoded.id;

    // ── Lab ownership check ─────────────────────────────────────────────────
    let lab: any;
    try {
      const res = await query(
        'SELECT id, user_id, namespace, pod_name, status FROM labs WHERE id = $1',
        [labId]
      );
      lab = res.rows[0];
    } catch (err) {
      ws.close(4500, 'DB error');
      return;
    }

    if (!lab) { ws.close(4004, 'Lab not found'); return; }
    if (lab.status !== 'ready') { ws.close(4009, 'Lab not ready'); return; }

    const isAdminOrInstructor = ['admin', 'instructor'].includes(decoded.role);
    if (lab.user_id !== userId && !isAdminOrInstructor) {
      ws.close(4003, 'Forbidden');
      return;
    }

    const namespace = lab.namespace as string;
    const podName   = lab.pod_name  as string;

    // ── Build exec command ──────────────────────────────────────────────────
    // Routers: open vtysh in FRR pathspace  (interactive CLI)
    // Hosts:   open bash inside the named netns
    const command = isRouter
      ? ['vtysh', '-N', netns]
      : ['ip', 'netns', 'exec', netns, 'bash'];

    // ── Stream bridges ──────────────────────────────────────────────────────
    // K8s Exec talks a multiplexed binary protocol over the WebSocket.
    // The @kubernetes/client-node Exec.exec() method wraps this; when tty=true
    // it collapses stdout/stderr into a single stream.  We create PassThrough
    // streams and pipe them to/from the browser WebSocket.

    const stdin  = new stream.PassThrough();
    const stdout = new stream.PassThrough();
    const stderr = new stream.PassThrough();

    // stdout/stderr → browser WebSocket
    stdout.on('data', (chunk: Buffer) => {
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(chunk);
      }
    });
    stderr.on('data', (chunk: Buffer) => {
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(chunk);
      }
    });

    // browser WebSocket message → stdin
    ws.on('message', (data: Buffer | string) => {
      touchLabActivity(labId).catch(console.error);
      try {
        stdin.write(data);
      } catch { /* ignore write-after-end */ }
    });

    // ── Exec ─────────────────────────────────────────────────────────────────
    let execConn: any = null;

    const cleanup = () => {
      try { stdin.end(); } catch { /* ignore */ }
      try { execConn?.abort?.(); } catch { /* ignore */ }
    };

    ws.on('close', cleanup);
    ws.on('error', (err) => {
      console.error('[ws] WebSocket error:', err.message);
      cleanup();
    });

    try {
      const kc   = getKubeConfig();
      const exec = new Exec(kc);

      execConn = await exec.exec(
        namespace,
        podName,
        'lab-node',   // container name
        command,
        stdout,       // K8s stdout → stdout PassThrough → ws
        stderr,       // K8s stderr → stderr PassThrough → ws
        stdin,        // stdin PassThrough ← ws messages
        true,         // tty=true → PTY (arrow keys, tab completion)
        (status: any) => {
          // exec finished — close the browser side cleanly
          console.log(`[ws] exec finished for lab ${labId}, status:`, status?.status);
          if (ws.readyState === WebSocket.OPEN) {
            ws.close(1000, 'Session ended');
          }
        }
      );

    } catch (err: any) {
      console.error('[ws] exec error:', err?.message || err);
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(`\r\n[ERROR] Failed to open terminal: ${err?.message}\r\n`);
        ws.close(4500, 'Exec failed');
      }
    }
  });
};
