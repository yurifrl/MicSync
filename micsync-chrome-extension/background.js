// Service worker: owns the WebSocket connection to the local controller app
// and routes commands to Google Meet tabs. Content scripts own the DOM;
// this file only transports messages and manages connection lifecycle.
import './shared.js';

const EXT_VERSION = chrome.runtime.getManifest().version;
const RECONNECT_BASE_MS = 500;
const RECONNECT_MAX_MS = 30_000;
const PING_INTERVAL_MS = 20_000; // WS activity resets the SW idle timer (Chrome 116+)

let ws = null;
let backoffMs = RECONNECT_BASE_MS;
let reconnectTimer = null;
let pingTimer = null;
let lastError = null;

function isOpen() {
  return Boolean(ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING));
}

function sendRaw(obj) {
  if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj));
}

function broadcastState() {
  chrome.runtime
    .sendMessage({ type: 'state', connected: ws?.readyState === WebSocket.OPEN, error: lastError })
    .catch(() => {}); // popup may be closed
}

function bootstrap() {
  connect();
}

function connect() {
  if (isOpen()) return;
  let ws_;
  try {
    ws_ = new WebSocket(MS.ENDPOINT);
  } catch (e) {
    lastError = `invalid endpoint: ${MS.ENDPOINT}`;
    console.warn('[MicSyncBridge] invalid endpoint', MS.ENDPOINT, e);
    scheduleReconnect();
    return;
  }
  ws = ws_;
  ws.onopen = () => {
    backoffMs = RECONNECT_BASE_MS;
    lastError = null;
    sendRaw({
      type: 'hello',
      client: 'chrome-extension',
      'protocol-version': MS.PROTOCOL_VERSION,
      app: MS.APP_TARGET,
      version: EXT_VERSION,
    });
    startPing();
    broadcastState();
  };
  ws.onmessage = (ev) => onAppMessage(ev.data);
  ws.onclose = () => {
    stopPing();
    ws = null;
    lastError = `controller not reachable at ${MS.ENDPOINT}`;
    broadcastState();
    scheduleReconnect();
  };
  ws.onerror = () => {}; // onclose always follows
}

function scheduleReconnect() {
  if (reconnectTimer) return;
  const delay = Math.round(backoffMs * (0.8 + Math.random() * 0.4));
  backoffMs = Math.min(backoffMs * 2, RECONNECT_MAX_MS);
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connect();
  }, delay);
}

function startPing() {
  stopPing();
  pingTimer = setInterval(() => sendRaw({ type: 'ping' }), PING_INTERVAL_MS);
}

function stopPing() {
  if (pingTimer) {
    clearInterval(pingTimer);
    pingTimer = null;
  }
}

function onAppMessage(raw) {
  let msg;
  try {
    msg = JSON.parse(raw);
  } catch {
    return;
  }
  if (msg?.type === 'pong') return;
  if (typeof msg?.action === 'string') {
    runAction(msg).then((res) => sendRaw({ type: 'result', id: msg.id ?? null, ...res }));
    return;
  }
  if (msg?.type === 'status-request') {
    runAction({ action: 'get-status', id: msg.id }).then((res) => sendRaw({ type: 'result', id: msg.id ?? null, ...res }));
    return;
  }
  // Unknown messages are logged and ignored so the server can evolve independently.
  console.warn('[MicSyncBridge] unrecognized message', raw);
}

async function meetTabs() {
  return chrome.tabs.query({ url: 'https://meet.google.com/*' });
}

// Executes one action and returns the result object. Callers decide where the
// result goes (back to the app over WS, or to the popup via sendResponse).
async function runAction(msg) {
  try {
    if (msg.action === 'bring-to-front') {
      return await bringToFront();
    }
    const tabs = await meetTabs();
    if (!tabs.length) return { ok: false, error: 'no-meet-tab' };
    for (const tab of tabs) {
      try {
        const res = await chrome.tabs.sendMessage(tab.id, { type: 'command', action: msg.action, value: msg.value, id: msg.id ?? null });
        if (res) {
          noteResult(res);
          return res;
        }
      } catch {
        /* tab without content script (e.g. landing page) */
      }
    }
    const res = { ok: false, error: 'no-content-script' };
    noteResult(res);
    return res;
  } catch (e) {
    const res = { ok: false, error: 'bridge-error', detail: String(e) };
    noteResult(res);
    return res;
  }
}

async function bringToFront() {
  const tabs = await meetTabs();
  if (!tabs.length) {
    const res = { ok: false, error: 'no-meet-tab' };
    noteResult(res);
    return res;
  }
  const tab = tabs[0];
  await chrome.tabs.update(tab.id, { active: true });
  if (tab.windowId) await chrome.windows.update(tab.windowId, { focused: true });
  return { ok: true };
}

// Records the outcome of the most recent action so the popup can show it.
function noteResult(res) {
  lastError = res && res.ok === false ? MS.friendlyError(res) : null;
  broadcastState();
}

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  (async () => {
    switch (msg?.type) {
      case 'popup-get-state':
        sendResponse({ connected: ws?.readyState === WebSocket.OPEN, error: lastError });
        break;
      case 'popup-command':
        sendResponse(await runAction({ action: msg.action, value: msg.value, id: `popup-${Date.now()}` }));
        break;
      default:
        sendResponse({ ok: false, error: 'unknown-message' });
    }
  })();
  return true; // async sendResponse
});

chrome.runtime.onInstalled.addListener(bootstrap);
chrome.runtime.onStartup.addListener(bootstrap);
bootstrap(); // also runs on every service-worker wake
