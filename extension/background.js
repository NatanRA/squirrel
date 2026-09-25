// Squirrel's background worker: owns the connection to the desktop app's
// download engine (native messaging) so downloads keep going after the popup
// closes. The popup talks to this worker with runtime messages.

const api = globalThis.browser ?? globalThis.chrome;
const HOST = 'com.natan.squirrel';  // desktop/*/NativeMessaging registers this
const IDLE_DISCONNECT_MS = 60_000;   // lets the engine exit once nothing is running

let port = null;
let nextId = 1;
const pending = new Map();  // request id -> {resolve, reject}
const jobs = new Map();     // job id -> job shown in the popup
let idleTimer = null;

function connect() {
  if (port) return port;
  port = api.runtime.connectNative(HOST);
  port.onMessage.addListener((message) => {
    const request = pending.get(message.id);
    if (!request) return;
    pending.delete(message.id);
    request.resolve(message);
  });
  port.onDisconnect.addListener((disconnected) => {
    const reason = disconnected.error?.message ?? api.runtime.lastError?.message ?? '';
    const error = describeDisconnect(reason);
    port = null;
    for (const request of pending.values()) request.reject(new Error(error));
    pending.clear();
    for (const job of jobs.values()) {
      if (isActive(job)) Object.assign(job, { status: 'failed', error });
    }
  });
  return port;
}

function describeDisconnect(reason) {
  if (/not found|no such native application|not registered|specified native messaging host/i.test(reason)) {
    return 'NO_HOST';
  }
  return reason ? `The Squirrel app stopped: ${reason}` : 'The Squirrel app stopped unexpectedly';
}

/** Sends one command to the engine (see desktop/host/squirrel_host.py). */
function call(cmd, args = {}) {
  clearTimeout(idleTimer);
  return new Promise((resolve, reject) => {
    const id = nextId++;
    pending.set(id, { resolve, reject });
    try {
      connect().postMessage({ id, cmd, args });
    } catch (error) {
      pending.delete(id);
      reject(new Error(describeDisconnect(error.message)));
    }
  }).finally(scheduleIdleDisconnect);
}

function scheduleIdleDisconnect() {
  clearTimeout(idleTimer);
  if ([...jobs.values()].some(isActive)) return;
  idleTimer = setTimeout(() => {
    if (port && ![...jobs.values()].some(isActive) && pending.size === 0) {
      port.disconnect();
      port = null;
    }
  }, IDLE_DISCONNECT_MS);
}

const isActive = (job) => ['starting', 'extracting', 'downloading', 'merging'].includes(job.status);

async function download({ url, title, thumbnail, choice }) {
  const jobId = crypto.randomUUID();
  const job = { id: jobId, url, title, thumbnail, label: choice.label, audio: choice.kind === 'audio',
    status: 'starting', fraction: null, summary: '', path: null, error: null };
  jobs.set(jobId, job);
  trimFinished();

  const poll = setInterval(async () => {
    try {
      updateProgress(job, await call('progress', { job_id: jobId }));
    } catch { /* the download call reports the failure */ }
  }, 500);
  try {
    const result = await call('download', {
      url, title, job_id: jobId, format_ids: choice.format_ids, ext: choice.ext ?? '', audio: job.audio,
    });
    if (result.ok) Object.assign(job, { status: 'finished', path: result.path, title: result.title ?? title });
    else if (result.cancelled) job.status = 'cancelled';
    else Object.assign(job, { status: 'failed', error: result.error ?? 'Download failed' });
  } catch (error) {
    Object.assign(job, { status: 'failed', error: error.message });
  } finally {
    clearInterval(poll);
    scheduleIdleDisconnect();
  }
}

function updateProgress(job, progress) {
  if (!isActive(job) || !progress?.ok) return;
  if (progress.status === 'merging') {
    Object.assign(job, { status: 'merging', fraction: 1, summary: progress.parts > 1 ? 'Merging audio and video…' : 'Finishing…' });
  } else if (progress.status === 'downloading') {
    const { downloaded = 0, total = 0, speed = 0, part = 1, parts = 1 } = progress;
    const fraction = total > 0 ? (part - 1 + Math.min(downloaded / total, 1)) / Math.max(parts, 1) : null;
    const summary = [
      parts > 1 ? (part === 1 ? 'Video' : 'Audio') : null,
      total > 0 ? `${size(downloaded)} of ${size(total)}` : size(downloaded),
      speed > 0 ? `${size(speed)}/s` : null,
    ].filter(Boolean).join(' · ');
    Object.assign(job, { status: 'downloading', fraction, summary });
  } else if (progress.status === 'extracting') {
    job.status = 'extracting';
  }
}

function size(bytes) {
  const units = ['B', 'KB', 'MB', 'GB'];
  let i = 0;
  while (bytes >= 1024 && i < units.length - 1) { bytes /= 1024; i++; }
  return `${bytes.toFixed(i < 2 ? 0 : 1)} ${units[i]}`;
}

/** Keep the popup's list short: the newest finished jobs plus anything running. */
function trimFinished() {
  const done = [...jobs.values()].filter((job) => !isActive(job));
  for (const job of done.slice(0, Math.max(0, done.length - 5))) jobs.delete(job.id);
}

api.runtime.onMessage.addListener((message, sender, sendResponse) => {
  (async () => {
    switch (message.type) {
      case 'call':  // start, extract, settings
        return await call(message.cmd, message.args);
      case 'download':
        download(message);
        return { ok: true };
      case 'cancel':
        return await call('cancel', { job_id: message.jobId });
      case 'jobs':
        return { ok: true, jobs: [...jobs.values()].reverse() };
      case 'clear':
        for (const job of [...jobs.values()]) if (!isActive(job)) jobs.delete(job.id);
        return { ok: true };
      default:
        return { ok: false, error: `Unknown message ${message.type}` };
    }
  })().then(sendResponse, (error) => sendResponse({ ok: false, error: error.message }));
  return true;  // responds asynchronously
});
