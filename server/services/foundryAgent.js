import { AIProjectClient } from '@azure/ai-projects';
import { DefaultAzureCredential } from '@azure/identity';
import { queryFabricAgent } from './fabricAgent.js';

const POLL_INTERVAL_MS = 800;
const POLL_TIMEOUT_MS = 120_000;

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
 * Dispatch a Foundry Agent tool call to the appropriate backend service.
 * Currently handles: query_semantic_model → fabricAgent.js
 */
async function dispatchToolCall(toolCall, fallbackQuestion) {
  if (toolCall.function?.name !== 'query_semantic_model') {
    return `Tool '${toolCall.function?.name}' is not implemented.`;
  }

  let args = {};
  try {
    args = JSON.parse(toolCall.function.arguments ?? '{}');
  } catch {
    // malformed args — use fallback question
  }

  try {
    return await queryFabricAgent({
      question: args.question ?? fallbackQuestion,
      context: args.context ?? null
    });
  } catch (err) {
    return `Fabric Data Agent error: ${err.message}`;
  }
}

/**
 * Send a user turn (with injected report context) to the Foundry Agent and return the response.
 * Handles query_semantic_model tool calls by routing to the Fabric Data Agent.
 *
 * Requires FOUNDRY_PROJECT_ENDPOINT and FOUNDRY_AGENT_ID in .env (Sprint 4).
 *
 * @param {{ userTurn: string }} params
 * @returns {Promise<string>} agent response text
 */
export async function sendToFoundryAgent({ userTurn }) {
  if (!process.env.FOUNDRY_AGENT_ID) {
    throw new Error('FOUNDRY_AGENT_ID not set in .env (Sprint 4)');
  }

  const agents = getClient().agents;
  const thread = await agents.createThread();

  await agents.createMessage(thread.id, {
    role: 'user',
    content: userTurn
  });

  let run = await agents.createRun(thread.id, {
    assistantId: process.env.FOUNDRY_AGENT_ID
  });

  const deadline = Date.now() + POLL_TIMEOUT_MS;

  while (run.status === 'queued' || run.status === 'in_progress' || run.status === 'requires_action') {
    if (Date.now() > deadline) {
      throw new Error('Foundry Agent run timed out after 120s');
    }

    await new Promise((resolve) => setTimeout(resolve, POLL_INTERVAL_MS));

    if (run.status === 'requires_action') {
      const toolCalls = run.requiredAction?.submitToolOutputs?.toolCalls ?? [];

      const toolOutputs = await Promise.all(
        toolCalls.map(async (tc) => ({
          toolCallId: tc.id,
          output: await dispatchToolCall(tc, userTurn)
        }))
      );

      run = await agents.submitToolOutputsToRun(thread.id, run.id, { toolOutputs });
    } else {
      run = await agents.getRun(thread.id, run.id);
    }
  }

  if (run.status !== 'completed') {
    throw new Error(`Foundry Agent run ended with status: ${run.status}`);
  }

  const messages = await agents.listMessages(thread.id);
  const assistantMsg = messages.data?.find((m) => m.role === 'assistant');
  const content = assistantMsg?.content?.[0];

  return content?.type === 'text' ? content.text.value : 'No response from agent.';
}
