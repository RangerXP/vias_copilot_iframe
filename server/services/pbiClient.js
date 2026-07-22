import { ConfidentialClientApplication } from '@azure/msal-node';

let msalClient = null;

function getMsalClient() {
  if (!msalClient) {
    msalClient = new ConfidentialClientApplication({
      auth: {
        clientId: process.env.CLIENT_ID,
        clientSecret: process.env.CLIENT_SECRET,
        authority: `https://login.microsoftonline.com/${process.env.TENANT_ID}`
      }
    });
  }
  return msalClient;
}

async function getPbiAccessToken() {
  const result = await getMsalClient().acquireTokenByClientCredential({
    scopes: ['https://analysis.windows.net/powerbi/api/.default']
  });
  if (!result?.accessToken) throw new Error('Failed to acquire Power BI access token');
  return result.accessToken;
}

/**
 * Generate a PBIE embed token for App-Owns-Data embedding.
 *
 * Uses the multi-resource GenerateToken endpoint (confirmed working with VISA-PBIE-EmbedService SP).
 * The per-report endpoint (/groups/{id}/reports/{id}/GenerateToken) uses a different body shape
 * and was not validated against this SP — do not revert to it.
 *
 * @param {{ workspaceId: string, reportId: string, datasetId: string, userIdentity?: { username: string, roles?: string[], customData?: string } }} params
 *   userIdentity — when provided, embeds an effectiveIdentity so RLS is enforced for that user.
 *                  username should be the user's UPN (e.g. user@contoso.com).
 *                  roles is optional; only needed when a static Roles-based RLS role should be activated.
 *                  customData carries an entitlement value for CUSTOMDATA()-based dynamic RLS
 *                  (see docs/design_notes.md Section 16) — retrieved server-side via CUSTOMDATA()
 *                  in the model's Role_Entitlement TMDL role, the same mechanism XMLA's `CustomData`
 *                  connection-string property feeds into CUSTOMDATA()/CustomData().
 *
 * Returns { accessToken, tokenId, expiration, embedUrl, reportId }
 */
export async function getEmbedToken({ workspaceId, reportId, datasetId, userIdentity }) {
  const accessToken = await getPbiAccessToken();

  // Multi-resource GenerateToken endpoint — confirmed working 2026-07-21 with SP Admin workspace role.
  const url = 'https://api.powerbi.com/v1.0/myorg/GenerateToken';

  // Build request body using the multi-resource form.
  // identities[] enforces RLS effectiveIdentity when a user UPN is supplied by the frontend.
  // This is the security boundary for external/guest users — the SP generates the token but
  // the Power BI engine scopes data access to what the named user is allowed to see.
  const body = {
    reports: [{ id: reportId }],
    datasets: [{ id: datasetId }],
    targetWorkspaces: [{ id: workspaceId }]
  };

  if (userIdentity?.username) {
    body.identities = [
      {
        username: userIdentity.username,
        datasets: [datasetId],
        ...(userIdentity.roles?.length ? { roles: userIdentity.roles } : {}),
        ...(userIdentity.customData ? { customData: userIdentity.customData } : {})
      }
    ];
  }

  const response = await fetch(url, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${accessToken}`,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify(body)
  });

  if (!response.ok) {
    const detail = await response.text();
    throw new Error(`GenerateToken failed (${response.status}): ${detail}`);
  }

  const data = await response.json();

  return {
    accessToken: data.token,
    tokenId: data.tokenId,
    expiration: data.expiration,
    embedUrl: `https://app.powerbi.com/reportEmbed?reportId=${reportId}&groupId=${workspaceId}`,
    reportId
  };
}
