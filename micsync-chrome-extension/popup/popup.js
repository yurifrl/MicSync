// Popup: just the bridge indicator — connected / disconnected (with the
// reason when disconnected). Commands and status live with the controller
// app; the extension has nothing to configure and nothing to click.
(() => {
  const $ = (id) => document.getElementById(id);
  const dot = $('dot');
  const conn = $('conn');

  function render(s) {
    dot.className = `dot ${s.connected ? 'on' : 'off'}`;
    conn.textContent = s.connected ? 'connected' : (s.error || 'disconnected');
    conn.classList.toggle('error', !s.connected);
  }

  async function refresh() {
    render(await chrome.runtime.sendMessage({ type: 'popup-get-state' }));
  }

  chrome.runtime.onMessage.addListener((msg) => {
    if (msg?.type === 'state') render(msg);
  });

  refresh();
})();
