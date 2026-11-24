import { GestureEngine } from './gesture-engine.js';

const STORAGE_TOKEN_KEY = 'airtrackpad_token';
const STORAGE_OVERRIDDEN_URL_TOKEN_KEY = 'airtrackpad_overridden_url_token';
const STORAGE_SETTINGS_KEY = 'airtrackpad_settings_v1';

const defaultSettings = {
  pointerSensitivity: 1.2,
  pointerAcceleration: true,
  scrollSpeed: 1.0,
  naturalScroll: true,
  naturalSpaces: true,
  dragRelayMs: 400,
  orientationLock: 'auto',
  showFeedbackPill: true,
  keepAwake: false
};

function loadSettings() {
  try {
    const raw = localStorage.getItem(STORAGE_SETTINGS_KEY);
    if (!raw) return { ...defaultSettings };
    const parsed = JSON.parse(raw);
    return { ...defaultSettings, ...parsed };
  } catch {
    return { ...defaultSettings };
  }
}

function saveSettings(settings) {
  try {
    localStorage.setItem(STORAGE_SETTINGS_KEY, JSON.stringify(settings));
  } catch {
    // Ignore storage quota errors in Private Browsing
  }
}

function resolveToken() {
  const params = new URLSearchParams(window.location.search);
  const urlToken = params.get('token')?.trim();
  let storedToken = '';
  let overriddenUrlToken = '';
  try {
    storedToken = localStorage.getItem(STORAGE_TOKEN_KEY)?.trim() || '';
    overriddenUrlToken = localStorage.getItem(STORAGE_OVERRIDDEN_URL_TOKEN_KEY)?.trim() || '';
  } catch {
    // Ignore storage errors
  }

  if (urlToken) {
    if (overriddenUrlToken && urlToken === overriddenUrlToken && storedToken) {
      return storedToken;
    }
    try {
      localStorage.removeItem(STORAGE_OVERRIDDEN_URL_TOKEN_KEY);
      localStorage.setItem(STORAGE_TOKEN_KEY, urlToken);
    } catch {
      // Ignore storage errors
    }
    return urlToken;
  }
  return storedToken;
}

const trackpadEl = document.getElementById('trackpad');
const statusPillEl = document.getElementById('status-pill');
const settingsBtn = document.getElementById('settings-btn');
const settingsDialog = document.getElementById('settings-dialog');
const connDotEl = document.getElementById('conn-dot');
const connLabelEl = document.getElementById('conn-label');
const connSubtitleEl = document.getElementById('conn-subtitle');
const connDetailEl = document.getElementById('conn-detail');
const reconnectBtn = document.getElementById('reconnect-btn');
const tokenBoxEl = document.getElementById('token-box');
const tokenInputEl = document.getElementById('token-input');
const saveTokenBtn = document.getElementById('save-token-btn');

const pointerSensEl = document.getElementById('pointer-sens');
const pointerSensValEl = document.getElementById('pointer-sens-val');
const pointerAccelEl = document.getElementById('pointer-accel');
const scrollSpeedEl = document.getElementById('scroll-speed');
const scrollSpeedValEl = document.getElementById('scroll-speed-val');
const naturalScrollEl = document.getElementById('natural-scroll');
const naturalSpacesEl = document.getElementById('natural-spaces');
const dragRelayEl = document.getElementById('drag-relay');
const dragRelayValEl = document.getElementById('drag-relay-val');
const orientationLockEl = document.getElementById('orientation-lock');
const feedbackPillEl = document.getElementById('feedback-pill');
const keepAwakeEl = document.getElementById('keep-awake');

let settings = loadSettings();
let token = resolveToken();
let ws = null;
let reconnectTimer = null;
let heartbeatTimer = null;
let reconnectDelayMs = 400;
let lastHostName = window.location.host;
let lastRttMs = null;
let pillHideTimer = null;

let wakeLockSentinel = null;
let silentKeepAwakeVideo = null;

function showPill(text) {
  if (!settings.showFeedbackPill || !text) return;
  statusPillEl.textContent = text;
  statusPillEl.classList.add('visible');
  clearTimeout(pillHideTimer);
  pillHideTimer = setTimeout(() => {
    statusPillEl.classList.remove('visible');
  }, 900);
}

