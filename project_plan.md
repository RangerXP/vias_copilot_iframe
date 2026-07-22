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
- [x] Iframe renders the target Fabric report locally — **confirmed 2026-07-21**: `/api/embed-token` returns valid token + embedUrl for report `e833a03b`
- [x] `docs/local_server_setup.md` validated (setup steps confirmed working)

**Validation:**
> Report visible in browser at `http://localhost:3000`. No sign-in prompt. Filter pane accessible.
> **STATUS: PASSED** — SP `VISA-PBIE-EmbedService` issues valid embed tokens via `server/routes/embedToken.js`.

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
- [x] POST to `server/routes/context.js` endpoint (confirmed 200 round-trip)
- [x] Context flows through to `/api/chat` as `rawContext` → normalized → injected into Foundry agent user turn — confirmed via `[Report Context]` block in `chat.js`

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
- [x] Fabric Data Agent (`Commercial_Spend_Agent`) provisioned — **but has no public REST query endpoint** (CRUD-only Fabric API, confirmed by exhaustive endpoint probing)
- [x] **Pivoted** to direct Power BI `executeQueries` REST API against the semantic model (`server/services/fabricAgent.js`) — same grounded-query outcome, different transport
- [x] Query interface implemented: `queryFabricAgent({ question, context, daxQuery }) → JSON string` (summary/trend/segment DAX shapes auto-selected by question pattern)
- [x] Auth: `DefaultAzureCredential` (delegated user token) — SP client-credentials blocked by tenant Power BI admin setting ("Allow service principals to use Power BI APIs" not enabled)
- [x] `docs/fabric_agent_config.md` — needs update to reflect the executeQueries pivot (doc still describes original Data Agent REST plan)

**Validation:**
> POST `{ "question": "What is the total spend and transaction count?" }` to `/api/chat`. Agent returns a grounded answer from real semantic model data.
> **STATUS: PASSED** — confirmed live 2026-07-21: "$74,812,278.37 ... 250,000 transactions ... $299.25 per transaction."

---

## Sprint 4 — Foundry Agent + Context Injection (Pattern 1 Core)

**Goal:** Build the Pattern 1 Foundry Agent that accepts context + question and returns grounded answers via the Fabric Data Agent as a tool.

**Pattern source:** build_guide.md — Phase 3 Deliverable

**Deliverables:**
- [x] Azure AI Foundry Agent created — `pbie-context-agent` (`asst_0VlPo0xeZeprd75h0Jve0a5l`), model `gpt-5.1`, project `visa-pbie-context` (West US 3 — `visa-pbie-context-rsc`)
- [x] Tool: `query_semantic_model(question, context)` — implemented in `server/services/foundryAgent.js` with tool call dispatch loop
- [x] `server/services/foundryAgent.js` — Foundry SDK (`@azure/ai-agents` v1.x sub-client API: `agents.threads`, `agents.messages`, `agents.runs`) with `requires_action` polling and tool routing to `fabricAgent.js`
- [x] Chat panel wired: user message → context capture → Foundry Agent → response
- [x] Agent synthesizes natural-language answers from tool JSON (system prompt enforces synthesis; client-side fallback synthesizer in `foundryAgent.js` as a safety net)
- [ ] `docs/pattern1_iframe_injection.md` — full injection flow documented (update after live validation)

