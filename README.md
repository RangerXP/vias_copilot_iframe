# MSIE Power BI Embedded — Context-Aware AI Assistant

## Project: Pattern 1 — Context Injection Agent

This project implements a **local Power BI Embedded (PBIE) development server** that serves iframe-embedded analytics powered by a **Fabric semantic model**, with a **Fabric Data Agent** as the semantic model access layer and **Azure AI Foundry** for conversational reasoning.

---

## Quick Navigation

| File | Purpose |
|------|---------|
| [build_guide.md](build_guide.md) | Source pattern definition (Pattern 1) |
| [docs/design_notes.md](docs/design_notes.md) | **Customer handoff** — implementation requirements, token management, SP setup, constraints |
| [project_plan.md](project_plan.md) | Sprint-by-sprint development roadmap |
| [docs/architecture.md](docs/architecture.md) | Full system architecture with Fabric integration |
| [docs/local_server_setup.md](docs/local_server_setup.md) | Local PBIE dev server setup and iframe deployment |
| [docs/pattern1_iframe_injection.md](docs/pattern1_iframe_injection.md) | Pattern 1 detailed implementation spec |
| [docs/fabric_model_discovery.md](docs/fabric_model_discovery.md) | Fabric semantic model discovery and connection |
| [docs/fabric_agent_config.md](docs/fabric_agent_config.md) | Fabric Data Agent configuration guide |
| [docs/demo_script.md](docs/demo_script.md) | Demo walkthrough and talking points |
| [semantic/model_metadata.md](semantic/model_metadata.md) | Discovered semantic model metadata (fill per model) |

---

## What We Are Building

A **Copilot-like experience for Power BI Embedded** that works without native Copilot support inside the PBIE iframe.

```text
Browser
  │
  ├── PBIE iframe  ──────────────► Power BI Embed / REST API
  │     (renders report,               (App-Owns-Data token)
  │      reports page/filter state)
  │
  └── AI Chat Panel ──► Node.js/Express backend ──► Azure AI Foundry Agent
        (conversationId,        (context service:              │
         question)               field_map.json)                ▼
                                                     query_semantic_model tool
                                                                  │
                                                                  ▼
                                            Power BI executeQueries REST API
                                                                  │
                                                                  ▼
                                         Fabric Semantic Model (Direct Lake,
                                         Commercial_Spend_Analytics, 250K rows)
```

The local dev server proves out the architecture before any cloud deployment.

---

## Key Design Decisions

| Decision | Choice | Reason |
|----------|--------|--------|
| Semantic model source | Microsoft Fabric (Direct Lake, `Commercial_Spend_Analytics`) | Governed, production-grade model |
| Model access layer | Power BI `executeQueries` REST API (direct DAX) | Fabric Data Agent has no public query REST endpoint (CRUD only) — pivoted to direct DAX execution via the Foundry agent's tool |
| Iframe token source | PBIE App-Owns-Data embed token | Supports enterprise tenant without user sign-in per session |
| AI reasoning layer | Azure AI Foundry Agent | Prompt orchestration, multi-turn conversation memory (conversationId → thread), tool calling |
| Local server runtime | Node.js / Express | Lightweight, easy iframe hosting, portable |
| Context injection | Pattern 1 (from build_guide.md) | Proved pattern, no PBIE runtime modification needed |

---

## Prerequisites

- [x] Microsoft Fabric workspace — `VISA PBIE Context Injection` confirmed (`349db6f1`)
- [x] Power BI Embedded capacity — `fabcmksettlement` (`cb113ec9-926c-4af4-99fe-0b5b55fb69b6`)
- [x] Node.js 20+ installed and `npm install` run
- [x] Azure CLI installed and authenticated
- [x] Fabric tenant policy `ElevatedGuestsTenant` enabled
- [x] Service principal registered (`VISA-PBIE-EmbedService`, `595278db`) — Admin in workspace, embed token confirmed working
- [x] Fabric Data Agent provisioned (`Commercial_Spend_Agent`) — no public query REST API; pivoted to Power BI `executeQueries` for grounded queries
- [x] Azure AI Foundry project created — `visa-pbie-context` (West US 3, `visa-pbie-context-rsc`), agent `pbie-context-agent` on `gpt-5.1`

---

## Getting Started

1. Copy `.env.example` → `.env` and fill in `CLIENT_ID` + `CLIENT_SECRET` from the `VISA-PBIE-EmbedService` service principal
2. `npm run dev` — starts the local Express server on `http://localhost:3000`
3. Read [docs/local_server_setup.md](docs/local_server_setup.md) for troubleshooting
4. Open `http://localhost:3000` — the iframe renders the live report and the Analytics Assistant chat panel is wired to the Foundry agent
5. To re-provision the Foundry agent (e.g. after moving regions), run `node scripts/provision-foundry-agent.js` and update `FOUNDRY_AGENT_ID` in `.env`

---

## Repository

**GitHub:** https://github.com/RangerXP/vias_copilot_iframe

---

## Project Status

| Sprint | Name | Status |
|--------|------|--------|
| Sprint 1 | Local PBIE Server + Iframe Render | **Complete** — embed token confirmed, iframe renders live report |
| Sprint 2 | Context Capture to JSON | **Complete** — context flows end-to-end into Foundry agent prompts |
| Sprint 3 | Fabric Data Agent Integration | **Complete** (pivoted) — Power BI `executeQueries` used in place of Data Agent REST (no public query API exists) |
| Sprint 4 | Foundry Agent + Context Injection | **Complete** — end-to-end validated: chat → Foundry agent (`gpt-5.1`) → tool call → real data → natural-language answer |
| Sprint 5 | Semantic Query Layer Refinement | **Complete** — 10 DAX query shapes, `field_map.json` rewrite, context service, multi-turn conversation memory (conversationId → Foundry thread) |
| Sprint 6 | Demo Build + Talking Points | **Complete** — `docs/demo_script.md` rewritten against the live `Commercial_Spend_Analytics` report and real validated data |

**All 6 sprints complete.** The project is demo-ready end-to-end: iframe → context capture → Foundry agent → live semantic model query → natural-language answer, with multi-turn memory.

**Auth boundary:** Path B active (SP + effectiveIdentity + context injection) for embed tokens. Fabric semantic model queries use `DefaultAzureCredential` (delegated user token) — SP client-credentials blocked until tenant Power BI admin enables service-principal API access.
