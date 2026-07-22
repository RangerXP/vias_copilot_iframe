# MSIE Power BI Embedded — Context-Aware AI Assistant

## Project: Pattern 1 — Context Injection Agent

This project implements a **local Power BI Embedded (PBIE) development server** that serves iframe-embedded analytics powered by a **Fabric semantic model**, with a **Fabric Data Agent** as the semantic model access layer and **Azure AI Foundry** for conversational reasoning.

---

## The Problem

Power BI Embedded reports rendered inside a third-party iframe have no native Copilot/chat experience — end users can see charts and filters, but they can't ask natural-language questions about what's on screen, and the host application has no way to ground an AI assistant in the same data (and the same row-level security) that the report itself enforces. Standing up that experience safely requires solving several problems at once: how to query the semantic model programmatically without bypassing RLS, how to keep the chat agent's answers consistent with what's rendered in the report, and how to do all of this for external/synthetic customer identities that don't have real Microsoft Entra ID accounts (App-Owns-Data, not user sign-in).

## The Solution

A Node.js/Express server hosts the PBIE iframe alongside a chat panel. The chat panel captures the report's current page/filter context and sends it to an **Azure AI Foundry agent**, which answers questions by querying the same **Fabric Direct Lake semantic model** (`Commercial_Spend_Analytics`) the report itself is built on — via the **XMLA endpoint** (service-principal, app-only OAuth) rather than the more limited `executeQueries` REST API. Row-Level Security is enforced identically on both surfaces through a single dynamic TMDL role (`Role_Entitlement`, driven by `CUSTOMDATA()`), so the same entitlement value scopes both the rendered report and the agent's query results — no unfiltered fallback path exists on either surface. The result is a Copilot-like chat experience layered on top of an embedded report, fully consistent with what the user is authorized to see, without requiring native Copilot support inside the iframe or real end-user Entra ID identities.

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
| Model access layer | XMLA endpoint via PowerShell `Invoke-ASCmd` shim (SP app-only OAuth) | Matches Microsoft's own guidance for RLS-enabled scenarios; `executeQueries` + SPN hits known limitations under RLS at scale (see [docs/design_notes.md](docs/design_notes.md) §15) |
| Row-Level Security | Single dynamic TMDL role `Role_Entitlement` (`CUSTOMDATA()`-driven), activated via `Roles=`/`identities[].roles` | Scales to any number of entitlement values without new TMDL roles per value; symmetric across XMLA and PBIE — see [docs/design_notes.md](docs/design_notes.md) §16 |
| Iframe token source | PBIE App-Owns-Data embed token, `effectiveIdentity` with `roles` + `customData` | Supports enterprise tenant without user sign-in per session, while still enforcing per-entitlement RLS |
| AI reasoning layer | Azure AI Foundry Agent | Prompt orchestration, multi-turn conversation memory (conversationId → thread), tool calling |
| Local server runtime | Node.js / Express | Lightweight, easy iframe hosting, portable |
| Context injection | Pattern 1 (from build_guide.md) | Proved pattern, no PBIE runtime modification needed |

---

## Prerequisites

