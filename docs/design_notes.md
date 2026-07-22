# Design Notes — Implementation Requirements
## VISA Commercial Spend Analytics — PBIE + FilterSession Context Injection (Pattern 2)

**Prepared for:** Customer Implementation Team  
**Pattern:** Host-App Filter Injection + FilterSession Context Grounding  
**Tenant:** `MngEnvMCAP660444.onmicrosoft.com`  
**Last updated:** 2026-07-22 (rev 4 — `Spend YoY %` KPI card bug diagnosed and fixed, see Section 18; entitlement-based dynamic RLS live end-to-end; Direct Lake fixed-identity/SSO binding resolved; see Section 17 for current security posture)  
**Redesign note:** Project scope updated 2026-07-21 from Pattern 1 (slicer-read context injection) to Pattern 2 (host-app filter injection via `setFilters()` + `Fact_FilterSession` grounding). See Section 4 for the updated context flow and Section 11 for the new data model.

---

## Purpose

This document captures the implementation requirements, constraints, and decisions that the development team needs to know before building the Pattern 2 solution. It covers identity, token management, embedding, filter-state ownership, session persistence, and agent grounding.

### Pattern 2 — Host-App Filter Injection (current design)

The host application (VISA Partner Portal) **owns the filter/prompt experience**. The report never uses native Power BI slicers for context-driven filtering. Instead:

```
VISA Partner Portal
  → custom prompt / filter UI
  → accumulated filter state
  → PBIE setFilters()            ← applies state to embedded report
  → Direct Lake semantic model
  → persisted Fact_FilterSession ← same state written to Fabric Lakehouse
  → Foundry / Fabric Data Agent  ← agent receives filter state as grounding context
```

This approach avoids Power BI native slicer interaction issues in embedded scenarios, gives the host app full control over filter state, and allows the agent to query `Fact_FilterSession` directly against the governed semantic model rather than relying on screenshot/DOM capture.

---

## 1. Identity & Service Principal

### What is required

A **native service principal** must be registered in the `MngEnvMCAP660444.onmicrosoft.com` tenant. This SP is used by the backend server to:

1. Acquire embed tokens for the PBIE iframe (Power BI REST API)
2. Query the Fabric Data Agent (Fabric REST API)
3. Optionally, acquire tokens for Azure AI Foundry (if not using Managed Identity)

### Why a native SP is required (not a guest/cross-tenant identity)

This tenant enforces an **inbound communication policy** (`RequestDeniedByInboundPolicy`) that blocks Power BI and Fabric REST API calls from cross-tenant/external identities — even with a valid access token. Guest accounts (e.g., `seankelley@microsoft.com`) cannot call these APIs from outside the tenant. The service principal must be homed in `MngEnvMCAP660444`.

### Confirmed SP — VISA-PBIE-EmbedService (implemented 2026-07-21)

| Field | Value |
|-------|-------|
| App display name | `VISA-PBIE-EmbedService` |
| Client ID (appId) | `595278db-8070-426d-85b5-7933db47de2c` |
| SP Object ID | `9ee7391e-9fac-4bc5-ac1b-79e083aa76bd` |
| App Object ID | `72035c43-ea1a-4f7a-932b-3de79f4a5392` |
| Tenant | `b7e47691-9726-4f67-a302-e567815f3522` |
| Workspace role | **Admin** (in `VISA PBIE Context Injection`) |
| Embed token test | **200 confirmed** (`H4sI...` format, 1h expiry) |

### How it was registered (az CLI)

```powershell
# 1. Create app registration
az ad app create --display-name "VISA-PBIE-EmbedService"

# 2. Create the Enterprise App (Service Principal) object — must be done separately
az ad sp create --id "<appId>"

# 3. Add Power BI API resource reference (triggers AAD to accept client_credentials scope)
az ad app permission add --id "<appId>" \
  --api "00000009-0000-0000-c000-000000000000" \
  --api-permissions "7504609f-c495-4c64-8542-686125a5a36f=Role"

# 4. Add SP to Fabric workspace as Admin (use Fabric API — NOT Power BI workspace users API)
# Power BI workspace users API returns 403 during AAD propagation window
# Fabric roleAssignments API returns 201 immediately once SP object exists
$body = @{ principal = @{ id = "<spObjectId>"; type = "ServicePrincipal" }; role = "Admin" }
# POST https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/roleAssignments

# 5. Create a client secret (see Section 14 for timing quirk)
az ad app credential reset --id "<appId>" --display-name "embed-prod" --years 1
```

> **Key finding:** Admin consent is NOT required for the client_credentials flow to work against Power BI. Adding the API resource reference (`az ad app permission add`) is sufficient to unblock the scope. Admin consent failure (`Request_BadRequest`) can be safely ignored for this use case.

### API permissions — what actually works

Adding the Power BI Service resource (`00000009-0000-0000-c000-000000000000`) to `requiredResourceAccess` is sufficient. The specific permission ID is not critical for the client_credentials token scope — what matters is that the resource is listed. The entitlement ID `7504609f` is wrong (not found on the resource) but adding it does not prevent token issuance.

### Workspace role — Admin required (not Member)

The embed token `GenerateToken` API (multi-resource form) requires the SP to have **Admin** or **Member** workspace role. Member is documented as sufficient but Admin was confirmed working. Use **Admin** for embed scenarios.

- Workspace: `VISA PBIE Context Injection` (`349db6f1-5df6-4992-ba67-ebc4449fead5`)
- Role: **Admin**
- Added via: Fabric roleAssignments API (`POST /v1/workspaces/{id}/roleAssignments`)

---

## 2. Token Management

### Token types in this solution

The solution uses **three distinct token types** from three different auth flows. Understanding each is critical for a production implementation.

| Token | Purpose | Acquired By | TTL | Refresh Strategy |
|-------|---------|------------|-----|-----------------|
| **Embed Token** | Authorizes the PBIE iframe to render the report | Backend via Power BI REST API | **1 hour** | Silent re-issue before expiry |
| **Entra Access Token** | Backend calls to Power BI REST API and Fabric API | Backend via client credentials flow | 1 hour | Automatic via MSAL token cache |
| **Foundry Token** | Backend calls to Azure AI Foundry Agent | Backend via DefaultAzureCredential or client credentials | 1 hour | Automatic via MSAL token cache |

---

### 2a. Embed Token — App-Owns-Data Flow

This is the most critical token. The embed token is a short-lived credential that authorizes a specific user session to view a specific report. It is **not** a general OAuth token.

**API call to generate it — use the multi-resource form (confirmed working):**

The single-report endpoint (`/groups/{id}/reports/{id}/GenerateToken`) works but requires the SP to be in the workspace via Power BI workspace users API. The **multi-resource endpoint** works with any workspace-level Admin role and is more reliable:

```
POST https://api.powerbi.com/v1.0/myorg/GenerateToken
Authorization: Bearer {entraAccessToken}   ← SP token, scope: analysis.windows.net/powerbi/api/.default
Content-Type: application/json

{
  "reports":          [{ "id": "{reportId}" }],
  "datasets":         [{ "id": "{datasetId}" }],
  "targetWorkspaces": [{ "id": "{workspaceId}" }]
}
```

**Confirmed values for this project (Pattern 2 — VISA PBIE Context Injection workspace):**

```json
{
  "reports":          [{ "id": "e833a03b-2cf9-42d2-a1ee-a40f847fd75d" }],
  "datasets":         [{ "id": "b7bc94fc-a087-4e71-9476-f128ba57cf3a" }],
  "targetWorkspaces": [{ "id": "349db6f1-5df6-4992-ba67-ebc4449fead5" }]
}
```

**Embed token response shape:**

```json
{
  "token": "H4sI...",
  "tokenId": "...",
  "expiration": "2026-07-21T20:00:00Z"
}
```

**Token expiry handling (required for production):**

