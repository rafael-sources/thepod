/*
 * Entrada de thePod en la web: la misma animación y el mismo sonido que la app de Mac al abrirse.
 * El sonido oficial (el cuatro) y los cuatro íconos que se encienden con su nota; con cada nota salen dos de
 * las ocho estrellas, en arco, y al final se encienden todos y aparece «thePod».
 * Tiempos copiados de la app (IntroView.swift).
 *
 * Uso:
 *   ThePodIntro.unlock();                 // dentro del clic o del envío del formulario (habilita el sonido)
 *   ThePodIntro.play(function () { ... }); // cuando el login salió bien; llama al callback al terminar
 */
(function () {
  var BASE = (document.currentScript && document.currentScript.src.replace(/[^/]*$/, "")) || "/static/intro/";
  var NOTES = [["pre", 0.02], ["ama", 0.24], ["post", 0.46], ["prod", 0.68]];
  var BLOOM = 1.164, TOTAL = BLOOM + 1.5;
  var audio = null;

  function makeAudio() {
    if (audio) return audio;
    audio = new Audio();
    var canM4a = audio.canPlayType('audio/mp4; codecs="mp4a.40.2"');
    audio.src = BASE + (canM4a ? "thepod-login.m4a" : "thepod-login.mp3");
    audio.preload = "auto";
    return audio;
  }

  // Los navegadores solo dejan sonar audio iniciado por un gesto. Esto se llama en el clic de «Entrar»:
  // reproduce en silencio un instante para que después, cuando el login responda, pueda sonar de verdad.
  function unlock() {
    var a = makeAudio();
    try {
      a.muted = true;
      var p = a.play();
      if (p && p.then) p.then(function () { a.pause(); a.currentTime = 0; a.muted = false; }).catch(function () { a.muted = false; });
    } catch (e) { a.muted = false; }
  }

  function css() {
    if (document.getElementById("thepod-intro-css")) return;
    var s = document.createElement("style");
    s.id = "thepod-intro-css";
    s.textContent =
      ".tpi{position:fixed;inset:0;z-index:99999;background:#1A1510;display:flex;align-items:center;justify-content:center;" +
      "flex-direction:column;gap:28px;cursor:pointer;opacity:1;transition:opacity .35s ease}" +
      ".tpi.out{opacity:0}" +
      ".tpi-box{position:relative;width:300px;height:260px;display:flex;align-items:center;justify-content:center}" +
      ".tpi-grid{display:grid;grid-template-columns:96px 96px;gap:8px}" +
      ".tpi-grid img{width:96px;height:96px;opacity:.18;transform:scale(1);transition:opacity .18s ease-out,transform .18s ease-out}" +
      ".tpi-grid img.on{opacity:1;transform:scale(1.04)}" +
      ".tpi-star{position:absolute;left:50%;top:50%;width:17px;height:17px;margin:-8.5px 0 0 -8.5px;opacity:0;" +
      "transform:translate(var(--x),var(--y)) scale(.2);transition:opacity .2s ease,transform .32s cubic-bezier(.34,1.56,.64,1),filter .25s ease;" +
      "filter:drop-shadow(0 0 4px rgba(255,255,255,.45))}" +
      ".tpi-star.on{opacity:1;transform:translate(var(--x),var(--y)) scale(1)}" +
      ".tpi-star.tw{transform:translate(var(--x),var(--y)) scale(1.18);filter:drop-shadow(0 0 9px rgba(255,255,255,.9))}" +
      ".tpi-name{font:700 30px ui-rounded,'SF Pro Rounded',system-ui,-apple-system,sans-serif;color:#EFE3D0;opacity:0;transition:opacity .4s ease-in}" +
      ".tpi-name.on{opacity:1}" +
      "@media (prefers-reduced-motion: reduce){.tpi-grid img,.tpi-star{transition:opacity .15s ease-out}.tpi-grid img.on{transform:none}}" +
      "@media (max-width:420px){.tpi-box{transform:scale(.85)}}";
    document.head.appendChild(s);
  }

  var STAR = '<svg viewBox="0 0 24 24" width="17" height="17" aria-hidden="true"><path fill="#fff" d="M12 2.5l2.9 6.1 6.6.8-4.9 4.6 1.3 6.6L12 17.3l-5.9 3.3 1.3-6.6-4.9-4.6 6.6-.8z"/></svg>';

  function play(done) {
    css();
    var finished = false;
    var root = document.createElement("div");
    root.className = "tpi";
    root.setAttribute("role", "img");
    root.setAttribute("aria-label", "thePod");
    var tiles = { pre: "prepod", prod: "prodpod", post: "postpod", ama: "amapod" };
    // Misma grilla que la app: pre · prod arriba, post · ama abajo
    var grid = '<div class="tpi-grid">' + ["pre", "prod", "post", "ama"].map(function (k) {
      return '<img data-k="' + k + '" src="' + BASE + "tile-" + tiles[k] + '.png" alt="">';
    }).join("") + "</div>";
    // Ocho estrellas en arco (162° a 18°), centrado un poco arriba del disco
    var stars = "";
    for (var i = 0; i < 8; i++) {
      var ang = (162 - i * (144 / 7)) * Math.PI / 180;
      var x = Math.cos(ang) * 132, y = -Math.sin(ang) * 132 + 26;
      stars += '<span class="tpi-star" data-i="' + i + '" style="--x:' + x.toFixed(1) + "px;--y:" + y.toFixed(1) + 'px">' + STAR + "</span>";
    }
    root.innerHTML = '<div class="tpi-box">' + grid + stars + '</div><div class="tpi-name">thePod</div>';
    document.body.appendChild(root);

    var order = [0, 7, 1, 6, 2, 5, 3, 4];   // de las puntas del arco hacia el centro
    var shown = 0;
    function showStars(n) {
      for (; shown < Math.min(8, n); shown++) {
        var el = root.querySelector('.tpi-star[data-i="' + order[shown] + '"]');
        if (el) el.classList.add("on");
      }
    }
    function tile(k, on) { var el = root.querySelector('img[data-k="' + k + '"]'); if (el) el.classList.toggle("on", on); }

    var timers = [];
    function at(t, fn) { timers.push(setTimeout(fn, t * 1000)); }
    function finish() {
      if (finished) return;
      finished = true;
      timers.forEach(clearTimeout);
      root.classList.add("out");
      setTimeout(function () { root.remove(); if (done) done(); }, 350);
    }
    root.addEventListener("click", finish);

    var a = makeAudio();
    try { a.muted = false; a.currentTime = 0; var p = a.play(); if (p && p.catch) p.catch(function () {}); } catch (e) {}

    NOTES.forEach(function (n, idx) {
      at(n[1], function () { tile(n[0], true); showStars((idx + 1) * 2); });
    });
    at(BLOOM - 0.04, function () { ["pre", "prod", "post", "ama"].forEach(function (k) { tile(k, false); }); });
    at(BLOOM + 0.05, function () {
      ["pre", "prod", "post", "ama"].forEach(function (k) { tile(k, true); });
      showStars(8);
      root.querySelectorAll(".tpi-star").forEach(function (s) { s.classList.add("tw"); });
      root.querySelector(".tpi-name").classList.add("on");
    });
    at(BLOOM + 0.5, function () { root.querySelectorAll(".tpi-star").forEach(function (s) { s.classList.remove("tw"); }); });
    at(TOTAL, finish);
  }

  window.ThePodIntro = { unlock: unlock, play: play };
})();
