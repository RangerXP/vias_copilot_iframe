import express from 'express';
import { isKnownCustomer, resolveCustomerDisplayName } from '../services/rlsTestUsers.js';

const router = express.Router();

// Server-managed session + entitlement resolution (docs/design_notes.md §17).
// Replaces the unauthenticated `?user=<upn>` transport: the frontend no longer
// supplies an identity directly to /api/embed-token or /api/chat. Instead it
// establishes an HTTP-only session cookie here, and every downstream route reads
// the customerId from req.session — never from client-supplied query/body input.
//
// PRODUCTION NOTE: this route stands in for a real Visa Portal login. In production
// this would validate an MSAL.js-acquired Entra ID token (or an existing portal SSO
// session) server-side before establishing req.session — never trust a bare
// customerId from the request body as this PoC does. The rest of the pipeline
// (session → resolve entitlement → CUSTOMDATA()) is unchanged either way.
router.post('/login', (req, res) => {
  const { customerId } = req.body || {};
  if (!isKnownCustomer(customerId)) {
    return res.status(401).json({ error: 'Unknown customer.' });
  }
  req.session.customerId = customerId;
  res.json({ customerId, displayName: resolveCustomerDisplayName(customerId) });
});

router.post('/logout', (req, res) => {
  req.session.destroy(() => res.json({ ok: true }));
});

router.get('/me', (req, res) => {
  if (!req.session.customerId) {
    return res.status(401).json({ error: 'Not signed in.' });
  }
  res.json({
    customerId: req.session.customerId,
    displayName: resolveCustomerDisplayName(req.session.customerId)
  });
});

export default router;
