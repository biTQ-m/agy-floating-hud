/**
 * AGY Floating HUD sidecar server for Antigravity 2.0 Desktop.
 *
 * 1. Supervises the native macOS AgyFloatingHud.app Dynamic Capsule overlay.
 * 2. Provides a <5ms long-polling navigation bridge (`/api/wait-nav` + `/api/ack-nav`)
 *    so clicking any session card in the macOS floating HUD jumps Antigravity Desktop
 *    straight to that exact conversation via official `window.sidecar.ui.toggleConversation`.
 * 3. Serves the redesigned Floating HUD Control Center UI (`/` and `/bridge`).
 */

import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, renameSync, statSync, watch, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { basename, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { SidecarApp, Response } from 'sidecar_sdk';

const __dirname = dirname(fileURLToPath(import.meta.url));
const PLUGIN_ROOT = resolve(__dirname, '..', '..');
const HTML_PATH = join(__dirname, 'web', 'index.html');
const HUD_APP = join(PLUGIN_ROOT, 'macos', 'AgyFloatingHud.app');
const HUD_BIN = join(HUD_APP, 'Contents', 'MacOS', 'AgyFloatingHud');

const DEFAULT_SETTINGS = {
  visible: true,
  pinnedExpanded: false,
  soundEnabled: true,
  autoDimIdle: true,
  opacity: 0.94,
  positionPreset: 'top_right',
  maxSessionsShown: 5,
};

function resolveAppDataDir() {
  const raw = process.env.ANTIGRAVITY_EXECUTABLE_DATA_DIR;
  if (raw) {
    for (let d = raw; d !== dirname(d); d = dirname(d)) {
      if (basename(d) === 'sidecar_data') {
        return dirname(d);
      }
    }
  }
  return join(homedir(), '.gemini', 'antigravity');
}

const APP_DATA_DIR = resolveAppDataDir();
const DATA_DIR = join(APP_DATA_DIR, 'plugin_data', 'agy-floating-hud');
const SETTINGS_FILE = join(DATA_DIR, 'settings.json');
const HELPER_STATUS_FILE = join(DATA_DIR, 'helper_status.json');
const NAV_REQ_FILE = join(DATA_DIR, 'nav_request.json');
const BRIDGE_STATUS_FILE = join(DATA_DIR, 'bridge_status.json');

mkdirSync(DATA_DIR, { recursive: true });

function readJsonSafe(filePath, fallback) {
  try {
    if (!existsSync(filePath)) return fallback;
    return JSON.parse(readFileSync(filePath, 'utf8'));
  } catch {
    return fallback;
  }
}

function writeJsonAtomic(filePath, data) {
  mkdirSync(dirname(filePath), { recursive: true });
  const tmp = `${filePath}.${process.pid}.${Date.now()}.${Math.random().toString(36).slice(2, 7)}.tmp`;
  writeFileSync(tmp, JSON.stringify(data, null, 2), 'utf8');
  renameSync(tmp, filePath);
}

function getUiBuildTag() {
  try {
    return existsSync(HTML_PATH) ? Math.floor(statSync(HTML_PATH).mtimeMs) : 0;
  } catch {
    return 0;
  }
}

function getSettings() {
  const saved = readJsonSafe(SETTINGS_FILE, {});
  return { ...DEFAULT_SETTINGS, ...(saved && typeof saved === 'object' ? saved : {}) };
}

function updateSettings(patch) {
  const curr = getSettings();
  const next = { ...curr };

  if (typeof patch.visible === 'boolean') next.visible = patch.visible;
  if (typeof patch.pinnedExpanded === 'boolean') next.pinnedExpanded = patch.pinnedExpanded;
  if (typeof patch.soundEnabled === 'boolean') next.soundEnabled = patch.soundEnabled;
  if (typeof patch.autoDimIdle === 'boolean') next.autoDimIdle = patch.autoDimIdle;
  if (typeof patch.opacity === 'number' && Number.isFinite(patch.opacity)) {
    next.opacity = Math.min(1, Math.max(0.45, Number(patch.opacity.toFixed(2))));
  }
  if (
    typeof patch.positionPreset === 'string' &&
    ['top_right', 'top_center', 'bottom_right', 'bottom_left', 'custom'].includes(patch.positionPreset)
  ) {
    next.positionPreset = patch.positionPreset;
    if (patch.positionPreset !== 'custom') {
      delete next.customTopCenterX;
      delete next.customTopY;
    }
  }
  if (typeof patch.maxSessionsShown === 'number') {
    next.maxSessionsShown = Math.min(8, Math.max(1, Math.round(patch.maxSessionsShown)));
  }
  if (typeof patch.clearedCompletedBefore === 'number') {
    next.clearedCompletedBefore = patch.clearedCompletedBefore;
    delete next.dismissedSessions;
  }
  if (patch.dismissedSessions && typeof patch.dismissedSessions === 'object') {
    next.dismissedSessions = patch.dismissedSessions;
  }

  writeJsonAtomic(SETTINGS_FILE, next);
  return next;
}

function isPidAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 1) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function getHelperStatus() {
  const installed = process.platform === 'darwin' && existsSync(HUD_BIN);
  const raw = readJsonSafe(HELPER_STATUS_FILE, null);
  const pid = Number(raw?.pid || 0);
  const running = Boolean(pid && isPidAlive(pid));
  return {
    installed,
    running,
    pid: running ? pid : null,
    activeCount: running ? Number(raw?.activeCount || 0) : 0,
    totalTracked: running ? Number(raw?.totalTracked || 0) : 0,
    sessions: running && Array.isArray(raw?.sessions) ? raw.sessions : [],
    updatedAt: raw?.updatedAt || null,
  };
}

