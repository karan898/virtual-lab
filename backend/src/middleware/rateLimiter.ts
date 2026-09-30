import rateLimit from 'express-rate-limit';

// Note: Using default memory store. 
// For production deployments, consider using a RedisStore (e.g. rate-limit-redis) to share state across multiple instances.

export const loginLimiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 minutes
  max: 1000, // Limit each IP to 1000 login requests per `window` (here, per 15 minutes)
  standardHeaders: true, // Return rate limit info in the `RateLimit-*` headers
  legacyHeaders: false, // Disable the `X-RateLimit-*` headers
  message: { error: 'Too many login attempts, please try again after 15 minutes' },
});

export const labCreateLimiter = rateLimit({
  windowMs: 10 * 60 * 1000, // 10 minutes
  max: 1000, // Limit each IP to 1000 lab create requests per window
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Too many lab creation requests, please try again after 10 minutes' },
});
