import { getReport, getUserUpn } from './embed.js';
import { captureContext } from './context-capture/captureContext.js';

const chatInput = document.getElementById('chat-input');
const sendBtn = document.getElementById('send-btn');
const chatHistory = document.getElementById('chat-history');

// Sprint 5: persist the conversationId for the browser tab session so follow-up
// questions and page transitions share Foundry thread history instead of each
// request starting a brand-new conversation.
const CONVERSATION_ID_KEY = 'pbie-conversation-id';

function getConversationId() {
  return sessionStorage.getItem(CONVERSATION_ID_KEY);
}

function setConversationId(id) {
  if (id) sessionStorage.setItem(CONVERSATION_ID_KEY, id);
}

function appendMessage(role, text) {
  const div = document.createElement('div');
  div.className = `message ${role}`;
  div.textContent = text;
  chatHistory.appendChild(div);
  chatHistory.scrollTop = chatHistory.scrollHeight;
  return div;
}

async function handleSend() {
  const question = chatInput.value.trim();
  if (!question) return;

  chatInput.value = '';
  sendBtn.disabled = true;
  appendMessage('user', question);

  let rawContext = null;
  try {
    const report = getReport();
    if (report) rawContext = await captureContext(report);
  } catch {
    // context capture is best-effort — proceed without it
  }

  const thinkingEl = appendMessage('assistant', '...');

  try {
    const res = await fetch('/api/chat', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        question,
        rawContext,
        conversationId: getConversationId(),
        // Same UPN used for the embed token's effectiveIdentity (embed.js) — so
        // XMLA queries in the chat/agent path enforce RLS for the same user
        // (docs/design_notes.md Section 15d).
        user: getUserUpn()
      })
    });
    const data = await res.json();
    setConversationId(data.conversationId);
    thinkingEl.textContent = data.answer || data.error || 'No response.';
  } catch (err) {
    thinkingEl.textContent = `Error: ${err.message}`;
  } finally {
    sendBtn.disabled = false;
    chatInput.focus();
  }
}

sendBtn.addEventListener('click', handleSend);
chatInput.addEventListener('keydown', (e) => {
  if (e.key === 'Enter') handleSend();
});
