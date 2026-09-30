#!/usr/bin/env tsx
// src/scripts/seed.ts — Seed demo users for development
import argon2 from 'argon2';
import { query } from '../db/client';
import { v4 as uuidv4 } from 'uuid';

interface SeedUser {
  username: string;
  password: string;
  role: 'admin' | 'instructor' | 'student';
}

const users: SeedUser[] = [
  { username: 'admin',       password: process.env.SEED_ADMIN_PASSWORD      ?? 'admin123',  role: 'admin' },
  { username: 'instructor1', password: process.env.SEED_INSTRUCTOR_PASSWORD  ?? 'pass123',   role: 'instructor' },
  { username: 'student1',    password: process.env.SEED_STUDENT_PASSWORD     ?? 'pass123',   role: 'student' },
  { username: 'student2',    password: process.env.SEED_STUDENT_PASSWORD     ?? 'pass123',   role: 'student' },
  { username: 'student3',    password: process.env.SEED_STUDENT_PASSWORD     ?? 'pass123',   role: 'student' },
  { username: 'student4',    password: process.env.SEED_STUDENT_PASSWORD     ?? 'pass123',   role: 'student' },
  { username: 'student5',    password: process.env.SEED_STUDENT_PASSWORD     ?? 'pass123',   role: 'student' },
];

async function seed() {
  console.log('Seeding users...');
  for (const user of users) {
    const hash = await argon2.hash(user.password, { type: argon2.argon2id });
    await query(
      `INSERT INTO users (id, username, password_hash, role)
       VALUES ($1, $2, $3, $4)
       ON CONFLICT (username) DO UPDATE
         SET password_hash = EXCLUDED.password_hash,
             role = EXCLUDED.role`,
      [uuidv4(), user.username, hash, user.role]
    );
    console.log(`  ✓ ${user.role}: ${user.username}`);
  }
  console.log('Seeding complete.');
  process.exit(0);
}

seed().catch(err => {
  console.error('Seed failed:', err);
  process.exit(1);
});
