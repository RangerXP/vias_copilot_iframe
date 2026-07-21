# Pattern 1 — Iframe Context Injection: Implementation Spec

## What This Document Covers

This is the detailed implementation specification for **Pattern 1 — Context Injection Agent** from the VISA PBI Embedded build guide.

It covers:
- Context capture from the PBIE iframe
- Context normalization (PBIE → business terms)
- Prompt construction with injected context
- Foundry Agent tool call flow through Fabric Data Agent

---

## Context Object Specification

### Raw PBIE Context (from `captureContext.js`)

```json
{
  "reportId": "string",
  "reportName": "string",
  "page": {
    "name": "string (internal)",
    "displayName": "string (human readable)"
  },
  "filters": [
    {
      "table": "string",
      "column": "string",
      "operator": "string",
      "values": ["string"]
    }
  ],
  "slicers": [
    {
      "visual": "string (visual title)",
      "field": "string (table/column)",
      "selected": ["string"]
    }
  ],
  "visualSelections": [
    {
      "visual": "string",
      "dataPoints": [{ "field": "string", "value": "string" }]
    }
  ]
}
```

### Normalized Business Context (from `contextService.js`)

```json
{
  "page": "string (display name)",
  "filters": {
    "FieldName": "value"
  },
  "slicers": {
    "FieldName": "value"
  },
  "visualSelections": {
    "FieldName": "value"
  }
}
```

---

## Context Capture Implementation — `captureContext.js`

```javascript
export async function captureContext(report) {
  if (!report) return null;

  const [pages, filters] = await Promise.all([
    report.getPages(),
    report.getFilters()
  ]);

  const activePage = pages.find(p => p.isActive) || pages[0];
  const visuals = await activePage.getVisuals();

  // Collect slicer states in parallel
  const slicerData = await Promise.all(
    visuals
      .filter(v => v.type === 'slicer')
      .map(async (v) => {
        try {
          const state = await v.getSlicerState();
          return { visual: v.title, state };
        } catch {
          return null;
        }
      })
  );

  return {
    reportId: report.config?.id,
    reportName: report.config?.embedUrl,
    page: {
      name: activePage.name,
      displayName: activePage.displayName
    },
    filters: filters.map(normalizeFilter),
    slicers: slicerData.filter(Boolean).map(normalizeSlicerState),
    visualSelections: [] // Sprint 5: extend to visual cross-filter selections
  };
}

function normalizeFilter(filter) {
  return {
    table: filter.target?.table,
    column: filter.target?.column,
    operator: filter.operator,
    values: filter.values || []
  };
}

function normalizeSlicerState(item) {
  return {
    visual: item.visual,
    field: item.state?.targets?.[0]?.column,
    selected: item.state?.filters?.[0]?.values || []
  };
}
```

---

## Context Service — Field Name Translation

### `semantic/metadata/field_map.json`

```json
{
  "merchant_id": "Merchant",
  "merchant_name": "Merchant",
  "MerchantName": "Merchant",
  "region_code": "Region",
  "RegionName": "Region",
  "approval_rate": "Approval Rate",
  "ApprovalRate": "Approval Rate",
  "decline_rate": "Decline Rate",
  "TransactionDate": "Transaction Date",
  "txn_date": "Transaction Date",
  "risk_score": "Risk Score",
  "RiskScore": "Risk Score",
  "CardProduct": "Card Product",
  "IssuerCountry": "Issuer Country"
}
```

> Update this file with actual column names discovered from the target Fabric semantic model. See [fabric_model_discovery.md](fabric_model_discovery.md).

### `server/services/contextService.js`

```javascript
import fieldMap from '../../semantic/metadata/field_map.json' assert { type: 'json' };

export function normalizeContext(rawContext) {
  const translate = (name) => fieldMap[name] || name;

  const businessContext = {
    page: rawContext.page?.displayName || rawContext.page?.name,
    filters: {},
    slicers: {},
    selections: {}
  };

  for (const filter of rawContext.filters || []) {
    const key = translate(filter.column);
    businessContext.filters[key] = filter.values;
  }

  for (const slicer of rawContext.slicers || []) {
    const key = translate(slicer.field);
    if (slicer.selected.length > 0) {
      businessContext.slicers[key] = slicer.selected.join(', ');
    }
  }

  return businessContext;
}

export function buildContextBlock(businessContext) {
  const lines = [];
  lines.push(`Page: ${businessContext.page}`);

  for (const [k, v] of Object.entries(businessContext.slicers)) {
    lines.push(`${k}: ${v}`);
  }
  for (const [k, v] of Object.entries(businessContext.filters)) {
    lines.push(`${k}: ${Array.isArray(v) ? v.join(', ') : v}`);
  }

  return lines.join('\n');
}
```

---

## Foundry Agent Prompt Template

### System Prompt

```
You are an embedded analytics assistant integrated into a Power BI Embedded portal.

You have access to a semantic model query tool. Always use the tool for any data question.
Never answer data questions from memory or general knowledge.

When a user asks a question, you will receive the current state of the embedded report:
- Active page
- Active filters
- Active slicers

Interpret the report state as the user's current data context.
Respond in plain, business-friendly language appropriate for an analytics portal user.
If the user asks to "explain this chart" or "summarize this view", use the context to 
understand which page and filter combination is visible, then query accordingly.
```

### User Turn Structure

```
[Report Context]
Page: {{page}}
{{context_lines}}

[User Question]
{{question}}
```

---

## Foundry Agent Tool Definition

```json
{
  "name": "query_semantic_model",
  "description": "Executes a natural language or DAX query against the connected Power BI semantic model via the Fabric Data Agent. Use for all data retrieval — metrics, rankings, trends, comparisons.",
  "parameters": {
    "type": "object",
    "properties": {
      "question": {
        "type": "string",
        "description": "The data question to answer. Include relevant context from the report state."
      },
      "context": {
        "type": "object",
        "description": "Key-value pairs of active filters and slicers from the report (e.g. { 'Merchant': 'Costco', 'Region': 'North America' })"
      }
    },
    "required": ["question"]
  }
}
```

---

## End-to-End Request Flow

### POST `/api/chat`

**Request body:**
```json
{
  "question": "Why are declines increasing?",
  "rawContext": {
    "page": { "name": "ReportSection1", "displayName": "Customer Risk" },
    "slicers": [{ "visual": "Merchant", "field": "MerchantName", "selected": ["Costco"] }],
    "filters": [{ "column": "RegionName", "values": ["North America"] }]
  }
}
```

**Backend processing:**
```javascript
// 1. Normalize context
const businessContext = normalizeContext(rawContext);
const contextBlock = buildContextBlock(businessContext);

// 2. Build user turn
const userTurn = `[Report Context]\n${contextBlock}\n\n[User Question]\n${question}`;

// 3. Send to Foundry Agent
const response = await foundryAgent.sendMessage(userTurn);

// 4. Return
res.json({ answer: response.content });
```

---

## Validation Checklist

### Sprint 2 — Context Capture
- [ ] Slicer changes reflected in captured JSON within 500ms
- [ ] Page navigation updates `page.displayName`
- [ ] Multiple active filters captured correctly
- [ ] Empty slicer selections handled (no empty keys in output)

### Sprint 3 — Fabric Agent Integration
- [ ] Tool call reaches Fabric Data Agent
- [ ] Response references actual data from semantic model
- [ ] Context (filters) passed through to query

### Sprint 4 — End-to-End Pattern 1
- [ ] "What am I looking at?" returns page + active filter summary
- [ ] "Why are declines increasing?" returns model-grounded answer with context
- [ ] Filter change → new question returns updated answer (no stale context)
