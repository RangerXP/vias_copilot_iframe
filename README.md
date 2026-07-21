# MSIE Power BI Embedded — Context-Aware AI Assistant

## Project: Pattern 2 — Host-App Filter Injection + FilterSession Grounding

This project implements a **local Power BI Embedded (PBIE) development server** that serves iframe-embedded analytics powered by a **Fabric Direct Lake semantic model**, with a **Fabric Data Agent** as the semantic query layer and **Azure AI Foundry** for conversational reasoning.

The host application owns the filter/prompt experience. Report context is persisted to `Fact_FilterSession` in the Fabric Lakehouse, giving the agent governed, queryable grounding data rather than a DOM snapshot.

---

## Quick Navigation

| File | Purpose |
|------|---------|
| [build_guide.md](build_guide.md) | Source pattern definition |
| [docs/design_notes.md](docs/design_notes.md) | **Implementation reference** — SP setup, token management, PBIR schemas, AAD quirks |
| [project_plan.md](project_plan.md) | Sprint-by-sprint development roadmap |
| [docs/architecture.md](docs/architecture.md) | Full system architecture with Fabric integration |
| [docs/local_server_setup.md](docs/local_server_setup.md) | Local PBIE dev server setup — confirmed IDs, SP details, troubleshooting |
| [docs/pattern1_iframe_injection.md](docs/pattern1_iframe_injection.md) | Context capture and filter injection spec |
| [docs/fabric_agent_config.md](docs/fabric_agent_config.md) | Fabric Data Agent configuration |
| [docs/demo_script.md](docs/demo_script.md) | Demo walkthrough and talking points |
| [semantic/model_metadata.md](semantic/model_metadata.md) | Confirmed Fabric workspace item IDs and model schema |

---

## What We Are Building

A **Copilot-like experience for Power BI Embedded** that works without native Copilot support inside the PBIE iframe.

```text
VISA Partner Portal (host app)
  │
  ├── Custom filter/prompt UI
  │     └── report.setFilters()  ──────────────► PBIE iframe (Direct Lake report)
  │     └── POST /api/session    ──────────────► Fact_FilterSession (Fabric Lakehouse)
  │                                                      │
  └── Chat panel                                         ▼
        └── POST /api/chat                    Fabric Data Agent
              └── filter state as context  ◄──── queries semantic model
                    └── Azure AI Foundry Agent
```

---

## Confirmed Fabric Stack (live as of 2026-07-21)

| Item | Name | ID |
|------|------|----|
| Workspace | `VISA PBIE Context Injection` | `349db6f1-5df6-4992-ba67-ebc4449fead5` |
| Lakehouse | `Commercial_Spend_Analytics` | `1aa73044-f85f-4843-b3e5-588cab4c0499` |
| Semantic Model | `Commercial_Spend_Analytics` | `b7bc94fc-a087-4e71-9476-f128ba57cf3a` |
| Report | `Commercial_Spend_Analytics` | `e833a03b-2cf9-42d2-a1ee-a40f847fd75d` |
| Data Agent | `Commercial_Spend_Agent` | `d2042f7c-989f-47d2-a3b4-92603f3e55ab` |
| Capacity | `fabcmksettlement` | `cb113ec9-926c-4af4-99fe-0b5b55fb69b6` |

**250,000** synthetic commercial spend rows · 8 dimension tables · 9 DAX measures · Direct Lake storage mode

**SP:** `VISA-PBIE-EmbedService` (`595278db`) — Admin in workspace · embed token confirmed 200

---

## Key Design Decisions

| Decision | Choice | Reason |
|----------|--------|--------|
| Context ownership | Host app (Pattern 2) | Avoids PBIE slicer sync issues; full filter state control |
| Semantic model | Direct Lake over Fabric Lakehouse | Governed, production-grade; Delta tables, no import latency |
| Model access layer | Fabric Data Agent (`Commercial_Spend_Agent`) | Natural language → DAX over semantic model |
| Grounding mechanism | `Fact_FilterSession` persisted to Lakehouse | Agent queries structured filter history, not DOM/screenshot |
| Iframe token | PBIE App-Owns-Data (SP client credentials) | No per-user sign-in; effectiveIdentity enforces RLS at report layer |
| Token endpoint | Multi-resource `GenerateToken` API | Confirmed working with SP Admin workspace role |
| AI reasoning | Azure AI Foundry Agent | Prompt orchestration, conversation memory, tool calling |
| Local server | Node.js / Express | Lightweight, easy iframe hosting, portable |

---

## Getting Started

```bash
# 1. Clone and install
git clone https://github.com/RangerXP/vias_copilot_iframe.git
cd vias_copilot_iframe
npm install

# 2. Configure environment
cp .env.example .env
# Fill in CLIENT_SECRET — all other values are pre-populated with confirmed IDs

# 3. Start server
npm run dev
# Open http://localhost:3000
```

See [docs/local_server_setup.md](docs/local_server_setup.md) for SP credential setup and troubleshooting.

> **Note on CLIENT_SECRET:** After `az ad app credential reset`, wait **35–40 seconds** before the new secret is valid. See [docs/design_notes.md](docs/design_notes.md) Section 14.

---

## Repository Branches

| Branch | Purpose |
|--------|---------|
| `main` | Project source — Node.js server, frontend, scripts, docs |
| `branch` | Fabric Git integration — TMDL, Report PBIR definition, DataAgent config |

Fabric auto-commits land on `branch`. `main` is merged into `branch` to keep them in sync.

---

## Project Status

| Sprint | Name | Status |
|--------|------|--------|
| Sprint 1 | Local PBIE Server + Iframe Render | **Ready to run** — SP + `.env` confirmed, `npm run dev` unblocked |
| Sprint 2 | Context Capture + Filter Injection | **Scaffolded** — `captureContext.js`, `setFilters()` wiring built |
| Sprint 3 | Fabric Data Agent Integration | **Agent live** — `fabricAgent.js` scaffolded, agent ID confirmed |
| Sprint 4 | Foundry Agent + Context Injection | **Scaffolded** — tool call routing + provisioning script built |
| Sprint 5 | Semantic Query Layer | Not Started |
| Sprint 6 | Demo Build + Talking Points | Not Started |

**Auth boundary:** SP (`VISA-PBIE-EmbedService`) generates all Fabric/PBI tokens. `effectiveIdentity` scopes embed tokens to the requesting user's UPN for RLS enforcement. Path A (user-delegated) not required for demo.
