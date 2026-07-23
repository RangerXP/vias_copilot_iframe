# Local PBIE Server Setup

## Purpose

This document walks through standing up a **local Node.js / Express server** that hosts a Power BI Embedded iframe using an App-Owns-Data embed token sourced from a **Fabric-backed semantic model**.

The local server is the Pattern 1 development environment — it replaces the eventual MSIE portal for dev and demo purposes.

---

## Prerequisites

| Requirement | Notes |
|------------|-------|
| Node.js 20+ | `node --version` to verify |
| Azure CLI | `az --version` to verify |
| Service principal | Entra ID app registration with Power BI API permissions |
| Fabric workspace access | At minimum, Viewer on the target workspace |
| Capacity license | Premium Per User or Fabric/Power BI Embedded capacity |

---

## Service Principal Setup

The local server uses **App-Owns-Data** embedding — the SP generates embed tokens on behalf of the application, not the end user.

### Confirmed SP — `VISA-PBIE-EmbedService` (registered 2026-07-21)

| Field | Value |
|-------|-------|
| App display name | `VISA-PBIE-EmbedService` |
| Client ID | `595278db-8070-426d-85b5-7933db47de2c` |
| SP Object ID | `9ee7391e-9fac-4bc5-ac1b-79e083aa76bd` |
| Workspace role | **Admin** in `VISA PBIE Context Injection` (`349db6f1`) |

SP was added to the workspace via the **Fabric roleAssignments API** (not the Power BI workspace users API — that returns 403 during AAD propagation). See `docs/design_notes.md` Section 1 for the full `az` CLI registration sequence and Section 14 for the AAD credential timing quirk.

**Admin consent is NOT required** for the client_credentials token flow. Adding the Power BI Service resource to the app registration is sufficient.

### GenerateToken endpoint and effectiveIdentity

The server uses the **multi-resource `GenerateToken` endpoint** (confirmed working):

```
POST https://api.powerbi.com/v1.0/myorg/GenerateToken
```

**Updated 2026-07-22:** identity is resolved from the server-managed session (`req.session.customerId`, established via `POST /api/session/login` — see §17 in `docs/design_notes.md`), never from a client-supplied query param. When a session exists, the embed token includes an `identities[]` block (effectiveIdentity) driven by the session's resolved entitlement. This scopes the report to that customer's data access — RLS is enforced at the Power BI engine layer, and the backend never sees raw data. See `server/services/pbiClient.js`, `server/routes/session.js`, and `server/routes/embedToken.js`.

### Local `.env` File

All IDs below are confirmed production values for the Pattern 2 `VISA PBIE Context Injection` workspace.

```env
# Power BI / Fabric — MngEnvMCAP660444 tenant
TENANT_ID=b7e47691-9726-4f67-a302-e567815f3522
CLIENT_ID=595278db-8070-426d-85b5-7933db47de2c
CLIENT_SECRET=<from secure store — never commit>

# VISA PBIE Context Injection workspace (Pattern 2)
WORKSPACE_ID=349db6f1-5df6-4992-ba67-ebc4449fead5
REPORT_ID=e833a03b-2cf9-42d2-a1ee-a40f847fd75d
DATASET_ID=b7bc94fc-a087-4e71-9476-f128ba57cf3a
AGENT_ID=d2042f7c-989f-47d2-a3b4-92603f3e55ab
LAKEHOUSE_ID=1aa73044-f85f-4843-b3e5-588cab4c0499

# Server
PORT=3000
```

> **Never commit `.env` to git.** It is listed in `.gitignore`. Use `.env.example` as the committed template.

---

## Project Directory Structure

```
pbie-context-agent/
│
├── server/
│   ├── index.js              ← Express entry point
│   ├── routes/
│   │   ├── embedToken.js     ← GET /api/embed-token
│   │   ├── chat.js           ← POST /api/chat
│   │   └── context.js        ← POST /api/context
│   └── services/
│       ├── pbiClient.js      ← Power BI REST API wrapper
│       ├── contextService.js ← PBIE → business context translation
│       └── fabricAgent.js    ← Fabric Data Agent client (called directly from chat.js)
│
├── frontend/
│   ├── index.html            ← Iframe host shell
│   ├── embed.js              ← powerbi-client embed logic
│   ├── chat.js               ← Chat panel UI
│   └── context-capture/
│       └── captureContext.js ← Reads PBIE report state
│
├── semantic/
│   ├── dax/                  ← Example DAX for agent tool calls
│   └── metadata/
│       └── field_map.json    ← PBIE field name → business name
│
├── .env                      ← Local secrets (gitignored)
├── .env.example              ← Template for .env
├── .gitignore
└── package.json
```

---

## Server Bootstrap — `server/index.js`

