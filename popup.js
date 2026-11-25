const $ = (id) => document.getElementById(id);

$('card-css').textContent = CU.CARD_CSS;
$('refreshIcon').innerHTML = CU.ICONS.refresh;
$('usage').innerHTML = CU.ICONS.external;

async function render() {
  const s = await chrome.storage.local.get(['usage', 'status', 'error', 'pillEnabled', 'hiddenHosts']);
  const limits = s.usage?.limits || [];
  $('body').innerHTML = limits.length ? CU.limitsHTML(limits) : CU.messageHTML(s.status, s.error);
  $('refresh').title = `Updated ${CU.fmtAgo(s.usage?.fetchedAt)}`;

  // Only mention the pill when it's hidden somewhere — otherwise stay out of the way.
  const hidden = s.hiddenHosts || [];
  const off = s.pillEnabled === false;
  $('hiddenNote').hidden = !off && !hidden.length;
  $('hiddenText').textContent = off ? 'Pill is hidden (⌥⇧U)' : `Pill hidden on ${hidden.length} site${hidden.length === 1 ? '' : 's'}`;
}

$('show').addEventListener('click', () => chrome.storage.local.set({ pillEnabled: true, hiddenHosts: [] }));
$('refresh').addEventListener('click', async () => {
  const btn = $('refresh');
  if (btn.classList.contains('busy')) return;
  btn.classList.add('busy');
  $('refreshText').textContent = 'Refreshing';
  await chrome.runtime.sendMessage({ type: 'refresh', force: true }).catch(() => {});
  btn.classList.remove('busy');
  $('refreshText').textContent = 'Updated';
  setTimeout(() => ($('refreshText').textContent = 'Refresh'), 1500);
});

chrome.storage.onChanged.addListener(render);
render();
chrome.runtime.sendMessage({ type: 'refresh' }).catch(() => {});
setInterval(render, 15_000);