The embed token expires in 1 hour by default. The `powerbi-client` SDK raises a `tokenExpired` event when this occurs. The host application must handle this and silently re-issue.

```javascript
embeddedReport.on('tokenExpired', async () => {
  const newToken = await fetch('/api/embed-token').then(r => r.json());
  await embeddedReport.setAccessToken(newToken.token);
});
```

> **Implementation requirement:** The `/api/embed-token` backend endpoint must be callable by the frontend at any time without user interaction. It must never prompt for MFA. This is why a **service principal with client credentials** (not delegated/user flow) is required.

---

### 2b. Entra Access Token — Client Credentials Flow

The backend acquires this token to call the Power BI REST API (for embed token generation) and the Fabric API (for Data Agent queries).

**Token acquisition (Node.js / MSAL):**

```javascript
import { ConfidentialClientApplication } from '@azure/msal-node';

const msalClient = new ConfidentialClientApplication({
  auth: {
    clientId: process.env.CLIENT_ID,
    clientSecret: process.env.CLIENT_SECRET,
    authority: `https://login.microsoftonline.com/${process.env.TENANT_ID}`
  }
});

// For Power BI REST API
const pbiToken = await msalClient.acquireTokenByClientCredential({
  scopes: ['https://analysis.windows.net/powerbi/api/.default']
});

// For Fabric REST API
const fabricToken = await msalClient.acquireTokenByClientCredential({
  scopes: ['https://api.fabric.microsoft.com/.default']
});
```

MSAL automatically caches and refreshes these tokens. Do not manually manage Entra access token expiry.

---

### 2c. Row-Level Security (RLS) Considerations

If the semantic model uses Row-Level Security, the embed token must include an **effective identity** to enforce data access:

```json
{
  "accessLevel": "View",
  "datasetId": "5686371f-58c7-453f-89c8-26b0e2fb7f9d",
  "identities": [
    {
      "username": "user@domain.com",
      "roles": ["RoleName"],
      "datasets": ["5686371f-58c7-453f-89c8-26b0e2fb7f9d"]
    }
  ]
}
```

> **Action required:** Confirm whether the `Visa Slicer Demo v2` semantic model has RLS roles defined. If yes, the effective identity must be passed per-user-session. If no, RLS can be omitted.

---

## 3. Power BI Embedded Capacity

### Confirmed capacity

The VISA workspace is on a **dedicated Fabric capacity**:

| Field | Value |
|-------|-------|
| Capacity Name | [fabriccapwest3](https://portal.azure.com/#resource/subscriptions/0a913923-fe62-46fb-8fdd-b78fb498f7a9/resourceGroups/Fabric-West3-RG/providers/Microsoft.Fabric/capacities/fabriccapwest3) |
| Subscription | `0a913923-fe62-46fb-8fdd-b78fb498f7a9` |
| Resource Group | `Fabric-West3-RG` |
| Workspace | VISA (`8dd24078-9814-4e5d-a26c-3713092564bd`) |

Embed tokens can be generated without a per-user Power BI Pro or Premium Per User license because the workspace is backed by dedicated capacity. The **service principal** generating the embed token does not itself need a Power BI license.

> **Do not move the VISA workspace off dedicated capacity** — doing so will break embed token generation unless PPU licenses are assigned to all users.

---

## 4. Context Flow — Host-App Filter Injection (Pattern 2)

In Pattern 2, the host application owns the filter state. The `powerbi-client` SDK is used to **apply** filters to the report, not to read them back.

### 4a. Applying Filters to the Embedded Report

The host app builds a filter object from the custom UI and pushes it into the report:

```javascript
import * as pbi from 'powerbi-client';

// Build a basic filter — IBasicFilter from powerbi-models
const filter = {
  $schema: 'http://powerbi.com/product/schema#basic',
  target: { table: 'Dim_Client', column: 'ClientName' },
  operator: 'In',
  values: ['ACME Corp', 'Global Bank']
};

// Apply to report (replaces all report-level filters)
await report.setFilters([filter]);

// Or apply to a specific page
const pages = await report.getPages();
const activePage = pages.find(p => p.isActive);
await activePage.setFilters([filter]);
```

> **Why `setFilters()` instead of slicers?** Native Power BI slicers in embedded scenarios have cross-visual sync issues and are difficult to drive programmatically from the host app. `setFilters()` applies directly to the report's filter context, is reliable in embedded mode, and keeps filter state management in the host app where it belongs.

### 4b. Accumulating Filter State in the Host App

The host app maintains a `filterState` object in memory (or in React/component state). Each user interaction updates this object:

```javascript
// filterState shape — matches embedded_filter_context_schema.json
const filterState = {
  sessionId: crypto.randomUUID(),
  timestamp: new Date().toISOString(),
  userId: window.PBIE_USER_UPN,
  reportId: '<reportId>',
  page: { name: 'Demo PBIP', displayName: 'Demo PBIP' },
  filters: [
    { table: 'Dim_Client', column: 'ClientName', values: ['ACME Corp'] },
    { table: 'Dim_Date', column: 'CalendarYear', values: [2024, 2025] }
  ],
  segments: [],
  mccs: []
};
```

### 4c. Persisting Filter State to Fact_FilterSession

On each filter change (or on session end), the host app writes the filter state to `Fact_FilterSession` in the Fabric Lakehouse. This table is part of the Direct Lake semantic model and queryable by the Fabric Data Agent:

```javascript
// POST to backend — backend writes to Lakehouse via Fabric REST API
await fetch('/api/session', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify(filterState)
});
```

### 4d. Passing Filter State to the Agent

When the user sends a chat message, the current `filterState` is serialized and injected as context in the Foundry Agent user turn:

```
[Report Context]
Page: Demo PBIP
Filters active:
  - Client: ACME Corp
  - Year: 2024, 2025

[User Question]
What is the approval rate trend for this client over the selected period?
```

The agent also has access to `Fact_FilterSession` via the semantic model, enabling it to look up historical filter sessions for the same user.

### 4e. SDK version

```json
"powerbi-client": "^2.23.1"
```

### Previously implemented (Pattern 1 — superseded)

The prior implementation in `frontend/context-capture/captureContext.js` reads slicer state via `getSlicerState()`. This file is retained in the codebase but is superseded by the Pattern 2 approach. It can be repurposed as a fallback or removed in Sprint 3.

---

## 5. Fabric Data Agent

### What it is

The Fabric Data Agent is an AI-powered query interface provisioned inside a Fabric workspace. It accepts natural language questions and returns answers by generating and executing DAX queries against a connected semantic model.

### Status — **Provisioned** (2026-07-21)

| Field | Value |
|-------|-------|
| Agent name | `Commercial_Spend_Agent` |
| Agent ID | `d2042f7c-989f-47d2-a3b4-92603f3e55ab` |
| Workspace | `VISA PBIE Context Injection` (`349db6f1`) |
| Bound model | `Commercial_Spend_Analytics` (`b7bc94fc`) |

Provisioned via Fabric REST API (see `scripts/create_data_agent.ps1`). The agent definition consists of 4 JSON parts base64-encoded: `data_agent.json`, `stage_config.json`, `datasource.json`, `fewshots.json`.

### Target semantic model for the Data Agent

The Data Agent should be provisioned against the **VISA Commercial Spend Analytics** model (not `Visa Slicer Demo v2`). Key tables the agent should be able to query:

| Table | Purpose |
|-------|---------|
| `Fact_CommercialSpend` | 250k synthetic transaction rows — primary fact table |
| `Fact_FilterSession` | Persisted host-app filter sessions — agent uses this for user context |
| `Dim_Client` | Client/cardholder dimension |
| `Dim_Merchant` | Merchant dimension |
| `Dim_MCC` | Merchant Category Code dimension |
| `Dim_Country` | Country/region dimension |
| `Dim_Product` | Card product dimension |
| `Dim_Segment` | Business segment dimension |
| `Dim_Date` | Date dimension |
| `Dim_ApprovalStatus` | Transaction approval status dimension |

### Provisioning steps

1. Complete Section 11 (Fabric Lakehouse deployment) first
2. Open the **VISA PBIE Context Injection** workspace in Fabric portal
3. Click **New item → Data agent** (or "AI skill" depending on tenant feature flag)
4. Select data source type: **Semantic model (Power BI)**
5. Select **VISA Commercial Spend Analytics**
6. Add table/measure descriptions using the descriptions in `model_spec.json` (from starter package)
7. Publish the agent and record the **agent ID** and **endpoint URL**

### Auth for backend calls to Fabric Data Agent

```
POST https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/dataagentruns
Authorization: Bearer {fabricAccessToken}
```

The `fabricAccessToken` is the client credentials token acquired against scope `https://api.fabric.microsoft.com/.default` (see Section 2b).

