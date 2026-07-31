/* ============================================================
   We Rondayview — service worker

   Deliberately network-first for the app itself.

   The tempting version of this file serves from cache first, which
   makes the app open instantly and also means people keep running last
   week's copy long after you have fixed something. Since this is one
   HTML file over a fast connection, the speed is not worth the class
   of bug where a fix is live and nobody can see it.

   So: always try the network, fall back to cache only when offline.
   Icons are the exception, because they never change.
   ============================================================ */

const VERSION = 'wrv-v1';
const SHELL = ['./', './index.html', './manifest.webmanifest',
               './icons/icon-192.png', './icons/icon-512.png'];

self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(VERSION)
      .then(c => c.addAll(SHELL))
      .then(() => self.skipWaiting())
      .catch(() => self.skipWaiting())   // a cold cache must never block install
  );
});

self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== VERSION).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', event => {
  const req = event.request;
  if (req.method !== 'GET') return;

  const url = new URL(req.url);

  // Never touch anything that is not ours: Supabase, map tiles, the
  // geocoder, the venue directory. Caching a signed-in API response
  // and handing it back later is exactly the wrong thing to do.
  if (url.origin !== self.location.origin) return;

  const isIcon = url.pathname.includes('/icons/');

  if (isIcon){
    event.respondWith(
      caches.match(req).then(hit => hit || fetch(req).then(res => {
        const copy = res.clone();
        caches.open(VERSION).then(c => c.put(req, copy)).catch(()=>{});
        return res;
      }))
    );
    return;
  }

  event.respondWith(
    fetch(req)
      .then(res => {
        const copy = res.clone();
        caches.open(VERSION).then(c => c.put(req, copy)).catch(()=>{});
        return res;
      })
      .catch(() => caches.match(req).then(hit => hit || caches.match('./index.html')))
  );
});
