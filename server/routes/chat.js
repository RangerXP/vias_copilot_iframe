import express from 'express';
import { normalizeContext, buildContextBlock } from '../services/contextService.js';
import { sendToFoundryAgent } from '../services/foundryAgent.js';

const router = express.Router();

router.post('/', async (req, res) => {
  try {
    const { question, rawContext } = req.body;

    if (!question || typeof question !== 'string') {
      return res.status(400).json({ error: 'question (string) is required' });
    }

    const businessContext = rawContext ? normalizeContext(rawContext) : null;
    const contextBlock = businessContext ? buildContextBlock(businessContext) : '';

    const userTurn = contextBlock
      ? `[Report Context]\n${contextBlock}\n\n[User Question]\n${question}`
      : question;

    const answer = await sendToFoundryAgent({ userTurn });
    res.json({ answer });
  } catch (err) {
    console.error('[chat]', err.message);
    res.status(500).json({ error: err.message });
  }
});

export default router;
