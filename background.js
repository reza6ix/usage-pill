importScripts('shared.js');

const API = 'https://claude.ai/api';
const POLL_MINUTES = 2;
const MIN_REFRESH_GAP_MS = 10_000;

let inflight = null;
let lastAttempt = 0;

// ---------- lifecycle ----------

function init() {
  chrome.alarms.create('poll', { periodInMinutes: POLL_MINUTES });
  chrome.alarms.create('tick', { periodInMinutes: 1 }); // keeps the badge countdown fresh
  chrome.storage.local.get({ pillEnabled: true }).then(({ pillEnabled }) =>
    chrome.storage.local.set({ pillEnabled })
  );
  refresh(true);
}
chrome.runtime.onInstalled.addListener(init);
chrome.runtime.onStartup.addListener(init);

chrome.alarms.onAlarm.addListener(async (a) => {
  if (a.name === 'poll') return refresh(true);
  if (a.name === 'tick') {
    // If a window just reset, fetch the new numbers instead of showing "0m".
    const { usage } = await chrome.storage.local.get('usage');
    const p = CU.primary(usage?.limits);
    if (p?.resetsAt && p.resetsAt <= Date.now()) return refresh(true);
    paint();
  }
});

chrome.commands.onCommand.addListener(async (cmd) => {
  if (cmd !== 'toggle-pill') return;
  const { pillEnabled = true } = await chrome.storage.local.get('pillEnabled');
  chrome.storage.local.set({ pillEnabled: !pillEnabled });
});

// Tell each tab its ⌘+/⌘− zoom so the pill can stay the same size.
chrome.tabs.onZoomChange.addListener(({ tabId, newZoomFactor }) => {
  chrome.tabs.sendMessage(tabId, { type: 'zoom', zoom: newZoomFactor }).catch(() => {});
});

chrome.runtime.onMessage.addListener((msg, sender, reply) => {
  if (msg?.type === 'get-zoom' && sender.tab?.id != null) {
    chrome.tabs.getZoom(sender.tab.id).then(reply, () => reply(1));
    return true;
  }
  if (msg?.type === 'refresh') {
    refresh(!!msg.force).then(() => reply({ ok: true }));
    return true;
  }
  if (msg?.type === 'page-usage' && msg.raw) {
    // A claude.ai tab fetched usage same-origin — use it (fallback if the worker is blocked).
    save(msg.raw, msg.orgId).then(() => reply({ ok: true }));
    return true;
  }
});

// ---------- data ----------

async function refresh(force) {
  if (inflight) return inflight;
  if (!force && Date.now() - lastAttempt < MIN_REFRESH_GAP_MS) return;
  lastAttempt = Date.now();
  inflight = (async () => {
    try {
      const { orgId } = await chrome.storage.local.get('orgId');
      const res = await CU.fetchUsage(API, orgId);
      await save(res.raw, res.orgId);
    } catch (e) {
      await chrome.storage.local.set({
        status: CU.isSignedOutError(e) ? 'signed_out' : 'error',
        error: String(e?.message || e),
        lastAttempt: Date.now(),
      });
      if (CU.isSignedOutError(e)) chrome.storage.local.remove('orgId');
      await paint();
    } finally {
      inflight = null;
    }
  })();
  return inflight;
}

async function save(raw, orgId) {
  const limits = CU.normalize(raw);
  if (!limits.length) return;
  await chrome.storage.local.set({
    usage: { limits, fetchedAt: Date.now() },
    status: 'ok',
    error: null,
    ...(orgId ? { orgId } : {}),
  });
  await paint();
}

// ---------- toolbar icon + badge ----------

// ---------- desktop widget (mac/ app) ----------
// Hand the latest numbers to the Usage Pill Mac app, if it's running. Silent if not.
const DESKTOP = 'http://127.0.0.1:47823/usage';
async function pushDesktop(usage, status) {
  let ok = false;
  try {
    const r = await fetch(DESKTOP, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ limits: usage?.limits || [], fetchedAt: usage?.fetchedAt || null, status: status || null }),
    });
    ok = r.ok;
  } catch (_) { /* app not running */ }
  // While the Mac app is running, the in-page pill steps aside (no double pills).
  const { desktopApp = false } = await chrome.storage.local.get('desktopApp');
  if (desktopApp !== ok) chrome.storage.local.set({ desktopApp: ok });
}

async function paint() {
  const { usage, status } = await chrome.storage.local.get(['usage', 'status']);
  pushDesktop(usage, status);
  const p = CU.primary(usage?.limits);

  if (status === 'signed_out' && !p) {
    await chrome.action.setBadgeText({ text: '?' });
    await chrome.action.setBadgeBackgroundColor({ color: '#71717a' });
    await chrome.action.setTitle({ title: 'Claude usage — sign in at claude.ai' });
    await chrome.action.setIcon({ imageData: ring(null) });
    return;
  }
  if (!p) return;

  const left = p.resetsAt ? p.resetsAt - Date.now() : null;
  await chrome.action.setIcon({ imageData: ring(p.pct) });
  await chrome.action.setBadgeText({ text: p.resetsAt ? CU.fmtBadge(left) : '' });
  await chrome.action.setBadgeBackgroundColor({ color: '#27272a' });
  if (chrome.action.setBadgeTextColor) await chrome.action.setBadgeTextColor({ color: '#fafafa' });

  const lines = usage.limits.map(
    (l) => `${l.label}: ${Math.round(l.pct)}%` + (l.resetsAt ? ` · resets in ${CU.fmtLeft(l.resetsAt - Date.now())}` : '')
  );
  await chrome.action.setTitle({ title: lines.join('\n') });
}

/** Draw a progress ring as the toolbar icon. */
function ring(pct) {
  const out = {};
  for (const size of [16, 32]) {
    const c = new OffscreenCanvas(size, size);
    const g = c.getContext('2d');
    const r = size / 2 - size * 0.14;
    const cx = size / 2, cy = size / 2;
    g.lineWidth = size * 0.2;
    g.lineCap = 'round';
    g.strokeStyle = 'rgba(128,128,128,0.35)';
    g.beginPath();
    g.arc(cx, cy, r, 0, Math.PI * 2);
    g.stroke();
    if (pct != null && pct > 0) {
      g.strokeStyle = CU.iconColor(pct);
      g.beginPath();
      g.arc(cx, cy, r, -Math.PI / 2, -Math.PI / 2 + (Math.PI * 2 * Math.max(pct, 2)) / 100);
      g.stroke();
    }
    out[size] = g.getImageData(0, 0, size, size);
  }
  return out;
}
