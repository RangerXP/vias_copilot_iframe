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

- [ ] Microsoft Fabric workspace with at least one published semantic model
- [ ] Azure AI Foundry project (or access to create one)
- [ ] Power BI Embedded capacity OR Premium Per User license for embed tokens
- [ ] Node.js 20+ installed locally
- [ ] Azure CLI installed and authenticated
- [ ] Fabric Data Agent provisioned against target semantic model

---

## Getting Started

1. Read [docs/fabric_model_discovery.md](docs/fabric_model_discovery.md) — identify the target semantic model
2. Read [docs/local_server_setup.md](docs/local_server_setup.md) — run the local PBIE server
3. Follow [project_plan.md](project_plan.md) Sprint 1 to validate iframe context capture
4. Follow [docs/fabric_agent_config.md](docs/fabric_agent_config.md) to wire the Fabric Data Agent

---

## Project Status

| Sprint | Name | Status |
|--------|------|--------|
| Sprint 1 | Local PBIE Server + Iframe Render | **Ready to start** — all IDs confirmed |
| Sprint 2 | Context Capture to JSON | Not Started |
| Sprint 3 | Fabric Data Agent Integration | Not Started |
| Sprint 4 | Foundry Agent + Context Injection | Not Started |
| Sprint 5 | Semantic Query Layer | Not Started |
| Sprint 6 | Demo Build + Talking Points | Not Started |
