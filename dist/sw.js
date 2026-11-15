const CACHE = 'photosfera-shell-v1';
const assets = ['./','./manifest.webmanifest','./icon-192.png','./icon-512.png','./sfera.woff','./serra.webp','./avatar.webp','./lia.webp','./rafael.webp','./clara.webp','./joao.webp'];
self.addEventListener('install', event => event.waitUntil(caches.open(CACHE).then(cache => cache.addAll(assets)).then(() => self.skipWaiting())));
self.addEventListener('activate', event => event.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(key => key.startsWith('photosfera-shell-') && key !== CACHE).map(key => caches.delete(key)))).then(() => self.clients.claim())));
self.addEventListener('fetch', event => {
  const request = event.request;
  if (request.method !== 'GET' || !request.url.startsWith(self.registration.scope)) return;
  const fallback = request.mode === 'navigate' ? './' : request;
  event.respondWith(fetch(request).catch(async () => (await caches.open(CACHE)).match(fallback)));
});