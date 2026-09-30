import { Router, Request, Response, NextFunction } from 'express';
import { verifyToken, requireRole } from '../middleware/auth';
import { labCreateLimiter } from '../middleware/rateLimiter';
import { createLab, resetLab, destroyLab } from '../services/labManager';
import { gradeSubmission } from '../services/grader';
import { query } from '../db/client';

const router = Router();
router.use(verifyToken);

const VALID_TEMPLATES = ['ospf', 'static-routing', 'vlan'];

// Helper: fetch lab and enforce ownership/admin access
const getLabAndCheckAccess = async (
  req: Request,
  res: Response,
  ownerOnly: boolean
) => {
  const labId = req.params.id;
  const user  = (req as any).user;

  const result = await query('SELECT * FROM labs WHERE id = $1', [labId]);
  const lab = result.rows[0];

  if (!lab) {
    res.status(404).json({ message: 'Lab not found' });
    return null;
  }

  const isOwner           = lab.user_id === user.id;
  const isAdminOrInstructor = ['admin', 'instructor'].includes(user.role);

  if (ownerOnly && !isOwner && !isAdminOrInstructor) {
    res.status(403).json({ message: 'Forbidden: owner access required' });
    return null;
  }
  if (!ownerOnly && !isOwner && !isAdminOrInstructor) {
    res.status(403).json({ message: 'Forbidden' });
    return null;
  }

  return lab;
};

// Helper: map DB row (snake_case) to camelCase Lab response
const rowToLab = (r: any) => ({
  id:           r.id,
  userId:       r.user_id,
  template:     r.template,
  status:       r.status,
  namespace:    r.namespace,
  podName:      r.pod_name,
  createdAt:    r.created_at,
  readyAt:      r.ready_at,
  destroyedAt:  r.destroyed_at,
  lastActivity: r.last_activity,
});

// POST /api/labs — create lab
router.post('/', requireRole('student', 'instructor'), labCreateLimiter,
  async (req: Request, res: Response, next: NextFunction) => {
    try {
      const { template } = req.body;
      if (!VALID_TEMPLATES.includes(template)) {
        return res.status(400).json({ message: `Invalid template. Must be one of: ${VALID_TEMPLATES.join(', ')}` });
      }
      const lab = await createLab((req as any).user.id, template);
      await query(
        `INSERT INTO audit_log (user_id, action, resource_id) VALUES ($1, 'create_lab', $2)`,
        [(req as any).user.id, lab.id]
      );
      return res.status(201).json(lab);
    } catch (error) {
      if ((error as Error).message?.includes('active lab')) {
        return res.status(409).json({ message: 'You already have an active lab' });
      }
      next(error);
    }
  }
);

// GET /api/labs — list labs
router.get('/', async (req: Request, res: Response, next: NextFunction) => {
  try {
    const user = (req as any).user;
    const isAdminOrInstructor = ['admin', 'instructor'].includes(user.role);
    const result = isAdminOrInstructor
      ? await query('SELECT * FROM labs ORDER BY created_at DESC')
      : await query('SELECT * FROM labs WHERE user_id = $1 ORDER BY created_at DESC', [user.id]);
    return res.json(result.rows.map(rowToLab));
  } catch (error) {
    next(error);
  }
});

// GET /api/labs/:id
router.get('/:id', async (req: Request, res: Response, next: NextFunction) => {
  try {
    const lab = await getLabAndCheckAccess(req, res, false);
    if (!lab) return;
    return res.json(rowToLab(lab));
  } catch (error) {
    next(error);
  }
});

// POST /api/labs/:id/reset
router.post('/:id/reset', async (req: Request, res: Response, next: NextFunction) => {
  try {
    const lab = await getLabAndCheckAccess(req, res, true);
    if (!lab) return;
    await resetLab(lab.id, lab.user_id);
    await query(
      `INSERT INTO audit_log (user_id, action, resource_id) VALUES ($1, 'reset_lab', $2)`,
      [(req as any).user.id, lab.id]
    );
    return res.json({ message: 'Lab reset initiated' });
  } catch (error) {
    next(error);
  }
});

// DELETE /api/labs/:id
router.delete('/:id', async (req: Request, res: Response, next: NextFunction) => {
  try {
    const lab = await getLabAndCheckAccess(req, res, false);
    if (!lab) return;
    await destroyLab(lab.id, lab.user_id);
    await query(
      `INSERT INTO audit_log (user_id, action, resource_id) VALUES ($1, 'destroy_lab', $2)`,
      [(req as any).user.id, lab.id]
    );
    return res.json({ message: 'Lab destroyed' });
  } catch (error) {
    next(error);
  }
});

// POST /api/labs/:id/submit — grade the lab
router.post('/:id/submit', async (req: Request, res: Response, next: NextFunction) => {
  try {
    const lab = await getLabAndCheckAccess(req, res, true);
    if (!lab) return;
    if (lab.status !== 'ready') {
      return res.status(409).json({ message: 'Lab must be in ready state to submit' });
    }
    // Load the topology JSON from disk via the pod env (stored in DB)
    // For grading, pass namespace/podName from lab record + read topo from templates
    const fs = await import('fs');
    const path = await import('path');
    const topoPath = path.join('/templates', `${lab.template}.json`);
    const topoJson = JSON.parse(fs.readFileSync(topoPath, 'utf8'));

    const result = await gradeSubmission(lab.id, (req as any).user.id, lab.namespace, lab.pod_name, topoJson);
    await query(
      `INSERT INTO audit_log (user_id, action, resource_id) VALUES ($1, 'submit_lab', $2)`,
      [(req as any).user.id, lab.id]
    );
    return res.json(result);
  } catch (error) {
    next(error);
  }
});

// POST /api/labs/:id/finish — destroy and mark finished
router.post('/:id/finish', async (req: Request, res: Response, next: NextFunction) => {
  try {
    const lab = await getLabAndCheckAccess(req, res, true);
    if (!lab) return;
    await destroyLab(lab.id, lab.user_id);
    await query(
      `INSERT INTO audit_log (user_id, action, resource_id) VALUES ($1, 'finish_lab', $2)`,
      [(req as any).user.id, lab.id]
    );
    return res.json({ message: 'Lab finished and destroyed' });
  } catch (error) {
    next(error);
  }
});

export default router;
