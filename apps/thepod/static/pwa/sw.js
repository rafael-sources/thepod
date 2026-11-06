/* thePod · service worker.
   Solo guarda la cáscara (iconos, fuentes, vendors) y responde con ella sin red.
   Todo lo de /api/ y todo lo que no sea GET va siempre a la red: nada de datos viejos. */
const VERSION = "thepod-sw-2";
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

/* Avisos: el servidor manda {title, body, url, tag, icon}; al tocar, se abre (o se enfoca) esa pantalla */
self.addEventListener("push", (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (_) { d = { title: "thePod", body: e.data ? e.data.text() : "" }; }
  const title = d.title || "thePod";
  e.waitUntil(self.registration.showNotification(title, {
    body: d.body || "",
    icon: d.icon || "/static/pwa/icon-192.png",
    badge: "/static/pwa/icon-192.png",
    tag: d.tag || undefined,
    renotify: !!d.tag,
    data: { url: d.url || "/" },
  }));
});

self.addEventListener("notificationclick", (e) => {
  e.notification.close();
  const url = new URL((e.notification.data && e.notification.data.url) || "/", self.location.origin).href;
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((list) => {
    for (const c of list) {
      if (c.url === url && "focus" in c) return c.focus();
    }
    for (const c of list) {
      if ("navigate" in c && "focus" in c) return c.navigate(url).then((w) => w && w.focus());
    }
    return self.clients.openWindow(url);
  }));
});
