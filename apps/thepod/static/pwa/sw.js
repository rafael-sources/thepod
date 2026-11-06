/* thePod · service worker.
   Only caches the shell (icons, fonts, vendors) and serves it when offline.
   Everything under /api/ and anything that is not GET always goes to the network: no stale data. */
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

  // Static files: cache first, network after (and new ones are stored)
  if (isStatic(url) || url.hostname === "fonts.gstatic.com" || url.hostname === "fonts.googleapis.com") {
    e.respondWith(
      caches.match(req).then((hit) => hit || fetch(req).then((res) => {
        if (res.ok) { const copy = res.clone(); caches.open(VERSION).then((c) => c.put(req, copy)); }
        return res;
      }))
    );
    return;
  }

  // Pages: network first; when offline, the "offline" page
  if (req.mode === "navigate") {
    e.respondWith(fetch(req).catch(() => caches.match("/offline.html")));
  }
});

/* Notifications: the server sends {title, body, url, tag, icon}; on tap, that screen opens (or is focused) */
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
