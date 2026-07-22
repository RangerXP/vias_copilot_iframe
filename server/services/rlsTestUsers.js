// RLS functional test matrix (docs/design_notes.md Section 15d) — synthetic test
// users, each mapped to exactly one RLS role defined in the semantic model
// (Commercial_Spend_Analytics.SemanticModel/definition/roles/*.tmdl).
//
// These are synthetic UPNs, not real Microsoft Entra ID accounts. That's fine for
// the embed-token GenerateToken/effectiveIdentity path (App-Owns-Data doesn't
// require real AAD accounts), but it means we CANNOT use XMLA's EffectiveUserName
// property for RLS enforcement here (EffectiveUserName requires a real Entra ID
// identity with Read+Build permission on the model). Instead, the XMLA query path
// activates the mapped role directly via the connection string's `Roles` property
// (scripts/query_xmla.ps1) — the same "test as role" mechanism used for validating
// RLS role definitions, which our workspace-Admin service principal is allowed to
// invoke without needing role membership itself.
export const TEST_USER_ROLES = {
  'regiona.test@visapoc.demo': ['Role_RegionA'],
  'regionb.test@visapoc.demo': ['Role_RegionB']
};

/**
 * Resolve a user identifier to its mapped RLS role names.
 * Falls back to an empty array (no role activated -> full/unfiltered access)
 * when the user isn't in the known test-user map.
 * @param {string|undefined|null} user
 * @returns {string[]}
 */
export function resolveRoles(user) {
  if (!user) return [];
  return TEST_USER_ROLES[user] ?? [];
}
