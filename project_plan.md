# Development Plan — MSIE PBIE Context-Aware AI Assistant

## Project Framing

**Pattern 1 — Context Injection Agent** from the VISA PBI Embedded build guide is the target implementation.

The objective is to build and demo a local PBIE server where:
- An iframe renders a live report from a **Fabric semantic model**
- A chat panel captures report state and sends it to the chat backend
- The **Fabric Data Agent** executes semantic queries grounded in the visible report context
- Responses are returned in natural language to the chat panel

---

## Phase Map

```
Phase 0: Model Discovery + Local Server Scaffold
Phase 1: Iframe Render + Context Capture
Phase 2: Fabric Data Agent Integration
Phase 3: Context Injection Chat Layer (Pattern 1)
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
- [x] Context flows through to `/api/chat` as `rawContext` → normalized → injected into the chat backend's query to the Fabric Data Agent — confirmed via `[Report Context]` block in `chat.js`

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

## Sprint 4 — Context Injection Chat Layer (Pattern 1 Core)

**Goal:** Wire `/api/chat` to accept context + question and return grounded answers directly from the Fabric Data Agent query layer — no separate LLM orchestration/agent-hosting layer in between.

**Pattern source:** build_guide.md — Phase 3 Deliverable

**Deliverables:**
- [x] `server/routes/chat.js` — `POST /api/chat` route: normalizes `rawContext`, calls `queryFabricAgent({ question, context, effectiveUserName })` directly
- [x] `server/services/fabricAgent.js` — maps the question to one of several DAX query shapes (`semantic/dax/query_patterns.md`), executes it, and formats the structured result into a natural-language answer
- [x] Chat panel wired: user message → context capture → chat backend → response
- [x] `docs/pattern1_iframe_injection.md` — full injection flow documented (update after live validation)

**Design note (2026-07-26):** An earlier design in this sprint evaluated routing chat questions through a separate Azure AI Foundry agent (LLM orchestration + tool-calling) that would call this same Fabric Data Agent query layer as a tool. That layer was built, tested, and then backed out — it added Azure resource provisioning complexity (a Foundry account/project/model deployment, plus data-plane RBAC) without adding reasoning value beyond what the direct DAX-shape query layer already provides. The chat backend calls `queryFabricAgent()` directly instead.

**Query Construction Template:**
```
[Report Context]
{{context_block}}

