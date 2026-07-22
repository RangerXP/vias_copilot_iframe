import express from 'express';
import { randomUUID } from 'crypto';
import { normalizeContext, buildContextBlock } from '../services/contextService.js';
import { sendToFoundryAgent } from '../services/foundryAgent.js';
import { queryFabricAgent } from '../services/fabricAgent.js';

const router = express.Router();

router.post('/', async (req, res) => {
  // Evaluate at request-time — dotenv.config() runs after ESM imports are hoisted,
  // so top-level module constants would see undefined env vars.
  const USE_FOUNDRY = Boolean(process.env.FOUNDRY_AGENT_ID && process.env.FOUNDRY_PROJECT_ENDPOINT);
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

    // Sprint 5: a conversationId ties requests to the same Foundry thread so
    // follow-up questions and page transitions retain history. Client generates
    // one on first use and echoes it back on subsequent requests; we mint one
    // here as a fallback if the client didn't send one.
    const conversationId = clientConversationId || randomUUID();

    const businessContext = rawContext ? normalizeContext(rawContext) : null;
    const contextBlock = businessContext ? buildContextBlock(businessContext) : '';

    let answer;
    if (USE_FOUNDRY) {
      const userTurn = contextBlock
        ? `[Report Context]\n${contextBlock}\n\n[User Question]\n${question}`
        : question;
      answer = await sendToFoundryAgent({ userTurn, conversationId, effectiveUserName });
    } else {
      // Direct Fabric Data Agent path (used when FOUNDRY_AGENT_ID is not configured)
      answer = await queryFabricAgent({ question, context: businessContext, effectiveUserName });
    }

    res.json({ answer, conversationId });
  } catch (err) {
    console.error('[chat]', err.message);
    res.status(500).json({ error: err.message });
  }
});

export default router;