```javascript
import express from 'express';
import cors from 'cors';
import dotenv from 'dotenv';
import embedTokenRoute from './routes/embedToken.js';
import chatRoute from './routes/chat.js';
import contextRoute from './routes/context.js';

dotenv.config();

const app = express();
app.use(cors({ origin: 'http://localhost:3000' }));
app.use(express.json());
app.use(express.static('../frontend'));

app.use('/api/embed-token', embedTokenRoute);
app.use('/api/chat', chatRoute);
app.use('/api/context', contextRoute);

app.listen(process.env.PORT || 3000, () => {
  console.log(`PBIE local server running on http://localhost:${process.env.PORT || 3000}`);
});
```

---

## Embed Token Route — `server/routes/embedToken.js`

**Updated 2026-07-22 (docs/design_notes.md §17):** identity comes from `req.session.customerId`, established by a prior `POST /api/session/login` call — never from a query param or request body. The route fails closed (`401`/`403`) if there's no session or the session's customer doesn't resolve to a known entitlement, before ever calling `GenerateToken`.

```javascript
router.get('/', async (req, res) => {
  const customerId = req.session.customerId;
  if (!customerId) return res.status(401).json({ error: 'Not signed in.' });

  const customData = resolveEntitlement(customerId);
  if (!customData) return res.status(403).json({ error: `No entitlement resolved for customer '${customerId}'.` });

  const userIdentity = { username: customerId, roles: [ENTITLEMENT_ROLE_NAME], customData };
  const token = await getEmbedToken({
    workspaceId: process.env.WORKSPACE_ID,
    reportId: process.env.REPORT_ID,
    datasetId: process.env.DATASET_ID,
    userIdentity
  });
  res.json(token);
});
```

> **Production note:** this PoC's `POST /api/session/login` accepts a bare `customerId` as a stand-in for a real Visa Portal login. Production should validate an MSAL.js-acquired Entra ID token (or existing portal SSO session) before establishing `req.session` — the rest of the pipeline (session → resolved entitlement → `CUSTOMDATA()`) stays the same.

---

## Frontend Iframe Shell — `frontend/index.html`

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>PBIE Context Agent — Dev</title>
  <script src="https://cdn.jsdelivr.net/npm/powerbi-client@2/dist/powerbi.min.js"></script>
  <link rel="stylesheet" href="styles.css">
</head>
<body>
  <div id="app-container">
    <div id="report-container"></div>
    <div id="chat-container">
      <div id="chat-history"></div>
      <div id="chat-input-row">
        <input id="chat-input" type="text" placeholder="Ask about this report...">
        <button id="send-btn">Send</button>
      </div>
    </div>
  </div>
  <script type="module" src="embed.js"></script>
  <script type="module" src="chat.js"></script>
</body>
</html>
```

---

## Embed Logic — `frontend/embed.js`

**Updated 2026-07-22:** the frontend no longer holds or transmits any user identifier. `frontend/session.js` establishes the session cookie via `POST /api/session/login` (a PoC stand-in for real portal/MSAL.js login), and every embed-token fetch — including the silent `tokenExpired` refresh — just sends `credentials: 'include'` so the cookie rides along automatically.

```javascript
embeddedReport.on('tokenExpired', async () => {
  const refreshData = await fetch('/api/embed-token', { credentials: 'include' }).then(r => r.json());
  await embeddedReport.setAccessToken(refreshData.accessToken);
});
```

See `frontend/embed.js` for the full implementation.

---

## Running the Server

```bash
cd pbie-context-agent
npm install
node server/index.js
```

Open `http://localhost:3000` — the embedded report should render.

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| 401 on embed token | SP not added to workspace | Confirm SP is Admin via Fabric roleAssignments API (not PBI workspace users API) |
| `AADSTS7000215` on SP token | AAD credential not yet propagated | Wait 35–40 seconds after `az ad app credential reset` before requesting token. See design_notes Section 14. |
| `GenerateToken failed (403)` | SP not in workspace or wrong role | SP needs Admin or Member. Verify via Fabric portal → workspace → Manage access |
| Blank iframe | Invalid embed URL or wrong IDs | Confirm `REPORT_ID`, `WORKSPACE_ID`, `DATASET_ID` in `.env` match Pattern 2 values |
| 403 on Fabric API | Tenant data plane access | Fabric REST API is enabled in this tenant — check token scope (`api.fabric.microsoft.com/.default`) |
| `powerbi is not defined` | CDN not loaded | Check internet access; the `powerbi-client` CDN link is in `frontend/index.html` |
| Token expired mid-session | 1hr embed token default | `embed.js` handles `tokenExpired` automatically — UPN is re-sent to preserve effectiveIdentity |
