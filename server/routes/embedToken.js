import express from 'express';
import { getEmbedToken } from '../services/pbiClient.js';

const router = express.Router();

// Accept optional user identity for RLS enforcement.
// External/guest users should pass their UPN via query param: /api/embed-token?user=alice@contoso.com
// In production this should come from a validated session/token, not an open query param.
router.get('/', async (req, res) => {
  try {
    // userIdentity is optional — when supplied, embed token enforces RLS for that user.
    const userIdentity = req.query.user
      ? { username: req.query.user }
      : undefined;

    const token = await getEmbedToken({
      workspaceId: process.env.WORKSPACE_ID,
      reportId: process.env.REPORT_ID,
      datasetId: process.env.DATASET_ID,
      userIdentity
    });
    res.json(token);
  } catch (err) {
    console.error('[embedToken]', err.message);
    res.status(500).json({ error: err.message });
  }
});

export default router;