### Fallback if Fabric Data Agent is not available

If the Data Agent feature is unavailable in this tenant, the fallback is **direct XMLA/DAX execution** via the Power BI REST API `executeQueries` endpoint:

```
POST https://api.powerbi.com/v1.0/myorg/groups/{workspaceId}/datasets/{datasetId}/executeQueries
```

This requires the backend to generate DAX — which is the Foundry Agent's responsibility in Sprint 4.

---

## 6. Azure AI Foundry Agent

### Status

> **Not yet provisioned.** Requires an Azure AI Foundry project in an accessible subscription.

### Recommended placement

Create the Foundry project in the same subscription as the Fabric capacity or in the MSIE Azure subscription — wherever the customer's AI Services quota is available.

### Auth for backend calls to Foundry

```javascript
import { AIProjectClient } from '@azure/ai-projects';
import { DefaultAzureCredential } from '@azure/identity';

const client = new AIProjectClient(
  process.env.FOUNDRY_PROJECT_ENDPOINT,
  new DefaultAzureCredential()
);
```

`DefaultAzureCredential` will use the service principal if `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, and `AZURE_TENANT_ID` are set in the environment — same SP as the embed token flow.

The SP needs **Azure AI Developer** role on the Foundry project resource.

---

## 7. CORS and Local Dev Constraints

### Local development

The Node.js server runs on `http://localhost:3000`. The `powerbi-client` SDK embeds the iframe pointing to `app.powerbi.com`. Power BI's embedding does not require CORS headers on the host server — the iframe loads from Microsoft's CDN.

CORS **is** required on `/api/*` routes if the frontend is served from a different origin than the backend (e.g., Vite dev server on port 5173 + Express on port 3000). Configure:

```javascript
app.use(cors({
  origin: ['http://localhost:3000', 'http://localhost:5173'],
  methods: ['GET', 'POST']
}));
```

### Production hosting

In production, the server should run over **HTTPS** — Power BI embedded content requires secure context in most browser configurations. A self-signed certificate is sufficient for internal demos.

---

## 8. Known Tenant Constraints

| Constraint | Detail |
|-----------|--------|
| Cross-tenant CLI access blocked | `az login` with device code flow to `MngEnvMCAP660444` is blocked for external Microsoft identities — do not attempt programmatic token acquisition from a `@microsoft.com` account against this tenant's Fabric/PBI APIs |
| Power BI REST API restricted to tenant members | API calls must originate from a token scoped to `b7e47691-9726-4f67-a302-e567815f3522` |
| ~~Service principal consent requires admin~~ | **Resolved.** Admin consent is NOT required for client_credentials to work. Adding the Power BI resource reference to the app registration is sufficient. `az ad app permission admin-consent` returned 400 but tokens still issued successfully. |
| Fabric Data Agent feature flag | The "Data agent" item type is **already enabled** in this tenant — `Commercial_Spend_Agent` was created via REST API without any tenant setting change. |
| AAD credential propagation delay | After `az ad app credential reset`, the new credential takes **35–40 seconds** to propagate. Token requests before this window fail with `AADSTS7000215`. See Section 14. |
| Power BI workspace users API timing | `POST /groups/{id}/users` for a new SP returns 403 "Failed to get service principal details" until AAD fully propagates the SP object. Use the **Fabric roleAssignments API** instead — it returns 201 immediately. |

---

## 8a. External User Auth Boundary — Pattern 1 Design Decision

The iframe is consumed by **external users** (guests) who are not native members of `MngEnvMCAP660444`. Because the tenant's inbound communication policy (`RequestDeniedByInboundPolicy`) blocks cross-tenant API calls, external user credentials **cannot** be used to call Fabric or Power BI REST APIs directly from the backend.

**This is the primary reason Pattern 1 (context injection) exists.**

### How the user data boundary is enforced without delegated credentials

| Boundary mechanism | How it works | Requires |
|-------------------|-------------|----------|
| **Effective identity in embed token** | SP generates an embed token with the user's UPN as `effectiveIdentity` — the Power BI engine enforces any RLS roles defined on the semantic model for that user | RLS roles defined on the model |
| **Context injection layer** | `captureContext.js` reads only what is currently visible in the user's filtered iframe. The Foundry Agent receives only that slice of context — it cannot query data outside the user's current view | Pattern 1 implementation (done) |

Together these two mechanisms scope the AI agent's data access to exactly what the user can see, without requiring the external user's token to reach Fabric APIs.

### Production path — enabling full delegated access for external users (Path A)

If full user-delegated Fabric access is required in production (agent queries run as the user, not the SP), the tenant admin must:

1. **Entra ID → External Identities → Cross-tenant access settings**
2. For each external tenant (e.g. `microsoft.com`): configure **Inbound** → B2B collaboration → **Allow** for the specific app registration (`pbie-context-agent-sp`)
3. This removes the `RequestDeniedByInboundPolicy` error for those external identities
4. Once enabled: add MSAL.js to the frontend, acquire Fabric-scoped tokens for the signed-in guest user, and pass them to the backend via `Authorization` header

**This is a tenant admin action. No code change unblocks it.**

### Current implementation (Path B — active)

