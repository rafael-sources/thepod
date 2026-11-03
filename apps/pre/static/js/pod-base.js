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
