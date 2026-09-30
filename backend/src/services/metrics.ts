import { Registry, Histogram, Counter, Gauge, collectDefaultMetrics } from 'prom-client';
import { Request, Response } from 'express';

export const register = new Registry();

collectDefaultMetrics({ register });

export const labProvisionSeconds = new Histogram({
  name: 'lab_provision_seconds',
  help: 'Duration in seconds to provision a lab',
  buckets: [5, 10, 20, 30, 60, 120],
  registers: [register],
});

export const labResetSeconds = new Histogram({
  name: 'lab_reset_seconds',
  help: 'Duration in seconds to reset a lab',
  registers: [register],
});

export const labDestroySeconds = new Histogram({
  name: 'lab_destroy_seconds',
  help: 'Duration in seconds to destroy a lab',
  registers: [register],
});

export const labProvisionFailures = new Counter({
  name: 'lab_provision_failures_total',
  help: 'Total number of lab provision failures',
  labelNames: ['template'],
  registers: [register],
});

export const activeLabsGauge = new Gauge({
  name: 'active_labs_total',
  help: 'Total number of currently active labs',
  registers: [register],
});

export const metricsMiddleware = async (req: Request, res: Response) => {
  try {
    res.set('Content-Type', register.contentType);
    const metrics = await register.metrics();
    res.send(metrics);
  } catch (err) {
    res.status(500).send('Error generating metrics');
  }
};