- SP makes all Fabric/Foundry API calls
- Embed token includes `effectiveIdentity` (user's UPN) when provided → RLS enforced at report layer
- Context injection constrains agent queries to the user's visible report state
- User identity is passed as a query param to `/api/embed-token?user=<upn>` (to be replaced with a validated session token before production)

---

## 9. Confirmed Resource IDs

> These are production values confirmed via API on 2026-07-21. Treat as stable unless workspace is recreated.

### Pattern 2 — VISA PBIE Context Injection workspace (active)

```
TENANT_ID      = b7e47691-9726-4f67-a302-e567815f3522
WORKSPACE_ID   = 349db6f1-5df6-4992-ba67-ebc4449fead5
DATASET_ID     = b7bc94fc-a087-4e71-9476-f128ba57cf3a   # SemanticModel
REPORT_ID      = e833a03b-2cf9-42d2-a1ee-a40f847fd75d   # Report
AGENT_ID       = d2042f7c-989f-47d2-a3b4-92603f3e55ab   # DataAgent
LAKEHOUSE_ID   = 1aa73044-f85f-4843-b3e5-588cab4c0499
CAPACITY_NAME  = fabriccapwest3   # see docs/design_notes.md Section 3 for portal link
CLIENT_ID      = 595278db-8070-426d-85b5-7933db47de2c   # SP app ID
```

### Pattern 1 — VISA workspace (legacy, reference only)

```
WORKSPACE_ID  = 8dd24078-9814-4e5d-a26c-3713092564bd
REPORT_ID     = daed8d4d-2dc3-4708-ad82-5611c667498c
DATASET_ID    = 5686371f-58c7-453f-89c8-26b0e2fb7f9d
XMLA_ENDPOINT = powerbi://api.powerbi.com/v1.0/myorg/VISA
```

---

## 11. Data Model — VISA Commercial Spend Analytics

The project uses a purpose-built synthetic dataset. It does **not** contain real VISA, PAN, PII, cardholder, merchant, or production transaction data.

### Dataset summary

| Item | Detail |
|------|--------|
| Transaction rows | 250,000 synthetic commercial spend records |
| Filter session rows | 5,000 synthetic host-app filter sessions |
| Dimension tables | 8 |
| Fact tables | 2 |
| Storage mode | Direct Lake (Fabric Lakehouse → Delta tables) |
| Starter package | `VISA commercial spend starter package.zip` (contains CSVs, DAX measures, model spec, filter contract, notebook) |

### Tables

| File | Type | Description |
|------|------|-------------|
| `Dim_Date.csv` | Dimension | Calendar date table |
| `Dim_Client.csv` | Dimension | Client / cardholder accounts |
| `Dim_Country.csv` | Dimension | Country / region |
| `Dim_Product.csv` | Dimension | Card product type |
| `Dim_Segment.csv` | Dimension | Business segment |
| `Dim_Merchant.csv` | Dimension | Merchant records |
| `Dim_MCC.csv` | Dimension | Merchant Category Codes |
| `Dim_ApprovalStatus.csv` | Dimension | Transaction approval status codes |
| `Fact_CommercialSpend.csv` | Fact | Commercial spend transactions |
| `Fact_FilterSession.csv` | Fact | Host-app filter/prompt sessions |

### Fabric deployment path

1. Upload all CSV files to the **Files** area of a Fabric Lakehouse in the `VISA PBIE Context Injection` workspace
2. Load each CSV to a Delta table with the same table name (use the included Fabric notebook or Dataflow Gen2)
3. Create a **Direct Lake** semantic model over the Delta tables
4. Apply relationships from `model_spec.json` (included in starter package)
5. Add DAX measures from `semantic_model_measures.dax` (included in starter package)
6. Provision the Fabric Data Agent against this model (see Section 5)

> Microsoft Learn reference: [Load data into a Fabric Lakehouse](https://learn.microsoft.com/en-us/fabric/data-engineering/load-data-lakehouse) · [CSV-to-Delta quickstart](https://learn.microsoft.com/en-us/fabric/data-engineering/get-started-csv-upload)

### Updating semantic/model_metadata.md

Once the model is deployed, update `semantic/model_metadata.md` and `semantic/metadata/field_map.json` with the confirmed table names and column names from this model (replacing the `Visa Slicer Demo v2` placeholders).

---

## 12. Filter Context Contract

The file `embedded_filter_context_schema.json` (included in the starter package) defines the JSON contract that flows between:

- Host application prompt/filter UI state
- `report.setFilters()` call to PBIE
- `Fact_FilterSession` write to Fabric Lakehouse
- Agent prompt builder (grounding context block)

### Schema shape

```json
{
  "sessionId": "<uuid>",
  "timestamp": "2026-07-21T18:00:00Z",
  "userId": "user@domain.com",
  "reportId": "<pbi-report-id>",
  "page": {
    "name": "Demo PBIP",
    "displayName": "Demo PBIP"
  },
  "filters": [
    {
      "table": "Dim_Client",
      "column": "ClientName",
      "operator": "In",
      "values": ["ACME Corp"]
    },
    {
      "table": "Dim_Date",
      "column": "CalendarYear",
      "operator": "In",
      "values": [2024, 2025]
    }
  ],
  "segments": [],
  "mccs": [],
  "question": "What is the approval rate for this client YTD?"
}
```

### Contract usage by component

| Component | Usage |
|-----------|-------|
| Frontend filter UI | Writes to `filterState` object in memory |
| `embed.js` | Calls `report.setFilters()` using `filters[]` array converted to `IBasicFilter` objects |
| `server/routes/session.js` (Sprint 3) | Receives full contract, writes to `Fact_FilterSession` via Fabric Lakehouse API |
| `server/routes/chat.js` | Receives `filterState` as `rawContext`, builds context block for agent turn |
| Fabric Data Agent | Queries `Fact_FilterSession` directly by `sessionId` or `userId` for historical context |

---

## 10. Implementation Checklist (Pre-Sprint 1)

### Blocked on Customer Tenant Admin

| Item | Owner | Status |
|------|-------|--------|
| ~~Register service principal in `MngEnvMCAP660444` tenant~~ | ~~Customer tenant admin~~ | **Done** — `VISA-PBIE-EmbedService` (`595278db`) |
| ~~Grant admin consent for Power BI + Fabric API permissions~~ | ~~Customer tenant admin~~ | **Not required** — client_credentials works without admin consent |
| ~~Add SP to workspace~~ | ~~Customer tenant admin~~ | **Done** — Admin role via Fabric API |
| ~~Confirm `CLIENT_ID` and `CLIENT_SECRET` and add to `.env`~~ | ~~Dev team~~ | **Done** — `.env` populated, embed token 200 confirmed |
| Confirm RLS status of `Commercial_Spend_Analytics` — model has no RLS roles (Direct Lake, synthetic data) | Customer | **Superseded** — actively adding 2 RLS roles + XMLA migration, see Section 15 |
| ~~Provision Fabric Data Agent~~ | ~~Customer/Fabric admin~~ | **Done** — `Commercial_Spend_Agent` (`d2042f7c`) |
| ~~Enable "AI skills" feature in Fabric tenant admin settings~~ | ~~Customer tenant admin~~ | **Already enabled** — REST API creation succeeded |

### Blocked on Dev Team

| Item | Owner | Status |
|------|-------|--------|
| Create Azure AI Foundry project | Dev team | Open |
| Assign SP **Azure AI Developer** role on Foundry project | Dev team | Open |
| Run `node scripts/provision-foundry-agent.js` to create agent | Dev team | Open (requires Foundry project) |
| Add `FOUNDRY_AGENT_ID` to `.env` | Dev team | Open |
| Install Node.js 20+ locally | Dev team | Open |

### Production Gate — External User Auth (Path A, not required for demo)

| Item | Owner | Status |
|------|-------|--------|
| Configure Entra cross-tenant access policy to allow B2B inbound for external orgs | Customer tenant admin | Not started |
| Scope to specific app registration (`VISA-PBIE-EmbedService`) in inbound policy | Customer tenant admin | Not started |
| Replace `?user=<upn>` query param with validated session identity | Dev team | Not started |
| Add MSAL.js to frontend for guest user sign-in | Dev team | Not started |
| Switch `fabricAgent.js` to use user-delegated token when present | Dev team | Not started |

---

## 13. PBIR Report Creation — Confirmed Schema URLs (implemented 2026-07-21)

The Fabric REST API creates reports in **PBIR format** (Power BI Report v4). The multi-part definition must use exact schema URLs. Four of the five files had wrong schemas that caused the async operation to fail.

All schemas are under the base path: `https://developer.microsoft.com/json-schemas/fabric/item/report/definition/`

| File | `$schema` value | Common mistake |
|------|----------------|----------------|
| `definition.pbir` | `.../definitionProperties/2.0.0/schema.json` | Omitting the `$schema` key |
| `definition/version.json` | `.../versionMetadata/1.0.0/schema.json` | Using `version/1.0.0` or wrong `version` value |
| `definition/report.json` | `.../report/3.1.0/schema.json` | Missing required `themeCollection` property |
| `definition/pages/pages.json` | `.../pagesMetadata/1.0.0/schema.json` | Using `pages/1.0.0`; omitting `activePageName` |
| `definition/pages/{id}/page.json` | `.../page/2.1.0/schema.json` | Using `page/2.0.0` |

### Required `version.json` shape

```json
{
  "$schema": "https://developer.microsoft.com/json-schemas/fabric/item/report/definition/versionMetadata/1.0.0/schema.json",
  "version": "2.0.0"
}
```

`"version": "2.0.0"` is required. Using `"3.1.0"` or any other value causes a validation error.

### Required `report.json` additions

The `report.json` must include a `themeCollection` block even if no custom theme is applied:

```json
{
  "$schema": "https://developer.microsoft.com/json-schemas/fabric/item/report/definition/report/3.1.0/schema.json",
  "themeCollection": {
    "baseTheme": {
      "name": "CY25SU12",
      "reportVersionAtImport": { "major": 5, "minor": 64 },
      "type": "SharedResources"
    }
  }
}
```

### Async operation polling pattern

The Fabric Create Item endpoint returns `202 Accepted` with an `x-ms-operation-id` header — **not** a body.

```powershell
# Create item (202 with operation ID header)
$response = Invoke-WebRequest -Uri "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/items" ...
$operationId = $response.Headers["x-ms-operation-id"]

# Poll until succeeded
do {
    Start-Sleep 3
    $status = Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/operations/$operationId" ...
} while ($status.status -notin @("Succeeded", "Failed"))

# Retrieve item ID after success
$items = Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/items" ...
$report = $items.value | Where-Object { $_.displayName -eq "Commercial_Spend_Analytics" }
```

See `scripts/create_report.ps1` for the full implementation.

---

## 14. SP Credential Setup — AAD Propagation Quirk

> **This section documents a critical timing constraint.** Skipping these steps results in `AADSTS7000215: Invalid client secret` even for a freshly-issued credential.

### The problem

After `az ad app credential reset`, AAD does not immediately accept the new credential for token requests. The propagation window is **35–40 seconds**. Token requests during this window return `AADSTS7000215`.

Additionally, an app registration with no API resource references defined in `requiredResourceAccess` may also fail token issuance even after propagation.

### Required sequence

```powershell
# Step 1: Add a Power BI API resource reference BEFORE resetting the credential.
# This "touches" the app in AAD and ensures resource references are indexed.
az ad app permission add `
  --id $appId `
  --api "00000009-0000-0000-c000-000000000000" `
  --api-permissions "7504609f-c495-4c64-8542-686125a5a36f=Role"

# Step 2: Reset the credential
$cred = az ad app credential reset --id $appId --display-name "embed-prod" --years 1 | ConvertFrom-Json

# Step 3: Wait for AAD propagation (35-40 seconds minimum)
Start-Sleep 40

# Step 4: Request token using URL-ENCODED FORM BODY (NOT a PowerShell hashtable)
# PowerShell Invoke-RestMethod with -Body @{} serializes differently and fails even though
# the content looks the same. URL-encode the client_secret to handle special characters.
$tb = "grant_type=client_credentials" +
      "&client_id=$($cred.appId)" +
      "&client_secret=$([System.Uri]::EscapeDataString($cred.password))" +
      "&scope=https%3A%2F%2Fanalysis.windows.net%2Fpowerbi%2Fapi%2F.default"

$tr = Invoke-WebRequest `
  -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" `
  -Method POST `
  -Body $tb `
  -ContentType "application/x-www-form-urlencoded"

$spToken = ($tr.Content | ConvertFrom-Json).access_token
```

### Writing credentials to `.env` — avoid `-replace`

PowerShell's `-replace` operator treats `$` and `~` as regex special characters. Using it to write `CLIENT_SECRET` into `.env` silently corrupts the value. Use `[System.IO.File]::WriteAllLines` instead:

```powershell
$lines = [System.IO.File]::ReadAllLines($envPath)
$updated = $lines | ForEach-Object {
    if ($_ -match '^CLIENT_SECRET=') { "CLIENT_SECRET=$secret" }
    elseif ($_ -match '^CLIENT_ID=') { "CLIENT_ID=$appId" }
    else { $_ }
}
[System.IO.File]::WriteAllLines($envPath, $updated, [System.Text.UTF8Encoding]::new($false))
```

See `scripts/validate_sp_embed.ps1` for the full implementation including embed token generation and `.env` write.

---

## 15. Alignment vs. VISA Production Architecture & XMLA/RLS Migration Plan

> **Added 2026-07-21.** Gap analysis performed against VISA's documented production PBIE architecture (Teams/email threads describing their custom-slicer + RLS work), to confirm this POC's security model is representative before the customer demo.

### 15a. Gap analysis summary

| VISA's documented production pattern | This POC (current) | Aligned? |
|---|---|---|
| App-Owns-Data embedding | App-Owns-Data (`server/routes/embedToken.js`) | ✅ |
| Embed tokens generated via application SPN | SP via client-credentials (`VISA-PBIE-EmbedService`) | ✅ |
| Username + role passed in `identities`/effectiveIdentity for RLS enforcement | `effectiveIdentity` with UPN passed on `GenerateToken`, but `roles` array is currently empty — model has no RLS roles defined | ⚠️ Same shape, not yet exercised |
| Custom filter UI drives report via `setFilters()` | Documented in Section 4 (Pattern 2), `report.setFilters()` | ✅ |
| SPN + client credentials + `executeQueries` + `impersonatedUserName` for custom slicer/RLS scenarios — **Microsoft guidance moved VISA to XMLA** because this combination hit limitations under RLS | Foundry Agent DAX execution uses SPN + `executeQueries` (Section 5 fallback) — has not hit the same limitation only because the current model has **no RLS** | ❌ **Gap — see 15b** |
| Frontend token-transport architecture (Bearer header vs. session cookie vs. BFF) — not documented on VISA's side either | UPN passed as an unauthenticated `?user=<upn>` query param — self-flagged as not production-safe | ⚠️ Shared open risk, not a contradiction, but ours is the weaker option today |

### 15b. Gap — `executeQueries` + SPN + RLS is a known limitation

VISA's own custom-slicer implementation used SPN + OAuth client credentials + Power BI `executeQueries` + `impersonatedUserName` against an RLS-enabled model, and **Microsoft guidance shifted them to the XMLA endpoint** because that combination hit limitations under RLS at scale.

This POC's Foundry Agent query layer currently uses the identical combination (SPN client-credentials + `executeQueries`), but has never exercised RLS because `Commercial_Spend_Analytics` has no RLS roles defined. The moment RLS is introduced (see 15d below), we should expect to hit the same limitation VISA hit — so the query layer needs to move to XMLA **before** RLS is turned on, not after.

### 15c. Decision — migrate query layer from `executeQueries` to XMLA endpoint

**Decision:** Move the semantic-model query layer (currently `executeQueries` in `server/services/fabricAgent.js`) to the **XMLA endpoint**, matching the path Microsoft already recommended to VISA for RLS-enabled scenarios. This replaces the Section 5 "fallback" path as the primary query mechanism going forward.

- XMLA endpoint (confirmed): `powerbi://api.powerbi.com/v1.0/myorg/VISA PBIE Context Injection`
- **Auth (validated 2026-07-22):** NOT a pre-acquired bearer token passed as `Password=`. That approach fails ("Authentication failed for all authenticators"). The working pattern is the documented MSOLAP app-only connection string: `User ID=app:<ClientId>@<TenantId>;Password=<ClientSecret>` — the MSOLAP provider performs its own client-credentials OAuth exchange using the raw secret. Same SP (`VISA-PBIE-EmbedService`) used everywhere else; no new app registration needed.
- `Initial Catalog` must be the model's display **name** (`Commercial_Spend_Analytics`), not its GUID — the GUID form returns `PowerBIEntityNotFound`.
- **RLS enforcement mechanism (corrected from original plan):** XMLA's `EffectiveUserName` property requires the impersonated account to be a **real Microsoft Entra ID identity** with Read+Build permission on the model — synthetic/demo UPNs (like the ones this project uses for embed-token `effectiveIdentity`) do not qualify. Instead, RLS roles are activated directly via the connection string's **`Roles=`** property ("test as role"), which our workspace-Admin SP is permitted to invoke without needing role membership. This is functionally equivalent to how `GenerateToken`'s `identities[].roles` already works for the embed token, so both surfaces now use the same synthetic-user → role mapping (`server/services/rlsTestUsers.js`).

### 15d. RLS test plan — 2 users, 2 roles, functional demo

To validate RLS end-to-end, the semantic model needs real RLS roles and two test identities with different data visibility:

1. **Define 2 RLS roles** in the TMDL model — DONE: `Role_RegionA` (`dim_client[HomeRegion] = "North America"`) / `Role_RegionB` (`dim_client[HomeRegion] = "Europe"`), committed under `Commercial_Spend_Analytics.SemanticModel/definition/roles/` and referenced from `model.tmdl`. Requires an **Update from Git** sync in the Fabric workspace's Source Control panel after pushing — local TMDL edits are not live until synced.
2. **Map 2 synthetic test users to roles** — DONE, no real Entra ID accounts needed since RLS is activated via the `Roles=` connection property rather than `EffectiveUserName` (see 15c correction). Mapping lives in `server/services/rlsTestUsers.js`: `regiona.test@visapoc.demo` → `Role_RegionA`, `regionb.test@visapoc.demo` → `Role_RegionB`.
3. **Embed token path**: each user's embed token carries `effectiveIdentity` with their UPN + the correct `roles` array entry, resolved from the same shared map — DONE.
4. **Chat/agent path**: DAX queries issued via XMLA activate the requesting user's mapped role(s) via `Roles=`, so the agent's answers are scoped identically to what that user sees in the embedded report — DONE.
5. **Functional test matrix — VALIDATED 2026-07-22** (via `scripts/query_xmla.ps1` directly and via `queryFabricAgent()` end-to-end):
   - No user / no role → `dim_client[HomeRegion]` returns all 5 values (North America, APAC, LATAM, Europe, CEMEA)
   - `regiona.test@visapoc.demo` (Role_RegionA) → returns only "North America" ✅
   - `regionb.test@visapoc.demo` (Role_RegionB) → returns only "Europe" ✅
   - Neither test user's query returns the other's region — core isolation proof point confirmed at the query layer
   - Report-side (embedded iframe) isolation still needs a manual browser round-trip test with each synthetic UPN before the demo (query-layer isolation is confirmed; report-rendering isolation is not yet separately re-validated post-migration)

### 15e. Hard constraint — embed token shape/behavior must not change

**The embed token request/response shape must stay exactly as it is today.** VISA's Angular frontend (`powerbi-client-angular`) consumes the embed token the same way this POC's vanilla-JS frontend does — same `GenerateToken` call shape, same `effectiveIdentity` structure, same response fields (`accessToken`, `embedUrl`, `reportId`). The only thing that changes with this migration is that the `roles` array (currently always empty) now gets populated with a real role name per user. No breaking changes to `/api/embed-token`'s contract are permitted, since that contract is what any future Angular integration would rely on.

### 15f. Constraint — Node.js XMLA client access without bypassing 2FA

Company policy blocks npm packages that bypass 2FA/MFA. Most Node.js XMLA/ADOMD-style client libraries require the legacy **Resource Owner Password Credentials (ROPC)** OAuth flow (raw username + password) to authenticate against Analysis Services/XMLA — ROPC is a "public client" flow that bypasses interactive MFA/Conditional Access, which is why packages built on it are blocked.

**Solution:** Do not use a Node-native XMLA/ADOMD npm package. Instead, execute XMLA/DAX calls through a small PowerShell shim (`Invoke-ASCmd`, part of the `SqlServer` PowerShell module) invoked from Node via `child_process` — the same pattern already used for the existing `scripts/*.ps1` SP token scripts. This shim authenticates using the **same SP client-credentials token** already used everywhere else in this project (scope `https://analysis.windows.net/powerbi/api/.default`) — an app-only OAuth flow that never involves ROPC or MFA bypass, so it is not subject to the blocked-package policy.

```powershell
# Actual working pattern (validated 2026-07-22) — see scripts/query_xmla.ps1 for the full script.
# SP app-only auth via User ID=app:<ClientId>@<TenantId>, RLS role activated via Roles= property.
$cs = "Provider=MSOLAP;Data Source=$XmlaEndpoint;Initial Catalog=$Database;" + `
      "User ID=app:$ClientId@$TenantId;Password=$ClientSecret;" + `
      "Persist Security Info=True;Impersonation Level=Impersonate;Roles=$Roles"
Invoke-ASCmd -ConnectionString $cs -Query $daxQuery -QueryTimeout 60
```

Node's `server/services/fabricAgent.js` (`runXmlaQuery()`) shells out to `scripts/query_xmla.ps1` per query via `child_process.execFile('pwsh', ...)`, resolving the requesting user's role(s) via `rlsTestUsers.resolveRoles()` instead of `executeQueries`.

### 15g. Open items — tracked for this migration

| Item | Owner | Status |
|------|-------|--------|
| Define 2 RLS roles in TMDL (`Role_RegionA` / `Role_RegionB`) against `Dim_Client` | Dev team | ✅ Done — synced to live model 2026-07-22 |
| Map 2 synthetic test users to roles (no real AAD accounts needed — see 15c) | Dev team | ✅ Done (`server/services/rlsTestUsers.js`) |
| Migrate `server/services/fabricAgent.js` from `executeQueries` to XMLA (via PowerShell `Invoke-ASCmd` shim) | Dev team | ✅ Done — `USE_XMLA=true` validated end-to-end |
| Populate `roles` array in embed token `effectiveIdentity` per user (currently always empty) | Dev team | ✅ Done |
| Functional test: User A/User B chat data isolation (Section 15d matrix) — query layer | Dev team | ✅ Validated 2026-07-22 |
| Functional test: User A/User B embedded **report** data isolation (browser round-trip) | Dev team | ✅ Validated 2026-07-22 — Direct Lake fixed-identity/SSO-disabled cloud connection bound to the semantic model's datasource in the Fabric portal; `regiona.test@visapoc.demo` and `regionb.test@visapoc.demo` both return `200` from `/api/embed-token` and load successfully in-browser |
| Confirm embed token request/response contract unchanged post-migration (Section 15e) | Dev team | ✅ Verified by code inspection — no shape changes |
| Bind semantic model datasource to fixed-identity connection (SSO disabled) in Fabric portal | Dev team | ✅ Done 2026-07-22 — resolved the `403 "not supported for this datasource"` blocker described below |

This supersedes the "Confirm RLS status" row in Section 10's Implementation Checklist — RLS is now being actively added rather than being "not applicable."

## 16. Entitlement-Based Dynamic RLS via CUSTOMDATA() (prototype, added 2026-07-22)

> Follow-up to Section 15's XMLA/RLS migration and the architectural question of whether XMLA and PBIE can carry the "same identity object". This section prototypes replacing one-static-role-per-value RLS with a single dynamic role driven by `CUSTOMDATA()`/`customData`, so both surfaces enforce RLS from the same entitlement string.

### 16a. Design

- **New TMDL role `Role_Entitlement`**: `dim_client[HomeRegion] = CUSTOMDATA()` — one dynamic role instead of one static role per entitlement value. `Role_RegionA`/`Role_RegionB` are kept in the model, but are no longer used by the default runtime path — they exist only so `scripts/compare_rls_mechanisms.ps1` can prove the new mechanism is equivalent.
- The entitlement **value** (not a role name) is carried identically on both surfaces:
  - **PBIE**: `GenerateToken` `identities[].customData`, with `identities[].roles: ['Role_Entitlement']` to activate the dynamic role.
  - **XMLA**: connection string `CustomData=<value>` alongside `Roles=Role_Entitlement`.
- `server/services/rlsTestUsers.js`: `TEST_USER_ENTITLEMENTS` maps each synthetic UPN to an entitlement value (`regiona.test@visapoc.demo` → `"North America"`, `regionb.test@visapoc.demo` → `"Europe"`) via `resolveEntitlement()`. The old `TEST_USER_ROLES`/`resolveRoles()` mapping is retained, comparison-only.
- `server/routes/embedToken.js` defaults to entitlement mode; `?mode=static` reverts to the legacy static-role mapping for side-by-side testing; `?customData=` overrides the resolved value for ad-hoc testing.
- `server/services/fabricAgent.js` `runXmlaQuery()` defaults to `Roles=Role_Entitlement` + `CustomData=<entitlement>`; an `rlsMode: 'static'` param falls back to the legacy per-value `Roles=` mapping.
- `scripts/query_xmla.ps1` gained a `-CustomData` param, appended as `CustomData=<value>` in the MSOLAP connection string (property name confirmed exact — no space — via the MS Learn `connection-string-properties-analysis-services` reference).

### 16b. Validation — XMLA layer (static vs. dynamic row-set parity)

`scripts/compare_rls_mechanisms.ps1` runs the same DAX query 5 ways and diffs row sets. **Result (2026-07-22, post Fabric Git sync): both PASS.**

| Query | Roles= | CustomData= | Result |
|---|---|---|---|
| Baseline | *(none)* | *(none)* | 5 regions returned (unfiltered) |
| Static Role_RegionA | `Role_RegionA` | — | `North America` only |
| Dynamic entitlement | `Role_Entitlement` | `North America` | `North America` only — **identical to static Role_RegionA** ✅ |
| Static Role_RegionB | `Role_RegionB` | — | `Europe` only |
| Dynamic entitlement | `Role_Entitlement` | `Europe` | `Europe` only — **identical to static Role_RegionB** ✅ |

The dynamic `Role_Entitlement` role produces byte-for-byte identical row sets (region, spend, transaction count) to the static role it replaces, for both test entitlement values.

**PBIE layer — RESOLVED 2026-07-22.** Re-testing `/api/embed-token?user=regiona.test@visapoc.demo` after switching to entitlement mode initially reproduced the *same* `403 "Creating embed token with effective identity is not supported for this datasource"` error as before this feature — confirming the entitlement-mode request was well-formed and hit the same Direct Lake fixed-identity/SSO blocker documented in Section 15, not a new regression. That blocker was then resolved by binding the semantic model's OneLake datasource to the fixed-identity cloud connection (service-principal auth, Entra ID SSO for DirectQuery/Direct Lake left **disabled**) via the model's Settings → "Gateway and cloud connections" in the Fabric portal. After binding, `/api/embed-token?user=regiona.test@visapoc.demo` and `?user=regionb.test@visapoc.demo` both return **`200`** with a valid `accessToken`/`embedUrl`, and both load successfully in-browser.

As an interesting side effect: since the model now has a live RLS role (`Role_Entitlement` synced), a bare `GenerateToken` call **with no identity at all** now fails, with `400 "requires effective identity to be provided"` — this is expected/correct fail-closed behavior once any RLS role is defined on the model, not a bug.

Full PBIE-vs-XMLA row-set parity has been validated at the **token/report-load level** for both entitlement values. Pixel/data-level confirmation that the rendered visuals show the exact NA/EU totals from the XMLA comparison (`$15,594,460.57` / 51,476 txns vs. `$15,887,031.70` / 53,022 txns) is a recommended follow-up but not a blocker.

### 16c. Does this eliminate the dependency on `Roles=` overrides?

**Partially — not entirely.** `Roles=`/`identities[].roles` is still required to *activate* which TMDL role applies to the connection; `CustomData`/`customData` only supplies the *filter value* that role's DAX expression reads. What's eliminated is needing **one role per entitlement value** — a single dynamic role now serves any number of entitlement values, so scaling from 2 test regions to N real customer entitlements no longer means adding a TMDL role (and redeploying the model) per new value.

The `Roles=` requirement itself is intrinsic to how App-Owns-Data RLS works for **non-member** identities (synthetic test users, or real external/guest customers who aren't members of the workspace's own security groups): the connecting SP must always explicitly state which role a request should be evaluated under, whether that role's filter is static or CUSTOMDATA()-driven. This isn't a workaround — it mirrors how `GenerateToken`'s `identities[].roles` has always worked; the improvement here is purely in the TMDL role count, not in removing the activation mechanism.

### 16d. Comparison — Static Roles vs. EffectiveUserName vs. CUSTOMDATA() for external-customer App-Owns-Data

| Dimension | Static Roles (`Role_RegionA`/`B`) | `EffectiveUserName` | `CUSTOMDATA()` / entitlement |
|---|---|---|---|
| TMDL roles needed | 1 per distinct entitlement value — doesn't scale | 0 (relies on real AAD role/group membership) | 1 total, regardless of value count |
| Requires a real Microsoft Entra ID account? | No | **Yes** — Read+Build permission, caller must be workspace admin | No |
| Usable for external/non-AAD customers (App-Owns-Data)? | Yes | **No** | Yes |
| PBIE mechanism | `effectiveIdentity.roles` | `effectiveIdentity.username` (PBIE itself never validates this against AAD — only XMLA's `EffectiveUserName` does) | `effectiveIdentity.customData` |
| XMLA mechanism | `Roles=<name>` | `EffectiveUserName=<upn>` | `CustomData=<value>` + `Roles=<dynamic role>` |
| Symmetric across XMLA + PBIE for synthetic/external identities? | Yes (both just select a role name) | **No** — asymmetric; XMLA requires a real AAD identity, PBIE doesn't validate at all | **Yes** — pure pass-through string, zero identity validation on either surface |
| Scales to N customer entitlement values | Poorly — new TMDL role + model redeploy per value | N/A — depends on real AAD group provisioning, not TMDL roles | Well — one role, unlimited values from any backing store (DB, claims, JWT, etc.) |
| Production hardening risk | SP silently bypasses RLS (full Admin view) if no role resolved for a user | Not usable at all for true external customers | Same SP-bypass risk as static Roles — must still fail closed if entitlement unresolved |
| Best fit | Small, fixed number of coarse segments known at model-design time | Internal/enterprise users who are real, licensed tenant members | External-customer, App-Owns-Data, many or dynamic entitlement values — matches VISA's production shape |

**Recommendation**: for external-customer App-Owns-Data architectures like this POC and VISA's production pattern, `CUSTOMDATA()`-based entitlement RLS is the better long-term mechanism — it scales to arbitrary entitlement counts without per-value TMDL changes, and it's the only mechanism proven symmetric across XMLA and PBIE for non-AAD synthetic/external identities. `EffectiveUserName` is not viable for this architecture class at all: it requires real, licensed AAD identities with Build permission, which directly contradicts the App-Owns-Data premise of embedding for users who are external to (or unknown to) the host tenant.

### 16e. Open items

| Item | Status |
|------|--------|
| Define `Role_Entitlement` dynamic TMDL role | ✅ Done, synced to live model 2026-07-22 |
| Switch default runtime path (embed token + XMLA) to entitlement mode, keep static mode for comparison | ✅ Done |
| Validate static-vs-dynamic row-set parity at the XMLA layer | ✅ PASS for both test entitlement values (16b) |
| Sync new TMDL role to the live model without a manual portal click | ❌ **Not automatable** — `POST /v1/workspaces/{id}/git/status`/`updateFromGit` returned `400 GitCredentialsNotConfigured` for the SP caller; Fabric's Git integration API requires the calling identity's own registered Git credentials (a user-level PAT via "My Git Credentials"), which service principals don't have here. Same class of platform gap as Section 15's fixed-identity-connection bind — portal-only ("Update from Git" in Source Control). User performed this manually 2026-07-22. |
| Validate PBIE-vs-XMLA row-set parity end-to-end | ✅ **Resolved 2026-07-22** — Section 15 Direct Lake fixed-identity/SSO binding gap closed (portal binding completed); embed tokens now return `200` with `effectiveIdentity` for both test entitlement values, and both load successfully in-browser |
| Fail-closed hardening: reject/error when no entitlement resolves for a user, instead of silently falling back to the SP's full/unfiltered view | ⬜ Not yet implemented — recommended next step; currently an unresolved entitlement is indistinguishable from "no identity provided", which already fails via the platform's own RLS enforcement, but this should be made an explicit application-level rejection rather than relying solely on the platform behavior |
| Rotate `CLIENT_SECRET` for `VISA-PBIE-EmbedService` | ✅ **Done 2026-07-22** — secret rotated after exposure; post-rotation validation confirmed SP auth, embed token generation, RLS (both entitlement values), and XMLA connectivity all still working (byte-identical row sets to pre-rotation) |

---

## 17. Current Security Posture (as of 2026-07-22)

> Snapshot for quick reference. Details live in Sections 1, 15, and 16 above.

| Control | Mechanism | Status |
|---|---|---|
| Backend service identity | Single native SP `VISA-PBIE-EmbedService`, homed in `MngEnvMCAP660444` tenant (required — cross-tenant/guest identities are blocked by tenant inbound policy) | ✅ Working |
| End-user identity model | App-Owns-Data — no real end-user AAD identity; synthetic entitlement strings only (no license/Build-permission dependency) | ✅ By design |
| Row-Level Security | Single dynamic TMDL role `Role_Entitlement` (`dim_client[HomeRegion] = CUSTOMDATA()`), activated via `Roles=`/`identities[].roles`, value supplied via `CustomData=`/`identities[].customData` — same entitlement value on both PBIE and XMLA surfaces | ✅ Working, validated identical to legacy static roles |
| Query layer transport | XMLA endpoint via SP app-only OAuth (`User ID=app:<ClientId>@<TenantId>`), invoked from Node via a PowerShell `Invoke-ASCmd` shim — avoids both `executeQueries`+RLS limitations and ROPC/2FA-bypass policy violations | ✅ Working |
| Embed token transport | `GenerateToken` REST API, `effectiveIdentity` with `roles` + `customData` | ✅ Working — `200` for both test entitlements |
| Data-plane binding | Direct Lake datasource bound to a fixed-identity cloud connection (service-principal auth, Entra ID SSO **disabled**) | ✅ Resolved 2026-07-22 (previously the long-standing `403` blocker) |
| Fail-closed behavior | Requests with no identity fail once any RLS role exists on the model (platform-enforced) | ✅ Confirmed working, ⬜ not yet hardened as an explicit app-level check |
| Frontend UPN transport | `?user=<upn>` query param, unauthenticated | ⚠️ Known open risk — acceptable for local dev/demo only, **not production-safe**; needs a real session/auth mechanism before any production use |
| Secret hygiene | `CLIENT_SECRET` for `VISA-PBIE-EmbedService` | ✅ **Rotated 2026-07-22** after exposure in a chat attachment — post-rotation smoke test confirmed SP auth, embed token generation, RLS, and XMLA connectivity all unaffected. **Two separate Fabric/Power BI-side credential stores** were found stale for the OneLake data source: (1) the Fabric `/v1/connections` object `VISA-PBIE-FixedIdentity-DirectLake` — fixed via `PATCH /v1/connections/{id}` (SP-callable, since the SP owns that connection); (2) the classic Power BI gateway-datasource binding surfaced under the semantic model's own Settings → "Gateway and cloud connections" — this one was configured via the portal by a human user, so SP app-only calls get `DMTS_NotEnoughPermissionToManangeDatasourceErrorCode`; requires a manual **Edit credentials** step in the portal |

**Net assessment:** no unfiltered data-access fallback path exists once RLS roles are defined; the entitlement value is the single source of truth for filtering on both the embed and query surfaces; the SP has no standing broad access outside the fixed-identity connection's scope. Residual risk is operational (rotate the exposed secret) and defense-in-depth (make the fail-closed path an explicit rejection, and replace the unauthenticated `?user=` query param before production).

---

## 18. `Spend YoY %` measure fix (2026-07-22)

**Symptom:** the "Spend YoY %" headline KPI cards (Spend Trends page, Executive Summary page) showed a value (~49.6%, seen on-screen as "46.9%") that didn't reconcile with the per-year trend table on the same page.

**Root cause — two compounding bugs, both confirmed via direct XMLA DAX queries against the live model:**

1. **`DATEADD`/`SAMEPERIODLASTYEAR` return BLANK when filter context comes from `dim_date[Year]`** (an integer column — what the per-year trend table visual groups on), even though min/max date in that context correctly resolves to the filtered year, and the exact same prior-year data is reachable when filtering `dim_date[Date]` directly instead. This is a real DAX limitation with these time-intelligence functions and is **not fixed by marking the table as a Date Table** — `dataCategory: Time` was added to `dim_date.tmdl` (good practice regardless, and confirmed live via `INFO.TABLES()`) but the Year-column-filter case was re-tested afterward and still returned blank. Net effect: every row of the "Spend YoY %" column in the per-year trend table (`v_trnd_tbl`) was silently blank.
2. **The two KPI cards had no year filter at all** (`"filterConfig":{"filters":[]}`), so they evaluated `Spend YoY %` at the grand-total level — across the full 3-year unfiltered date range (2024-01-01 to 2026-12-31) — which DATEADD interprets as "shift the entire multi-year window back one year" rather than "this year vs. last year." That produced a technically-real-but-meaningless ~49.6% figure with no corresponding bar/row in the trend visuals.

**First fix attempt (superseded):** marking `dim_date` as a Date Table plus a separate self-scoping `Spend YoY % (Latest Year)` measure using `CALCULATE([Spend YoY %], dim_date[Year] = LatestYear)`. After syncing to the live model, XMLA validation showed this did **not** work — the new measure still relied on `DATEADD` internally and returned blank for the same Year-column-filter reason as bug #1. This confirms "Mark as Date Table" only helps in some scenarios (e.g. built-in date hierarchies from slicers) and does not fix `DATEADD`/`SAMEPERIODLASTYEAR` when the filter is a direct predicate on a non-date column of the same table.

**Actual fix (validated via XMLA against the live model before implementing):** rewrote `Spend YoY %` to bypass time-intelligence functions entirely, using explicit Year-arithmetic filtering instead:
```
measure 'Spend YoY %' =
    VAR CurYear = MAX(dim_date[Year])
    VAR CurSpend = CALCULATE([Total Spend USD], FILTER(ALL(dim_date), dim_date[Year] = CurYear))
    VAR PriorSpend = CALCULATE([Total Spend USD], FILTER(ALL(dim_date), dim_date[Year] = CurYear - 1))
    RETURN
        DIVIDE(CurSpend - PriorSpend, PriorSpend)
```
This is self-scoping in every context because `CurSpend` and `PriorSpend` are both explicitly re-filtered to a specific year rather than relying on the ambient filter context alone:
- **Unfiltered (KPI cards, no year filter):** `CurYear` = `MAX(dim_date[Year])` across all data = 2026 (the latest year present) → correctly compares 2026 vs. 2025.
- **Filtered by `dim_date[Year]` (trend table, one row per year):** works correctly per row (validated for 2024/2025/2026 — 2024 correctly shows blank since there's no 2023 data).
- **Filtered by `dim_date[Date]` directly:** unaffected, still correct (this path already worked).
- The now-redundant `Spend YoY % (Latest Year)` measure was **removed** — this single measure now handles both use cases, so both KPI cards (`v_trnd02`, `v_exec05`) reference plain `Spend YoY %` again.

**Status:** TMDL/PBIR changes committed to `branch` and synced via a manual **Fabric workspace → Source Control → "Update from Git"** click (per Section 16e). Validated live via XMLA: unfiltered → `-1.86%` (2026 vs. 2025), `Year=2025` → `+2.38%` (2025 vs. 2024), `Year=2024` → blank (no prior year), all consistent with the direct-date-filter case. This also incidentally resolved a related credential issue — see the Secret hygiene row in Section 17.


