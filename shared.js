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

  CU.COLORS = { low: '#4ade80', mid: '#fbbf24', high: '#f87171', none: '#71717a' };

  CU.level = (pct) => (pct == null ? 'none' : pct >= 80 ? 'high' : pct >= 50 ? 'mid' : 'low');
  CU.color = (pct) => CU.COLORS[CU.level(pct)];

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
