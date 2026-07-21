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

The local server uses **App-Owns-Data** embedding, meaning it generates embed tokens on behalf of the application, not the end user.

### Required API Permissions (Entra ID App Registration)

| Permission | Type | Purpose |
|-----------|------|---------|
| `Power BI Service / Report.Read.All` | Application | Read reports for embed |
| `Power BI Service / Dataset.Read.All` | Application | Access semantic model |
| `Fabric / Item.Read.All` | Application | Access Fabric items |

### Add Service Principal to Fabric Workspace

In the Fabric workspace settings, add the service principal as a **Member** (not Viewer — embed tokens require Member or higher).

### Local `.env` File

```env
# Power BI / Fabric — MngEnvMCAP660444 tenant (CONFIRMED)
TENANT_ID=b7e47691-9726-4f67-a302-e567815f3522
CLIENT_ID=<service-principal-app-id>  # register SP in MngEnvMCAP660444 tenant
CLIENT_SECRET=<service-principal-secret>

# VISA workspace — CONFIRMED
WORKSPACE_ID=8dd24078-9814-4e5d-a26c-3713092564bd
REPORT_ID=daed8d4d-2dc3-4708-ad82-5611c667498c
DATASET_ID=5686371f-58c7-453f-89c8-26b0e2fb7f9d

# Fabric Data Agent
FABRIC_AGENT_ENDPOINT=<fabric-data-agent-url>
FABRIC_AGENT_ID=<fabric-data-agent-id>

# Foundry
FOUNDRY_PROJECT_ENDPOINT=<foundry-project-endpoint>
FOUNDRY_AGENT_ID=<foundry-agent-id>

# Server
PORT=3000
```

> **Never commit `.env` to git.** Add `.env` to `.gitignore` immediately.

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
│       ├── fabricAgent.js    ← Fabric Data Agent client
│       └── foundryAgent.js   ← Azure AI Foundry client
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

## Embed Token Generation — `server/routes/embedToken.js`

```javascript
import express from 'express';
import { getEmbedToken } from '../services/pbiClient.js';

const router = express.Router();

router.get('/', async (req, res) => {
  try {
    const token = await getEmbedToken({
      workspaceId: process.env.WORKSPACE_ID,
      reportId: process.env.REPORT_ID,
      datasetId: process.env.DATASET_ID
    });
    res.json(token);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

export default router;
```

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

```javascript
let embeddedReport = null;

async function loadReport() {
  const res = await fetch('/api/embed-token');
  const { accessToken, embedUrl, reportId } = await res.json();

  const models = window['powerbi-client'].models;

  const config = {
    type: 'report',
    tokenType: models.TokenType.Embed,
    accessToken,
    embedUrl,
    id: reportId,
    settings: {
      filterPaneEnabled: true,
      navContentPaneEnabled: true
    }
  };

  const reportContainer = document.getElementById('report-container');
  embeddedReport = window.powerbi.embed(reportContainer, config);

  embeddedReport.on('loaded', () => {
    console.log('[PBIE] Report loaded');
    window.dispatchEvent(new Event('reportReady'));
  });
}

export function getReport() {
  return embeddedReport;
}

loadReport();
```

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
| 401 on embed token | Service principal not added to workspace | Add SP as Member in Fabric workspace settings |
| Blank iframe | Invalid embed URL or report ID | Verify REPORT_ID in `.env` |
| 403 on Fabric API | Tenant data plane access disabled | Enable Fabric REST API in tenant admin settings |
| `powerbi is not defined` | CDN not loaded | Check internet access or host the library locally |
| Token expired mid-session | Default 1hr embed token | Implement token refresh on `tokenExpired` event |
