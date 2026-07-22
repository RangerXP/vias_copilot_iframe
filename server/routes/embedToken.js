import express from 'express';
import { getEmbedToken } from '../services/pbiClient.js';
import { TEST_USER_ROLES, TEST_USER_ENTITLEMENTS, ENTITLEMENT_ROLE_NAME } from '../services/rlsTestUsers.js';

const router = express.Router();

// Accept optional user identity for RLS enforcement.
// External/guest users should pass their UPN via query param: /api/embed-token?user=alice@contoso.com
// In production this should come from a validated session/token, not an open query param.
//
// Default RLS mechanism (docs/design_notes.md Section 16): entitlement-based dynamic RLS via
// CUSTOMDATA(). The user's entitlement value (e.g. HomeRegion) is resolved and passed as
// effectiveIdentity.customData alongside roles: [Role_Entitlement] — the single dynamic TMDL
// role dim_client[HomeRegion] = CUSTOMDATA() enforces it. Pass ?customData=<value> to override
// the resolved entitlement for ad-hoc testing.
//
// Legacy/comparison mechanism: pass ?mode=static to fall back to the original static
// Role_RegionA/Role_RegionB Roles= mapping (kept only for the RLS-mechanism comparison in
// scripts/compare_rls_mechanisms.ps1 and docs/design_notes.md Section 16).
router.get('/', async (req, res) => {
  try {
    const user = req.query.user;
    const mode = req.query.mode === 'static' ? 'static' : 'entitlement';

    let userIdentity;
    if (user && mode === 'static') {
      const roles = TEST_USER_ROLES[user]
        ?? (req.query.role ? String(req.query.role).split(',').map(r => r.trim()) : undefined);
      userIdentity = { username: user, ...(roles?.length ? { roles } : {}) };
    } else if (user) {
      const customData = req.query.customData ?? TEST_USER_ENTITLEMENTS[user];
      userIdentity = {
        username: user,
        ...(customData ? { roles: [ENTITLEMENT_ROLE_NAME], customData } : {})
      };
    }

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
