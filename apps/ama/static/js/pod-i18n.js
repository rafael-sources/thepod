/* thePod · idioma de la interfaz (es / en), compartido por las cuatro apps y la landing.
   Las apps están escritas en español; el inglés sale de un diccionario (/static/i18n/en.json) que se aplica
   sobre lo que se dibuja: nodos de texto, placeholder, title, aria-label y el título de la pestaña. Un observador
   traduce también lo que aparece después (Vue, SweetAlert2, toasts). Las claves con * son patrones: casan con
   cualquier trozo (nombres, números) y lo vuelven a poner en el mismo orden.
   El idioma vive en la cookie pod_lang (compartida por el dominio, la lee también Flask) y en localStorage. */
(function () {
  var ATTRS = ["placeholder", "title", "aria-label", "alt"];
  function readCookie(n) { var m = document.cookie.match("(?:^|; )" + n + "=([^;]*)"); return m ? decodeURIComponent(m[1]) : null; }
  function writeCookie(n, v) {
    var base = n + "=" + encodeURIComponent(v) + "; path=/; max-age=31536000; samesite=lax";
    document.cookie = base;
    if (window.POD_COOKIE_DOMAIN) document.cookie = base + "; domain=" + window.POD_COOKIE_DOMAIN;
  }
  function detect() {
    var c = readCookie("pod_lang"); if (c === "en" || c === "es") return c;
    try { var l = localStorage.getItem("pod_lang"); if (l === "en" || l === "es") return l; } catch (_) {}
    var nav = (navigator.language || "es").toLowerCase();
    return nav.indexOf("en") === 0 ? "en" : "es";
  }
  var LANG = detect();
  var dict = null, patterns = [], cache = {};

  function compile(d) {
    dict = {}; patterns = [];
    Object.keys(d).forEach(function (k) {
      if (k.indexOf("*") >= 0) {
        var parts = k.split("*").map(function (p) { return p.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"); });
        patterns.push({ re: new RegExp("^" + parts.join("(.+?)") + "$"), out: d[k].split("*"), n: parts.length - 1 });
      } else dict[k] = d[k];
    });
  }
  function translate(text) {
    var t = text.replace(/\s+/g, " ").trim();
    if (!t || !dict) return null;
    if (cache.hasOwnProperty(t)) return cache[t];
    var r = dict[t] || null;
    if (!r) {
      for (var i = 0; i < patterns.length; i++) {
        var m = patterns[i].re.exec(t);
        if (m) {
          var o = patterns[i].out, s = o[0];
          for (var j = 1; j < o.length; j++) s += (m[j] !== undefined ? m[j] : "") + o[j];
          r = s; break;
        }
      }
    }
    cache[t] = r;
    return r;
  }
  function apply(text) {
    var r = translate(text);
    if (r === null) return null;
    var lead = text.match(/^\s*/)[0], trail = text.match(/\s*$/)[0];
    return lead + r + trail;
  }
  var SKIP = { SCRIPT: 1, STYLE: 1, TEXTAREA: 1, CODE: 1, PRE: 1 };
  function walk(node) {
    if (node.nodeType === 3) {
      var p = node.parentNode;
      if (p && SKIP[p.nodeName]) return;
      if (p && p.isContentEditable) return;
      var v = apply(node.nodeValue);
      if (v !== null && v !== node.nodeValue) { node._podEs = node.nodeValue; node.nodeValue = v; }
      return;
    }
    if (node.nodeType !== 1) return;
    if (SKIP[node.nodeName] || node.getAttribute("data-i18n") === "off") return;
    for (var i = 0; i < ATTRS.length; i++) {
      var a = ATTRS[i];
      if (node.hasAttribute(a)) { var v2 = apply(node.getAttribute(a)); if (v2 !== null) node.setAttribute(a, v2); }
    }
    if (node.nodeName === "INPUT" && (node.type === "button" || node.type === "submit") && node.value) {
      var v3 = apply(node.value); if (v3 !== null) node.value = v3;
    }
    for (var c = node.firstChild; c; c = c.nextSibling) walk(c);
  }
  var pending = false;
  function translateAll() {
    walk(document.body);
    var tt = apply(document.title); if (tt !== null) document.title = tt;
  }
  function observe() {
    var mo = new MutationObserver(function (muts) {
      for (var i = 0; i < muts.length; i++) {
        var m = muts[i];
        if (m.type === "characterData") walk(m.target);
        else if (m.type === "attributes") walk(m.target);
        else for (var j = 0; j < m.addedNodes.length; j++) walk(m.addedNodes[j]);
      }
    });
    mo.observe(document.body, { childList: true, subtree: true, characterData: true, attributes: true, attributeFilter: ATTRS });
  }

  function switcher() {
    var b = document.createElement("button");
    b.id = "pod-lang"; b.type = "button"; b.setAttribute("data-i18n", "off");
    b.textContent = LANG === "en" ? "ES" : "EN";
    b.title = LANG === "en" ? "Ver en español" : "Switch to English";
    b.style.cssText = "position:fixed;right:12px;bottom:12px;z-index:99999;font:600 11px/1 system-ui,sans-serif;letter-spacing:.08em;padding:7px 9px;border-radius:999px;border:1px solid rgba(255,255,255,.18);background:rgba(20,22,30,.82);color:#e8e6df;cursor:pointer;backdrop-filter:blur(6px);opacity:.75";
    b.onmouseenter = function () { b.style.opacity = "1"; }; b.onmouseleave = function () { b.style.opacity = ".75"; };
    b.onclick = function () { window.podSetLang(LANG === "en" ? "es" : "en"); };
    document.body.appendChild(b);
  }

  window.podLang = function () { return LANG; };
  window.podSetLang = function (l) {
    if (l !== "en" && l !== "es") return;
    writeCookie("pod_lang", l);
    try { localStorage.setItem("pod_lang", l); } catch (_) {}
    location.reload();      // volver al español es volver a dibujar; al inglés, se aplica al cargar
  };
  /* t('texto en español') para el código que arma frases a mano */
  window.t = function (s) { var r = translate(String(s)); return r === null ? s : r; };

  function start() {
    if (!document.body) { document.addEventListener("DOMContentLoaded", start); return; }
    if (window.POD_NO_LANG_SWITCH !== true) switcher();
    if (LANG !== "en") return;
    document.documentElement.setAttribute("lang", "en");
    var base = window.POD_BASE || "";
    fetch(base + "/static/i18n/en.json", { credentials: "same-origin" }).then(function (r) { return r.json(); }).then(function (d) {
      compile(d); translateAll(); observe();
    }).catch(function () {});
  }
  start();
})();
