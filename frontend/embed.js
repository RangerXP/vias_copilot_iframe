let embeddedReport = null;

// Identity/RLS enforcement is driven entirely by the server-managed session
// (docs/design_notes.md §17) — see frontend/session.js for the login flow. This
// module no longer accepts or forwards any client-supplied user identifier; the
// embed token endpoint resolves the entitlement itself from req.session.

async function loadReport() {
  let tokenData;
  try {
    const res = await fetch('/api/embed-token', { credentials: 'include' });
    if (!res.ok) throw new Error(`Embed token request failed: ${res.status}`);
    tokenData = await res.json();
  } catch (err) {
    console.error('[PBIE] Failed to fetch embed token:', err.message);
    document.getElementById('report-container').textContent =
      `Error loading report: ${err.message}`;
    return;
  }

  const { accessToken, embedUrl, reportId } = tokenData;
  const models = window['powerbi-client'].models;

  const config = {
    type: 'report',
    tokenType: models.TokenType.Embed,
    accessToken,
    embedUrl,
    id: reportId,
    settings: {
      filterPaneEnabled: true,
      navContentPaneEnabled: true
    }
  };

  const reportContainer = document.getElementById('report-container');
  embeddedReport = window.powerbi.embed(reportContainer, config);

  embeddedReport.on('loaded', () => {
    console.log('[PBIE] Report loaded');
    window.dispatchEvent(new Event('reportReady'));
  });

  embeddedReport.on('error', (event) => {
    console.error('[PBIE] Embed error:', event.detail);
  });

  // Silently re-issue embed token before 1-hour expiry. The session cookie (not any
  // client-held identifier) is what preserves effectiveIdentity/RLS on every refresh.
  embeddedReport.on('tokenExpired', async () => {
    console.log('[PBIE] Token expired — refreshing');
    try {
      const refreshRes = await fetch('/api/embed-token', { credentials: 'include' });
      const refreshData = await refreshRes.json();
      await embeddedReport.setAccessToken(refreshData.accessToken);
      console.log('[PBIE] Token refreshed');
    } catch (err) {
      console.error('[PBIE] Token refresh failed:', err.message);
    }
  });
}

export function getReport() {
  return embeddedReport;
}

export { loadReport };

