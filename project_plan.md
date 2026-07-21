# Development Plan — MSIE PBIE Context-Aware AI Assistant

## Project Framing

**Pattern 1 — Context Injection Agent** from the VISA PBI Embedded build guide is the target implementation.

The objective is to build and demo a local PBIE server where:
- An iframe renders a live report from a **Fabric semantic model**
- A chat panel captures report state and sends it to a **Foundry Agent**
- The **Fabric Data Agent** executes semantic queries grounded in the visible report context
- Responses are returned in natural language to the chat panel

---

## Phase Map

```
Phase 0: Model Discovery + Local Server Scaffold
Phase 1: Iframe Render + Context Capture
Phase 2: Fabric Data Agent Integration
Phase 3: Foundry Agent + Context Injection (Pattern 1)
Phase 4: Semantic Query Layer (Production Pattern)
Phase 5: Demo Build
```

---

## Sprint 1 — Local PBIE Server + Fabric Model Registration

**Goal:** Prove we can render a Fabric-backed report in an iframe on a locally-hosted Node.js server.

**Inputs:**
- Fabric workspace ID (from model discovery)
- Target semantic model / report ID
- PBIE embed token (App-Owns-Data flow)

**Deliverables:**
- [x] `server/index.js` — Express server that serves the embed token and HTML shell
- [x] `frontend/index.html` — Iframe host page with `powerbi-client` loaded
- [x] `frontend/embed.js` — Calls `powerbi.embed()` with token from backend; `tokenExpired` refresh with effectiveIdentity preserved
- [ ] Iframe renders the target Fabric report locally — **blocked: SP credentials pending**
- [ ] `docs/local_server_setup.md` validated (setup steps confirmed working) — **blocked: SP credentials pending**

**Validation:**
> Report visible in browser at `http://localhost:3000`. No sign-in prompt. Filter pane accessible.

**Fabric Model Reference:**
- See [docs/fabric_model_discovery.md](docs/fabric_model_discovery.md) to identify workspace + report IDs
- See [semantic/model_metadata.md](semantic/model_metadata.md) for discovered model schema

---

## Sprint 2 — Context Capture Layer

**Goal:** Capture current report state from the iframe and produce a structured JSON context object.

**Pattern 1 source:** `build_guide.md` — Phase 1 Deliverable

**Deliverables:**
- [x] `frontend/context-capture/captureContext.js` — reads PBIE state
- [x] Captures: `reportId`, `page`, `filters`, `slicers`, `selections`
- [x] Serializes to clean JSON
- [x] POST to `backend/api/context` endpoint
- [ ] `docs/pattern1_iframe_injection.md` updated with actual field names from Fabric model — **pending XMLA/portal model browse**

**Output shape:**
```json
{
  "reportId": "...",
  "page": "...",
  "filters": [],
  "slicers": [],
  "visualSelections": []
}
```

**Validation:**
> Change a slicer in the embedded report. Trigger context capture. JSON reflects the new slicer state.

---

## Sprint 3 — Fabric Data Agent Integration

**Goal:** Wire the Fabric Data Agent as the semantic query engine for the agent backend.

**Pattern source:** build_guide.md — Phase 4 (Semantic Model Query Layer, moved earlier given Fabric native agent)

**Deliverables:**
- [ ] Fabric Data Agent provisioned against target semantic model
- [ ] `backend/fabric-agent/fabricClient.js` — wrapper for Fabric Data Agent REST calls
- [ ] Query interface: `{ question: string, context: object } → string answer`
- [ ] `docs/fabric_agent_config.md` validated (agent ID, endpoint, auth)

**Validation:**
> POST `{ "question": "What is the approval rate?", "context": { "Merchant": "Costco" } }` to backend. Agent returns a grounded answer from the Fabric semantic model.

---

## Sprint 4 — Foundry Agent + Context Injection (Pattern 1 Core)

**Goal:** Build the Pattern 1 Foundry Agent that accepts context + question and returns grounded answers via the Fabric Data Agent as a tool.

**Pattern source:** build_guide.md — Phase 3 Deliverable

