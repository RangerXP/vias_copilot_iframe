import express from 'express';
import { getEmbedToken } from '../services/pbiClient.js';
import { TEST_USER_ROLES } from '../services/rlsTestUsers.js';

const router = express.Router();

// Accept optional user identity for RLS enforcement.
// External/guest users should pass their UPN via query param: /api/embed-token?user=alice@contoso.com
// In production this should come from a validated session/token, not an open query param.
router.get('/', async (req, res) => {
  try {
    // userIdentity is optional — when supplied, embed token enforces RLS for that user.
    // roles is resolved from the known test-user map above; falls back to an explicit
    // ?role= override (comma-separated) for ad-hoc testing against other role names.
    const user = req.query.user;
    const roles = TEST_USER_ROLES[user]
      ?? (req.query.role ? String(req.query.role).split(',').map(r => r.trim()) : undefined);

    const userIdentity = user
      ? { username: user, ...(roles?.length ? { roles } : {}) }
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
