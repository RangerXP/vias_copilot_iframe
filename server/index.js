import express from 'express';
import cors from 'cors';
import session from 'express-session';
import dotenv from 'dotenv';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import embedTokenRoute from './routes/embedToken.js';
import chatRoute from './routes/chat.js';
import contextRoute from './routes/context.js';
import sessionRoute from './routes/session.js';

dotenv.config();

const __dirname = dirname(fileURLToPath(import.meta.url));
const app = express();
const isProduction = process.env.NODE_ENV === 'production';

if (!process.env.SESSION_SECRET && isProduction) {
  throw new Error('SESSION_SECRET must be set in production.');
}

app.use(cors({
  origin: [
    `http://localhost:${process.env.PORT || 3000}`,
    'http://localhost:5173'
  ],
  methods: ['GET', 'POST'],
  credentials: true // required so the session cookie is sent/accepted cross-origin (dev only; same-origin in prod)
}));
app.use(express.json());

// Server-managed session (docs/design_notes.md §17) — the entitlement value used for
// RLS is resolved from this session, never from a client-supplied query param/body field.
app.use(session({
  name: 'pbie.sid',
  secret: process.env.SESSION_SECRET || 'dev-only-insecure-secret-do-not-use-in-production',
  resave: false,
  saveUninitialized: false,
  cookie: {
    httpOnly: true,
    secure: isProduction,
    sameSite: 'lax',
    maxAge: 8 * 60 * 60 * 1000 // 8 hours
  }
}));

app.use(express.static(join(__dirname, '..', 'frontend')));

app.use('/api/session', sessionRoute);
app.use('/api/embed-token', embedTokenRoute);
app.use('/api/chat', chatRoute);
app.use('/api/context', contextRoute);

const port = process.env.PORT || 3000;
app.listen(port, () => {
  console.log(`PBIE local server running on http://localhost:${port}`);
});

