import { Router, Request, Response, NextFunction } from 'express';
import { z } from 'zod';
import * as argon2 from 'argon2';
import jwt from 'jsonwebtoken';
import { query } from '../db/client';
import { verifyToken } from '../middleware/auth';
import { loginLimiter } from '../middleware/rateLimiter';

// For MVP, skip Redis blacklist for logout (just client-side drop) since redis client wasn't defined.

const router = Router();

const loginSchema = z.object({
  username: z.string().min(1),
  password: z.string().min(1),
});

const JWT_SECRET = process.env.JWT_SECRET || 'secret';
const JWT_EXPIRES_IN = 3600; // 1 hour

router.post('/login', loginLimiter, async (req: Request, res: Response, next: NextFunction) => {
  try {
    const { username, password } = loginSchema.parse(req.body);

    const userResult = await query('SELECT * FROM users WHERE username = $1', [username]);
    const user = userResult.rows[0];

    if (!user) {
      await query(`INSERT INTO audit_log (action, resource_id) VALUES ('login_failure_user_not_found', $1)`, [username]);
      return res.status(401).json({ message: 'Invalid credentials' });
    }

    const isValid = await argon2.verify(user.password_hash, password);

    if (!isValid) {
      await query(`INSERT INTO audit_log (user_id, action, resource_id) VALUES ($1, 'login_failure_invalid_password', $2)`, [user.id, username]);
      return res.status(401).json({ message: 'Invalid credentials' });
    }

    const token = jwt.sign(
      { id: user.id, username: user.username, role: user.role },
      JWT_SECRET,
      { expiresIn: JWT_EXPIRES_IN }
    );

    await query(`INSERT INTO audit_log (user_id, action, resource_id) VALUES ($1, 'login_success', $2)`, [user.id, username]);

    return res.json({ 
      token, 
      user: { id: user.id, username: user.username, role: user.role } 
    });
  } catch (error) {
    if (error instanceof z.ZodError) {
      return res.status(400).json({ message: 'Validation error', errors: error.errors });
    }
    next(error);
  }
});

router.post('/logout', verifyToken, (req: Request, res: Response) => {
  // For MVP, just dropping the token on the client is sufficient.
  return res.status(200).json({ message: 'Logged out successfully' });
});

router.get('/me', verifyToken, (req: Request, res: Response) => {
  return res.json({ user: (req as any).user });
});

export default router;
