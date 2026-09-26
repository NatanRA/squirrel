// Squirrel for Safari. Safari extensions can't reach the download engine the way the Chrome and
// Firefox extension does, so this hands the link to the Squirrel app, which shows the formats.
// The app's SafariWebExtensionHandler opens it as squirrel://download?url=…

const api = globalThis.browser;
const MENU_ID = 'squirrel-download';

/** The link that was right-clicked, else an embedded player's page, else the page itself. */
function linkFor(info, tab) {
  const web = (url) => (/^https?:\/\//i.test(url ?? '') ? url : null);
  const frame = info.frameUrl && info.frameUrl !== info.pageUrl ? info.frameUrl : null;
  return web(info.linkUrl) ?? web(frame) ?? web(info.pageUrl) ?? web(tab?.url);
}

async function send(url, tab) {
  if (!url) return;
  try {
    const reply = await api.runtime.sendNativeMessage('app.squirrel', { url });
    if (reply?.ok) return;
  } catch { /* the app isn't reachable; fall back below */ }
  // Safari asks before opening the app this way
  if (tab?.id != null) api.tabs.update(tab.id, { url: `squirrel://download?url=${encodeURIComponent(url)}` });
}

api.contextMenus.removeAll().then(() => api.contextMenus.create({
  id: MENU_ID,
  title: 'Download with Squirrel',
  contexts: ['page', 'link', 'video', 'audio', 'frame'],
}));

api.contextMenus.onClicked.addListener((info, tab) => {
  if (info.menuItemId === MENU_ID) send(linkFor(info, tab), tab);
});

api.browserAction.onClicked.addListener((tab) => send(/^https?:\/\//i.test(tab.url ?? '') ? tab.url : null, tab));