function launchHelper() {
  if (process.platform !== 'darwin' || !existsSync(HUD_BIN)) return false;
  if (getHelperStatus().running) return true;
  try {
    const child = spawn('/usr/bin/open', ['-g', '-a', HUD_APP], {
      detached: true,
      stdio: 'ignore',
    });
    child.unref();
    return true;
  } catch {
    return false;
  }
}

function stopHelper() {
  const st = getHelperStatus();
  if (st.running && st.pid) {
    try {
      process.kill(st.pid, 'SIGTERM');
    } catch {
      // ignore
    }
  }
  return true;
}

// --- Instant Conversation Navigation Bridge ---

let latestNav = readJsonSafe(NAV_REQ_FILE, null);
let lastAckedSeq = Number(latestNav?.seq || 0);
const navWaiters = new Set();
let lastClientSeenAt = 0;

function writeBridgeStatus() {
  const connected = navWaiters.size > 0 || Date.now() - lastClientSeenAt < 10_000;
  try {
    writeJsonAtomic(BRIDGE_STATUS_FILE, {
      connected,
      waiters: navWaiters.size,
      lastAckedSeq,
      updatedAt: new Date().toISOString(),
    });
  } catch {
    // ignore
  }
}

function checkNavFileAndWake() {
  const raw = readJsonSafe(NAV_REQ_FILE, null);
  if (!raw || typeof raw !== 'object') return;
  const seq = Number(raw.seq || 0);
  const convId = String(raw.conversationId || '').trim();
  if (!seq || !convId) return;
  if (!latestNav || seq > Number(latestNav.seq || 0)) {
    latestNav = {
      seq,
      conversationId: convId,
      projectId: String(raw.projectId || ''),
      requestedAt: raw.requestedAt || Date.now(),
    };
    const firstWaiter = navWaiters.values().next().value;
    if (firstWaiter) {
      navWaiters.delete(firstWaiter);
      lastAckedSeq = seq;
      firstWaiter(latestNav);
    }
  }
}

try {
  watch(DATA_DIR, (_eventType, filename) => {
    if (!filename || filename === 'nav_request.json' || filename.startsWith('.nav_')) {
      checkNavFileAndWake();
    }
  });
} catch {
  // Fallback fast poll
}
setInterval(checkNavFileAndWake, 150);
setInterval(writeBridgeStatus, 4000);

function getPendingNavFor(sinceSeq) {
  checkNavFileAndWake();
  if (!latestNav) return null;
  const seq = Number(latestNav.seq || 0);
  const ageMs = Date.now() - Number(latestNav.requestedAt || seq);
  if (seq > sinceSeq && seq > lastAckedSeq && ageMs < 15_000) {
    return latestNav;
  }
  return null;
}