function gestureLabel(ev) {
  switch (ev.t) {
    case 'click':
      if (ev.count === 2) return '双击';
      if (ev.count === 3) return '三击';
      return null;
    case 'rightClick':
      return '右键';
    case 'dragStart':
      return '三指拖动';
    case 'dragEnd':
      return '释放拖动';
    case 'lookup':
      return '查词 Look Up';
    case 'pinchBegin':
      return '双指缩放';
    case 'spread4':
      return '显示桌面';
    case 'pinch4':
      return '启动台';
    case 'swipe4':
      if (ev.dir === 'up') return '调度中心';
      if (ev.dir === 'down') return 'App Exposé';
      if (ev.dir === 'left') return ev.naturalSpaces ? '右侧桌面' : '左侧桌面';
      if (ev.dir === 'right') return ev.naturalSpaces ? '左侧桌面' : '右侧桌面';
      return null;
    default:
      return null;
  }
}

function updateConnectionUI(state, detail = '') {
  connDotEl.classList.remove('ok', 'err');
  if (state === 'connected') {
    connDotEl.classList.add('ok');
    connLabelEl.textContent = '已连接';
    const rttPart = lastRttMs !== null ? ` · 延迟 ${Math.round(lastRttMs)} ms` : '';
    connSubtitleEl.textContent = `${lastHostName}${rttPart}`;
    connDetailEl.textContent = detail || `地址：${window.location.host}`;
    tokenBoxEl.hidden = true;
  } else if (state === 'unauthorized') {
    connDotEl.classList.add('err');
    connLabelEl.textContent = '配对码无效或已重置';
    connSubtitleEl.textContent = '请重新扫码或输入新配对码';
    connDetailEl.textContent = detail || 'Mac 端重置了配对码或链接未携带 Token。';
    tokenBoxEl.hidden = false;
    tokenInputEl.value = token;
  } else if (state === 'connecting') {
    connLabelEl.textContent = '正在连接…';
    connSubtitleEl.textContent = window.location.host;
    connDetailEl.textContent = detail || '等待与 Mac 建立 WebSocket 通道…';
    tokenBoxEl.hidden = !token ? false : true;
  } else {
    connDotEl.classList.add('err');
    connLabelEl.textContent = '已断开';
    connSubtitleEl.textContent = '将自动重连';
    connDetailEl.textContent = detail || `目标主机：${window.location.host}`;
    tokenBoxEl.hidden = false;
    if (document.activeElement !== tokenInputEl) {
      tokenInputEl.value = token;
    }
  }
}

function sendEvent(ev) {
  const label = gestureLabel(ev);
  if (label) {
    showPill(label);
  }
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(ev));
  }
}

const engine = new GestureEngine({
  ...settings,
  onEvent: sendEvent
});

function syncSettingsUI() {
  pointerSensEl.value = String(settings.pointerSensitivity);
  pointerSensValEl.textContent = `${Number(settings.pointerSensitivity).toFixed(2)}x`;
  pointerAccelEl.checked = Boolean(settings.pointerAcceleration);

  scrollSpeedEl.value = String(settings.scrollSpeed);
  scrollSpeedValEl.textContent = `${Number(settings.scrollSpeed).toFixed(2)}x`;
  naturalScrollEl.checked = Boolean(settings.naturalScroll);
  naturalSpacesEl.checked = Boolean(settings.naturalSpaces);

  dragRelayEl.value = String(settings.dragRelayMs);
  dragRelayValEl.textContent = settings.dragRelayMs > 0 ? `${settings.dragRelayMs} ms` : '关闭';

  orientationLockEl.value = settings.orientationLock || 'auto';
  feedbackPillEl.checked = Boolean(settings.showFeedbackPill);
  keepAwakeEl.checked = Boolean(settings.keepAwake);
}

function applySettingsUpdate(partial) {
  settings = { ...settings, ...partial };
  saveSettings(settings);
  engine.updateOptions(settings);
  syncSettingsUI();
}

function currentViewport() {
  const apiAngle = window.screen?.orientation?.angle;
  const legacyAngle = typeof window.orientation === 'number' ? window.orientation : undefined;
  const isLandscape = window.innerWidth > window.innerHeight;
  const angle = (isLandscape && apiAngle === 0 && legacyAngle && legacyAngle !== 0)
    ? legacyAngle
    : (apiAngle ?? legacyAngle ?? 0);
  return {
    orientationLock: settings.orientationLock,
    viewportWidth: window.innerWidth,
    viewportHeight: window.innerHeight,
    screenAngle: angle
  };
}

function convertTouches(touchList) {
  const out = [];
  for (let i = 0; i < touchList.length; i += 1) {
    const t = touchList[i];
    out.push({ id: t.identifier, x: t.clientX, y: t.clientY });
  }
  return out;
}

