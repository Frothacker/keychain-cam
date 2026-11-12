// Keeps Keychain Cam working offline. Bump VERSION when any file changes.
const VERSION = 'kc-v3';
const FILES = ['./', 'index.html', 'sound/', 'sound-chain.js', 'kc-worklets.js', 'manifest.webmanifest',
  'icon-192.png', 'icon-512.png', 'apple-touch-icon.png',
  'noise/index.js', 'noise/rnnoise-worklet.js', 'noise/gtcrn-worklet.js', 'noise/speex-worklet.js',
  'noise/rnnoise.wasm', 'noise/rnnoise_simd.wasm', 'noise/gtcrn.wasm', 'noise/speex.wasm'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(VERSION).then(c => c.addAll(FILES)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== VERSION).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
// Network first (so updates show up), falling back to the saved copy when offline.
self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET' || new URL(e.request.url).origin !== location.origin) return;
  e.respondWith(
    fetch(e.request).then(res => {
      if (res.ok) { const copy = res.clone(); caches.open(VERSION).then(c => c.put(e.request, copy)); }
      return res;
    }).catch(() => caches.match(e.request, { ignoreSearch: true }).then(r => r || caches.match('index.html')))
  );
});
