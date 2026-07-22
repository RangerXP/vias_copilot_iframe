import express from 'express';
import { getEmbedToken } from '../services/pbiClient.js';
import { resolveEntitlement, ENTITLEMENT_ROLE_NAME } from '../services/rlsTestUsers.js';

const router = express.Router();

// Identity source: the authenticated session (docs/design_notes.md §17), NEVER a
// client-supplied query param or request body field. The frontend must call
// POST /api/session/login first (see server/routes/session.js) to establish
// req.session.customerId before requesting an embed token.
//
// RLS mechanism: entitlement-based dynamic RLS via CUSTOMDATA(). The session's
// customerId is resolved to an entitlement value (e.g. HomeRegion) and passed as
// effectiveIdentity.customData alongside roles: [Role_Entitlement] — the single
// dynamic TMDL role dim_client[HomeRegion] = CUSTOMDATA() enforces it.
router.get('/', async (req, res) => {
  try {
    const customerId = req.session.customerId;

    // Explicit app-level fail-closed check (docs/design_notes.md §17): don't rely on
    // Power BI's own "requires effective identity" 400 as the only enforcement point.
    // Reject up front, before ever calling GenerateToken, if:
    //   (a) there is no authenticated session at all, or
    //   (b) the session's customerId doesn't resolve to a known entitlement.
    // This guarantees there is no code path that reaches PBI with an ambiguous/partial
    // identity that could fall back to an unfiltered SP-level view.
    if (!customerId) {
      return res.status(401).json({ error: 'Not signed in. Call POST /api/session/login first.' });
    }

    const customData = resolveEntitlement(customerId);
    if (!customData) {
      return res.status(403).json({ error: `No entitlement resolved for customer '${customerId}'.` });
    }

    const userIdentity = { username: customerId, roles: [ENTITLEMENT_ROLE_NAME], customData };

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
