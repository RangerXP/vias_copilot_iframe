import express from 'express';

const router = express.Router();

// Receives raw PBIE context from the frontend.
// Sprint 3+: extend to trigger proactive agent queries on context change.
router.post('/', async (req, res) => {
  try {
    const { rawContext } = req.body;
    if (!rawContext || typeof rawContext !== 'object') {
      return res.status(400).json({ error: 'rawContext (object) is required' });
    }
    res.json({ received: true, context: rawContext });
  } catch (err) {
    console.error('[context]', err.message);
    res.status(500).json({ error: err.message });
  }
});

export default router;
