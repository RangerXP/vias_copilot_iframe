import { DefaultAzureCredential } from '@azure/identity';
import { executeDax, DAX_SHAPES, escapeHtml, describeContext } from './fabricAgent.js';

// ── LLM orchestrator (Azure OpenAI chat completions + function calling) ────
//
// This is the "put an LLM back in front of the RLS-safe query layer" architecture
// documented as the recommended alternative to the native Fabric Data Agent path
// (queryFabricAgent's USE_DATA_AGENT branch), which cannot enforce per-user RLS for
// this project's synthetic/non-Entra customer identities (see docs/design_notes.md
// Section 20). It mirrors how the removed Azure AI Foundry Agent worked — the LLM
// never touches the semantic model or the Fabric Data Agent directly, it only calls
// ONE tool (get_commercial_spend_data), which this file executes itself via the
// existing executeDax()/runXmlaQuery() path. effectiveUserName/rlsMode always come
// from the authenticated session (server/routes/chat.js), NEVER from the LLM's tool
// call arguments — the model only chooses WHICH data shape to fetch, not WHO it's
// fetching it for. This is a lighter-weight alternative to re-provisioning a full
// Azure AI Foundry Agent project (no Agents SDK, no separate thread/assistant
// resources, no extra data-plane RBAC beyond "Cognitive Services OpenAI User") while
// preserving the exact same RLS guarantee.

const AOAI_API_VERSION = process.env.AOAI_API_VERSION || '2024-10-21';
const MAX_TOOL_ITERATIONS = 3;

let _credential = null;
function getCredential() {
  if (!_credential) _credential = new DefaultAzureCredential();
  return _credential;
}

async function getAoaiToken() {
  const tokenResponse = await getCredential().getToken('https://cognitiveservices.azure.com/.default');
  if (!tokenResponse?.token) throw new Error('Failed to acquire Azure OpenAI access token');
  return tokenResponse.token;
}

const TOOL_DEFINITION = {
  type: 'function',
  function: {
    name: 'get_commercial_spend_data',
    description:
      'Fetch a named data shape from the Commercial Spend Analytics semantic model. ' +
      'Always call this exactly once per shape you need before answering — never guess ' +
      'or fabricate numbers. The data returned is already scoped to the current user\'s ' +
      'entitlement (row-level security); you do not need to (and cannot) specify a user.',
    parameters: {
      type: 'object',
      properties: {
        shape: {
          type: 'string',
          enum: Object.keys(DAX_SHAPES),
          description: Object.entries(DAX_SHAPES)
            .map(([key, { label }]) => `${key} = ${label}`)
            .join('; ')
        }
      },
      required: ['shape']
    }
  }
};

function buildSystemPrompt(contextNote) {
  return (
    'You are a concise analytics assistant for the VISA Commercial Spend Analytics ' +
    'Power BI report. Answer the user\'s question using ONLY data returned by the ' +
    'get_commercial_spend_data tool — call it as many times as needed (different ' +
    '"shape" values) to gather what you need, then write a short, business-toned ' +
    'natural-language answer. Cite concrete figures from the tool results. Do not ' +
    'invent data, and do not mention the tool, RLS, or internal implementation details.' +
    (contextNote ? ` The user is currently viewing: ${contextNote}.` : '')
  );
}

async function callChatCompletions(messages) {
  const endpoint = (process.env.AOAI_ENDPOINT || '').replace(/\/+$/, '');
  const deployment = process.env.AOAI_DEPLOYMENT;
  if (!endpoint) throw new Error('AOAI_ENDPOINT not set in .env (required when USE_LLM_ORCHESTRATOR=true)');
  if (!deployment) throw new Error('AOAI_DEPLOYMENT not set in .env (required when USE_LLM_ORCHESTRATOR=true)');

  const token = await getAoaiToken();
  const url = `${endpoint}/openai/deployments/${deployment}/chat/completions?api-version=${AOAI_API_VERSION}`;

  const res = await fetch(url, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({
      messages,
      tools: [TOOL_DEFINITION],
      tool_choice: 'auto'
    })
  });

  if (!res.ok) {
    const detail = await res.text().catch(() => '');
    throw new Error(`Azure OpenAI chat completions failed (${res.status}): ${detail}`);
  }
  return res.json();
}

/**
 * Answer a question by orchestrating an LLM (Azure OpenAI, function calling) whose only
 * tool is the existing RLS-aware DAX-shape catalog. effectiveUserName/rlsMode are bound
 * server-side and applied to every tool execution regardless of what the model requests.
 *
 * @param {{ question: string, context?: object, effectiveUserName?: string, rlsMode?: 'entitlement'|'static', conversationId?: string }} params
 * @returns {Promise<string>} HTML-safe answer paragraph
 */
export async function runOrchestratedQuery({ question, context, effectiveUserName, rlsMode }) {
  const contextNote = describeContext(context);
  const messages = [
    { role: 'system', content: buildSystemPrompt(contextNote) },
    { role: 'user', content: question }
  ];

  for (let iteration = 0; iteration < MAX_TOOL_ITERATIONS; iteration++) {
    const completion = await callChatCompletions(messages);
    const choice = completion.choices?.[0];
    const message = choice?.message;
    if (!message) throw new Error('Azure OpenAI returned no message');

    const toolCalls = message.tool_calls ?? [];
    if (!toolCalls.length) {
      const text = message.content ?? "I couldn't get an answer.";
      return `<p>${escapeHtml(text).replace(/\n/g, '<br>')}</p>`;
    }

    messages.push({ role: 'assistant', content: message.content ?? null, tool_calls: toolCalls });

    for (const toolCall of toolCalls) {
      let rows;
      try {
        const args = JSON.parse(toolCall.function.arguments || '{}');
        const shapeDef = DAX_SHAPES[args.shape];
        if (!shapeDef) throw new Error(`Unknown shape: ${args.shape}`);
        rows = await executeDax(shapeDef.dax, { effectiveUserName, rlsMode });
      } catch (err) {
        rows = { error: err.message };
      }
      messages.push({
        role: 'tool',
        tool_call_id: toolCall.id,
        content: JSON.stringify(rows)
      });
    }
  }

  throw new Error(`LLM orchestrator exceeded ${MAX_TOOL_ITERATIONS} tool-call iterations without a final answer`);
}
