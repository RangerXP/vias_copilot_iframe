import { getReport } from './embed.js';
import { captureContext } from './context-capture/captureContext.js';

const chatInput = document.getElementById('chat-input');
const sendBtn = document.getElementById('send-btn');
const chatHistory = document.getElementById('chat-history');

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
      body: JSON.stringify({ question, rawContext })
    });
    const data = await res.json();
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
