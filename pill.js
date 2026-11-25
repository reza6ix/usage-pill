// The floating pill. Injected on every page; renders only from chrome.storage
// (it never reads anything from the page it sits on).
(() => {
  if (window.top !== window || window.__claudeUsagePill) return;
  window.__claudeUsagePill = true;

  const HOST = location.hostname;
  const alive = () => !!chrome.runtime?.id; // false after the extension is reloaded
  const send = (msg) => { if (alive()) chrome.runtime.sendMessage(msg).catch(() => {}); };

  // ---------- claude.ai fallback: fetch same-origin and hand it to the worker ----------
  if (HOST === 'claude.ai') {
    const sync = async () => {
      if (!alive() || document.visibilityState !== 'visible') return;
      const { usage, orgId } = await chrome.storage.local.get(['usage', 'orgId']);
      if (usage && Date.now() - usage.fetchedAt < 60_000) return;
      try {
        const res = await CU.fetchUsage('/api', orgId);
        send({ type: 'page-usage', raw: res.raw, orgId: res.orgId });
      } catch (_) {}
    };
    sync();
    document.addEventListener('visibilitychange', sync);
    setInterval(sync, 120_000);
  }

  // ---------- DOM ----------
  const host = document.createElement('div');
  host.style.cssText = 'all:initial;position:fixed;z-index:2147483647;display:none;';
  const root = host.attachShadow({ mode: 'closed' });
  root.innerHTML = `
<style>
  :host { all: initial; }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  .wrap { position: relative; font: 500 12px/1 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Inter", system-ui, sans-serif;
          color: #fafafa; -webkit-font-smoothing: antialiased; font-variant-numeric: tabular-nums; letter-spacing: -0.01em; }
  .glass { background: rgba(24, 24, 27, 0.86); backdrop-filter: blur(14px) saturate(1.4); -webkit-backdrop-filter: blur(14px) saturate(1.4);
           border: 1px solid rgba(255,255,255,0.09); box-shadow: 0 8px 28px rgba(0,0,0,0.28), 0 1px 2px rgba(0,0,0,0.3); }

  .pill { display: flex; align-items: center; gap: 7px; height: 30px; padding: 0 11px 0 7px; border-radius: 999px;
          cursor: grab; user-select: none; transition: transform .15s ease, opacity .2s ease; }
  .pill:hover { transform: translateY(-1px); }
  .dragging .pill { cursor: grabbing; transform: scale(1.04); }
  .stale .pill { opacity: .6; }
  .ring { width: 18px; height: 18px; transform: rotate(-90deg); flex: none; }
  .ring circle { fill: none; stroke-width: 2.6; }
  .ring .track { stroke: rgba(255,255,255,0.14); }
  .ring .fill { stroke-linecap: round; transition: stroke-dasharray .5s ease, stroke .3s; }
  .pct { font-weight: 650; }
  .dot { width: 3px; height: 3px; border-radius: 50%; background: rgba(255,255,255,0.3); }
  .left { color: rgba(250,250,250,0.68); }

  .panel { position: absolute; width: 264px; padding: 14px; border-radius: 14px; opacity: 0; pointer-events: none;
           transform: translateY(4px) scale(.98); transition: opacity .16s ease, transform .16s ease; }
  .panel::before { content: ""; position: absolute; left: 0; right: 0; height: 12px; } /* hover bridge */
  .up .panel { bottom: calc(100% + 8px); transform-origin: bottom; }
  .up .panel::before { top: 100%; }
  .down .panel { top: calc(100% + 8px); transform-origin: top; transform: translateY(-4px) scale(.98); }
  .down .panel::before { bottom: 100%; }
  .alignR .panel { right: 0; } .alignL .panel { left: 0; }
  .open .panel { opacity: 1; pointer-events: auto; transform: none; }

  .head { display: flex; align-items: center; justify-content: space-between; margin-bottom: 12px; }
  .title { font-size: 12px; font-weight: 650; color: rgba(250,250,250,0.92); }
  .icon-btn { all: unset; cursor: pointer; width: 22px; height: 22px; display: grid; place-items: center; border-radius: 6px; color: rgba(250,250,250,0.6); }
  .icon-btn:hover { background: rgba(255,255,255,0.08); color: #fff; }
  .spin svg { animation: spin .8s linear infinite; } @keyframes spin { to { transform: rotate(360deg); } }

  .row + .row { margin-top: 12px; }
  .rl { display: flex; justify-content: space-between; align-items: baseline; margin-bottom: 6px; }
  .label { color: rgba(250,250,250,0.72); font-weight: 500; }
  .val { font-weight: 650; }
  .bar { height: 5px; border-radius: 99px; background: rgba(255,255,255,0.09); overflow: hidden; }
  .bar i { display: block; height: 100%; border-radius: 99px; transition: width .5s ease; }
  .sub { margin-top: 6px; font-size: 11px; color: rgba(250,250,250,0.5); }
  .msg { color: rgba(250,250,250,0.75); line-height: 1.45; font-weight: 450; }
  .msg a { color: #fbbf8a; }

  .foot { display: flex; justify-content: space-between; align-items: center; margin-top: 14px; padding-top: 10px;
          border-top: 1px solid rgba(255,255,255,0.07); font-size: 11px; color: rgba(250,250,250,0.45); }
  .foot a { color: rgba(250,250,250,0.7); text-decoration: none; } .foot a:hover { color: #fff; }
  .actions { display: flex; gap: 6px; margin-top: 10px; }
  .actions button { all: unset; cursor: pointer; flex: 1; text-align: center; padding: 6px 0; border-radius: 7px; font-size: 11px;
                    color: rgba(250,250,250,0.6); background: rgba(255,255,255,0.05); }
  .actions button:hover { background: rgba(255,255,255,0.1); color: #fff; }
  kbd { font: inherit; opacity: .6; }
</style>
<div class="wrap up alignR">
  <div class="panel glass">
    <div class="head">
      <span class="title">Claude usage</span>
      <button class="icon-btn" data-act="refresh" title="Refresh">
        <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12a9 9 0 1 1-2.64-6.36"/><path d="M21 3v6h-6"/></svg>
      </button>
    </div>
    <div class="body"></div>
    <div class="foot"><span class="ago"></span><a href="https://claude.ai/settings/usage" target="_blank" rel="noopener">Usage page ↗</a></div>
    <div class="actions">
      <button data-act="hide-site">Hide on this site</button>
      <button data-act="hide-all">Hide <kbd>⌥⇧U</kbd></button>
    </div>
  </div>
  <div class="pill glass">
    <svg class="ring" viewBox="0 0 20 20"><circle class="track" cx="10" cy="10" r="7.5"/><circle class="fill" cx="10" cy="10" r="7.5" stroke-dasharray="0 100"/></svg>
    <span class="pct">—</span><span class="dot"></span><span class="left">Claude</span>
  </div>
</div>`;

  const $ = (s) => root.querySelector(s);
  const wrap = $('.wrap'), pill = $('.pill'), body = $('.body');
  const CIRC = 2 * Math.PI * 7.5;
  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

  let state = { usage: null, status: null, error: null, pillEnabled: true, hiddenHosts: [], pillPos: { right: 20, bottom: 20 } };

  // ---------- render ----------
  function render() {
    const visible = state.pillEnabled && !state.hiddenHosts.includes(HOST) && !document.fullscreenElement;
    host.style.display = visible ? 'block' : 'none';
    if (!visible) return;

    const limits = state.usage?.limits || [];
    const p = CU.primary(limits);
    const now = Date.now();
    const stale = !state.usage || now - state.usage.fetchedAt > 10 * 60_000;
    wrap.classList.toggle('stale', stale && state.status !== 'ok');

    // pill
    const fill = $('.fill');
    if (p) {
      fill.setAttribute('stroke-dasharray', `${(CIRC * Math.max(p.pct, 1.5)) / 100} ${CIRC}`);
      fill.style.stroke = CU.color(p.pct);
      $('.pct').textContent = `${Math.round(p.pct)}%`;
      $('.left').textContent = p.resetsAt ? CU.fmtLeft(p.resetsAt - now) : 'no session';
    } else {
      fill.setAttribute('stroke-dasharray', `0 ${CIRC}`);
      $('.pct').textContent = '—';
      $('.left').textContent = state.status === 'signed_out' ? 'Sign in to Claude' : 'Claude';
    }

    // panel
    if (limits.length) {
      body.innerHTML = limits.map((l) => {
        const left = l.resetsAt ? l.resetsAt - now : null;
        const sub = l.resetsAt ? `Resets in ${CU.fmtLeft(left)} · ${CU.fmtResetAt(l.resetsAt)}` : 'Starts with your next message';
        return `<div class="row">
          <div class="rl"><span class="label">${esc(l.label)}</span><span class="val">${Math.round(l.pct)}%</span></div>
          <div class="bar"><i style="width:${l.pct}%;background:${CU.color(l.pct)}"></i></div>
          <div class="sub">${esc(sub)}</div></div>`;
      }).join('');
    } else if (state.status === 'signed_out') {
      body.innerHTML = `<p class="msg">You're signed out. <a href="https://claude.ai/login" target="_blank" rel="noopener">Log in to claude.ai</a> and this fills in automatically.</p>`;
    } else if (state.status === 'error') {
      body.innerHTML = `<p class="msg">Couldn't reach claude.ai (${esc(state.error || 'error')}). Opening <a href="https://claude.ai" target="_blank" rel="noopener">claude.ai</a> in a tab usually fixes it.</p>`;
    } else {
      body.innerHTML = `<p class="msg">Loading…</p>`;
    }
    $('.ago').textContent = state.status === 'error' && state.usage
      ? `Offline · updated ${CU.fmtAgo(state.usage.fetchedAt)}`
      : `Updated ${CU.fmtAgo(state.usage?.fetchedAt)}`;

    placePanel();
  }

  function applyPos() {
    const r = pill.getBoundingClientRect();
    const w = r.width || 120, h = r.height || 30;
    const right = Math.min(Math.max(state.pillPos.right, 6), innerWidth - w - 6);
    const bottom = Math.min(Math.max(state.pillPos.bottom, 6), innerHeight - h - 6);
    host.style.right = `${right}px`;
    host.style.bottom = `${bottom}px`;
    placePanel();
  }

  function placePanel() {
    const r = pill.getBoundingClientRect();
    wrap.classList.toggle('up', r.top > innerHeight / 2);
    wrap.classList.toggle('down', r.top <= innerHeight / 2);
    wrap.classList.toggle('alignR', r.left + r.width / 2 > innerWidth / 2);
    wrap.classList.toggle('alignL', r.left + r.width / 2 <= innerWidth / 2);
  }

  // ---------- hover to expand ----------
  let openT, closeT, dragging = false;
  wrap.addEventListener('mouseenter', () => {
    clearTimeout(closeT);
    if (dragging) return;
    openT = setTimeout(() => { wrap.classList.add('open'); send({ type: 'refresh' }); }, 90);
  });
  wrap.addEventListener('mouseleave', () => {
    clearTimeout(openT);
    closeT = setTimeout(() => wrap.classList.remove('open'), 220);
  });

  // ---------- drag ----------
  pill.addEventListener('pointerdown', (e) => {
    if (e.button !== 0) return;
    const start = { x: e.clientX, y: e.clientY, right: parseFloat(host.style.right), bottom: parseFloat(host.style.bottom) };
    let moved = false;
    pill.setPointerCapture(e.pointerId);
    const move = (ev) => {
      const dx = ev.clientX - start.x, dy = ev.clientY - start.y;
      if (!moved && Math.hypot(dx, dy) < 4) return;
      if (!moved) { moved = dragging = true; wrap.classList.add('dragging'); wrap.classList.remove('open'); }
      state.pillPos = { right: start.right - dx, bottom: start.bottom - dy };
      applyPos();
    };
    const up = () => {
      pill.removeEventListener('pointermove', move);
      pill.removeEventListener('pointerup', up);
      pill.removeEventListener('pointercancel', up);
      wrap.classList.remove('dragging');
      if (moved && alive()) {
        state.pillPos = { right: parseFloat(host.style.right), bottom: parseFloat(host.style.bottom) };
        chrome.storage.local.set({ pillPos: state.pillPos });
      } else {
        wrap.classList.toggle('open'); // tap = toggle panel (handy on touch / trackpads)
      }
      setTimeout(() => (dragging = false), 0);
    };
    pill.addEventListener('pointermove', move);
    pill.addEventListener('pointerup', up);
    pill.addEventListener('pointercancel', up);
  });

  // ---------- panel buttons ----------
  root.addEventListener('click', (e) => {
    const act = e.target.closest('[data-act]')?.dataset.act;
    if (!act || !alive()) return;
    if (act === 'refresh') {
      const btn = $('[data-act="refresh"]');
      btn.classList.add('spin');
      chrome.runtime.sendMessage({ type: 'refresh', force: true }).catch(() => {}).finally(() => btn.classList.remove('spin'));
    } else if (act === 'hide-site') {
      chrome.storage.local.set({ hiddenHosts: [...new Set([...state.hiddenHosts, HOST])] });
    } else if (act === 'hide-all') {
      chrome.storage.local.set({ pillEnabled: false });
    }
  });

  // ---------- wiring ----------
  const KEYS = ['usage', 'status', 'error', 'pillEnabled', 'hiddenHosts', 'pillPos'];
  chrome.storage.local.get(KEYS).then((s) => {
    state = { ...state, ...Object.fromEntries(Object.entries(s).filter(([, v]) => v != null)) };
    (document.body || document.documentElement).appendChild(host);
    render();
    applyPos();
    const fresh = state.usage && Date.now() - state.usage.fetchedAt < 3 * 60_000;
    if (!fresh) send({ type: 'refresh' });
  });

  chrome.storage.onChanged.addListener((changes, area) => {
    if (area !== 'local') return;
    for (const k of KEYS) if (k in changes) state[k] = changes[k].newValue ?? state[k];
    if ('hiddenHosts' in changes) state.hiddenHosts = changes.hiddenHosts.newValue || [];
    render();
    if ('pillPos' in changes) applyPos();
  });

  // Live countdown — cheap re-render every 20s while the tab is visible.
  setInterval(() => { if (alive() && document.visibilityState === 'visible') render(); }, 20_000);
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState !== 'visible' || !alive()) return;
    render();
    if (!state.usage || Date.now() - state.usage.fetchedAt > 60_000) send({ type: 'refresh' });
  });
  document.addEventListener('fullscreenchange', render);
  addEventListener('resize', applyPos);
})();
