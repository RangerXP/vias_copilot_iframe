# Architectural Summary: Fabric Data Agent vs. Lightweight LLM Orchestrator

**Date**: 2026-07-24
**Scope**: Compare/contrast the two conversational-Copilot architectures evaluated and implemented in this project, for use in a Fabric/Power BI Embedded product-engineering feature enhancement request. Framing is specific to **Power BI Embedded, App-Owns-Data (AOD)** — the embedding Angular SPA never holds an end-user Entra identity; a backend-for-frontend (BFF, this project's Node/Express server) holds a single service principal, and per-end-customer identity is *simulated* via RLS effective-identity mechanisms (Embed Token `identities[]`, or XMLA `Roles`+`CustomData`).

Grounded in: direct implementation/testing in this repo (`server/services/fabricAgent.js`, `server/services/llmOrchestrator.js`) plus Microsoft Learn documentation reviewed during this engagement (`concept-data-agent.md`, `data-agent-sharing.md`, `service-admin-row-level-security.md`).

---

## 1. Executive Summary

| | **Fabric Data Agent** (native, `USE_DATA_AGENT`) | **Lightweight LLM Orchestrator** (`USE_LLM_ORCHESTRATOR`) |
|---|---|---|
| RLS in AOD/API mode | ❌ Not supported — always executes under the semantic model's fixed connection identity | ✅ Full RLS — same guarantee as the deterministic (non-LLM) path |
| Where identity is bound | N/A (no parameter exists) | App backend code, from the authenticated session only |
| LLM interaction control | Opaque — Fabric-managed NL→query→NL pipeline | Fully transparent — app owns prompt, tool schema, model, iteration loop |
| New Azure infra | None (fully inside Fabric capacity) | One Cognitive Services/AOAI resource + RBAC (reused an existing resource here) |
| Verdict for AOD embedding | **Not viable today for multi-tenant/RLS-sensitive embedding** | **Viable — currently the only RLS-correct conversational option** |

The core finding: **Fabric Data Agent's conversational API has no effective-identity/RLS parameter at all** — it's an architectural gap, not a configuration miss. The lightweight orchestrator closes that gap by keeping the LLM *outside* the RLS boundary entirely and letting it only select *what* data to fetch, never *who* it's fetched for.

---

## 2. RLS Enforcement — Detailed Comparison

### Fabric Data Agent
- Conversational surface (`assistants/threads/messages/runs`, OpenAI-Assistants-API-compatible) is invoked here via a service-principal-issued Entra token — the only auth mode available for a headless embedded backend.
- The Data Agent's query execution against the underlying semantic model always runs under **the model's configured connection identity** (Direct Lake fixed-identity connection, in this project's case) — not the caller's identity.
- No parameter in the create-thread / create-run / create-message request bodies for `effectiveIdentity`, `customData`, or `roles` (confirmed by inspecting the actual request/response schemas, not assumed).
- **Empirically confirmed**: same session, same question, routed to the Data Agent returned the full-dataset grand total ($1,106,210.13) instead of the RLS-scoped figure ($229,610.09) the on-screen report cards and every other chat path showed for that user.
- This gap is *specific to the non-interactive/SP-driven access pattern AOD requires*. It is plausible (though not verified here) that Fabric/Copilot experiences invoked interactively by a real signed-in Entra user *do* get RLS enforcement via that user's own delegated token — that distinction is exactly the product gap: **there is no equivalent "act as this user" mechanism for programmatic/embedded callers**, unlike Power BI's own Embed Token API, which has supported `identities[]` (effective identity) for over a decade for reports/datasets.

### Lightweight LLM Orchestrator
- The LLM is called only to (a) decide which named data shape answers the question, and (b) turn structured rows into prose. It never touches the semantic model, XMLA endpoint, or Fabric APIs directly.
- Tool execution is 100% in-app code: `executeDax(shape.dax, { effectiveUserName, rlsMode })`, which flows into `runXmlaQuery()` → `Roles=Role_Entitlement` + `CustomData=<value>` on the MSOLAP connection string — the *exact same* RLS mechanism the deterministic (non-LLM) path already uses and that matches the report's own on-screen RLS.
- `effectiveUserName`/`rlsMode` are read **only** from the authenticated session (`req.session.customerId`) inside the app's own function signature — they are never read from, or overridable by, the model's tool-call JSON arguments. Even a compromised or adversarially-prompted model cannot request another customer's data, because the model has no channel through which to specify identity at all.
- **Empirically confirmed** across two different demo identities (North America vs. Europe) with multi-tool-call questions — figures matched each session's RLS-scoped deterministic table exactly.

**Security framing**: this is a classic **least-privilege / trusted-computing-base reduction** pattern — the LLM (an untrusted, prompt-injectable component) is deliberately kept outside the authorization boundary. Compare to the Data Agent, where the *entire* authorization decision is delegated to a platform component with no documented, callable identity-binding surface for this access pattern.

---

## 3. Synthesizing the LLM Interaction

| Dimension | Fabric Data Agent | Lightweight Orchestrator |
|---|---|---|
| NL → query translation | Fabric-managed, model choice/version not controllable by the app | N/A — no free-form NL→DAX; app exposes a fixed catalog of 10 vetted DAX shapes as the only callable tool |
| Query → NL synthesis | Fabric-managed (opaque prompt/model) | App-owned system prompt + Azure OpenAI chat completions, fully inspectable/tunable |
| Multi-turn memory | Built-in (`threadId` cached per `conversationId`) | Not yet implemented (stateless per request); same pattern (conversationId-keyed cache) could be added if needed |
| Tool-calling model | Implicit (NL→DAX generation is itself the "tool") | Explicit OpenAI-style function calling, one tool, enum-constrained parameter — narrow, auditable attack surface |
| Prompt injection exposure | Unknown/opaque — Data Agent's internal query-generation prompt is not visible to the app developer | Bounded — the only thing the model can "do" is pick one of 10 known-safe DAX shapes; it cannot construct arbitrary DAX, and its only side effect is a read-only, RLS-scoped query |
| Extensibility | Limited to `stage_config.json` `aiInstructions` tuning | Full control — new tools, new shapes, different models, retrieval augmentation, etc. all addable in app code |

**Product implication**: the Data Agent trades control for convenience — good for exploratory/ad hoc NL→DAX generation in trusted, interactive contexts; poor for a security-hardened, narrowly-scoped embedded Copilot where you want the LLM's "surface area" minimized and auditable.

---

## 4. Setting User Context (the crux issue for AOD)

This is the load-bearing difference and the one worth escalating to the product group.

**How AOD already solves this for reports** (established, documented API): `GenerateToken` accepts `identities: [{ username, roles: [...], datasets: [...], customData }]` — the embedding backend authenticates as one app identity, but stamps an *effective identity* onto the token for the report/dataset, and Power BI's own RLS engine enforces it. This is the well-known, supported pattern this project's report embedding already relies on (and that `runXmlaQuery()`'s `Roles`/`CustomData` mirrors at the XMLA layer).

**The gap**: **no equivalent field exists anywhere in the Fabric Data Agent's conversational API** (thread creation, run creation, message creation). There is no `identities`, no `customData`, no `roles` parameter to carry an effective identity through to the underlying semantic-model query the Data Agent generates and runs on the caller's behalf.

**Consequence for embedded Angular/AOD Copilot scenarios specifically**: any ISV building a multi-tenant embedded analytics product with an "ask a question" Copilot feature — which is an increasingly standard ask for Angular/React BI dashboards — cannot safely wire that feature directly to a Fabric Data Agent today if different embedded end-customers must see different RLS-scoped slices of the same semantic model. The lightweight orchestrator is the current viable substitute *precisely because* it moves identity-binding back into app code, where AOD's existing embed-token/XMLA CustomData patterns already work.

---

## 5. Product/Operational Tradeoffs

| | Fabric Data Agent | Lightweight Orchestrator |
|---|---|---|
| New Azure resources | None | One AOAI-capable Cognitive Services resource + RBAC role (reused an existing one here — near-zero incremental cost in this project) |
| Ops/maintenance burden | Low — fully managed by Fabric | Medium — app owns retry/backoff, token acquisition, tool-loop iteration limits, prompt maintenance |
| Cost model | Fabric capacity (CU) consumption | Fabric capacity (for XMLA query) + separate AOAI token billing |
| Time-to-value | Fast — point-and-publish in Fabric portal | Slower — requires writing/maintaining orchestration code |
| Governance/compliance fit | Opaque model choice, harder to audit for regulated data (e.g., PCI-adjacent commercial spend data, as here) | Fully auditable — app controls model version, data-plane region, logging of every tool call and its inputs/outputs |
| Fit for regulated/multi-tenant embedded scenarios | Poor today (RLS gap) | Good — matches the trust model AOD already requires for reports |

---

## 6. Recommended Product Engineering Feature Enhancement Request

Suggested framing for filing with the Fabric/Power BI Embedded product group:

> **Title**: Fabric Data Agent conversational API needs an effective-identity / RLS pass-through parameter for App-Owns-Data (service-principal-driven) callers
>
> **Problem statement**: Power BI Embedded's App-Owns-Data model has long supported per-end-customer RLS via Embed Token `identities[]` (and via XMLA `Roles`/`CustomData`) for reports and direct semantic-model queries. The Fabric Data Agent's conversational surface (threads/runs/messages) has no equivalent — queries it generates and executes always run under the semantic model's configured connection identity, never the caller-supplied effective identity. This makes the Data Agent unusable, as-is, for any embedded/AOD Copilot feature where different embedded tenants/customers must see different RLS-scoped answers from the same shared semantic model.
>
> **Current behavior**: Confirmed empirically — an SP-authenticated Data Agent conversation returns full, unfiltered dataset totals regardless of which embedded end-customer's session initiated the question.
>
> **Desired behavior**: Accept an `effectiveIdentity`/`customData`/`roles` field (mirroring `GenerateToken`'s `identities[]` schema) at thread- or run-creation time, and honor it when executing the underlying semantic-model query — consistent with how Direct Lake/XMLA already supports `Roles`+`CustomData` today.
>
> **Business justification**: This is a standard, expected capability gap for any ISV/ISV-like team (e.g., this project) building a multi-tenant embedded analytics product with a natural-language "ask a question" feature — a fast-growing ask across BI-embedding customers. Without it, teams must build and maintain a custom LLM-orchestration layer (as done here) purely to re-establish an RLS guarantee Fabric Data Agent should be able to provide natively.
>
> **Secondary ask**: Explicitly document this limitation in `concept-data-agent.md`/`data-agent-sharing.md` — currently it is discoverable only through empirical testing (as this project had to do), which risks other teams shipping an RLS-bypassing embedded Copilot unknowingly.

---

## 7. Bottom Line

For this project's App-Owns-Data, Angular-embedded, RLS-sensitive scenario: the **lightweight orchestrator is the only currently-viable option**, precisely because it re-uses the same identity-binding pattern (session → server-code-injected `CustomData`/`Roles`) that AOD already depends on for reports. The Fabric Data Agent is well-suited to interactive, single-tenant, Fabric-portal-native usage, but has a real, confirmable product gap for the exact access pattern embedded Copilot features require — that gap is what should be escalated as a feature request rather than worked around indefinitely.
