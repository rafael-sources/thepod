/* thePod · path prefix.
   When the app lives under a path (thepod.castmedia.space/pre), the server sets window.POD_BASE = "/pre".
   Code calls keep writing "/api/..." and the prefix is prepended here. Without a prefix, it does nothing. */
(function () {
  var B = window.POD_BASE || "";
  if (!B || B === "/") { window.POD_BASE = ""; window.podUrl = function (p) { return p; }; return; }
  function fix(u) {
    if (typeof u !== "string") return u;
    if (u.charAt(0) !== "/" || u.charAt(1) === "/") return u;      // relative, absolute with host, or "//"
    if (u === B || u.indexOf(B + "/") === 0) return u;              // already has the prefix
    return B + u;
  }
  window.podUrl = fix;
  var f = window.fetch;
  window.fetch = function (u, o) { return f.call(this, (u instanceof Request) ? u : fix(u), o); };
  var open = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (m, u) {
    var args = Array.prototype.slice.call(arguments); args[1] = fix(u);
    return open.apply(this, args);
  };
  if (window.EventSource) {
    var ES = window.EventSource;
    window.EventSource = function (u, c) { return new ES(fix(u), c); };
    window.EventSource.prototype = ES.prototype;
  }
  // Hand-written links and navigations: <a href="/..."> inside Vue templates
  document.addEventListener("click", function (e) {
    var a = e.target && e.target.closest ? e.target.closest("a[href]") : null;
    if (!a) return;
    var h = a.getAttribute("href");
    if (h && h.charAt(0) === "/" && h.charAt(1) !== "/" && h.indexOf(B + "/") !== 0 && h !== B) {
      a.setAttribute("href", B + h);
    }
  }, true);
})();

// PWA: the service worker lives at the domain root and only applies when the app runs under a path
if (window.POD_BASE && "serviceWorker" in navigator) {
  window.addEventListener("load", function () { navigator.serviceWorker.register("/sw.js", { scope: "/" }).catch(function () {}); });
}

/* ---- Install thePod and enable notifications (used by the «Yo» sheet of each app) ----
   Only makes sense when the app runs under thepod.castmedia.space/<app>/: that is where the service worker lives
   and there is a single subscription for the four apps. */
(function () {
  var ORIGIN = window.location.origin;
  var deferred = null;
  var P = {
    enabled: !!window.POD_BASE,
    isIOS: /iPhone|iPad|iPod/.test(navigator.userAgent) && !window.MSStream,
    installed: (window.matchMedia && window.matchMedia("(display-mode: standalone)").matches) || window.navigator.standalone === true,
    canInstall: false,
    onchange: null,
    _emit: function () { if (typeof P.onchange === "function") { try { P.onchange(); } catch (_) {} } },
    /* Android/desktop: triggers the install prompt. iPhone: there is none; the app shows the steps. */
    install: function () {
      if (!deferred) return Promise.resolve(false);
      var d = deferred; deferred = null; P.canInstall = false; P._emit();
      d.prompt();
      return d.userChoice.then(function (r) { return r && r.outcome === "accepted"; });
    },
    pushSupported: function () { return P.enabled && "serviceWorker" in navigator && "PushManager" in window && "Notification" in window; },
    /* "unsupported" | "needs-install" (iPhone not installed) | "denied" | "off" | "on" */
    pushState: function () {
      if (!P.pushSupported()) return (P.isIOS && !P.installed && P.enabled) ? "needs-install" : "unsupported";
      if (Notification.permission === "denied") return "denied";
      return navigator.serviceWorker.getRegistration("/").then(function (reg) {
        if (!reg) return "off";
        return reg.pushManager.getSubscription().then(function (s) { return s ? "on" : "off"; });
      });
    },
    enablePush: function () {
      if (!P.pushSupported()) return Promise.reject(new Error("Este navegador no permite avisos."));
      return Notification.requestPermission().then(function (perm) {
        if (perm !== "granted") throw new Error("No diste permiso para los avisos.");
        return navigator.serviceWorker.ready;
      }).then(function (reg) {
        return fetch(ORIGIN + "/api/push/key", { credentials: "same-origin" }).then(function (r) { return r.json(); }).then(function (k) {
          if (!k.ok) throw new Error(k.msg || "Los avisos no están disponibles.");
          return reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: P._key(k.public_key) });
        });
      }).then(function (sub) {
        return fetch(ORIGIN + "/api/push/subscribe", { method: "POST", credentials: "same-origin",
          headers: { "Content-Type": "application/json" }, body: JSON.stringify({ subscription: sub.toJSON() }) })
          .then(function (r) { return r.json(); }).then(function (d) { if (!d.ok) throw new Error(d.msg || "No se pudo guardar."); return true; });
      });
    },
    disablePush: function () {
      return navigator.serviceWorker.getRegistration("/").then(function (reg) {
        return reg ? reg.pushManager.getSubscription() : null;
      }).then(function (sub) {
        if (!sub) return true;
        var ep = sub.endpoint;
        return sub.unsubscribe().then(function () {
          return fetch(ORIGIN + "/api/push/unsubscribe", { method: "POST", credentials: "same-origin",
            headers: { "Content-Type": "application/json" }, body: JSON.stringify({ endpoint: ep }) });
        }).then(function () { return true; });
      });
    },
    testPush: function () {
      return fetch(ORIGIN + "/api/push/test", { method: "POST", credentials: "same-origin" }).then(function (r) { return r.json(); });
    },
    _key: function (b64) {
      var pad = "=".repeat((4 - b64.length % 4) % 4);
      var raw = atob((b64 + pad).replace(/-/g, "+").replace(/_/g, "/"));
      var out = new Uint8Array(raw.length);
      for (var i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
      return out;
    },
  };
  window.addEventListener("beforeinstallprompt", function (e) { e.preventDefault(); deferred = e; P.canInstall = true; P._emit(); });
  window.addEventListener("appinstalled", function () { P.installed = true; P.canInstall = false; deferred = null; P._emit(); });
  window.podPWA = P;
})();
