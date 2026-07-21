import { AIProjectClient } from '@azure/ai-projects';
import { DefaultAzureCredential } from '@azure/identity';

let projectClient = null;

function getClient() {
  if (!projectClient) {
    if (!process.env.FOUNDRY_PROJECT_ENDPOINT) {
      throw new Error('FOUNDRY_PROJECT_ENDPOINT not set in .env (Sprint 4)');
    }
    projectClient = new AIProjectClient(
      process.env.FOUNDRY_PROJECT_ENDPOINT,
      new DefaultAzureCredential()
    );
  }
  return projectClient;
}

/**
 * Send a user turn (with injected report context) to the Foundry Agent and return the response.
 * Requires FOUNDRY_PROJECT_ENDPOINT and FOUNDRY_AGENT_ID in .env (Sprint 4).
 *
 * @param {{ userTurn: string }} params
 * @returns {Promise<string>} agent response text
 */
export async function sendToFoundryAgent({ userTurn }) {
  if (!process.env.FOUNDRY_AGENT_ID) {
    throw new Error('FOUNDRY_AGENT_ID not set in .env (Sprint 4)');
  }

  const client = getClient();
  const agents = client.agents;

  const thread = await agents.createThread();

  await agents.createMessage(thread.id, {
    role: 'user',
    content: userTurn
  });

  const run = await agents.createAndPollRun(thread.id, {
    assistantId: process.env.FOUNDRY_AGENT_ID
  });

  if (run.status !== 'completed') {
    throw new Error(`Foundry Agent run ended with status: ${run.status}`);
  }

  const messages = await agents.listMessages(thread.id);
  const assistantMsg = messages.data?.find((m) => m.role === 'assistant');
  const content = assistantMsg?.content?.[0];

  return content?.type === 'text' ? content.text.value : 'No response from agent.';
}
