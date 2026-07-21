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
> We use that knowledge to inject context into a Foundry Agent backed by the same semantic model.  
> The result looks and feels like Copilot — without touching the PBIE runtime."

---

## Demo Environment Setup

Before the demo, ensure:

- [ ] Local PBIE server running: `node server/index.js` → `http://localhost:3000`
- [ ] Target Fabric report loaded in iframe (visible in browser)
- [ ] Slicer: **Merchant** visible and operational
- [ ] Filter: **Region** set to **North America** (or relevant region)
- [ ] Chat panel visible alongside the report
- [ ] Network DevTools closed (clean visual)
- [ ] Demo questions loaded in a scratch doc (don't type during demo)

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

**Action:** Set the **Merchant** slicer to **Costco**. Set the **Region** filter to **North America**.

**Talking Point:**
> "The user just filtered the report to Costco in North America.  
> Without any AI, they're seeing whatever the visual shows.  
> Now watch what happens when they ask a question."

**Action:** Type in chat: **"What am I looking at?"**

**Expected response:**  
> "You're viewing the Customer Risk page filtered to Merchant: Costco in Region: North America. The report shows transaction approval rates, decline trends, and risk scores for this merchant in the selected region."

**Talking Point:**
> "The agent didn't guess. It read the active page, filters, and slicers from the report state  
> and queried the semantic model to confirm what data is in scope.  
> That's the context injection."

---

## Scene 3 — Data Question with Context (3 min)

**Action:** Keep Costco / North America selected. Type: **"Why did approval rates decrease?"**

**Expected response:**  
> "For Costco in North America over the selected period, the approval rate declined from X% to Y%.  
> The primary driver was an increase in [decline reason — e.g., insufficient funds / fraud flags].  
> This pattern is consistent with [contextual explanation from model]."

**Talking Point:**
> "Notice — the agent didn't ask 'which merchant?' or 'which region?'  
> It already knew. That's the context injection.  
> And the answer is grounded in the Fabric semantic model — the same measures used in the visual."

---

## Scene 4 — Context Changes with the Report (2 min)

**Action:** Change the **Merchant** slicer to **Target** (or another merchant).

**Action:** Type: **"How does this compare to before?"**

**Expected response:**  
> "You're now viewing Target in North America. [Comparison statement relative to Target's metrics.]"

**Talking Point:**
> "The context updated automatically when the slicer changed.  
> The next question picked up the new state.  
> There's no manual context refresh — it reads the report state on every send."

---

## Scene 5 — Architectural Transparency (2 min)

**Action:** Open DevTools → Network tab. Send a chat message. Show the `/api/chat` POST request and the JSON body.

**Talking Point:**
> "Here's the data flow: the frontend captured the active filters and slicers from the iframe,  
> normalized them into business terms, and sent them to the backend alongside the question.  
> The backend injected the context into a Foundry Agent prompt,  
> which called the Fabric Data Agent as a tool to execute the actual semantic query.  
> The answer came from the model — not from the AI's general knowledge."

---

## Scene 6 — Close + North Star (1 min)

**Talking Point:**
> "This is Pattern 1 — a compatibility architecture.  
> It doesn't require changes to the PBIE runtime.  
> It doesn't require native Copilot support.  
> It works in any App-Owns-Data embedded scenario.  
>  
> The North Star is adding RAG over knowledge sources, conversation memory across pages,  
> and multi-visual context — but the foundation is working today."

---

## Anticipated Questions + Answers

| Question | Answer |
|----------|--------|
| Is this using Copilot for Power BI? | No — native Copilot doesn't run in PBIE. This is a custom Foundry Agent backed by the same Fabric semantic model. |
| What if the semantic model changes? | The Fabric Data Agent reflects the live model. No re-configuration needed. |
| How accurate is the context capture? | It uses the official `powerbi-client` API — same state used by the report runtime. |
| Can this be multi-tenant? | Yes — the embed token and agent are scoped per request. Multi-tenant is a configuration concern, not architectural. |
| Is this production-ready? | The architecture is production-viable. This demo is on a local dev server. Cloud deployment is Sprint 6+. |
| How is this different from a chatbot? | It's context-aware — it knows what the user sees without being told. A generic chatbot has no report state. |
| What about data security? | The Fabric Data Agent respects semantic model RLS. The Foundry Agent never has direct model access — it calls the governed agent tool. |

---

## Backup Demo Questions (If Live Questions Arise)

- "Show me the top 5 merchants by decline rate in this region."
- "Summarize this page."
- "What is the highest risk merchant currently visible?"
- "Is this trend improving or worsening?"

---

## Demo Failure Recovery

| Failure | Recovery |
|---------|---------|
| Chat returns error | Fall back to showing the context JSON in DevTools — explain the data flow manually |
| Iframe doesn't load | Refresh token: `curl http://localhost:3000/api/embed-token` then reload |
| Fabric agent timeout | Acknowledge, note it's a dev environment without prod capacity |
| Incorrect answer | Acknowledge it as a calibration item — note the field_map.json and measure descriptions improve accuracy |