trackpadEl.addEventListener(
  'touchstart',
  (e) => {
    if (settingsDialog.open) return;
    e.preventDefault();
    ensureKeepAwakeActive();
    engine.touchStart(
      convertTouches(e.changedTouches),
      performance.now(),
      currentViewport(),
      convertTouches(e.touches)
    );
  },
  { passive: false }
);

trackpadEl.addEventListener(
  'touchmove',
  (e) => {
    if (settingsDialog.open) return;
    e.preventDefault();
    engine.touchMove(
      convertTouches(e.changedTouches),
      performance.now(),
      currentViewport(),
      convertTouches(e.touches)
    );
  },
  { passive: false }
);

trackpadEl.addEventListener(
  'touchend',
  (e) => {
    if (settingsDialog.open) return;
    e.preventDefault();
    engine.touchEnd(
      convertTouches(e.changedTouches),
      performance.now(),
      currentViewport(),
      convertTouches(e.touches)
    );
  },
  { passive: false }
);

trackpadEl.addEventListener(
  'touchcancel',
  (e) => {
    e.preventDefault();
    engine.cancelAll();
  },
  { passive: false }
);

settingsBtn.addEventListener('touchstart', (e) => e.stopPropagation(), { passive: true });
settingsBtn.addEventListener('click', () => {
  engine.cancelAll();
  syncSettingsUI();
  if (!settingsDialog.open) {
    settingsDialog.showModal();
  }
});

// Fallback light dismiss when clicking backdrop (Safari lacks <dialog closedby="any">)
let pressedOutsideDialog = false;
const isOutsideDialog = (e) => {
  const r = settingsDialog.getBoundingClientRect();
  return e.clientX < r.left || e.clientX > r.right || e.clientY < r.top || e.clientY > r.bottom;
};
settingsDialog.addEventListener('pointerdown', (e) => {
  pressedOutsideDialog = isOutsideDialog(e);
});
settingsDialog.addEventListener('pointerup', (e) => {
  if (pressedOutsideDialog && isOutsideDialog(e)) {
    settingsDialog.close();
  }
  pressedOutsideDialog = false;
});
settingsDialog.addEventListener('pointercancel', () => {
  pressedOutsideDialog = false;
});

pointerSensEl.addEventListener('input', () => {
  applySettingsUpdate({ pointerSensitivity: parseFloat(pointerSensEl.value) });
});
pointerAccelEl.addEventListener('change', () => {
  applySettingsUpdate({ pointerAcceleration: pointerAccelEl.checked });
});
scrollSpeedEl.addEventListener('input', () => {
  applySettingsUpdate({ scrollSpeed: parseFloat(scrollSpeedEl.value) });
});
naturalScrollEl.addEventListener('change', () => {
  applySettingsUpdate({ naturalScroll: naturalScrollEl.checked });
});
naturalSpacesEl.addEventListener('change', () => {
  applySettingsUpdate({ naturalSpaces: naturalSpacesEl.checked });
});
dragRelayEl.addEventListener('input', () => {
  applySettingsUpdate({ dragRelayMs: parseInt(dragRelayEl.value, 10) });
});
orientationLockEl.addEventListener('change', () => {
  applySettingsUpdate({ orientationLock: orientationLockEl.value });
});
feedbackPillEl.addEventListener('change', () => {
  applySettingsUpdate({ showFeedbackPill: feedbackPillEl.checked });
});
keepAwakeEl.addEventListener('change', () => {
  applySettingsUpdate({ keepAwake: keepAwakeEl.checked });
  if (settings.keepAwake) {
    ensureKeepAwakeActive();
  } else {
    releaseKeepAwake();
  }
});

reconnectBtn.addEventListener('click', () => {
  reconnectNow();
});

saveTokenBtn.addEventListener('click', () => {
  const candidate = tokenInputEl.value.trim();
  if (!candidate) return;
  token = candidate;
  const urlToken = new URLSearchParams(window.location.search).get('token')?.trim() || '';
  try {
    if (urlToken && urlToken !== candidate) {
      localStorage.setItem(STORAGE_OVERRIDDEN_URL_TOKEN_KEY, urlToken);
    } else {
      localStorage.removeItem(STORAGE_OVERRIDDEN_URL_TOKEN_KEY);
    }
    localStorage.setItem(STORAGE_TOKEN_KEY, token);
  } catch {
    // Ignore storage errors
  }
  reconnectNow();
});