- [x] Microsoft Fabric workspace — `VISA PBIE Context Injection` confirmed (`349db6f1`)
- [x] Power BI Embedded capacity — [fabriccapwest3](https://portal.azure.com/#resource/subscriptions/0a913923-fe62-46fb-8fdd-b78fb498f7a9/resourceGroups/Fabric-West3-RG/providers/Microsoft.Fabric/capacities/fabriccapwest3)
- [x] Node.js 20+ installed and `npm install` run
- [x] Azure CLI installed and authenticated
- [x] Fabric tenant policy `ElevatedGuestsTenant` enabled
- [x] Service principal registered (`VISA-PBIE-EmbedService`, `595278db`) — Admin in workspace, embed token confirmed working with `effectiveIdentity`
- [x] Fabric Data Agent provisioned (`Commercial_Spend_Agent`) — no public query REST API; pivoted to XMLA endpoint (`Invoke-ASCmd` shim) for grounded queries
- [x] Row-Level Security: `Role_Entitlement` dynamic role (`CUSTOMDATA()`), fixed-identity Direct Lake datasource connection bound (SSO disabled) — validated end-to-end for two test entitlements
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

**GitHub:** https://github.com/RangerXP/visa_copilot_iframe (working branch: **`branch`** — this is where Fabric's Git integration syncs and where all commits should be pushed; `main` is a stale early snapshot, not actively used)

---

## Project Status

| Sprint | Name | Status |
|--------|------|--------|
| Sprint 1 | Local PBIE Server + Iframe Render | **Complete** — embed token confirmed, iframe renders live report |
| Sprint 2 | Context Capture to JSON | **Complete** — context flows end-to-end into Foundry agent prompts |
| Sprint 3 | Fabric Data Agent Integration | **Complete** (pivoted) — Power BI `executeQueries` used in place of Data Agent REST (no public query API exists); later migrated to the XMLA endpoint (see Sprint 7) for RLS compatibility |
| Sprint 4 | Foundry Agent + Context Injection | **Complete** — end-to-end validated: chat → Foundry agent (`gpt-5.1`) → tool call → real data → natural-language answer |
| Sprint 5 | Semantic Query Layer Refinement | **Complete** — 10 DAX query shapes, `field_map.json` rewrite, context service, multi-turn conversation memory (conversationId → Foundry thread) |
| Sprint 6 | Demo Build + Talking Points | **Complete** — `docs/demo_script.md` rewritten against the live `Commercial_Spend_Analytics` report and real validated data |
| Sprint 7 | XMLA Migration + Entitlement-Based RLS | **Complete** — query layer migrated to XMLA, `Role_Entitlement` dynamic RLS role live, Direct Lake fixed-identity/SSO binding resolved, embed tokens validated for both test entitlements |
| Sprint 8 | Data Correctness — `Spend YoY %` Fix + Credential Hygiene | **Complete** — diagnosed and fixed a `Spend YoY %` KPI bug (blank/incorrect year-over-year values) via empirical XMLA testing; rotated the SP client secret and resolved two separate stale Fabric/Power BI credential stores uncovered in the process. See [docs/design_notes.md](docs/design_notes.md) §18 |

**All 8 sprints complete.** The project is demo-ready end-to-end: iframe → context capture → Foundry agent → live semantic model query → natural-language answer, with multi-turn memory, and the headline KPI cards now show validated, correct year-over-year figures.

**Auth boundary:** SP client-credentials (`VISA-PBIE-EmbedService`) used consistently across both surfaces — embed tokens (`GenerateToken` + `effectiveIdentity`) and semantic model queries (XMLA via `Invoke-ASCmd`, app-only OAuth). No delegated/user token dependency remains.

---

## Security Model

Row-Level Security is enforced identically on both the embedded report and the chat/agent query path via a single dynamic TMDL role (`Role_Entitlement`, `dim_client[HomeRegion] = CUSTOMDATA()`), driven by one entitlement value per synthetic test user:

- **PBIE embed token**: `identities[].customData` + `identities[].roles: ['Role_Entitlement']`
- **XMLA query**: connection string `CustomData=<value>` + `Roles=Role_Entitlement`

This replaced an earlier design that used one static TMDL role per customer segment (`Role_RegionA`/`Role_RegionB`, still present for comparison) — the dynamic role scales to any number of entitlement values without adding TMDL roles or redeploying the model.

| Control | Status |
|---|---|
| Single SP identity, tenant-homed, used consistently for embed tokens + XMLA queries | ✅ |
| Dynamic entitlement-based RLS, validated identical to static roles at the XMLA layer | ✅ |
| Direct Lake datasource bound to fixed-identity connection (SSO disabled) | ✅ |
| Embed tokens with `effectiveIdentity` succeed for both test entitlements; requests with no identity fail closed | ✅ |
| Fail-closed hardening as an explicit app-level check (vs. relying on platform default) | ⬜ Not yet implemented |
| Frontend `?user=<upn>` transport is unauthenticated | ⚠️ Dev/demo only — not production-safe |

Full detail: [docs/design_notes.md](docs/design_notes.md) §15 (XMLA/RLS migration), §16 (CUSTOMDATA() entitlement design + Static/EffectiveUserName/CUSTOMDATA() comparison), §17 (current security posture snapshot).
