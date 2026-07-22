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

    // Explicit app-level fail-closed check (docs/design_notes.md §17): don't rely on
    // Power BI's own "requires effective identity" 400 as the only enforcement point.
    // Reject up front, before ever calling GenerateToken, if:
    //   (a) no user identity was supplied at all, or
    //   (b) a user was supplied but no entitlement/role resolves for them (unknown user).
    // This guarantees there is no code path that reaches PBI with an ambiguous/partial
    // identity that could fall back to an unfiltered SP-level view.
    if (!user) {
      return res.status(401).json({ error: 'A user identity is required (?user=<upn>).' });
    }

    let userIdentity;
    if (mode === 'static') {
      const roles = TEST_USER_ROLES[user]
        ?? (req.query.role ? String(req.query.role).split(',').map(r => r.trim()) : undefined);
      if (!roles?.length) {
        return res.status(403).json({ error: `No RLS role resolved for user '${user}'.` });
      }
      userIdentity = { username: user, roles };
    } else {
      const customData = req.query.customData ?? TEST_USER_ENTITLEMENTS[user];
      if (!customData) {
        return res.status(403).json({ error: `No entitlement resolved for user '${user}'.` });
      }
      userIdentity = { username: user, roles: [ENTITLEMENT_ROLE_NAME], customData };
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
