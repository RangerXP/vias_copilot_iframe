import express from 'express';
import { randomUUID } from 'crypto';
import { normalizeContext } from '../services/contextService.js';
import { queryFabricAgent } from '../services/fabricAgent.js';

const router = express.Router();

router.post('/', async (req, res) => {
  try {
    const { question, rawContext, conversationId: clientConversationId } = req.body;

    // Identity source: the authenticated session (docs/design_notes.md §17), NEVER a
    // client-supplied body field. This keeps the chat/XMLA RLS boundary identical to
    // the embed-token path (server/routes/embedToken.js) — the same session drives both.
    const effectiveUserName = req.session.customerId;
    if (!effectiveUserName) {
      return res.status(401).json({ error: 'Not signed in. Call POST /api/session/login first.' });
    }

    if (!question || typeof question !== 'string') {
      return res.status(400).json({ error: 'question (string) is required' });
    }

    // conversationId is returned to the client so it can be echoed back on
    // subsequent requests (kept for parity with the client's session storage).
    const conversationId = clientConversationId || randomUUID();

    const businessContext = rawContext ? normalizeContext(rawContext) : null;

    const answer = await queryFabricAgent({ question, context: businessContext, effectiveUserName });

    res.json({ answer, conversationId });
  } catch (err) {
    console.error('[chat]', err.message);
    res.status(500).json({ error: err.message });
  }
});

export default router;

