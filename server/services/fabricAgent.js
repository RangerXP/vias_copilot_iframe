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

async function getFabricAccessToken() {
  const result = await getMsalClient().acquireTokenByClientCredential({
    scopes: ['https://api.fabric.microsoft.com/.default']
  });
  if (!result?.accessToken) throw new Error('Failed to acquire Fabric access token');
  return result.accessToken;
}

/**
 * Send a natural language question to the Fabric Data Agent with optional report context.
 * Requires FABRIC_AGENT_ENDPOINT and FABRIC_AGENT_ID in .env (Sprint 3).
 *
 * @param {{ question: string, context?: object }} params
 * @returns {Promise<string>} agent answer text
 */
export async function queryFabricAgent({ question, context }) {
  if (!process.env.FABRIC_AGENT_ENDPOINT || !process.env.FABRIC_AGENT_ID) {
    throw new Error(
      'Fabric Data Agent not configured — set FABRIC_AGENT_ENDPOINT and FABRIC_AGENT_ID in .env (Sprint 3)'
    );
  }

  const accessToken = await getFabricAccessToken();

  const contextStr = context
    ? Object.entries(context).map(([k, v]) => `${k}: ${v}`).join('; ')
    : '';

  const fullQuestion = contextStr ? `${question} (Context: ${contextStr})` : question;

  const url = `https://api.fabric.microsoft.com/v1/workspaces/${process.env.WORKSPACE_ID}/dataagentruns`;

  const response = await fetch(url, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${accessToken}`,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({
      agentId: process.env.FABRIC_AGENT_ID,
      question: fullQuestion
    })
  });

  if (!response.ok) {
    const detail = await response.text();
    throw new Error(`Fabric Data Agent query failed (${response.status}): ${detail}`);
  }

  const data = await response.json();
  return data.answer ?? data.result ?? JSON.stringify(data);
}
