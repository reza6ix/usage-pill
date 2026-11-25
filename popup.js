const $ = (id) => document.getElementById(id);
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

async function render() {
  const s = await chrome.storage.local.get(['usage', 'status', 'error', 'pillEnabled', 'hiddenHosts']);
  const limits = s.usage?.limits || [];
  const now = Date.now();

  if (limits.length) {
    $('body').innerHTML = limits.map((l) => {
      const sub = l.resetsAt
        ? `Resets in ${CU.fmtLeft(l.resetsAt - now)} · ${CU.fmtResetAt(l.resetsAt)}`
        : 'Starts with your next message';
      return `<div class="row">
        <div class="rl"><span class="label">${esc(l.label)}</span><span class="val">${Math.round(l.pct)}%</span></div>
        <div class="bar"><i style="width:${l.pct}%;background:${CU.color(l.pct)}"></i></div>
        <div class="sub">${esc(sub)}</div></div>`;
    }).join('');
  } else if (s.status === 'signed_out') {
    $('body').innerHTML = `<p class="msg">You're signed out. <a href="https://claude.ai/login" target="_blank">Log in to claude.ai</a> and this fills in automatically.</p>`;
  } else if (s.status === 'error') {
    $('body').innerHTML = `<p class="msg">Couldn't reach claude.ai (${esc(s.error || 'error')}). Opening <a href="https://claude.ai" target="_blank">claude.ai</a> in a tab usually fixes it.</p>`;
  }

  $('ago').textContent = `Updated ${CU.fmtAgo(s.usage?.fetchedAt)}`;
  $('pill').checked = s.pillEnabled !== false;
  const hidden = s.hiddenHosts || [];
  $('hiddenLine').hidden = !hidden.length;
  $('hiddenText').textContent = `Hidden on ${hidden.length} site${hidden.length === 1 ? '' : 's'}`;
}

$('pill').addEventListener('change', (e) => chrome.storage.local.set({ pillEnabled: e.target.checked }));
$('unhide').addEventListener('click', () => chrome.storage.local.set({ hiddenHosts: [] }));
$('refresh').addEventListener('click', async () => {
  $('refresh').classList.add('spin');
  await chrome.runtime.sendMessage({ type: 'refresh', force: true }).catch(() => {});
  $('refresh').classList.remove('spin');
});

chrome.storage.onChanged.addListener(render);
render();
chrome.runtime.sendMessage({ type: 'refresh' }).catch(() => {});
setInterval(render, 15_000);
