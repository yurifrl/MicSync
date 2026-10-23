// Single source of truth for the protocol between the local app and this
// extension. Loaded as a classic script in content scripts / popup, and as an
// ES import in the service worker; everything reads the frozen global `MS`
// so no context can drift from the shared definition.
(() => {
  // A label containing one of these phrases describes the action needed to
  // REACH that state, so for the mic it means "currently muted" and for the
  // camera it means "currently off" (Meet labels buttons by their next action).
  const stateOn = /unmute|ativar|activar|enable|turn on|start/i;
  // Host-only controls ("Mute everyone") must never be mistaken for the
  // caller's own mic/camera buttons.
  const hostControls = /everyone|todos|todas|all\b/i;

  const PATTERNS = {
    mic: /\bmic\b|microphone|micrófono|microfone/i,
    camera: /camera|cámara|câmera|video|vídeo|webcam/i,
    stateOn,
    hostControls,
    leave: /leave call|leave meeting|sair da (chamada|reunião)|abandonar (la )?(llamada|reuni)/i,
    reactionsPanel: /send a reaction|enviar (uma )?reaç|enviar una reacci|reagir/i,
    raiseHand: /raise hand|levantar a m[ãa]o|levantar la mano/i,
    chat: /chat with everyone|conversar com todos|conversar con todos/i,
  };

  // Reaction command value -> label pattern inside the reactions panel.
  const REACTIONS = {
    applause: /applause|aplauso/i,
    laugh: /laugh|risada|risa/i,
    like: /\blike\b|gostei|me gusta/i,
    love: /\blove\b|coraç|coraz|amo\b/i,
    wow: /\bwow\b|uau|guau/i,
    celebrate: /celebrate|celebrar|celebraci/i,
    sad: /\bsad\b|triste/i,
    dislike: /dislike|não gostei|no me gusta/i,
    thinking: /thinking|pensando|pensativo/i,
  };

  globalThis.MS = Object.freeze({
    PROTOCOL_VERSION: '1.0.0',
    APP_TARGET: 'google-meet',
    SUPPORTED_ACTIONS: [
      'get-status', 'toggle-mute', 'mute-on', 'mute-off',
      'toggle-video', 'video-on', 'video-off',
      'leave', 'react', 'toggle-chat-window', 'bring-to-front',
    ],
    REACTION_VALUES: Object.keys(REACTIONS).concat(['raise-hand']),
    PATTERNS,
    REACTIONS,
    // Popup-facing text for the most common failures; unknown codes pass through.
    friendlyError(res) {
      const detail = res.detail ? ` (${res.detail})` : '';
      const MESSAGES = {
        'no-meet-tab': 'No Google Meet tab is open',
        'no-content-script': 'Open a meeting to connect',
        'not-in-call': 'Not in a meeting',
        'invalid-endpoint': `Bad endpoint URL${detail}`,
        'connection-failed': `Controller not reachable at ${this.ENDPOINT}`,
        timeout: `No answer from ${this.ENDPOINT}`,
        'bridge-error': `Bridge error${detail}`,
      };
      return MESSAGES[res.error] ?? `${res.error}${detail}`;
    },

    ENDPOINT: 'ws://127.0.0.1:8895/ws',
    PROTOCOL_VERSION: '1.0.0',
    APP_TARGET: 'google-meet',
  });
})();
