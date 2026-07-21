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
  ├── PBIE iframe  ←── Fabric Semantic Model (via Fabric Data Agent)
  │
  └── AI Chat Panel ←── Azure AI Foundry Agent ←── Fabric Data Agent
                                                         │
                                                    Fabric Semantic Model
```

The local dev server proves out the architecture before any cloud deployment.

---

## Key Design Decisions

| Decision | Choice | Reason |
|----------|--------|--------|
| Semantic model source | Microsoft Fabric (existing workspace) | Governed, production-grade model |
| Model access layer | Fabric Data Agent | Natural language + DAX query over semantic model without raw API |
| Iframe token source | PBIE App-Owns-Data embed token | Supports enterprise tenant without user sign-in per session |
| AI reasoning layer | Azure AI Foundry Agent | Prompt orchestration, conversation memory, tool calling |
| Local server runtime | Node.js / Express | Lightweight, easy iframe hosting, portable |
| Context injection | Pattern 1 (from build_guide.md) | Proved pattern, no PBIE runtime modification needed |

---

## Prerequisites

- [x] Microsoft Fabric workspace — VISA workspace, `Visa Slicer Demo v2` confirmed
- [x] Power BI Embedded capacity — `fabcmksettlement` (`cb113ec9-926c-4af4-99fe-0b5b55fb69b6`)
- [x] Node.js 20+ installed and `npm install` run
- [x] Azure CLI installed and authenticated
- [x] Fabric tenant policy `ElevatedGuestsTenant` enabled
- [ ] Service principal registered in `MngEnvMCAP660444` (blocked on customer tenant admin)
- [ ] Fabric Data Agent provisioned against `Visa Slicer Demo v2`
- [ ] Azure AI Foundry project created

---

## Getting Started

1. Copy `.env.example` → `.env` and fill in `CLIENT_ID` + `CLIENT_SECRET` once the service principal is issued
2. `npm run dev` — starts the local Express server on `http://localhost:3000`
3. Read [docs/local_server_setup.md](docs/local_server_setup.md) for troubleshooting
4. Once SP is issued: validate the iframe renders the VISA report (Sprint 1 validation)
5. Run `node scripts/provision-foundry-agent.js` once a Foundry project endpoint is available

---

## Repository

**GitHub:** https://github.com/RangerXP/vias_copilot_iframe

---

## Project Status

| Sprint | Name | Status |
|--------|------|--------|
| Sprint 1 | Local PBIE Server + Iframe Render | **Scaffolded** — blocked on SP credentials |
| Sprint 2 | Context Capture to JSON | **Scaffolded** (`captureContext.js` built) |
| Sprint 3 | Fabric Data Agent Integration | **Scaffolded** — blocked on agent provisioning |
| Sprint 4 | Foundry Agent + Context Injection | **Scaffolded** — tool call routing + provisioning script done |
| Sprint 5 | Semantic Query Layer | Not Started |
| Sprint 6 | Demo Build + Talking Points | Not Started |

**Auth boundary:** Path B active (SP + effectiveIdentity + context injection). Path A (user-delegated) gated on SP registration. `ElevatedGuestsTenant` Fabric policy enabled 2026-07-21.
