import { loadReport } from './embed.js';

// PoC login flow (docs/design_notes.md §17): stands in for a real Visa Portal /
// MSAL.js + Entra ID sign-in. Establishes the HTTP-only session cookie that every
// downstream route (embed-token, chat) resolves entitlement from — the frontend
// never holds or transmits a UPN/customerId itself once signed in.

const overlay = document.getElementById('login-overlay');
const loginError = document.getElementById('login-error');
const appContainer = document.getElementById('app-container');

async function login(customerId) {
  loginError.textContent = '';
  try {
    const res = await fetch('/api/session/login', {
      method: 'POST',
      credentials: 'include',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ customerId })
    });
    if (!res.ok) {
      const data = await res.json().catch(() => ({}));
      throw new Error(data.error || `Login failed: ${res.status}`);
    }
    onSignedIn();
  } catch (err) {
    loginError.textContent = err.message;
  }
}

function onSignedIn() {
  overlay.style.display = 'none';
  appContainer.style.display = '';
  loadReport();
}

async function checkExistingSession() {
  try {
    const res = await fetch('/api/session/me', { credentials: 'include' });
    if (res.ok) {
      onSignedIn();
      return;
    }
  } catch {
    // fall through to showing the login overlay
  }
  overlay.style.display = '';
  appContainer.style.display = 'none';
}

document.querySelectorAll('[data-customer-id]').forEach((btn) => {
  btn.addEventListener('click', () => login(btn.dataset.customerId));
});

checkExistingSession();
