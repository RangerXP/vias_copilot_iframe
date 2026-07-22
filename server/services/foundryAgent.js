import { AIProjectClient } from '@azure/ai-projects';
import { DefaultAzureCredential } from '@azure/identity';
import { queryFabricAgent } from './fabricAgent.js';

// ---------------------------------------------------------------------------
// Client-side synthesizer — used when the agent echoes raw JSON tool output
// instead of interpreting it.  Handles the three DAX shapes returned by
// fabricAgent: summary (Metric/Value), trend (Year + metrics), segment.
// ---------------------------------------------------------------------------
function synthesizeToolResult(jsonStr) {
  let parsed;
  try { parsed = JSON.parse(jsonStr); } catch { return null; }
  const rows = parsed?.rows;
  if (!Array.isArray(rows) || !rows.length) return null;

  const fmt = (n) => {
    if (n === null || n === undefined) return 'N/A';
    if (typeof n === 'number') {
      if (n >= 1_000_000) return `$${(n / 1_000_000).toFixed(1)}M`;
      if (n >= 1_000) return n % 1 === 0 ? n.toLocaleString() : `$${n.toFixed(2)}`;
      return String(n);
    }
    return String(n);
  };

  const keys = Object.keys(rows[0]);

  // --- Summary shape: rows have "Metric" and "Value" columns ---
  if (keys.includes('Metric') && keys.includes('Value')) {
    const parts = rows.map(r => `${r.Metric}: ${r.Value}`).join(', ');
    return `Here are the key performance metrics for this portfolio — ${parts}.`;
  }

  // --- Trend shape: rows have "Year" (or similar) + numeric measures ---
  const yearKey = keys.find(k => /year/i.test(k));
  if (yearKey) {
    const metricKeys = keys.filter(k => k !== yearKey);
    const primary = metricKeys.find(k => /spend/i.test(k)) ?? metricKeys[0];
    const lines = rows.map(r => `${r[yearKey]}: ${fmt(r[primary])}`).join(', ');
    const vals = rows.map(r => r[primary]).filter(v => typeof v === 'number');
    let trend = '';
    if (vals.length >= 2) {
      const pct = ((vals[vals.length - 1] - vals[0]) / Math.abs(vals[0]) * 100).toFixed(1);
      trend = ` Overall ${parseFloat(pct) >= 0 ? 'growth' : 'decline'} from ${rows[0][yearKey]} to ${rows[rows.length - 1][yearKey]}: ${pct}%.`;
    }
    return `${primary} by year — ${lines}.${trend}`;
  }

  // --- Segment shape: first column is category, rest are metrics ---
  const catKey = keys[0];
  const metricKey = keys.find(k => /spend/i.test(k)) ?? keys[1];
  const lines = rows.slice(0, 5).map(r => `${r[catKey]}: ${fmt(r[metricKey])}`).join(', ');
  return `${metricKey} by ${catKey} — ${lines}${rows.length > 5 ? `, and ${rows.length - 5} more segments` : ''}.`;
}

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
      context: args.context ?? null,
      daxQuery: args.daxQuery ?? null
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

  // @azure/ai-projects v1.0.1 — sub-client API with positional arguments
  const agents = getClient().agents;
  const thread = await agents.threads.create();

  // messages.create(threadId, role, content)
  await agents.messages.create(thread.id, 'user', userTurn);

  // runs.create(threadId, assistantId)
  let run = await agents.runs.create(thread.id, process.env.FOUNDRY_AGENT_ID);

  const deadline = Date.now() + POLL_TIMEOUT_MS;

  while (run.status === 'queued' || run.status === 'in_progress' || run.status === 'requires_action') {
    if (Date.now() > deadline) {
      throw new Error('Foundry Agent run timed out after 120s');
    }

    await new Promise((resolve) => setTimeout(resolve, POLL_INTERVAL_MS));

    if (run.status === 'requires_action') {
      const toolCalls = run.requiredAction?.submitToolOutputs?.toolCalls ?? [];
      console.log(`[foundryAgent] requires_action: ${toolCalls.length} tool call(s)`);

      const toolOutputs = await Promise.all(
        toolCalls.map(async (tc) => {
          const output = await dispatchToolCall(tc, userTurn);
          console.log(`[foundryAgent] tool ${tc.function?.name} → output[:80]: ${output.slice(0,80)}`);
          return { toolCallId: tc.id, output };
        })
      );

      run = await agents.runs.submitToolOutputs(thread.id, run.id, toolOutputs);
      console.log(`[foundryAgent] after submitToolOutputs: status=${run.status}`);
    } else {
      run = await agents.runs.get(thread.id, run.id);
      console.log(`[foundryAgent] poll: status=${run.status}`);
    }
  }

  if (run.status !== 'completed') {
    const errDetail = run.lastError ? ` — ${run.lastError.code}: ${run.lastError.message}` : '';
    throw new Error(`Foundry Agent run ended with status: ${run.status}${errDetail}`);
  }

  // messages.list returns an async iterable — collect newest-first
  const allMessages = [];
  for await (const msg of agents.messages.list(thread.id)) {
    allMessages.push(msg);
  }

  // Find the last assistant message that has text content
  const assistantMsgs = allMessages.filter(
    (m) => m.role === 'assistant' && m.content?.some((c) => c.type === 'text' && c.text?.value?.trim())
  );
  // messages are returned newest-first by the API
  const finalMsg = assistantMsgs[0];
  const rawText = finalMsg?.content?.find((c) => c.type === 'text')?.text?.value ?? '';

  // If the agent echoed raw tool JSON instead of synthesizing, do it client-side.
  const isEcho = rawText.includes('"Power BI semantic model"') || /"rows"\s*:/.test(rawText);
  if (isEcho) {
    const jsonStart = rawText.indexOf('{');
    const jsonEnd = rawText.lastIndexOf('}');
    if (jsonStart !== -1 && jsonEnd !== -1) {
      const synthesized = synthesizeToolResult(rawText.slice(jsonStart, jsonEnd + 1));
      if (synthesized) return synthesized;
    }
  }

  return rawText || 'No response from agent.';
}
