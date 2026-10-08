// CValRSketch service worker — offline-first cache of the single-file app.
// Bumping CACHE_NAME forces a fresh fetch + cache rebuild on next install.
const CACHE_NAME = 'cvalrsketch-v0.44.3';
const CORE_ASSETS = [
  './',
  './index.html',
  './core.js?v=0.44.3',
  './dictation.js?v=0.44.3',
  './manifest.webmanifest',
  './icon.svg',
  './icon-192.png',
  './icon-512.png',
  './LICENSE',
  './NOTICE',
  './m/',
  './m/index.html',
  './m/manifest.webmanifest',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) =>
      // addAll is atomic — if any asset fails (e.g. icon-192.png not yet present),
      // the whole install fails. Add the entry doc first, then settle the rest individually.
      cache.add('./index.html')
        .then(() => Promise.allSettled(CORE_ASSETS.map((url) => cache.add(url))))
    )
  );
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});

// Pages are network-first: online users get a new release on the first load
// instead of one load late (cache-first served the previous index.html until a
// second reload). A slow connection falls back to the cached page after a few
// seconds, and the fresh copy still lands in the cache for next time.
// Everything else stays cache-first: core.js / dictation.js / pdf-import.mjs
// carry ?v=<version>, and a CACHE_NAME bump clears the rest.
const PAGE_TIMEOUT_MS = 4000;

function isPage(request) {
  return request.mode === 'navigate' || request.destination === 'document';
}

// When the cached page had to be shown and the fresh one arrives afterwards,
// tell the open pages which version is now ready, so they can offer a reload.
function announcePage(resp) {
  return resp.text().then((html) => {
    const m = html.match(/const APP_VERSION = '([\d.]+)'/) || html.match(/id="app-version">v([\d.]+)</);
    if (!m) return;
    return self.clients.matchAll({ type: 'window' })
      .then((all) => all.forEach((c) => c.postMessage({ type: 'page-update', version: m[1] })));
  }).catch(() => {});
}

function networkFirstPage(request, event) {
  const cache = caches.open(CACHE_NAME);
  let servedCached = false;
  // A navigate-mode Request can't be re-issued with options, so fetch by URL;
  // no-cache makes the browser revalidate instead of reusing its own HTTP copy.
  const network = fetch(request.url, { cache: 'no-cache', credentials: 'same-origin' })
    .then((resp) => {
      if (resp && resp.ok) {
        const clone = resp.clone();
        cache.then((c) => c.put(request, clone));
        if (servedCached) return announcePage(resp.clone()).then(() => resp);
      }
      return resp;
    });
  // Keep the worker alive until the fresh page is in, even after the cached one went out.
  event.waitUntil(network.catch(() => null));
  const timeout = new Promise((resolve) => setTimeout(resolve, PAGE_TIMEOUT_MS));
  const shell = new URL(request.url).pathname.includes('/m/') ? './m/index.html' : './index.html';
  const fromCache = () => caches.match(request, { ignoreSearch: true }).then((hit) => hit || caches.match(shell));
  return Promise.race([network.catch(() => null), timeout])
    .then((resp) => {
      if (resp) return resp;
      servedCached = true;   // a fresh page that lands now is announced; pages ignore their own version
      return fromCache().then((hit) => hit || network);
    });
}

self.addEventListener('fetch', (event) => {
  if (event.request.method !== 'GET') return;
  const url = new URL(event.request.url);
  if (url.origin !== location.origin) return;
  if (isPage(event.request)) {
    event.respondWith(networkFirstPage(event.request, event));
    return;
  }
  event.respondWith(
    caches.match(event.request).then((cached) => {
      if (cached) return cached;
      return fetch(event.request)
        .then((resp) => {
          // Cache successful same-origin GETs as they're requested
          if (resp && resp.ok) {
            const clone = resp.clone();
            caches.open(CACHE_NAME).then((cache) => cache.put(event.request, clone));
          }
          return resp;
        })
        .catch(() => caches.match('./index.html'));
    })
  );
});
