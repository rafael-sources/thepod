/* thePod · service worker.
   Solo guarda la cáscara (iconos, fuentes, vendors) y responde con ella sin red.
   Todo lo de /api/ y todo lo que no sea GET va siempre a la red: nada de datos viejos. */
const VERSION = "thepod-sw-1";
const SHELL = ["/static/pwa/icon-192.png", "/static/pwa/icon-512.png", "/offline.html"];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(VERSION).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== VERSION).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

function isStatic(url) {
  return url.origin === self.location.origin && /\/static\//.test(url.pathname);
}

self.addEventListener("fetch", (e) => {
  const req = e.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (url.pathname.includes("/api/") || url.pathname.includes("/media/") || url.pathname.includes("/pub/m/")) return;

  // Estáticos: caché primero, red después (y se guarda lo nuevo)
  if (isStatic(url) || url.hostname === "fonts.gstatic.com" || url.hostname === "fonts.googleapis.com") {
    e.respondWith(
      caches.match(req).then((hit) => hit || fetch(req).then((res) => {
        if (res.ok) { const copy = res.clone(); caches.open(VERSION).then((c) => c.put(req, copy)); }
        return res;
      }))
    );
    return;
  }

  // Páginas: red primero; sin red, la página de "sin conexión"
  if (req.mode === "navigate") {
    e.respondWith(fetch(req).catch(() => caches.match("/offline.html")));
  }
});
