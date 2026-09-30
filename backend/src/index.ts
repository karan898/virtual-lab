import dotenv from 'dotenv';
import path from 'path';
dotenv.config({ path: path.join(__dirname, '../../.env') });

import express, { Request, Response, NextFunction } from 'express';
import http from 'http';
import WebSocket from 'ws';
import { parse } from 'url';

import authRouter from './routes/auth';
import labsRouter from './routes/labs';
import adminRouter from './routes/admin';
import { metricsMiddleware } from './services/metrics';
import { wsHandler } from './routes/ws';
import { initK8sClient } from './services/k8s';
import { initKafka } from './services/kafka';
import { checkIdleLabs } from './services/labManager';

const app = express();
const server = http.createServer(app);
const wss = new WebSocket.Server({ noServer: true });

wsHandler(wss);

app.use(express.json({ limit: '1mb' }));

app.use((req: Request, res: Response, next: NextFunction) => {
  const start = Date.now();
  res.on('finish', () => {
    const duration = Date.now() - start;
    console.error(`[${req.method}] ${req.originalUrl} ${res.statusCode} - ${duration}ms`);
  });
  next();
});

app.use('/api/auth', authRouter);
app.use('/api/labs', labsRouter);
app.use('/api/admin', adminRouter);

app.get('/health', (req: Request, res: Response) => {
  res.json({
    status: 'ok',
    uptime: process.uptime(),
    memory: process.memoryUsage()
  });
});

app.get('/metrics', metricsMiddleware);

server.on('upgrade', (request, socket, head) => {
  const { pathname } = parse(request.url || '', true);

  if (pathname === '/ws/console') {
    wss.handleUpgrade(request, socket, head, (ws) => {
      wss.emit('connection', ws, request);
    });
  } else {
    socket.destroy();
  }
});

const startServer = async () => {
  // K8s client — non-fatal if kubeconfig not yet ready
  try {
    initK8sClient();
    console.log('K8s client initialized.');
  } catch (err) {
    console.error('K8s client init failed (non-fatal — cluster may not be ready yet):', err);
  }

  // Kafka — always non-fatal
  initKafka().catch(err => {
    console.error('Kafka init failed (non-fatal):', err);
  });

  // Background idle-lab cleanup
  setInterval(checkIdleLabs, 60_000);

  const PORT = parseInt(process.env.PORT ?? '4000', 10);
  server.listen(PORT, () => {
    console.log(`[netlab-backend] Listening on :${PORT}`);
  });

  const shutdown = () => {
    console.log('SIGTERM received — shutting down gracefully');
    server.close(() => {
      console.log('HTTP server closed.');
      process.exit(0);
    });
    setTimeout(() => process.exit(1), 10_000); // force-exit after 10s
  };
  process.on('SIGTERM', shutdown);
  process.on('SIGINT',  shutdown);
};

startServer().catch(err => {
  console.error('Fatal startup error:', err);
  process.exit(1);
});