**Deliverables:**
- [ ] Azure AI Foundry Agent created — **run `node scripts/provision-foundry-agent.js` once project endpoint is available**
- [x] Tool: `query_semantic_model(question, context)` — implemented in `server/services/foundryAgent.js` with tool call dispatch loop
- [x] `server/services/foundryAgent.js` — Foundry SDK client with `requires_action` polling and Fabric Data Agent routing
- [x] Chat panel wired: user message → context capture → Foundry Agent → response
- [ ] `docs/pattern1_iframe_injection.md` — full injection flow documented (update after live validation)

**System Prompt Template:**
```
You are an embedded analytics assistant for a Power BI Embedded report.

The user is currently viewing:
{{context_block}}

Use the semantic model query tool to answer data questions.
Respond in plain language aligned with the visible report state.
Do not answer from memory. Always query the model for data values.
```

**Validation:**
> User selects Merchant = Costco in slicer. Types "Why are declines increasing?" Context injected. Agent responds with model-grounded answer about Costco.

---

## Sprint 5 — Semantic Query Layer Refinement

**Goal:** Improve Fabric Data Agent query quality — add DAX examples, field mappings, and context translation.

**Pattern source:** build_guide.md — Phase 2 (Context Service) + Phase 4 (Query Layer)

**Deliverables:**
- [ ] `semantic/dax/` — example DAX patterns for agent tool calls
- [ ] `semantic/metadata/field_map.json` — PBIE field name → business name mapping
- [ ] Context service middleware: normalize PBIE state to business-friendly context
- [ ] Multi-page context (page transitions preserved in conversation)

**Validation:**
> Ask multi-turn questions across two pages. Context is coherent across turns. Field names are human-readable in all responses.

---

## Sprint 6 — Demo Build + Talking Points

**Goal:** Produce a repeatable demo that tells the Pattern 1 story for PG review and stakeholder showcase.

**Deliverables:**
- [ ] `docs/demo_script.md` — step-by-step demo flow with talking points
- [ ] Demo report identified in Fabric (specific pages + slicers defined)
- [ ] Demo questions scripted and tested against live agent
- [ ] README updated with final architecture diagram

**Demo Questions (Draft):**
1. "What am I looking at?" — tests context summary
2. "Why did approval rates decrease?" — tests trend analysis with context
3. "Show me the highest risk merchant in this view." — tests filter-aware ranking
4. "Explain this chart." — tests page-aware visual description

---

## Technical Stack

| Layer | Technology |
|-------|-----------|
| Local web server | Node.js / Express |
| PBIE iframe | `powerbi-client` (JS SDK) |
| Context capture | `powerbi-client` API (`getFilters`, `getPages`, `getSlicers`) |
| Semantic model | Microsoft Fabric — existing workspace model |
| Model access | Fabric Data Agent (natural language + DAX over Fabric) |
| AI reasoning | Azure AI Foundry Agent |
| Auth (embed) | Power BI REST API — App-Owns-Data token |
| Auth (Fabric) | Entra ID service principal or user delegation |

---

## Open Questions

| # | Question | Owner | Status |
|---|----------|-------|--------|
| 1 | Which Fabric workspace/semantic model to target? | Sean | **RESOLVED — VISA workspace, Visa Slicer Demo v2** |
| 2 | Is a Fabric Data Agent already provisioned for this model? | Sean | Open |
| 3 | App-Owns-Data service principal created in tenant? | Sean | Open — register in MngEnvMCAP660444 |
| 4 | Azure AI Foundry project available or needs creation? | Sean | Open |
| 5 | Is Premium Per User or embedded capacity available for embed tokens? | Sean | **RESOLVED — dedicated capacity cb113ec9** |
| 6 | Target demo report identified (specific report ID)? | Sean | **RESOLVED — Visa Slicer Demo v2, page: Demo PBIP** |

---

## Risk Register

| Risk | Mitigation |
|------|-----------|
| Fabric Data Agent not available for target model | Fallback: Direct XMLA/REST query to semantic model via service principal |
| Embed token scope insufficient for Fabric-backed reports | Validate capacity license; use PPU if needed |
| Context object too large for prompt window | Implement context compression in context service |
| Fabric model field names opaque for prompt grounding | Use field_map.json to translate before injection |