function loadHtml() {
  let html = existsSync(HTML_PATH)
    ? readFileSync(HTML_PATH, 'utf8')
    : '<!doctype html><html><body><h3>Floating HUD</h3></body></html>';
  if (!html.includes('/preload.js')) {
    html = html.replace('</head>', '  <script src="/preload.js"></script>\n</head>');
  }
  return html;
}

const app = new SidecarApp();

const serveUiPage = () =>
  new Response(loadHtml(), {
    contentType: 'text/html; charset=utf-8',
  });

app.page('/', serveUiPage);
app.page('/bridge', serveUiPage);

app.api(
  '/api/state',
  () => {
    lastClientSeenAt = Date.now();
    const helper = getHelperStatus();
    return {
      ok: true,
      uiBuildTag: getUiBuildTag(),
      helper,
      bridgeConnected: true,
      settings: getSettings(),
      sessions: helper.sessions || [],
    };
  },
  'GET',
);

app.api(
  '/api/wait-nav',
  (data) => {
    lastClientSeenAt = Date.now();
    const since = Number(data?.since || 0);
    const immediate = getPendingNavFor(since);
    if (immediate) {
      lastAckedSeq = Number(immediate.seq);
      writeBridgeStatus();
      return Promise.resolve({ ok: true, nav: immediate });
    }

    return new Promise((resolvePromise) => {
      const timer = setTimeout(() => {
        navWaiters.delete(onWake);
        writeBridgeStatus();
        resolvePromise({ ok: true, nav: null });
      }, 18_000);

      function onWake(nav) {
        clearTimeout(timer);
        writeBridgeStatus();
        resolvePromise({ ok: true, nav: nav || null });
      }

      navWaiters.add(onWake);
      writeBridgeStatus();
    });
  },
  'GET',
);

app.api(
  '/api/ack-nav',
  (data) => {
    const seq = Number(data?.seq || 0);
    if (seq > lastAckedSeq) {
      lastAckedSeq = seq;
    }
    writeBridgeStatus();
    return { ok: true, lastAckedSeq };
  },
  'POST',
);

app.api(
  '/api/settings',
  (data) => {
    const settings = updateSettings(data || {});
    if (settings.visible) {
      launchHelper();
    }
    return {
      ok: true,
      settings,
      helper: getHelperStatus(),
    };
  },
  'POST',
);

app.api(
  '/api/helper',
  async (data) => {
    const action = data?.action || 'start';
    if (action === 'stop') {
      stopHelper();
    } else if (action === 'restart') {
      stopHelper();
      await new Promise((r) => setTimeout(r, 350));
      launchHelper();
    } else {
      updateSettings({ visible: true });
      launchHelper();
    }
    return {
      ok: true,
      helper: getHelperStatus(),
      settings: getSettings(),
    };
  },
  'POST',
);

app.api(
  '/api/clear-completed',
  () => {
    const helper = getHelperStatus();
    const nowSec = Date.now() / 1000;
    let maxTs = nowSec;
    for (const s of helper.sessions || []) {
      const parsed = Date.parse(s.updatedAt || '');
      if (Number.isFinite(parsed)) {
        maxTs = Math.max(maxTs, parsed / 1000);
      }
    }
    const settings = updateSettings({
      clearedCompletedBefore: maxTs,
    });
    return {
      ok: true,
      settings,
      helper: getHelperStatus(),
    };
  },
  'POST',
);

app.api(
  '/api/dismiss-session',
  (data) => {
    const convId = typeof data?.conversationId === 'string' ? data.conversationId.trim() : '';
    if (!convId) return { ok: false };
    const curr = getSettings();
    const map = { ...(curr.dismissedSessions && typeof curr.dismissedSessions === 'object' ? curr.dismissedSessions : {}) };
    map[convId] = Date.now() / 1000 + 2;
    const settings = updateSettings({ dismissedSessions: map });
    return {
      ok: true,
      settings,
      helper: getHelperStatus(),
    };
  },
  'POST',
);

launchHelper();
writeBridgeStatus();

await app.run();