**Known SDK gotcha (resolved):** `@azure/ai-agents` v1.x replaced the old flat `createThread/createMessage/createRun/listMessages` methods with sub-clients (`agents.threads.create()`, `agents.messages.create(threadId, role, content)`, `agents.runs.create(threadId, assistantId)`, `agents.runs.submitToolOutputs(threadId, runId, toolOutputsArray)`). Also: `USE_FOUNDRY` in `chat.js` must be evaluated inside the request handler, not at module load, since ESM imports are hoisted before `dotenv.config()` runs.

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
- [x] `semantic/dax/` — example DAX patterns for agent tool calls — 10 shapes documented in [semantic/dax/query_patterns.md](semantic/dax/query_patterns.md) (summary, trend, segment, merchant, country, product, MCC, approval, fraud, industry), backed by matching keyword-routed query templates in `server/services/fabricAgent.js`
- [x] `semantic/metadata/field_map.json` — PBIE field name → business name mapping — rewritten 2026-07-22 against the confirmed TMDL schema (was stale/mismatched placeholder data referencing fields that don't exist in the model)
- [x] Context service middleware: normalize PBIE state to business-friendly context — `server/services/contextService.js` (`normalizeContext`/`buildContextBlock`), pre-existing and confirmed working
- [x] Multi-page context (page transitions preserved in conversation) — implemented 2026-07-22: `frontend/chat.js` mints a `conversationId` (persisted in `sessionStorage` for the browser tab) and sends it with every `/api/chat` request; `foundryAgent.js` maps `conversationId → Foundry thread ID` (in-memory, capped at 500 conversations) and reuses the thread instead of starting a new one, so page transitions and follow-up questions retain full conversation history.

**Validation:**
> Ask multi-turn questions across two pages. Context is coherent across turns. Field names are human-readable in all responses.
> **STATUS: PASSED** — validated 2026-07-22: merchant/country/product/MCC/approval/fraud breakdown questions all return correct, human-readable, natural-language answers end-to-end (see examples below). Multi-turn memory confirmed: asked "What is the total spend?" (turn 1, $74,812,278.37), then "What was the dollar figure you told me a moment ago?" (turn 2, same `conversationId`) → agent correctly recalled "$74,812,278.37" from thread history without re-querying. A fresh request with no `conversationId` correctly started an isolated new thread (no cross-conversation leakage).
>
> Example validated Q&A:
> - "Which merchants have the highest spend?" → ranked top-10 list with merchant names and dollar amounts
> - "Which countries have the most spend?" → "United States at about $18,529,767... Canada... United Kingdom... India... Germany"
> - "How does spend break down by product?" → ranked list of Visa product lines with spend
> - "What merchant categories have the most spend?" → "Hospitals... Business Services... Subscription Services..."
> - "What is the approval rate versus decline rate?" → "approval rate is 94.9% and the decline rate is 3.5%..."
>
> Bug found + fixed during validation: `pickDax()` keyword regexes used `\b` word boundaries and exact-word matches that failed on plural forms the model naturally uses in tool calls (e.g. `/merchant\b/` didn't match "merchants", `/country/` didn't match "countries", `/industry/` didn't match "industries"). Fixed to prefix-style matching (`/merchant/`, `/countr/`, `/industr/`).

---

## Sprint 6 — Demo Build + Talking Points

**Goal:** Produce a repeatable demo that tells the Pattern 1 story for PG review and stakeholder showcase.

**Deliverables:**
- [x] `docs/demo_script.md` — step-by-step demo flow with talking points, rewritten 2026-07-21 to match the live `Commercial_Spend_Analytics` report and real validated data (was previously written against fictional merchants/pages before the model existed)
- [x] Demo report identified in Fabric — `Commercial_Spend_Analytics` report (`e833a03b-2cf9-42d2-a1ee-a40f847fd75d`), workspace `VISA PBIE Context Injection` (`349db6f1`), 7 pages (Overview, Risk & Approval, Executive Summary, Supplier Analysis, Spend Trends, Savings Opportunities, Filter Context Analysis)
- [x] Demo questions scripted and tested against live agent — reuses the Sprint 5 validated Q&A set (approval/decline rate, top merchants, country breakdown, product mix, MCC categories, multi-turn recall)
- [x] README updated with final architecture diagram and current sprint status

**Demo Questions (Final, validated live 2026-07-22):**
1. "What am I looking at?" — tests page-aware context summary
2. "What is the approval rate versus decline rate?" — 94.9% / 3.5% (235,081 / 8,646 transactions)
3. "Which merchants have the highest spend?" — Microsoft Merchant 0198 ($232,963), ExxonMobil Merchant 0898 ($174,976), Hilton Merchant 0714 ($161,619)
4. "How does spend break down by country?" — United States ($18,529,767), Canada ($5,358,022), UK ($4,546,435)
5. "What was the dollar figure you told me a moment ago?" — tests multi-turn conversation memory (thread reuse)

**Validation:**
> Full demo script walked through against the live server + Foundry agent 2026-07-21/22 — every scripted question returns a grounded, accurate answer from the real semantic model. No fictional data (e.g. Costco/Target merchants, "Customer Risk" page) remains in the script.
> **STATUS: PASSED — Sprint 6 complete.**

---

## Sprint 7 — XMLA Migration + Entitlement-Based RLS

**Goal:** Move the query layer off the `executeQueries` REST API (which has known limitations under RLS at scale) onto the XMLA endpoint, and replace static per-segment RLS roles with a single dynamic, entitlement-based role that scales without per-value TMDL changes.

**Deliverables:**
- [x] Query layer migrated to XMLA via a `Invoke-ASCmd` PowerShell shim, SP app-only OAuth (`scripts/query_xmla.ps1`)
- [x] Dynamic TMDL role `Role_Entitlement` (`dim_client[HomeRegion] = CUSTOMDATA()`) replacing static `Role_RegionA`/`Role_RegionB` as the default runtime path (static roles kept for comparison)
- [x] Direct Lake datasource bound to a fixed-identity cloud connection (service-principal auth, Entra ID SSO disabled) — resolved the long-standing `403 not supported for this datasource` blocker
- [x] Embed tokens + XMLA queries validated end-to-end for both test entitlement values, byte-identical row sets vs. legacy static roles

**Validation:**
> `scripts/compare_rls_mechanisms.ps1` — static vs. dynamic RLS parity PASS for both regions; browser round-trip confirmed both test users load the embedded report successfully.
> **STATUS: PASSED — Sprint 7 complete.**

---

## Sprint 8 — Data Correctness (`Spend YoY %` Fix) + Credential Hygiene

**Goal:** Fix a reported data bug in the `Spend YoY %` headline KPI cards, and resolve credential issues surfaced along the way.

**Deliverables:**
- [x] Root-caused the `Spend YoY %` bug via direct XMLA `EVALUATE` queries: `DATEADD`/`SAMEPERIODLASTYEAR` return blank when filter context comes from `dim_date[Year]` rather than `dim_date[Date]` — not fixed by marking the table as a Date Table (tested and ruled out empirically)
- [x] Replaced the measure with explicit Year-arithmetic filtering (no time-intelligence functions), validated correct in every context (unfiltered, Year-filtered, Date-filtered) via XMLA before and after syncing to the live model
- [x] Rotated `CLIENT_SECRET` for `VISA-PBIE-EmbedService` after repeated chat exposure; discovered and fixed two independent stale Fabric/Power BI credential stores for the OneLake datasource (one SP-patchable via the Fabric Connections API, one requiring a manual portal credential edit)
- [x] README and `docs/design_notes.md` (§18) updated with root cause, fix, and validation evidence

**Validation:**
> Post-sync XMLA check: per-year `Spend YoY %` populated correctly (2025 = +2.4%, 2026 = -1.9%, 2024 = blank/no prior year); unfiltered KPI-card value (-1.9%) matches the latest-year row exactly. Confirmed visually by the user in the live report.
> **STATUS: PASSED — Sprint 8 complete. All 8 sprints in the roadmap are now done.**

---

## Technical Stack

| Layer | Technology |
|-------|-----------|
| Local web server | Node.js / Express |
| PBIE iframe | `powerbi-client` (JS SDK) |
| Context capture | `powerbi-client` API (`getFilters`, `getPages`, `getSlicers`) |
| Semantic model | Microsoft Fabric — Direct Lake semantic model (`Commercial_Spend_Analytics`) |
| Model access | Power BI `executeQueries` REST API (direct DAX execution — pivoted from Fabric Data Agent, which has no public query endpoint) |
| AI reasoning | Azure AI Foundry Agent (`gpt-5.1`), with `query_semantic_model` tool + multi-turn conversation memory |
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
| 6 | Target demo report identified (specific report ID)? | Sean | **RESOLVED — `Commercial_Spend_Analytics` report (`e833a03b`), 7 pages, live embed target** |

---

## Risk Register

| Risk | Mitigation |
|------|-----------|
| Fabric Data Agent not available for target model | Fallback: Direct XMLA/REST query to semantic model via service principal |
| Embed token scope insufficient for Fabric-backed reports | Validate capacity license; use PPU if needed |
| Context object too large for prompt window | Implement context compression in context service |
| Fabric model field names opaque for prompt grounding | Use field_map.json to translate before injection |