async function ensureKeepAwakeActive() {
  if (!settings.keepAwake || document.visibilityState !== 'visible') return;

  if ('wakeLock' in navigator && !wakeLockSentinel) {
    try {
      wakeLockSentinel = await navigator.wakeLock.request('screen');
      wakeLockSentinel.addEventListener('release', () => {
        wakeLockSentinel = null;
      });
      return;
    } catch {
      // Fallback below when user opted in
    }
  }

  if (!wakeLockSentinel && !silentKeepAwakeVideo) {
    try {
      const canvas = document.createElement('canvas');
      canvas.width = 2;
      canvas.height = 2;
      const ctx = canvas.getContext('2d');
      if (ctx) {
        ctx.fillStyle = '#000000';
        ctx.fillRect(0, 0, 2, 2);
      }
      if (typeof canvas.captureStream === 'function') {
        const video = document.createElement('video');
        video.muted = true;
        video.playsInline = true;
        video.loop = true;
        video.srcObject = canvas.captureStream(1);
        silentKeepAwakeVideo = video;
        await video.play();
      }
    } catch {
      silentKeepAwakeVideo = null;
    }
  }
}

function releaseKeepAwake() {
  if (wakeLockSentinel) {
    wakeLockSentinel.release().catch(() => {});
    wakeLockSentinel = null;
  }
  if (silentKeepAwakeVideo) {
    try {
      silentKeepAwakeVideo.pause();
      silentKeepAwakeVideo.srcObject = null;
    } catch {
      // Ignore cleanup errors
    }
    silentKeepAwakeVideo = null;
  }
}

function stopHeartbeat() {
  clearInterval(heartbeatTimer);
  heartbeatTimer = null;
}

function startHeartbeat() {
  stopHeartbeat();
  heartbeatTimer = setInterval(() => {
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ t: 'ping', ts: performance.now() }));
    }
  }, 2000);
}

function scheduleReconnect() {
  clearTimeout(reconnectTimer);
  const delay = reconnectDelayMs;
  reconnectDelayMs = Math.min(5000, Math.round(reconnectDelayMs * 1.8));
  reconnectTimer = setTimeout(() => {
    connectWebSocket();
  }, delay);
}

function reconnectNow() {
  clearTimeout(reconnectTimer);
  reconnectDelayMs = 400;
  connectWebSocket();
}

function connectWebSocket() {
  clearTimeout(reconnectTimer);
  stopHeartbeat();

  if (ws) {
    try {
      ws.onopen = null;
      ws.onmessage = null;
      ws.onerror = null;
      ws.onclose = null;
      ws.close();
    } catch {
      // Ignore close error
    }
    ws = null;
  }

  if (!token) {
    updateConnectionUI('unauthorized', 'URL 中缺少配对 Token，请使用 Mac 菜单栏二维码重新打开。');
    return;
  }

  updateConnectionUI('connecting');
  const proto = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
  const url = `${proto}//${window.location.host}/ws?token=${encodeURIComponent(token)}`;
  const socket = new WebSocket(url);
  ws = socket;

  socket.onopen = () => {
    if (ws !== socket) return;
    reconnectDelayMs = 400;
    lastRttMs = null;
    updateConnectionUI('connected');
    startHeartbeat();
    showPill('已连接 Mac');
  };

  socket.onmessage = (event) => {
    if (ws !== socket) return;
    try {
      const msg = JSON.parse(event.data);
      if (msg.t === 'pong' && typeof msg.ts === 'number') {
        lastRttMs = Math.max(0, performance.now() - msg.ts);
        if (settingsDialog.open) {
          updateConnectionUI('connected');
        }
      } else if (msg.t === 'hello' && msg.host) {
        lastHostName = msg.host;
        updateConnectionUI('connected');
      }
    } catch {
      // Ignore malformed server payload
    }
  };

  socket.onerror = () => {
    // Wait for onclose to trigger reconnect
  };

  socket.onclose = (event) => {
    if (ws !== socket) return;
    stopHeartbeat();
    engine.cancelAll();
    if (event.code === 4001) {
      updateConnectionUI('unauthorized', 'Mac 已重置配对码，请扫描新二维码或输入新配对码。');
      return;
    }
    updateConnectionUI('disconnected');
    if (document.visibilityState === 'visible') {
      scheduleReconnect();
    }
  };
}

document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'hidden') {
    engine.cancelAll();
    releaseKeepAwake();
  } else {
    ensureKeepAwakeActive();
    if (!ws || ws.readyState === WebSocket.CLOSED) {
      reconnectNow();
    }
  }
});

window.addEventListener('pagehide', () => {
  engine.cancelAll();
  releaseKeepAwake();
});

window.addEventListener('online', () => {
  reconnectNow();
});

syncSettingsUI();
connectWebSocket();
