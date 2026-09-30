import { Router, Request, Response, NextFunction } from 'express';
import { verifyToken, requireRole } from '../middleware/auth';
import { query } from '../db/client';
import * as argon2 from 'argon2';
import { destroyLab } from '../services/labManager';

const router = Router();

// All admin routes require a valid JWT AND admin/instructor role
router.use(verifyToken);
router.use(requireRole('admin', 'instructor'));

// GET /api/admin/labs — all active labs with user info
router.get('/labs', async (req: Request, res: Response, next: NextFunction) => {
  try {
    const result = await query(`
      SELECT l.*, u.username, u.role AS user_role
      FROM labs l
      JOIN users u ON l.user_id = u.id
      WHERE l.status IN ('requesting','ready','resetting')
      ORDER BY l.created_at DESC
    `);
    
    const labs = result.rows.map(row => {
      let provisionTime = '';
      if (row.created_at && row.ready_at) {
        provisionTime = ((new Date(row.ready_at).getTime() - new Date(row.created_at).getTime()) / 1000).toFixed(1) + 's';
      }
      return {
        id: row.id,
        username: row.username,
        template: row.template,
        status: row.status,
        startTime: row.created_at,
        provisionTime: provisionTime
      };
    });
    
    return res.json(labs);
  } catch (error) {
    next(error);
  }
});

// GET /api/admin/users
router.get('/users', async (req: Request, res: Response, next: NextFunction) => {
  try {
    const result = await query(
      'SELECT id, username, role, created_at, last_seen FROM users ORDER BY created_at DESC'
    );
    return res.json(result.rows);
  } catch (error) {
    next(error);
  }
});

// POST /api/admin/users — create user
router.post('/users', async (req: Request, res: Response, next: NextFunction) => {
  try {
    const { username, password, role } = req.body;
    if (!username || !password || !role) {
      return res.status(400).json({ message: 'Missing required fields: username, password, role' });
    }
    if (!['student', 'instructor', 'admin'].includes(role)) {
      return res.status(400).json({ message: 'Invalid role' });
    }
    const hash = await argon2.hash(password, { type: argon2.argon2id });
    const result = await query(
      `INSERT INTO users (id, username, password_hash, role, created_at)
       VALUES (gen_random_uuid(), $1, $2, $3, NOW())
       RETURNING id, username, role, created_at`,
      [username, hash, role]
    );
    return res.status(201).json(result.rows[0]);
  } catch (error) {
    if ((error as any).code === '23505') {
      return res.status(409).json({ message: 'Username already exists' });
    }
    next(error);
  }
});

// DELETE /api/admin/labs/:id — force-destroy any lab
router.delete('/labs/:id', async (req: Request, res: Response, next: NextFunction) => {
  try {
    const labId = req.params.id;
    const labResult = await query('SELECT * FROM labs WHERE id = $1', [labId]);
    if (!labResult.rows[0]) {
      return res.status(404).json({ message: 'Lab not found' });
    }
    await destroyLab(labId, labResult.rows[0].user_id);
    return res.json({ message: 'Lab force-destroyed' });
  } catch (error) {
    next(error);
  }
});

// GET /api/admin/metrics-summary
router.get('/metrics-summary', async (req: Request, res: Response, next: NextFunction) => {
  try {
    const [active, total, failed, avgProv] = await Promise.all([
      query("SELECT COUNT(*) FROM labs WHERE status IN ('requesting','ready','resetting')"),
      query('SELECT COUNT(*) FROM labs'),
      query("SELECT COUNT(*) FROM labs WHERE status = 'failed'"),
      query(`
        SELECT AVG(EXTRACT(EPOCH FROM (ready_at - created_at)) * 1000) AS avg_ms
        FROM labs WHERE ready_at IS NOT NULL
      `),
    ]);
    return res.json({
      activeLabs:    parseInt(active.rows[0].count,  10),
      totalLabs:     parseInt(total.rows[0].count,   10),
      failedLabs:    parseInt(failed.rows[0].count,  10),
      avgProvisionMs: parseFloat(avgProv.rows[0].avg_ms) || 0,
    });
  } catch (error) {
    next(error);
  }
});

export default router;
