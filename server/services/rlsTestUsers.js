// RLS functional test matrix (docs/design_notes.md Section 15d/16) — synthetic
// test users, each mapped to an RLS identity defined in the semantic model
// (Commercial_Spend_Analytics.SemanticModel/definition/roles/*.tmdl).
//
// These are synthetic UPNs, not real Microsoft Entra ID accounts. That's fine for
// the embed-token GenerateToken/effectiveIdentity path (App-Owns-Data doesn't
// require real AAD accounts), but it means we CANNOT use XMLA's EffectiveUserName
// property for RLS enforcement here (EffectiveUserName requires a real Entra ID
// identity with Read+Build permission on the model).
//
// Two RLS mechanisms are available; entitlement-based CUSTOMDATA() is the DEFAULT
// as of Section 16 (see docs/design_notes.md), static Roles= is kept only for the
// side-by-side comparison in scripts/compare_rls_mechanisms.ps1 and as a fallback.
//
// --- Default mechanism: entitlement-based dynamic RLS via CUSTOMDATA() ---------
// A single dynamic TMDL role (Role_Entitlement: dim_client[HomeRegion] =
// CUSTOMDATA()) replaces the need for one static role per entitlement value. The
// entitlement VALUE (not a role name) is passed as:
//   - PBIE: effectiveIdentity.customData (GenerateToken identities[].customData)
//   - XMLA: the connection string's `CustomData` property (scripts/query_xmla.ps1
//     -CustomData) alongside `Roles=Role_Entitlement` (a workspace-Admin SP can
//     activate this role without being a member of it, same as static Roles=).
// Both surfaces evaluate CUSTOMDATA()/CustomData() identically — no AAD identity
// validation is performed on either side, unlike EffectiveUserName.
export const ENTITLEMENT_ROLE_NAME = 'Role_Entitlement';

export const TEST_USER_ENTITLEMENTS = {
  'regiona.test@visapoc.demo': 'North America',
  'regionb.test@visapoc.demo': 'Europe'
};

/**
 * Resolve a user identifier to its entitlement value (e.g. a HomeRegion string)
 * for CUSTOMDATA()-based dynamic RLS.
 * @param {string|undefined|null} user
 * @returns {string|undefined}
 */
export function resolveEntitlement(user) {
  if (!user) return undefined;
  return TEST_USER_ENTITLEMENTS[user];
}

// --- Legacy/comparison mechanism: static per-value Roles= override -------------
// Kept only so scripts/compare_rls_mechanisms.ps1 can validate that the new
// CUSTOMDATA()-based role produces identical row sets to the original static
// roles it replaces. Not used by the default runtime path anymore.
export const TEST_USER_ROLES = {
  'regiona.test@visapoc.demo': ['Role_RegionA'],
  'regionb.test@visapoc.demo': ['Role_RegionB']
};

/**
 * Resolve a user identifier to its mapped static RLS role names.
 * Falls back to an empty array (no role activated -> full/unfiltered access)
 * when the user isn't in the known test-user map.
 * @param {string|undefined|null} user
 * @returns {string[]}
 */
export function resolveRoles(user) {
  if (!user) return [];
  return TEST_USER_ROLES[user] ?? [];
}

// --- Server-managed session identity (docs/design_notes.md §17) ---------------
// Replaces the old unauthenticated `?user=`/body.user transport. The security
// boundary is the RESOLVED ENTITLEMENT VALUE, not any user identifier — a real
// deployment would populate this directory (or query a customer/entitlement
// service) after validating a portal session (e.g. MSAL.js + Entra ID), not
// trust a client-supplied identifier directly. The keys below (e.g.
// 'regiona.test@visapoc.demo') are treated as opaque customerId values resolved
// server-side from `req.session` — see server/routes/session.js — never read
// from client-supplied query params or request bodies.
export const CUSTOMER_DIRECTORY = {
  'regiona.test@visapoc.demo': { displayName: 'Contoso — North America', entitlement: 'North America' },
  'regionb.test@visapoc.demo': { displayName: 'Contoso — Europe', entitlement: 'Europe' }
};

/**
 * Resolve an authenticated session's customerId to its display name, for UI purposes only
 * (never used for authorization — that's `resolveEntitlement`/`resolveRoles` above).
 * @param {string|undefined|null} customerId
 * @returns {string|undefined}
 */
export function resolveCustomerDisplayName(customerId) {
  return CUSTOMER_DIRECTORY[customerId]?.displayName;
}

/**
 * True if customerId is a known, authenticatable customer (used by the login route
 * to validate the session-establishment request itself).
 * @param {string|undefined|null} customerId
 * @returns {boolean}
 */
export function isKnownCustomer(customerId) {
  return Boolean(customerId && CUSTOMER_DIRECTORY[customerId]);
}
