# Fabric Data Agent Configuration

## Purpose

This document covers how to configure the **Fabric Data Agent** as the semantic model query tool for the Pattern 1 Context Injection Agent.

---

## Role of the Fabric Data Agent

In Pattern 1, the Fabric Data Agent sits between the **Foundry Agent** and the **Fabric Semantic Model**:

```
Foundry Agent
    │
    │  tool call: query_semantic_model(question, context)
    ▼
Fabric Data Agent  ←── Natural language → DAX
    │
    ▼
Fabric Semantic Model  ←── Executes DAX
    │
    ▼
Results → Foundry Agent → Natural language response
```

The Fabric Data Agent eliminates the need for the Foundry Agent to generate raw DAX — it translates natural language questions (augmented with filter context) into governed model queries.

---

## Provisioning the Fabric Data Agent

### In Fabric Portal

1. Navigate to your target Fabric workspace
2. Click **New item**
3. Select **Data agent** (may appear as "AI skill" depending on tenant)
4. Choose data source type: **Semantic model (Power BI)**
5. Select your target semantic model
6. Configure agent settings (see below)
7. Publish the agent

### Agent Configuration Settings

| Setting | Recommended Value |
|---------|------------------|
| Agent name | `<ModelName>-data-agent` |
| Description | "Semantic model query agent for PBIE context injection" |
| Data source | Target Fabric semantic model |
| Language | English |
| Response format | Structured (JSON preferred for tool integration) |

---

## Adding Model Context to the Agent

The Fabric Data Agent uses instructions and table/measure descriptions to improve query accuracy.

### Recommended Instructions

```
This agent answers questions about payment processing analytics.
It has access to transaction, merchant, and approval rate data.

When answering:
- Always filter by any merchant, region, or date context provided
- Return numeric values with appropriate units (%, $, count)
- If a field name is ambiguous, prefer the measure over the column
- Do not generate historical comparisons unless date context is provided
```

### Table Descriptions (add per table in model)

Navigate to each table in the agent editor and add descriptions:

| Table | Description to Add |
|-------|-------------------|
| `Transactions` | Individual payment transaction records with approval/decline status |
| `Merchants` | Merchant master data including risk classification |
| `DateTable` | Date dimension — use for all time-based filtering |
| `Geography` | Region and country hierarchy |

### Measure Annotations (add per measure)

For key measures, add plain-English descriptions:

| Measure | Description |
|---------|-----------|
| `Approval Rate` | Percentage of transactions approved (Approved / Total) |
| `Decline Rate` | Percentage of transactions declined |
| `Transaction Count` | Total number of transactions |
| `Risk Score Avg` | Average merchant risk score |

---

## Backend Integration — `server/services/fabricAgent.js`

```javascript
import fetch from 'node-fetch';

const FABRIC_AGENT_ENDPOINT = process.env.FABRIC_AGENT_ENDPOINT;
const FABRIC_AGENT_ID = process.env.FABRIC_AGENT_ID;

async function getFabricToken() {
  // Use Entra ID client credentials flow
  const tokenUrl = `https://login.microsoftonline.com/${process.env.TENANT_ID}/oauth2/v2.0/token`;
  const body = new URLSearchParams({
    grant_type: 'client_credentials',
    client_id: process.env.CLIENT_ID,
    client_secret: process.env.CLIENT_SECRET,
    scope: 'https://api.fabric.microsoft.com/.default'
  });

  const res = await fetch(tokenUrl, { method: 'POST', body });
  const data = await res.json();
  return data.access_token;
}

