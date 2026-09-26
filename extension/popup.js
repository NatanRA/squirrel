// Squirrel popup: paste a link, pick a format, and the desktop app saves it to
// its download folder. Downloads run in background.js, so the popup can close.

const api = globalThis.browser ?? globalThis.chrome;
const RELEASES = 'https://github.com/NatanRA/squirrel/releases/latest';
const $ = (id) => document.getElementById(id);

let info = null;

const send = (message) => api.runtime.sendMessage(message);

async function engine(cmd, args) {
  const reply = await send({ type: 'call', cmd, args });
  if (!reply?.ok) throw new Error(reply?.error ?? 'No reply from Squirrel');
  return reply;
}

function showMessage(text, { info: isInfo = false } = {}) {
  const message = $('message');
  message.hidden = !text;
  message.className = isInfo ? 'message info' : 'message';
  message.textContent = '';
  if (text === 'NO_HOST') {
    message.append('Squirrel for desktop needs to be installed and opened once. ');
    const link = Object.assign(document.createElement('a'), { href: RELEASES, target: '_blank', textContent: 'Get Squirrel' });
    message.append(link);
  } else if (text) {
    message.textContent = text;
  }
}

async function fetchFormats(event) {
  event?.preventDefault();
  const url = $('url').value.trim();
  if (!url) return;
  $('fetch').disabled = true;
  $('fetch').textContent = '…';
  $('formats').hidden = true;
  showMessage('Getting formats…', { info: true });
  try {
    info = await engine('extract', { url });
    showMessage('');
    renderFormats();
  } catch (error) {
    showMessage(error.message);
  } finally {
    $('fetch').disabled = false;
    $('fetch').textContent = 'Get';
  }
}

function renderFormats() {
  $('title').textContent = info.title ?? '';
  const video = info.choices.filter((c) => c.kind !== 'audio');
  const audio = info.choices.filter((c) => c.kind === 'audio');
  fill($('video'), video);
  fill($('audio'), audio);
  $('video-group').hidden = !video.length;
  $('audio-group').hidden = !audio.length;
  $('formats').hidden = false;
}

function fill(list, choices) {
  list.replaceChildren(...choices.map((choice) => {
    const item = document.createElement('li');
    item.className = 'choice';
    item.tabIndex = 0;
    const text = document.createElement('div');
    const label = Object.assign(document.createElement('div'), { className: 'label', textContent: choice.label });
    const detail = Object.assign(document.createElement('div'), {
      className: choice.playable === false ? 'detail warn' : 'detail', textContent: choice.detail ?? '',
    });
    text.append(label, detail);
    const arrow = Object.assign(document.createElement('span'), { className: 'arrow', textContent: '↓' });
    item.append(text, arrow);
    const pick = () => startDownload(choice);
    item.addEventListener('click', pick);
    item.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); pick(); } });
    return item;
  }));
}

async function startDownload(choice) {
  await send({
    type: 'download', choice, url: info.webpage_url ?? $('url').value.trim(),
    title: info.title, thumbnail: info.thumbnail,
  });
  info = null;
  $('formats').hidden = true;
  $('url').value = '';
  refreshJobs();
}

async function refreshJobs() {
  const reply = await send({ type: 'jobs' });
  const jobs = reply?.jobs ?? [];
  $('jobs-section').hidden = !jobs.length;
  $('jobs').replaceChildren(...jobs.map(renderJob));
}

function renderJob(job) {
  const item = Object.assign(document.createElement('li'), { className: 'job' });
  const row = Object.assign(document.createElement('div'), { className: 'row' });
  row.append(Object.assign(document.createElement('span'), { className: 'name', textContent: job.title ?? job.url, title: job.title ?? '' }));
  const active = ['starting', 'extracting', 'downloading', 'merging'].includes(job.status);
  if (active) {
    const cancel = Object.assign(document.createElement('button'), { className: 'icon', type: 'button', title: 'Cancel', textContent: '×' });
    cancel.addEventListener('click', () => send({ type: 'cancel', jobId: job.id }));
    row.append(cancel);
  }
  item.append(row);
  if (job.status === 'downloading' || job.status === 'merging') {
    const bar = document.createElement('progress');
    if (job.fraction != null) { bar.max = 1; bar.value = job.fraction; }
    item.append(bar);
  }
  const status = document.createElement('div');
  status.className = job.status === 'failed' ? 'status error' : 'status';
  status.textContent = {
    starting: 'Starting…',
    extracting: 'Preparing…',
    downloading: job.summary || 'Downloading…',
    merging: job.summary || 'Finishing…',
    finished: `${job.label} · Saved as ${job.path?.split(/[\\/]/).pop() ?? 'file'}`,
    cancelled: 'Cancelled',
    failed: job.error === 'NO_HOST' ? 'Squirrel for desktop isn’t installed' : job.error,
  }[job.status] ?? job.status;
  item.append(status);
  return item;
}

async function init() {
  $('form').addEventListener('submit', fetchFormats);
  $('clear').addEventListener('click', async () => { await send({ type: 'clear' }); refreshJobs(); });

  // Start with the current page's address; the field stays editable.
  try {
    const [tab] = await api.tabs.query({ active: true, currentWindow: true });
    if (/^https?:\/\//.test(tab?.url ?? '')) $('url').value = tab.url;
  } catch { /* no tab access; paste instead */ }
  $('url').select();

  refreshJobs();
  setInterval(refreshJobs, 500);

  try {
    const settings = await engine('settings');
    $('footer').textContent = `Saving to ${settings.download_dir}`;
    $('footer').title = settings.download_dir;
  } catch (error) {
    showMessage(error.message);
  }
}

init();
