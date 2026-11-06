/* thePod · prefijo de ruta.
   Cuando la app vive bajo un camino (thepod.castmedia.space/pre), el servidor pone window.POD_BASE = "/pre".
   Las llamadas del código siguen escribiendo "/api/..." y aquí se les antepone el prefijo. Sin prefijo, no hace nada. */
(function () {
  var B = window.POD_BASE || "";
  if (!B || B === "/") { window.POD_BASE = ""; window.podUrl = function (p) { return p; }; return; }
  function fix(u) {
    if (typeof u !== "string") return u;
    if (u.charAt(0) !== "/" || u.charAt(1) === "/") return u;      // relativa, absoluta con host, o "//"
    if (u === B || u.indexOf(B + "/") === 0) return u;              // ya lleva el prefijo
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
  // Links y navegaciones escritas a mano: <a href="/..."> dentro de las plantillas de Vue
  document.addEventListener("click", function (e) {
    var a = e.target && e.target.closest ? e.target.closest("a[href]") : null;
    if (!a) return;
    var h = a.getAttribute("href");
    if (h && h.charAt(0) === "/" && h.charAt(1) !== "/" && h.indexOf(B + "/") !== 0 && h !== B) {
      a.setAttribute("href", B + h);
    }
  }, true);
})();

// PWA: el service worker vive en la raíz del dominio y solo aplica cuando la app va bajo un camino
if (window.POD_BASE && "serviceWorker" in navigator) {
  window.addEventListener("load", function () { navigator.serviceWorker.register("/sw.js", { scope: "/" }).catch(function () {}); });
}

/* ---- Instalar thePod y activar avisos (lo usa la hoja «Yo» de cada app) ----
   Solo tiene sentido cuando la app va bajo thepod.castmedia.space/<app>/: ahí vive el service worker
   y la suscripción es una sola para las cuatro apps. */
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
    /* Android/desktop: dispara el cuadro de instalar. iPhone: no existe; la app enseña los pasos. */
    install: function () {
      if (!deferred) return Promise.resolve(false);
      var d = deferred; deferred = null; P.canInstall = false; P._emit();
      d.prompt();
      return d.userChoice.then(function (r) { return r && r.outcome === "accepted"; });
    },
    pushSupported: function () { return P.enabled && "serviceWorker" in navigator && "PushManager" in window && "Notification" in window; },
    /* "unsupported" | "needs-install" (iPhone sin instalar) | "denied" | "off" | "on" */
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
