// Shared helpers — loaded by the background worker, the popup and the pill.
(() => {
  const CU = {};

  // Known limit buckets returned by claude.ai/api/organizations/{org}/usage.
  // Unknown buckets that look like limits are still shown, with a prettified key.
  const LABELS = {
    five_hour: 'Session · 5h',
    seven_day: 'Weekly · all models',
    seven_day_opus: 'Weekly · Opus',
    seven_day_sonnet: 'Weekly · Sonnet',
    seven_day_oauth_apps: 'Weekly · apps',
  };
  const ORDER = Object.keys(LABELS);

  // UI: monochrome until it matters. Toolbar icon keeps saturated colours so it reads on light toolbars too.
  CU.COLORS = { low: '#f5f5f4', mid: '#fbbf24', high: '#fb7185', none: '#52525b' };
  CU.ICON_COLORS = { low: '#22c55e', mid: '#f59e0b', high: '#ef4444', none: '#71717a' };

  CU.level = (pct) => (pct == null ? 'none' : pct >= 80 ? 'high' : pct >= 50 ? 'mid' : 'low');
  CU.color = (pct) => CU.COLORS[CU.level(pct)];
  CU.iconColor = (pct) => CU.ICON_COLORS[CU.level(pct)];

  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  CU.esc = esc;

  CU.ICONS = {
    refresh: '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12a9 9 0 1 1-2.64-6.36"/><path d="M21 3v6h-6"/></svg>',
    external: '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M7 17 17 7"/><path d="M8 7h9v9"/></svg>',
    eyeOff: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10.7 5.1A10 10 0 0 1 12 5c5 0 9 4.5 10 7a13 13 0 0 1-2.2 3.3M6.6 6.6C4.3 8 2.7 10.2 2 12c1 2.5 5 7 10 7 1.9 0 3.6-.6 5-1.5"/><path d="M9.9 9.9a3 3 0 0 0 4.2 4.2"/><path d="m3 3 18 18"/></svg>',
  };

  const SEGMENTS = 24;
  /** One limit: label, big number, countdown, segmented level meter. */
  CU.limitsHTML = (limits, now = Date.now()) =>
    limits.map((l) => {
      const on = l.pct > 0 ? Math.max(1, Math.round((l.pct / 100) * SEGMENTS)) : 0;
      const segs = Array.from({ length: SEGMENTS }, (_, i) => `<i${i < on ? ' class="on"' : ''}></i>`).join('');
      const right = l.resetsAt
        ? `<b>${esc(CU.fmtLeft(l.resetsAt - now))}</b><span>resets ${esc(CU.fmtResetAt(l.resetsAt))}</span>`
        : `<b>—</b><span>starts on next message</span>`;
      return `<div class="lim lvl-${CU.level(l.pct)}">
        <div class="lim-label">${esc(l.label)}</div>
        <div class="lim-top"><div class="lim-num">${Math.round(l.pct)}<small>%</small></div><div class="lim-reset">${right}</div></div>
        <div class="meter">${segs}</div></div>`;
    }).join('');

  CU.messageHTML = (status, error) =>
    status === 'signed_out'
      ? `<p class="msg">You're signed out. <a href="https://claude.ai/login" target="_blank" rel="noopener">Log in to claude.ai</a> and this fills in on its own.</p>`
      : status === 'error'
      ? `<p class="msg">Couldn't reach claude.ai (${esc(error || 'error')}). Opening <a href="https://claude.ai" target="_blank" rel="noopener">claude.ai</a> in a tab usually fixes it.</p>`
      : `<p class="msg">Loading…</p>`;

  /** Shared look for the popup and the in-page card. */
  CU.CARD_CSS = `
  .card { --fg:#f5f5f4; --mut:rgba(245,245,244,.46); --line:rgba(255,255,255,.07);
          font: 500 12px/1.2 "SF Pro Text", -apple-system, BlinkMacSystemFont, "Inter", system-ui, sans-serif;
          color: var(--fg); -webkit-font-smoothing: antialiased; font-variant-numeric: tabular-nums; letter-spacing: -0.01em; }
  .card-head { display:flex; align-items:center; gap:8px; margin-bottom:16px; }
  .card-head .mark { width:6px; height:6px; border-radius:50%; background:#d97757; box-shadow:0 0 10px rgba(217,119,87,.8); }
  .card-head .t { font-size:12px; font-weight:600; color:var(--fg); letter-spacing:0; }
  .lim + .lim { margin-top:18px; }
  .lim-label { font-size:10px; font-weight:600; letter-spacing:.09em; text-transform:uppercase; color:var(--mut); margin-bottom:6px; }
  .lim-top { display:flex; align-items:flex-end; justify-content:space-between; gap:12px; }
  .lim-num { font-size:30px; font-weight:600; letter-spacing:-.04em; line-height:.9; }
  .lim-num small { font-size:15px; font-weight:500; color:var(--mut); margin-left:1px; letter-spacing:0; }
  .lim-reset { text-align:right; line-height:1.3; }
  .lim-reset b { display:block; font-size:13px; font-weight:600; }
  .lim-reset span { display:block; font-size:11px; color:var(--mut); }
  .meter { display:grid; grid-template-columns:repeat(${SEGMENTS},1fr); gap:3px; margin-top:10px; }
  .meter i { height:7px; border-radius:2px; background:rgba(255,255,255,.08); }
  .lvl-low  .meter i.on { background:#f5f5f4; }
  .lvl-mid  .meter i.on { background:#fbbf24; box-shadow:0 0 8px rgba(251,191,36,.45); }
  .lvl-high .meter i.on { background:#fb7185; box-shadow:0 0 8px rgba(251,113,133,.5); }
  .lvl-mid .lim-num { color:#fcd34d; } .lvl-high .lim-num { color:#fda4af; }
  .msg { color:rgba(245,245,244,.78); line-height:1.5; font-weight:450; }
  .msg a { color:#f0a487; }
  .card-foot { display:flex; align-items:center; justify-content:space-between; gap:8px; margin-top:18px; padding-top:12px; border-top:1px solid var(--line); }
  .btn { all:unset; box-sizing:border-box; display:inline-flex; align-items:center; gap:7px; height:30px; padding:0 13px 0 11px; border-radius:999px;
         background:rgba(255,255,255,.08); color:var(--fg); font-size:12px; font-weight:550; cursor:pointer; transition:background .15s, transform .1s; }
  .btn:hover { background:rgba(255,255,255,.14); } .btn:active { transform:scale(.97); }
  .btn.busy svg { animation: cu-spin .7s linear infinite; } @keyframes cu-spin { to { transform: rotate(360deg); } }
  .icons { display:flex; gap:2px; }
  .ibtn { all:unset; box-sizing:border-box; width:30px; height:30px; display:grid; place-items:center; border-radius:999px; color:var(--mut); cursor:pointer; text-decoration:none; }
  .ibtn:hover { background:rgba(255,255,255,.08); color:var(--fg); }
  .note { display:flex; justify-content:space-between; align-items:center; margin-top:10px; font-size:11px; color:var(--mut); }
  .note button { all:unset; cursor:pointer; color:var(--fg); text-decoration:underline; text-underline-offset:2px; }
  [hidden] { display:none !important; }`;

  /** Turn the raw API payload into a sorted list of {key, label, pct, resetsAt}. */
  CU.normalize = (raw) => {
    const limits = [];
    for (const [key, v] of Object.entries(raw || {})) {
      if (!v || typeof v !== 'object' || typeof v.utilization !== 'number') continue;
      const pct = Math.max(0, Math.min(100, v.utilization));
      const resetsAt = v.resets_at ? Date.parse(v.resets_at) : null;
      limits.push({
        key,
        label: LABELS[key] || key.replace(/_/g, ' ').replace(/^\w/, (c) => c.toUpperCase()),
        pct,
        resetsAt: Number.isFinite(resetsAt) ? resetsAt : null,
      });
    }
    const rank = (k) => (ORDER.indexOf(k) === -1 ? 99 : ORDER.indexOf(k));
    return limits.sort((a, b) => rank(a.key) - rank(b.key));
  };

  /** The limit the pill shows up front: the 5-hour session, else the first one. */
  CU.primary = (limits) => (limits || []).find((l) => l.key === 'five_hour') || (limits || [])[0] || null;

  /** "47m", "2h 14m", "3d 4h" */
  CU.fmtLeft = (ms) => {
    if (ms == null) return '—';
    if (ms <= 0) return 'now';
    const m = Math.ceil(ms / 60000);
    if (m < 60) return `${m}m`;
    const h = Math.floor(m / 60), mm = m % 60;
    if (h < 24) return mm ? `${h}h ${mm}m` : `${h}h`;
    const d = Math.floor(h / 24), hh = h % 24;
    return hh ? `${d}d ${hh}h` : `${d}d`;
  };

  /** Toolbar badge (max ~4 chars): "47m", "2h", "3d". */
  CU.fmtBadge = (ms) => {
    if (ms == null) return '';
    if (ms <= 0) return '0m';
    const m = Math.ceil(ms / 60000);
    if (m < 60) return `${m}m`;
    const h = Math.floor(m / 60);
    if (h < 24) return `${h}h`;
    return `${Math.floor(h / 24)}d`;
  };

  CU.fmtResetAt = (ts) => {
    if (!ts) return '';
    const d = new Date(ts);
    const sameDay = d.toDateString() === new Date().toDateString();
    return sameDay
      ? d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })
      : d.toLocaleString([], { weekday: 'short', hour: 'numeric', minute: '2-digit' });
  };

  CU.fmtAgo = (ts) => {
    if (!ts) return 'never';
    const s = Math.round((Date.now() - ts) / 1000);
    if (s < 10) return 'just now';
    if (s < 60) return `${s}s ago`;
    const m = Math.round(s / 60);
    if (m < 60) return `${m}m ago`;
    return `${Math.round(m / 60)}h ago`;
  };

  /**
   * Fetch usage from claude.ai using the browser's logged-in session.
   * `base` is "https://claude.ai/api" from the worker, or "/api" from a claude.ai tab.
   * Returns {raw, orgId}. Throws an Error with .status on HTTP failure.
   */
  CU.fetchUsage = async (base, cachedOrgId) => {
    const getJSON = async (path) => {
      const r = await fetch(base + path, { credentials: 'include', headers: { accept: 'application/json' } });
      const isJSON = (r.headers.get('content-type') || '').includes('json');
      if (!r.ok) {
        const e = new Error(`HTTP ${r.status}`);
        e.status = r.status;
        e.isJSON = isJSON;
        throw e;
      }
      if (!isJSON) throw new Error('Unexpected non-JSON response');
      return r.json();
    };
    const hasLimits = (raw) => CU.normalize(raw).length > 0;

    if (cachedOrgId) {
      try {
        const raw = await getJSON(`/organizations/${cachedOrgId}/usage`);
        if (hasLimits(raw)) return { raw, orgId: cachedOrgId };
      } catch (e) {
        if (e.status === 401) throw e; // signed out — no point retrying other orgs
      }
    }

    const orgs = await getJSON('/organizations');
    // Prefer orgs that can chat (personal/team plans) over API-only orgs.
    const score = (o) => ((o.capabilities || []).includes('chat') ? 1 : 0);
    const sorted = [...(Array.isArray(orgs) ? orgs : [])].sort((a, b) => score(b) - score(a));
    for (const o of sorted) {
      try {
        const raw = await getJSON(`/organizations/${o.uuid}/usage`);
        if (hasLimits(raw)) return { raw, orgId: o.uuid };
      } catch (_) { /* try next org */ }
    }
    throw new Error('No usage limits found on this account');
  };

  /** 401, or a JSON 403 from the API, means "not logged in". A non-JSON 403 is usually a bot wall. */
  CU.isSignedOutError = (e) => e && (e.status === 401 || (e.status === 403 && e.isJSON));

  globalThis.CU = CU;
})();
