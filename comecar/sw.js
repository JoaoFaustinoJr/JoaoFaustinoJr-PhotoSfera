const CACHE = 'photosphera-comecar-v31';
const assets = ['../dist/cidade-em-meia-luz.mp3','../dist/mare-mansa.mp3','../dist/veludo-da-noite.mp3','../dist/pulso-pop.mp3','../dist/luz-suave.mp3','../dist/horizonte.mp3','./demo-amanhecer.webp', './demo-cachoeira.webp', './demo-orquidea.webp', '../dist/marca-photosphera.webp','./', './manifest.webmanifest?v=4', '../dist/photosphera-estrela-192.png', '../dist/photosphera-estrela-512.png', '../dist/sfera.woff', '../dist/obturador.wav'];
const sharedAssets = new Set(assets.filter(path => path.startsWith("../dist/")).map(path => new URL(path, self.registration.scope).href));
self.addEventListener('install', event => event.waitUntil(caches.open(CACHE).then(cache => cache.addAll(assets)).then(() => self.skipWaiting())));
self.addEventListener('activate', event => event.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(key => key.startsWith('photosphera-comecar-') && key !== CACHE).map(key => caches.delete(key)))).then(() => self.clients.claim())));
self.addEventListener('fetch', event => {
  const request = event.request;
  if (request.method !== 'GET' || (!request.url.startsWith(self.registration.scope) && !sharedAssets.has(request.url))) return;
  const fallback = request.mode === 'navigate' ? './' : request;
  event.respondWith(fetch(request).catch(async () => (await caches.open(CACHE)).match(fallback)));
});