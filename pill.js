// The floating pill. Injected on every page; renders only from chrome.storage
// (it never reads anything from the page it sits on).
(() => {
  if (window.top !== window || window.__claudeUsagePill) return;
  window.__claudeUsagePill = true;

  const HOST = location.hostname;
  const alive = () => !!chrome.runtime?.id; // false after the extension is reloaded
  const send = (msg) => (alive() ? chrome.runtime.sendMessage(msg).catch(() => {}) : Promise.resolve());

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
  // Anchored to the bottom-right of the page, then moved/scaled with a transform so it
  // follows the *visible* area at any zoom (⌘+ or trackpad pinch) and keeps its size.
  host.style.cssText = 'all:initial;position:fixed;right:0;bottom:0;transform-origin:100% 100%;z-index:2147483647;display:none;';
  const root = host.attachShadow({ mode: 'closed' });
  const SPRING = 'cubic-bezier(.2,.9,.25,1.15)';
  root.innerHTML = `
<style>
  :host { all: initial; }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  ${CU.CARD_CSS}

  .wrap { position: relative; }
  .surface { background: #0b0b0c; border: 1px solid rgba(255,255,255,.11);
             box-shadow: inset 0 1px 0 rgba(255,255,255,.07), 0 10px 30px rgba(0,0,0,.38), 0 2px 6px rgba(0,0,0,.3); }

  /* --- the capsule --- */
  .pill { display: flex; align-items: center; gap: 8px; height: 30px; padding: 0 12px 0 8px; border-radius: 999px;
          cursor: grab; user-select: none; -webkit-user-select: none;
          font: 600 12px/1 "SF Pro Text", -apple-system, BlinkMacSystemFont, "Inter", system-ui, sans-serif;
          color: #f5f5f4; -webkit-font-smoothing: antialiased; font-variant-numeric: tabular-nums; letter-spacing: -0.01em;
          transition: height .35s ${SPRING}, padding .35s ${SPRING}, gap .35s ${SPRING}, opacity .2s, transform .2s; }
  .wrap:hover .pill, .open .pill { height: 34px; padding: 0 15px 0 10px; gap: 9px; }
  .dragging .pill { cursor: grabbing; transform: scale(1.05); }
  .stale .pill { opacity: .55; }
  .ring { width: 16px; height: 16px; transform: rotate(-90deg); flex: none; }
  .ring circle { fill: none; stroke-width: 3; }
  .ring .track { stroke: rgba(255,255,255,.14); }
  .ring .fill { stroke-linecap: round; transition: stroke-dasharray .6s ease, stroke .3s; }
  .sep { width: 1px; height: 12px; background: rgba(255,255,255,.16); }
  .left { color: rgba(245,245,244,.6); font-weight: 500; }

  /* --- the card that springs out of it --- */
  .panel { position: absolute; width: 300px; padding: 16px 16px 12px; border-radius: 22px; --x: 0px;
           opacity: 0; pointer-events: none; transform: translateX(var(--x)) translateY(var(--y, 8px)) scale(.92);
           transition: opacity .18s ease, transform .38s ${SPRING}; }
  .panel::before { content: ""; position: absolute; left: 0; right: 0; height: 14px; } /* hover bridge */
  .up .panel   { bottom: calc(100% + 10px); --y: 10px; transform-origin: 50% 100%; } .up .panel::before { top: 100%; }
  .down .panel { top: calc(100% + 10px); --y: -10px; transform-origin: 50% 0; }      .down .panel::before { bottom: 100%; }
  .alignR .panel { right: 0; } .alignL .panel { left: 0; } .alignC .panel { left: 50%; --x: -50%; }
  .open .panel { opacity: 1; pointer-events: auto; transform: translateX(var(--x)) translateY(0) scale(1); }
</style>
<div class="wrap up alignC">
  <div class="panel card surface">
    <div class="card-head"><span class="mark"></span><span class="t">Claude usage</span></div>
    <div class="body"></div>
    <div class="card-foot">
      <button class="btn" data-act="refresh">${CU.ICONS.refresh}<span class="rt">Refresh</span></button>
      <div class="icons">
        <a class="ibtn" href="https://claude.ai/settings/usage" target="_blank" rel="noopener" title="Open Claude's usage page">${CU.ICONS.external}</a>
        <button class="ibtn" data-act="hide-site" title="Hide on this site (⌥⇧U hides everywhere)">${CU.ICONS.eyeOff}</button>
      </div>
    </div>
  </div>
  <div class="pill surface">
    <svg class="ring" viewBox="0 0 20 20"><circle class="track" cx="10" cy="10" r="7.5"/><circle class="fill" cx="10" cy="10" r="7.5" stroke-dasharray="0 100"/></svg>
    <span class="pct">—</span><span class="sep"></span><span class="left">Claude</span>
  </div>
</div>`;

  const $ = (s) => root.querySelector(s);
  const wrap = $('.wrap'), pill = $('.pill'), body = $('.body');
  const CIRC = 2 * Math.PI * 7.5;

  let state = { usage: null, status: null, error: null, pillEnabled: true, hiddenHosts: [], pillPos: null };

  // ---------- render ----------
  function render() {
    const visible = state.pillEnabled && !state.desktopApp && !state.hiddenHosts.includes(HOST) && !document.fullscreenElement;
    host.style.display = visible ? 'block' : 'none';
    if (!visible) return;

    const limits = state.usage?.limits || [];
    const p = CU.primary(limits);
    const now = Date.now();
    const stale = !state.usage || now - state.usage.fetchedAt > 10 * 60_000;
    wrap.classList.toggle('stale', stale && state.status !== 'ok');

    const fill = $('.fill');
    if (p) {
      fill.setAttribute('stroke-dasharray', `${(CIRC * Math.max(p.pct, 2)) / 100} ${CIRC}`);
      fill.style.stroke = CU.color(p.pct);
      $('.pct').textContent = `${Math.round(p.pct)}%`;
      $('.left').textContent = p.resetsAt ? CU.fmtLeft(p.resetsAt - now) : 'idle';
    } else {
      fill.setAttribute('stroke-dasharray', `0 ${CIRC}`);
      $('.pct').textContent = '—';
      $('.left').textContent = state.status === 'signed_out' ? 'Sign in' : 'Claude';
    }

    body.innerHTML = limits.length ? CU.limitsHTML(limits, now) : CU.messageHTML(state.status, state.error);
    $('[data-act="refresh"]').title = `Updated ${CU.fmtAgo(state.usage?.fetchedAt)}`;
    applyPos();
  }

  // ---------- zoom-proof positioning ----------
  // Positions are stored in "screen units" (px at 100% zoom), measured from the
  // bottom-right of what you can actually see.
  let pageZoom = 1; // ⌘+/⌘− factor, reported by the background worker
  let cur = { right: 0, bottom: 0 };
  const vv = window.visualViewport;
  const scale = () => 1 / (pageZoom * (vv ? vv.scale : 1)); // layout px per screen unit
  const view = () => (vv
    ? { x: vv.offsetLeft, y: vv.offsetTop, w: vv.width, h: vv.height }
    : { x: 0, y: 0, w: innerWidth, h: innerHeight });
  const clamp = (n, lo, hi) => Math.min(Math.max(n, lo), Math.max(lo, hi));

  function applyPos() {
    const s = scale(), v = view();
    const w = pill.offsetWidth || 120, h = pill.offsetHeight || 30;
    const W = v.w / s, H = v.h / s; // visible area in screen units
    const pos = state.pillPos || { right: 20, bottom: 20 }; // default: bottom-right corner
    cur = { right: clamp(pos.right, 8, W - w - 8), bottom: clamp(pos.bottom, 8, H - h - 8) };
    const de = document.documentElement;
    const tx = v.x + v.w - cur.right * s - de.clientWidth;
    const ty = v.y + v.h - cur.bottom * s - de.clientHeight;
    host.style.transform = `translate(${tx}px, ${ty}px) scale(${s})`;
    placePanel(W, H, w);
  }

  function placePanel(W, H, w) {
    const up = cur.bottom < H / 2;
    wrap.classList.toggle('up', up);
    wrap.classList.toggle('down', !up);
    const cx = W - cur.right - w / 2;
    const side = cx < 170 ? 'alignL' : cx > W - 170 ? 'alignR' : 'alignC';
    for (const c of ['alignL', 'alignR', 'alignC']) wrap.classList.toggle(c, c === side);
  }

  let rafPending = false;
  const schedulePos = () => {
    if (rafPending) return;
    rafPending = true;
    requestAnimationFrame(() => { rafPending = false; if (host.style.display !== 'none') applyPos(); });
  };
  vv?.addEventListener('resize', schedulePos);
  vv?.addEventListener('scroll', schedulePos);
  chrome.runtime.onMessage.addListener((msg) => {
    if (msg?.type === 'zoom' && msg.zoom > 0) { pageZoom = msg.zoom; schedulePos(); }
  });
  send({ type: 'get-zoom' }).then((z) => { if (z > 0) { pageZoom = z; schedulePos(); } });

  // ---------- hover to expand ----------
  let openT, closeT, dragging = false;
  wrap.addEventListener('mouseenter', () => {
    clearTimeout(closeT);
    if (dragging) return;
    openT = setTimeout(() => { wrap.classList.add('open'); send({ type: 'refresh' }); }, 80);
  });
  wrap.addEventListener('mouseleave', () => {
    clearTimeout(openT);
    closeT = setTimeout(() => wrap.classList.remove('open'), 240);
  });

  // ---------- drag ----------
  pill.addEventListener('pointerdown', (e) => {
    if (e.button !== 0) return;
    const start = { x: e.clientX, y: e.clientY, ...cur, s: scale() };
    let moved = false;
    pill.setPointerCapture(e.pointerId);
    const move = (ev) => {
      const dx = ev.clientX - start.x, dy = ev.clientY - start.y;
      if (!moved && Math.hypot(dx, dy) < 4) return;
      if (!moved) { moved = dragging = true; wrap.classList.add('dragging'); wrap.classList.remove('open'); }
      state.pillPos = { right: start.right - dx / start.s, bottom: start.bottom - dy / start.s };
      applyPos();
    };
    const up = () => {
      pill.removeEventListener('pointermove', move);
      pill.removeEventListener('pointerup', up);
      pill.removeEventListener('pointercancel', up);
      wrap.classList.remove('dragging');
      if (moved && alive()) {
        state.pillPos = { ...cur };
        chrome.storage.local.set({ pillPos: state.pillPos });
      } else {
        wrap.classList.toggle('open'); // tap = toggle the card (handy on trackpads)
      }
      setTimeout(() => (dragging = false), 0);
    };
    pill.addEventListener('pointermove', move);
    pill.addEventListener('pointerup', up);
    pill.addEventListener('pointercancel', up);
  });
  // Double-click the pill to send it back to the bottom-right corner.
  pill.addEventListener('dblclick', () => { state.pillPos = null; chrome.storage.local.remove('pillPos'); applyPos(); });

  // ---------- card buttons ----------
  root.addEventListener('click', async (e) => {
    const el = e.target.closest('[data-act]');
    if (!el || !alive()) return;
    if (el.dataset.act === 'refresh') {
      if (el.classList.contains('busy')) return;
      el.classList.add('busy');
      $('.rt').textContent = 'Refreshing';
      await send({ type: 'refresh', force: true });
      el.classList.remove('busy');
      $('.rt').textContent = 'Updated';
      setTimeout(() => ($('.rt').textContent = 'Refresh'), 1500);
    } else if (el.dataset.act === 'hide-site') {
      chrome.storage.local.set({ hiddenHosts: [...new Set([...state.hiddenHosts, HOST])] });
    }
  });

  // ---------- wiring ----------
  const KEYS = ['usage', 'status', 'error', 'pillEnabled', 'hiddenHosts', 'pillPos', 'desktopApp'];
  chrome.storage.local.get(KEYS).then((s) => {
    for (const k of KEYS) if (s[k] != null) state[k] = s[k];
    (document.body || document.documentElement).appendChild(host);
    render();
    const fresh = state.usage && Date.now() - state.usage.fetchedAt < 3 * 60_000;
    if (!fresh) send({ type: 'refresh' });
  });

  chrome.storage.onChanged.addListener((changes, area) => {
    if (area !== 'local') return;
    for (const k of KEYS) if (k in changes) state[k] = changes[k].newValue ?? null;
    state.hiddenHosts = state.hiddenHosts || [];
    if (state.pillEnabled == null) state.pillEnabled = true;
    render();
  });

  // Live countdown — cheap re-render every 20s while the tab is visible.
  setInterval(() => { if (alive() && document.visibilityState === 'visible') render(); }, 20_000);
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState !== 'visible' || !alive()) return;
    render();
    if (!state.usage || Date.now() - state.usage.fetchedAt > 60_000) send({ type: 'refresh' });
  });
  document.addEventListener('fullscreenchange', render);
  addEventListener('resize', schedulePos);
})();
