# Demo Script — Pattern 1: Context Injection Agent

## Demo Identity

**Title:** Copilot-Like AI for Power BI Embedded — Without Native Copilot  
**Pattern:** Context Injection Agent (Pattern 1)  
**Audience:** PG Review / Stakeholder Showcase  
**Duration:** 10–15 minutes  

---

## Positioning Statement (Open With This)

> "Power BI Embedded in App-Owns-Data mode doesn't support native Copilot.  
> But the host application knows everything about what the user is seeing.  
> We use that knowledge to inject context into an Azure AI Foundry Agent backed by the same semantic model.  
> The result looks and feels like Copilot — without touching the PBIE runtime."

---

## Demo Environment Setup

Before the demo, ensure:

- [ ] Local PBIE server running: `npm run dev` (or `node server/index.js`) → `http://localhost:3000`
- [ ] `.env` has valid `CLIENT_ID`/`CLIENT_SECRET`, `WORKSPACE_ID`, `REPORT_ID`, `DATASET_ID`, `FOUNDRY_PROJECT_ENDPOINT`, `FOUNDRY_AGENT_ID`
- [ ] Report **Commercial_Spend_Analytics** (Direct Lake, 250,000 transactions, 7 pages) loaded in iframe
- [ ] Page: **Overview** or **Risk & Approval** active
- [ ] Chat panel visible alongside the report
- [ ] Network DevTools closed (clean visual) until Scene 5
- [ ] Demo questions loaded in a scratch doc (don't type live from memory)

---

## Scene 1 — Set the Stage (2 min)

**Action:** Show the embedded report in the browser.

**Talking Point:**
> "This is a Power BI Embedded portal — the report is rendered inside an iframe.  
> The data is coming from a Fabric semantic model — the same governed model used across the business.  
> Standard App-Owns-Data pattern. No native Copilot."

**Action:** Show the chat panel is present but empty.

> "We've added a chat panel alongside the report.  
> The key thing to understand is: the AI behind this panel knows what page you're on,  
> what filters are active, and what the user is currently looking at."

---

## Scene 2 — Context Awareness (3 min)

**Action:** Navigate to the **Risk & Approval** page.

**Talking Point:**
> "The user just navigated to the Risk & Approval page.  
> Without any AI, they're seeing whatever the visuals show.  
> Now watch what happens when they ask a question."

**Action:** Type in chat: **"What am I looking at?"**

**Expected response (grounded in real context):**  
> "You're viewing the Risk & Approval page. This page focuses on transaction approval and decline patterns, and fraud exposure across merchants and merchant categories in the Commercial Spend Analytics model."

**Talking Point:**
> "The agent didn't guess. It read the active page from the report state  
> and grounded its answer in the actual model — that's the context injection."

---

## Scene 3 — Data Question with Context (3 min)

**Action:** Type: **"What is the approval rate versus decline rate?"**

**Expected response (validated live 2026-07-22):**  
> "The approval rate is 94.9% and the decline rate is 3.5%, based on 235,081 approved and 8,646 declined transactions out of 250,000 total."

**Talking Point:**
> "That number came from a live DAX query against the semantic model — `Approval Rate` and `Decline Rate`  
> are real measures, not something the model made up.  
> Every answer in this demo is grounded in the same measures used in the visuals."

**Action:** Type: **"Which merchants have the highest spend?"**

**Expected response (validated live 2026-07-22):**  
> "The top merchants by spend are Microsoft Merchant 0198 ($232,963), ExxonMobil Merchant 0898 ($174,976),  
> and Hilton Merchant 0714 ($161,619), followed by several others in the top 10."

---

## Scene 4 — Context Changes with the Report (2 min)

**Action:** Navigate to the **Overview** page (or apply a Country/Region filter if configured in the live report).

**Action:** Type: **"How does spend break down by country?"**

**Expected response (validated live 2026-07-22):**  
> "United States leads with $18,529,767, followed by Canada at $5,358,022, the UK at $4,546,435,  
> India at $4,237,309, and Germany at $3,961,162."

**Talking Point:**
> "The context updates automatically as the user moves through the report.  
> There's no manual context refresh — the frontend reads report state on every send,  
> and the backend keeps conversation memory per session, so follow-up questions  
> like 'what was that number again?' work without re-asking."

---

## Scene 5 — Architectural Transparency (2 min)

**Action:** Open DevTools → Network tab. Send a chat message. Show the `/api/chat` POST request and the JSON body.

**Talking Point:**
> "Here's the data flow: the frontend captured the active page and filters from the iframe  
> using the official `powerbi-client` API, normalized them into business terms via `field_map.json`,  
> and sent them to the backend alongside the question and a `conversationId`.  
> The backend injected the context into an Azure AI Foundry Agent prompt.  
> The agent called a `query_semantic_model` tool, which executes a DAX query directly against  
> the Power BI semantic model via the `executeQueries` REST API — the same governed model behind the report.  
> The answer came from that query result — not from the AI's general knowledge."

---

## Scene 6 — Close + North Star (1 min)

**Talking Point:**
> "This is Pattern 1 — a compatibility architecture.  
> It doesn't require changes to the PBIE runtime.  
> It doesn't require native Copilot support.  
> It works in any App-Owns-Data embedded scenario.  
>  
> Today it supports 10 distinct query shapes — spend summary, trend, segment, merchant, country,  
> product, merchant category, approval/decline, fraud risk, and industry — plus multi-turn memory  
> so follow-up questions work naturally.  
>  
> The North Star is adding RAG over knowledge sources, multi-visual context,  
> and a broader DAX pattern library — but the foundation is working today, live, against real data."

---

## Anticipated Questions + Answers

| Question | Answer |
|----------|--------|
| Is this using Copilot for Power BI? | No — native Copilot doesn't run in PBIE. This is a custom Azure AI Foundry Agent backed by the same Fabric semantic model. |
| What if the semantic model changes? | The agent's tool queries the live model on every call via `executeQueries` — no re-configuration needed for new data, only for new measures/columns. |
| How accurate is the context capture? | It uses the official `powerbi-client` API — the same state used by the report runtime. |
| Can this be multi-tenant? | Yes — the embed token and agent are scoped per request. Multi-tenant is a configuration concern, not architectural. |
| Is this production-ready? | The architecture is production-viable. This demo runs on a local dev server; cloud deployment is future scope. |
| How is this different from a chatbot? | It's context-aware — it knows what page/filters the user has active without being told, and it remembers the conversation across turns. |
| What about data security? | The agent never has direct model access outside its tool — the tool call executes a scoped DAX query via the Power BI REST API using a governed identity. |
| Does it remember earlier questions? | Yes — each browser session gets a `conversationId` mapped to a Foundry thread server-side, so follow-ups like "what was that number again?" resolve correctly. |

---

## Backup Demo Questions (If Live Questions Arise)

- "What merchant categories have the most spend?" → Hospitals ($6.56M), Business Services ($5.56M), Subscription Services ($5.54M)
- "How does spend break down by product?" → Visa Corporate ($21.76M), Visa Commercial ($17.01M), Visa Purchasing ($11.42M)
- "Which industries have the most fraud risk?" → ranked by Fraud Exposure Score (Operations, T&E, Fleet highest)
- "What is the total spend and transaction count?" → $74,812,278.37 across 250,000 transactions, $299.25 average ticket
- "What was the dollar figure you told me a moment ago?" → tests multi-turn conversation memory

---

## Demo Failure Recovery

| Failure | Recovery |
|---------|---------|
| Chat returns error | Fall back to showing the context JSON in DevTools — explain the data flow manually |
| Iframe doesn't load | Refresh token: `curl http://localhost:3000/api/embed-token` then reload |
| Foundry agent timeout | Acknowledge, note it's a dev environment without prod capacity |
| Incorrect answer | Acknowledge it as a calibration item — note `field_map.json` and the DAX pattern library (`semantic/dax/query_patterns.md`) are where accuracy improvements land |
| Wrong number recalled on follow-up | Check server log for `reusing thread` vs `created thread` — confirms whether conversation memory picked up the right session |
