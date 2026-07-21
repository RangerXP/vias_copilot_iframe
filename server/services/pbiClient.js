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
 * @param {{ workspaceId: string, reportId: string, datasetId: string, userIdentity?: { username: string, roles?: string[] } }} params
 *   userIdentity — when provided, embeds an effectiveIdentity so RLS is enforced for that user.
 *                  username should be the user's UPN (e.g. user@contoso.com).
 *                  roles is optional; required only if the model has RLS roles defined.
 *
 * Returns { accessToken, tokenId, expiration, embedUrl, reportId }
 */
export async function getEmbedToken({ workspaceId, reportId, datasetId, userIdentity }) {
  const accessToken = await getPbiAccessToken();

  const url = `https://api.powerbi.com/v1.0/myorg/groups/${workspaceId}/reports/${reportId}/GenerateToken`;

  // Build request body — include effectiveIdentity when a user identity is supplied.
  // This enforces RLS on the semantic model for external/guest users.
  const body = { accessLevel: 'View', datasetId };

  if (userIdentity?.username) {
    body.identities = [
      {
        username: userIdentity.username,
        datasets: [datasetId],
        ...(userIdentity.roles?.length ? { roles: userIdentity.roles } : {})
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