[User Question]
{{question}}
```

The question is matched against keyword-routed DAX query shapes (summary, trend, segment, merchant, country, product, MCC, approval, fraud, industry) and the result is formatted into a plain-language response aligned with the visible report state.

**Validation:**
> User selects Merchant = Costco in slicer. Types "Why are declines increasing?" Context injected. Chat backend responds with model-grounded answer about Costco.

---

## Sprint 5 — Semantic Query Layer Refinement

**Goal:** Improve Fabric Data Agent query quality — add DAX examples, field mappings, and context translation.

**Pattern source:** build_guide.md — Phase 2 (Context Service) + Phase 4 (Query Layer)

**Deliverables:**
- [x] `semantic/dax/` — example DAX patterns for agent tool calls — 10 shapes documented in [semantic/dax/query_patterns.md](semantic/dax/query_patterns.md) (summary, trend, segment, merchant, country, product, MCC, approval, fraud, industry), backed by matching keyword-routed query templates in `server/services/fabricAgent.js`
- [x] `semantic/metadata/field_map.json` — PBIE field name → business name mapping — rewritten 2026-07-22 against the confirmed TMDL schema (was stale/mismatched placeholder data referencing fields that don't exist in the model)
- [x] Context service middleware: normalize PBIE state to business-friendly context — `server/services/contextService.js` (`normalizeContext`/`buildContextBlock`), pre-existing and confirmed working
- [x] `conversationId` generated client-side (`frontend/chat.js`, persisted in `sessionStorage` for the browser tab) and sent with every `/api/chat` request for continuity/telemetry — the backend does not currently use it to retain multi-turn conversation memory (`queryFabricAgent()` is stateless per request)

**Validation:**
> Ask questions across two pages. Context is coherent per-request. Field names are human-readable in all responses.
> **STATUS: PASSED** — validated 2026-07-22: merchant/country/product/MCC/approval/fraud breakdown questions all return correct, human-readable, natural-language answers end-to-end (see examples below).
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

**Validation:**
> Full demo script walked through against the live server 2026-07-21/22 — every scripted question returns a grounded, accurate answer from the real semantic model. No fictional data (e.g. Costco/Target merchants, "Customer Risk" page) remains in the script.
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
> **STATUS: PASSED — Sprint 8 complete.**

---

## Sprint 9 — Auth Hardening (Fail-Closed Checks + Server-Managed Session)

**Goal:** Close two open security-posture items: make the fail-closed RLS behavior an explicit app-level check instead of relying on Power BI's own error, and replace the unauthenticated `?user=<upn>` transport with a real server-managed session.

**Deliverables:**
- [x] `server/routes/embedToken.js` now rejects (`401`/`403`) before ever calling `GenerateToken` if there's no session, or the session's customer doesn't resolve to a known entitlement
- [x] `server/routes/chat.js` rejects (`401`) if there's no session, instead of trusting a client-supplied `user` body field
- [x] Added `express-session` + `server/routes/session.js` (`POST /login`, `GET /me`, `POST /logout`) — an HTTP-only, signed session cookie now carries the resolved `customerId`; no route accepts identity from a query param or request body anymore
- [x] `frontend/session.js` + a login screen (`frontend/index.html`) replace the old `?user=` query-param/`window.PBIE_USER_UPN` mechanism; `embed.js`/`chat.js` send `credentials: 'include'` instead of any client-held identifier
- [x] `docs/design_notes.md` (§17d), `docs/local_server_setup.md`, and `docs/demo_script.md` updated to describe the session-based flow and the new login steps for the Scene 5 RLS demo

**Validation:**
> Cookie-jar HTTP client walkthrough: `/api/embed-token` and `/api/chat` both `401` pre-login; login with an unknown `customerId` returns `401`; login with a known `customerId` returns `200` and sets the session cookie; both routes then succeed using only the cookie, with no identity present in the URL or body.
> **STATUS: PASSED — Sprint 9 complete. All 9 sprints in the roadmap are now done.**

---

## Technical Stack

| Layer | Technology |
|-------|-----------|
| Local web server | Node.js / Express |
| PBIE iframe | `powerbi-client` (JS SDK) |
| Context capture | `powerbi-client` API (`getFilters`, `getPages`, `getSlicers`) |
| Semantic model | Microsoft Fabric — Direct Lake semantic model (`Commercial_Spend_Analytics`) |
| Model access | Power BI `executeQueries` REST API (direct DAX execution — pivoted from Fabric Data Agent, which has no public query endpoint) |
| AI reasoning | Chat backend (`server/services/fabricAgent.js`) — keyword-routed DAX query shapes, no separate LLM orchestration layer |
| Auth (embed) | Power BI REST API — App-Owns-Data token |
| Auth (Fabric) | Entra ID service principal or user delegation |

---

## Open Questions

| # | Question | Owner | Status |
|---|----------|-------|--------|
| 1 | Which Fabric workspace/semantic model to target? | Sean | **RESOLVED — VISA workspace, Visa Slicer Demo v2** |
| 2 | Is a Fabric Data Agent already provisioned for this model? | Sean | Open |
| 3 | App-Owns-Data service principal created in tenant? | Sean | Open — register in MngEnvMCAP660444 |
| 4 | ~~Azure AI Foundry project available or needs creation?~~ | Sean | **Removed 2026-07-26** — Foundry agent evaluated and backed out; chat backend calls the Fabric Data Agent query layer directly |
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