export async function queryFabricAgent(question, context = {}) {
  const token = await getFabricToken();

  // Build context-aware question
  const contextLines = Object.entries(context)
    .map(([k, v]) => `${k}: ${v}`)
    .join(', ');

  const enrichedQuestion = contextLines
    ? `${question} (Context: ${contextLines})`
    : question;

  const res = await fetch(`${FABRIC_AGENT_ENDPOINT}/agents/${FABRIC_AGENT_ID}/query`, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${token}`,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({ query: enrichedQuestion })
  });

  if (!res.ok) {
    const err = await res.text();
    throw new Error(`Fabric Data Agent query failed: ${res.status} ${err}`);
  }

  const result = await res.json();
  return result.answer || result.response || JSON.stringify(result);
}
```

---

## Foundry Agent Tool Wiring — `server/services/foundryAgent.js`

```javascript
import { AIProjectClient } from '@azure/ai-projects';
import { DefaultAzureCredential } from '@azure/identity';
import { queryFabricAgent } from './fabricAgent.js';

const client = new AIProjectClient(
  process.env.FOUNDRY_PROJECT_ENDPOINT,
  new DefaultAzureCredential()
);

export async function sendToFoundryAgent(question, businessContext) {
  const agentId = process.env.FOUNDRY_AGENT_ID;
  const contextBlock = buildContextBlock(businessContext);

  const userMessage = `[Report Context]\n${contextBlock}\n\n[User Question]\n${question}`;

  // Create a thread and send the message
  const thread = await client.agents.threads.create();
  await client.agents.messages.create(thread.id, 'user', userMessage);

  // Run the agent
  const run = await client.agents.runs.createAndPoll(thread.id, {
    assistantId: agentId
  });

  // Handle tool calls (Fabric Data Agent)
  if (run.status === 'requires_action') {
    const toolOutputs = [];

    for (const toolCall of run.requiredAction?.submitToolOutputs?.toolCalls || []) {
      if (toolCall.function.name === 'query_semantic_model') {
        const args = JSON.parse(toolCall.function.arguments);
        const answer = await queryFabricAgent(args.question, args.context || businessContext);
        toolOutputs.push({ tool_call_id: toolCall.id, output: answer });
      }
    }

    await client.agents.runs.submitToolOutputsAndPoll(thread.id, run.id, toolOutputs);
  }

  // Get final response
  const messages = await client.agents.messages.list(thread.id);
  const assistantMsg = messages.data.find(m => m.role === 'assistant');
  return assistantMsg?.content?.[0]?.text?.value || 'No response generated.';
}

function buildContextBlock(ctx) {
  const lines = [];
  if (ctx.page) lines.push(`Page: ${ctx.page}`);
  for (const [k, v] of Object.entries(ctx.slicers || {})) lines.push(`${k}: ${v}`);
  for (const [k, v] of Object.entries(ctx.filters || {})) {
    lines.push(`${k}: ${Array.isArray(v) ? v.join(', ') : v}`);
  }
  return lines.join('\n') || '(No active filters)';
}
```

---

## Fabric Data Agent Endpoint Discovery

Once provisioned, the Fabric Data Agent endpoint can be found:

1. In the Fabric portal, open the Data Agent item
2. Click **Settings** or **Details**
3. Copy the **API endpoint URL** — format: `https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/dataagentruns`

Alternative: use the Fabric REST API to list agents in the workspace:

```bash
TOKEN=$(az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv)

curl -H "Authorization: Bearer $TOKEN" \
  "https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/items?type=AISkill"
```

---

## Testing the Integration

### Direct test (before wiring Foundry)

```bash
curl -X POST http://localhost:3000/api/fabric-query \
  -H "Content-Type: application/json" \
  -d '{
    "question": "What is the approval rate for Costco?",
    "context": { "Merchant": "Costco", "Region": "North America" }
  }'
```

Expected: a numeric answer referencing the semantic model's approval rate measure.

### End-to-end test (Pattern 1)

```bash
curl -X POST http://localhost:3000/api/chat \
  -H "Content-Type: application/json" \
  -d '{
    "question": "Why are declines increasing?",
    "rawContext": {
      "page": { "displayName": "Customer Risk" },
      "slicers": [{ "visual": "Merchant", "field": "MerchantName", "selected": ["Costco"] }],
      "filters": []
    }
  }'
```

Expected: a natural language explanation grounded in Costco decline trend data from the semantic model.

---

## Required Configuration Values

| Config Key | Where to Get |
|-----------|-------------|
| `FABRIC_AGENT_ENDPOINT` | Fabric portal → Data Agent → Settings |
| `FABRIC_AGENT_ID` | Fabric portal → Data Agent → item ID in URL |
| `TENANT_ID` | Azure portal → Entra ID → Overview |
| `CLIENT_ID` | Azure portal → Entra ID → App registrations → your SP |
| `CLIENT_SECRET` | Azure portal → your SP → Certificates & secrets |
