# Pattern 1 — Iframe Context Injection: Implementation Spec

## What This Document Covers

This is the detailed implementation specification for **Pattern 1 — Context Injection Agent** from the VISA PBI Embedded build guide.

It covers:
- Context capture from the PBIE iframe
- Context normalization (PBIE → business terms)
- Query construction with injected context
- Direct chat-backend call into the Fabric Data Agent

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

## Fabric Data Agent Query Construction

### Query Guidance

```
This is an embedded analytics assistant integrated into a Power BI Embedded portal.

Every question is answered by querying the connected Power BI semantic model —
never from memory or general knowledge.

Each request includes the current state of the embedded report:
- Active page
- Active filters
- Active slicers

The report state is treated as the user's current data context. Responses use plain,
business-friendly language appropriate for an analytics portal user. When the user asks
to "explain this chart" or "summarize this view", the current page and filter
combination scopes the query.
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

## Fabric Data Agent Query Shape

`queryFabricAgent({ question, context, effectiveUserName })` in `server/services/fabricAgent.js` maps the question to one of several DAX query shapes (`semantic/dax/query_patterns.md`) — metrics, rankings, trends, comparisons — using the context object (key-value pairs of active filters and slicers from the report, e.g. `{ 'Merchant': 'Costco', 'Region': 'North America' }`) to scope the query, executes it against the semantic model, and synthesizes the structured result into a natural-language answer.

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

// 2. Query the Fabric Data Agent directly
const answer = await queryFabricAgent({ question, context: businessContext, effectiveUserName });

// 3. Return
res.json({ answer, conversationId });
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
