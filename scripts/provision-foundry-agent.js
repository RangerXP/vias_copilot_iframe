#!/usr/bin/env node
/**
 * provision-foundry-agent.js
 *
 * Creates the Azure AI Foundry Agent with the Pattern 1 system prompt
 * and the query_semantic_model tool definition.
 *
 * Prerequisites:
 *   - FOUNDRY_PROJECT_ENDPOINT set in .env (or as an environment variable)
 *   - Azure CLI logged in (`az login`) OR service principal env vars set:
 *       AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, AZURE_TENANT_ID
 *
 * Usage:
 *   node scripts/provision-foundry-agent.js
 *
 * On success, prints the FOUNDRY_AGENT_ID to add to .env.
 */

import { AIProjectClient } from '@azure/ai-projects';
import { DefaultAzureCredential } from '@azure/identity';
import dotenv from 'dotenv';

dotenv.config();

// ── System prompt ─────────────────────────────────────────────────────────────

const SYSTEM_PROMPT = `You are an embedded analytics assistant integrated into a Power BI Embedded portal for VISA commercial payment data analysis.

You have access to a semantic model query tool. Always use the tool for any data question.
Never answer data questions from memory or general knowledge.

IMPORTANT — after the tool returns data, you MUST synthesize it into a clear, concise natural language answer.
Do NOT repeat the raw tool output. Interpret the numbers and explain what they mean for the business.
Format currency values with $ and commas. Format percentages with one decimal place.
Keep answers to 2-4 sentences unless the user asks for detail.

When a user asks a question, you may also receive the current state of the embedded report:
- Active page
- Active filters
- Active slicers

Interpret the report state as the user's current data context.
Respond in plain, business-friendly language appropriate for an analytics portal user.
If the user asks to "explain this chart" or "summarize this view", use the context to
understand which page and filter combination is visible, then query accordingly.

Do not speculate about data values. If the semantic model query returns no data, say so clearly.`;

// ── Tool definition ───────────────────────────────────────────────────────────

const QUERY_TOOL = {
  type: 'function',
  function: {
    name: 'query_semantic_model',
    description:
      'Executes a natural language query against the Power BI semantic model (Visa Slicer Demo v2) via the Fabric Data Agent. Use this for all data retrieval — metrics, rankings, trends, comparisons, summaries.',
    parameters: {
      type: 'object',
      properties: {
        question: {
          type: 'string',
          description:
            'The data question to answer. Be specific and include relevant filter context from the report.'
        },
        context: {
          type: 'object',
          description:
            "Key-value pairs of active report filters and slicers that scope the query (e.g. { \"Merchant\": \"Costco\", \"Region\": \"North America\" })"
        }
      },
      required: ['question']
    }
  }
};

// ── Main ──────────────────────────────────────────────────────────────────────

async function main() {
  if (!process.env.FOUNDRY_PROJECT_ENDPOINT) {
    console.error('ERROR: FOUNDRY_PROJECT_ENDPOINT is not set.');
    console.error('Add it to .env or set it as an environment variable.');
    process.exit(1);
  }

  console.log('Foundry project endpoint:', process.env.FOUNDRY_PROJECT_ENDPOINT);
  console.log('Connecting...\n');

  const client = new AIProjectClient(
    process.env.FOUNDRY_PROJECT_ENDPOINT,
    new DefaultAzureCredential()
  );

  const agent = await client.agents.createAgent('gpt-5.1', {
    name: 'pbie-context-agent',
    instructions: SYSTEM_PROMPT,
    tools: [QUERY_TOOL]
  });

  console.log('Agent created successfully.');
  console.log('  Agent ID :', agent.id);
  console.log('  Name     :', agent.name);
  console.log('  Model    :', agent.model);
  console.log('\nAdd the following to your .env file:');
  console.log(`\nFOUNDRY_AGENT_ID=${agent.id}\n`);
}

main().catch((err) => {
  console.error('Provisioning failed:', err.message);
  process.exit(1);
});
