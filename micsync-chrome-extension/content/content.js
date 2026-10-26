// Google Meet controller: turns protocol commands into DOM actions and
// answers status polls. Push (observer + message) is gone — the app asks
// when it needs state, so nothing runs between polls.
// Runs in the content-script isolated world; the page itself is never modified.
(() => {
  if (globalThis.__msBridgeLoaded) return;
  globalThis.__msBridgeLoaded = true;

  const P = MS.PATTERNS;
  const WAIT_AFTER_CLICK_MS = 350;
  const PANEL_OPEN_WAIT_MS = 300;

  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

  function labelOf(el) {
    return (
      el.getAttribute('aria-label')
      || el.dataset?.tooltip
      || el.querySelector('[aria-label]')?.getAttribute('aria-label')
      || el.getAttribute('title')
      || ''
    );
  }

  function candidates() {
    return Array.from(document.querySelectorAll('button, [role="button"]'));
  }

  function findButton(pattern) {
    return (
      candidates().find((el) => {
        const label = labelOf(el);
        if (!label || !pattern.test(label)) return false;
        const r = el.getBoundingClientRect();
        return r.width > 0 && r.height > 0; // skip hidden/duplicate overlays
      }) || null
    );
  }

  // Self mic/camera controls live in the bottom control bar. Per-person
  // mic labels (participant tiles, People rows) match the same patterns,
  // so the search requires the label on the element itself (a tile whose
  // descendant icon mentions the mic can never win), keeps the host-control
  // exclusion, and ranks matches by proximity to the bottom-center anchor.
  function findSelfButton(pattern) {
    const anchorX = window.innerWidth / 2;
    const anchorY = window.innerHeight;
    let best = null;
    let bestScore = Infinity;
    for (const el of candidates()) {
      const label =
        el.getAttribute('aria-label') || el.dataset?.tooltip || el.getAttribute('title') || '';
      if (!label || !pattern.test(label) || P.hostControls.test(label)) continue;
      const r = el.getBoundingClientRect();
      if (r.width <= 0 || r.height <= 0) continue; // skip hidden/duplicate overlays
      const score = anchorY - r.bottom + Math.abs(r.left + r.width / 2 - anchorX);
      if (score < bestScore) {
        best = el;
        bestScore = score;
      }
    }
    return best;
  }

  function findControls() {
    return {
      mic: findSelfButton(P.mic),
      cam: findSelfButton(P.camera),
    };
  }

  function readStatus() {
    const { mic, cam } = findControls();
    const inCall = Boolean(mic || cam);
    const muted = mic ? P.stateOn.test(labelOf(mic)) : null;
    const cameraOn = cam ? !P.stateOn.test(labelOf(cam)) : null;
    let handRaised = null;
    const hand = findButton(P.raiseHand);
    if (hand) {
      const pressed = hand.getAttribute('aria-pressed');
      if (pressed != null) handRaised = pressed === 'true';
    }
    return { app: MS.APP_TARGET, inCall, muted, cameraOn, handRaised, title: document.title };
  }

  function click(el) {
    const opts = { bubbles: true, cancelable: true, view: window, pointerId: 1, pointerType: 'mouse', isPrimary: true };
    el.dispatchEvent(new PointerEvent('pointerdown', opts));
    el.dispatchEvent(new MouseEvent('mousedown', opts));
    el.dispatchEvent(new PointerEvent('pointerup', opts));
    el.dispatchEvent(new MouseEvent('mouseup', opts));
    el.dispatchEvent(new MouseEvent('click', opts));
  }

  async function openReactionsPanel() {
    const btn = findButton(P.reactionsPanel);
    if (!btn) return null;
    // The button toggles the panel; only click when it is (probably) closed.
    if (btn.getAttribute('aria-expanded') !== 'true') click(btn);
    await sleep(PANEL_OPEN_WAIT_MS);
    return btn;
  }

  async function pressReaction(value) {
    if (value === 'raise-hand') {
      const opened = await openReactionsPanel();
      if (!opened) return { ok: false, error: 'reactions-panel-not-found' };
      const hand = findButton(P.raiseHand);
      if (!hand) return { ok: false, error: 'raise-hand-button-not-found' };
      click(hand);
      await sleep(WAIT_AFTER_CLICK_MS);
      return { ok: true };
    }
    const pattern = MS.REACTIONS[value];
    if (!pattern) return { ok: false, error: 'unknown-reaction', detail: value };
    const opened = await openReactionsPanel();
    if (!opened) return { ok: false, error: 'reactions-panel-not-found' };
    const target = candidates().find((el) => pattern.test(labelOf(el)));
    if (!target) return { ok: false, error: 'reaction-button-not-found', detail: value };
    click(target);
    await sleep(200);
    return { ok: true };
  }

  async function setMuted(desired) {
    const { mic } = findControls();
    if (!mic) return { ok: false, error: 'mic-button-not-found' };
    if (P.stateOn.test(labelOf(mic)) === desired) return { ok: true };
    click(mic);
    await sleep(WAIT_AFTER_CLICK_MS);
    return { ok: true };
  }

  async function setCameraOn(desired) {
    const { cam } = findControls();
    if (!cam) return { ok: false, error: 'camera-button-not-found' };
    const onNow = !P.stateOn.test(labelOf(cam));
    if (onNow === desired) return { ok: true };
    click(cam);
    await sleep(WAIT_AFTER_CLICK_MS);
    return { ok: true };
  }

  async function handle(action, value) {
    const { mic, cam } = findControls();
    const inCall = Boolean(mic || cam);

    switch (action) {
      case 'get-status':
        return { ok: true, status: readStatus() };
      case 'bring-to-front':
        return { ok: true, status: readStatus() }; // performed by the service worker
      default:
        break;
    }
    if (!inCall) return { ok: false, error: 'not-in-call', status: readStatus() };

    switch (action) {
      case 'toggle-mute': {
        const mutedNow = P.stateOn.test(labelOf(mic));
        return setMuted(!mutedNow);
      }
      case 'mute-on':
        return setMuted(true);
      case 'mute-off':
        return setMuted(false);
      case 'toggle-video': {
        if (!cam) return { ok: false, error: 'camera-button-not-found' };
        const onNow = !P.stateOn.test(labelOf(cam));
        return setCameraOn(!onNow);
      }
      case 'video-on':
        return setCameraOn(true);
      case 'video-off':
        return setCameraOn(false);
      case 'leave': {
        const btn = findButton(P.leave);
        if (!btn) return { ok: false, error: 'leave-button-not-found' };
        click(btn);
        await sleep(200);
        return { ok: true };
      }
      case 'react':
        return pressReaction(value);
      case 'toggle-chat-window': {
        const btn = findButton(P.chat);
        if (!btn) return { ok: false, error: 'chat-button-not-found' };
        click(btn);
        return { ok: true };
      }
      default:
        return { ok: false, error: 'unsupported-action', detail: action };
    }
  }

  chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
    if (msg?.type !== 'command') return false;
    handle(msg.action, msg.value)
      .then((res) => {
        res.status = readStatus();
        sendResponse(res);
      })
      .catch((e) => sendResponse({ ok: false, error: 'content-script-error', detail: String(e) }));
    return true; // async sendResponse
  });
})();
