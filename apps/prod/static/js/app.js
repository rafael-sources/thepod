var { createApp, reactive, ref, computed, onMounted, onBeforeUnmount, watch, nextTick } = Vue;
var LK = window.LivekitClient;  // set by livekit-client.umd.min.js

/* ==========================================================================
   Helpers
   ========================================================================== */

async function api(path, options) {
  options = options || {};
  var opts = {
    credentials: "same-origin",
    headers: { Accept: "application/json" },
  };
  for (var k in options) opts[k] = options[k];
  if (opts.body && !(opts.body instanceof FormData)) {
    opts.headers["Content-Type"] = "application/json";
    opts.body = JSON.stringify(opts.body);
  }
  var res = await fetch(path, opts);
  var text = await res.text();
  var data = null;
  try { data = text ? JSON.parse(text) : null; } catch (_) { data = { error: text }; }
  if (!res.ok) {
    var err = new Error((data && data.error) || res.statusText);
    err.status = res.status;
    err.data = data;
    throw err;
  }
  return data;
}

function formatTC(seconds) {
  if (!seconds || seconds < 0) return "00:00:00";
  var s = Math.floor(seconds);
  var hh = Math.floor(s / 3600);
  var mm = Math.floor((s % 3600) / 60);
  var ss = s % 60;
  return (hh < 10 ? "0" : "") + hh + ":" +
         (mm < 10 ? "0" : "") + mm + ":" +
         (ss < 10 ? "0" : "") + ss;
}

function initials(name) {
  if (!name) return "?";
  var parts = name.split(/\s+/).filter(Boolean);
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
  return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
}

function fmtDate(s) {
  if (!s) return "";
  try {
    return new Date(s.endsWith && s.endsWith("Z") ? s : s + "Z").toLocaleString("es-AR", {
      day: "2-digit", month: "short", hour: "2-digit", minute: "2-digit",
    });
  } catch (_) { return s; }
}

/* ==========================================================================
   Login
   ========================================================================== */

var LoginView = {
  props: { onLoggedIn: { type: Function, required: true } },
  setup: function (props) {
    var username = ref("");
    var password = ref("");
    var error = ref("");
    var busy = ref(false);
    async function submit() {
      error.value = "";
      busy.value = true;
      try {
        var d = await api("/api/auth/login", {
          method: "POST",
          body: { username: username.value, password: password.value },
        });
        props.onLoggedIn(d);
      } catch (e) { error.value = e.message; }
      finally { busy.value = false; }
    }
    return { username: username, password: password, error: error, busy: busy, submit: submit };
  },
  template: `
    <div class="login-wrapper">
      <div class="login-card">
        <div class="eyebrow">LIVE BOOTH · ON AIR</div>
        <h2>prod<em>Pod</em></h2>
        <div class="subtitle">Estudio remoto multi-participante con grabación y streaming.</div>
        <form @submit.prevent="submit">
          <div class="form-row">
            <label>Operador</label>
            <input type="text" v-model="username" autofocus autocomplete="username">
          </div>
          <div class="form-row" style="margin-top:14px;">
            <label>Clave</label>
            <input type="password" v-model="password" autocomplete="current-password">
          </div>
          <div v-if="error" class="error">{{ error }}</div>
          <button type="submit" class="primary" :disabled="busy">
            {{ busy ? "Verificando…" : "Entrar al estudio" }}
          </button>
        </form>
        <div class="footer-line">
          <span>CH · 03</span>
          <span>v0.1 · plan 1</span>
        </div>
      </div>
    </div>
  `,
};

/* ==========================================================================
   Dashboard — sessions list
   ========================================================================== */

var DashboardView = {
  props: { onOpen: { type: Function, required: true } },
  setup: function (props) {
    var sessions = ref([]);
    var loading = ref(true);
    var error = ref("");
    var showCreate = ref(false);
    var form = reactive({ title: "", description: "", max_participants: 4 });
    var creating = ref(false);

    async function load() {
      loading.value = true;
      try { sessions.value = await api("/api/sessions"); }
      catch (e) { error.value = e.message; }
      finally { loading.value = false; }
    }

    // Refresh sessions every 5s so the live participant chip reflects reality
    // without the user having to reload the page manually.
    var pollHandle = null;
    function startPolling() {
      stopPolling();
      pollHandle = setInterval(function () {
        api("/api/sessions").then(function (s) { sessions.value = s; }).catch(function () {});
      }, 5000);
    }
    function stopPolling() {
      if (pollHandle) { clearInterval(pollHandle); pollHandle = null; }
    }
    async function create() {
      if (!form.title.trim()) return;
      creating.value = true;
      try {
        var s = await api("/api/sessions", {
          method: "POST",
          body: { title: form.title.trim(), description: form.description, max_participants: form.max_participants },
        });
        showCreate.value = false;
        form.title = ""; form.description = "";
        props.onOpen(s);
      } catch (e) { error.value = e.message; }
      finally { creating.value = false; }
    }
    async function remove(s, ev) {
      ev.stopPropagation();
      if (!await podSwal.confirm("¿Eliminar sesión \"" + s.title + "\"? Se borran invitados y grabaciones.")) return;
      try { await api("/api/sessions/" + s.id, { method: "DELETE" }); await load(); }
      catch (e) { error.value = e.message; }
    }
    var importing = ref(false);
    function triggerImport() {
      var input = document.createElement("input");
      input.type = "file";
      input.accept = ".zip";
      input.onchange = async function () {
        if (!input.files || !input.files[0]) return;
        importing.value = true;
        error.value = "";
        try {
          var fd = new FormData();
          fd.append("file", input.files[0]);
          var r = await fetch("/api/sessions/import", { method: "POST", credentials: "same-origin", body: fd });
          var data = await r.json();
          if (!r.ok) throw new Error(data.error || "error al importar");
          await load();
        } catch (e) { error.value = e.message; }
        finally { importing.value = false; }
      };
      input.click();
    }
    function exportSession(s, ev) {
      ev.stopPropagation();
      window.location.href = "/api/sessions/" + s.id + "/export-bundle";
    }
    onMounted(function () { load(); startPolling(); });
    onBeforeUnmount(stopPolling);
    return { sessions: sessions, loading: loading, error: error, showCreate: showCreate, form: form,
             creating: creating, create: create, remove: remove, fmtDate: fmtDate,
             importing: importing, triggerImport: triggerImport, exportSession: exportSession };
  },
  template: `
    <div class="container">
      <div class="page-head">
        <div>
          <div class="eyebrow">SESIONES · LIVE BOOTH</div>
          <h2>Studio <em style="color:var(--signal);font-style:italic;">live</em></h2>
        </div>
        <div class="spacer"></div>
        <button class="ghost d-only" @click="triggerImport" :disabled="importing" style="margin-right:8px;">
          {{ importing ? "Importando…" : "↑ Importar" }}
        </button>
        <button class="primary" @click="showCreate = true">＋ Nueva sesión</button>
      </div>
      <div v-if="error" class="error">{{ error }}</div>
      <div v-if="loading" class="muted">Cargando sesiones…</div>
      <div v-else-if="sessions.length === 0" class="empty-state">
        <div class="icon">◉</div>
        <div style="font-family:var(--font-display); font-size:18px; font-style:italic; margin-bottom:4px;">
          Todavía no hay sesiones.
        </div>
        <div>Crea una para invitar participantes y grabar.</div>
      </div>
      <div v-else class="sessions-list">
        <div v-for="s in sessions" :key="s.id" class="session-tile"
             :class="{ 'is-live': (s.live_participants || []).length > 0 }"
             @click="$props.onOpen(s)">
          <span class="status" :class="s.status">{{ s.status }}</span>
          <h3>{{ s.title }}</h3>
          <div class="desc">{{ s.description || "—" }}</div>
          <div v-if="(s.live_participants || []).length" class="live-chip">
            <span class="dot"></span>
            {{ s.live_participants.length }} EN VIVO · {{ s.live_participants.join(', ') }}
          </div>
          <div class="bottom">
            <span class="tiny">{{ fmtDate(s.created_at) }} · {{ s.max_participants }}p</span>
            <button class="ghost d-only" style="font-size:11px;padding:3px 8px;" @click="exportSession(s, $event)">↓ Exportar</button>
            <button class="danger" @click="remove(s, $event)">Eliminar</button>
          </div>
        </div>
      </div>

      <div v-if="showCreate" class="modal-backdrop" @click.self="showCreate = false">
        <div class="modal">
          <div class="eyebrow">NUEVA SESIÓN</div>
          <h3>Configurar grabación</h3>
          <p class="muted" style="margin-bottom:18px;">Cada sesión crea una sala WebRTC aislada. Tú eres el host y puedes invitar hasta 4 participantes.</p>
          <div class="form-row" style="margin-bottom:12px;">
            <label>Título</label>
            <input type="text" v-model="form.title" @keyup.enter="create" autofocus placeholder="Episodio #5 — sobre podcasts">
          </div>
          <div class="form-row" style="margin-bottom:12px;">
            <label>Descripción (opcional)</label>
            <textarea v-model="form.description" rows="2" placeholder="Notas breves…"></textarea>
          </div>
          <div class="form-row">
            <label>Máx. participantes (incluyéndote)</label>
            <input type="number" v-model.number="form.max_participants" min="2" max="4">
          </div>
          <div class="row right" style="margin-top:20px; gap:8px;">
            <button class="ghost" @click="showCreate = false">Cancelar</button>
            <button class="primary" @click="create" :disabled="creating || !form.title.trim()">
              {{ creating ? "Creando…" : "Crear y abrir estudio" }}
            </button>
          </div>
        </div>
      </div>
    </div>
  `,
};

/* ==========================================================================
   Studio — LiveKit room + recording + soundboard + chat + meters (Plan 2)
   ========================================================================== */

/* ----- helpers shared by host + guest studios ----- */

function _mountRemoteVideo(identity, track) {
  var el = track.attach();
  el.style.width = "100%";
  el.style.height = "100%";
  el.style.objectFit = "cover";
  var attempts = 0;
  function tryMount() {
    var host = document.querySelector('[data-remote-id="' + identity + '"]');
    if (host) { host.innerHTML = ""; host.appendChild(el); return; }
    attempts++;
    if (attempts < 20) setTimeout(tryMount, 250);
  }
  nextTick(tryMount);
  return el;
}

// Puerta de ruido en vivo: cuando no hablas, lo que oyen los demás (y el stream) baja −18 dB,
// así no se cuelan teclas, el perro o la calle. Tu grabación local sigue siendo el micrófono sin tocar.
// También aplica la ganancia guardada de la prueba de micrófono. Devuelve el track procesado y controles.
function _micChain(rawTrack, gainDb, gateOn) {
  var AC = window.AudioContext || window.webkitAudioContext;
  var ctx = new AC();
  var src = ctx.createMediaStreamSource(new MediaStream([rawTrack]));
  var gain = ctx.createGain();
  gain.gain.value = Math.pow(10, (gainDb || 0) / 20);
  var gate = ctx.createGain();
  gate.gain.value = 1;
  var an = ctx.createAnalyser();
  an.fftSize = 512;
  var dest = ctx.createMediaStreamDestination();
  src.connect(gain); gain.connect(an); gain.connect(gate); gate.connect(dest);
  var data = new Float32Array(an.fftSize);
  var state = { on: !!gateOn, open: true, below: 0, timer: null, speaking: false };
  var OPEN_DB = -42, CLOSE_DB = -48, HOLD_MS = 350, LOW = 0.125;
  function tick() {
    if (!state.on) { if (!state.open) { gate.gain.setTargetAtTime(1, ctx.currentTime, 0.02); state.open = true; } return; }
    an.getFloatTimeDomainData(data);
    var sum = 0; for (var i = 0; i < data.length; i++) sum += data[i] * data[i];
    var db = 20 * Math.log10(Math.sqrt(sum / data.length) + 1e-9);
    var now = performance.now();
    if (db > OPEN_DB) { state.below = now; if (!state.open) { gate.gain.setTargetAtTime(1, ctx.currentTime, 0.015); state.open = true; } }
    else if (db < CLOSE_DB && state.open && now - state.below > HOLD_MS) { gate.gain.setTargetAtTime(LOW, ctx.currentTime, 0.06); state.open = false; }
    state.speaking = state.open;
  }
  state.timer = setInterval(tick, 40);
  return {
    track: dest.stream.getAudioTracks()[0],
    setGate: function (on) { state.on = !!on; },
    isOpen: function () { return state.open; },
    close: function () { clearInterval(state.timer); try { ctx.close(); } catch (_) {} },
  };
}
function _gatePref() { var v = localStorage.getItem("prodpod.gate"); return v === null ? true : v === "1"; }
function _setGatePref(on) { localStorage.setItem("prodpod.gate", on ? "1" : "0"); }

function _attachMeter(track, onLevel) {
  try {
    var stream = new MediaStream([track.mediaStreamTrack || track]);
    var AC = window.AudioContext || window.webkitAudioContext;
    var ctx = new AC();
    var src = ctx.createMediaStreamSource(stream);
    var an = ctx.createAnalyser();
    an.fftSize = 256;
    src.connect(an);
    var data = new Uint8Array(an.frequencyBinCount);
    var raf = null;
    function tick() {
      an.getByteFrequencyData(data);
      var sum = 0;
      for (var i = 0; i < data.length; i++) sum += data[i];
      var avg = sum / data.length;           // 0..255
      var level = Math.min(100, Math.round((avg / 128) * 100));
      onLevel(level);
      raf = requestAnimationFrame(tick);
    }
    tick();
    return function stop() {
      if (raf) cancelAnimationFrame(raf);
      try { ctx.close(); } catch (_) {}
    };
  } catch (e) { return function () {}; }
}

function _encodeMsg(obj) { return new TextEncoder().encode(JSON.stringify(obj)); }
function _decodeMsg(payload) {
  try { return JSON.parse(new TextDecoder().decode(payload)); } catch (_) { return null; }
}

/* Track-based recorder: records a MediaStream into a single webm blob.
   onChunk(blob) is called with each chunk for incremental upload.
   encOpts (opcional): { videoBitsPerSecond } — fija el bitrate del archivo
   local; la calidad de grabación NO cambia durante la llamada. */
function _startRecorder(stream, onComplete, timesliceMs, audioOnly, onChunk, encOpts) {
  var types = audioOnly
    ? ["audio/webm;codecs=opus", "audio/webm", "audio/mp4"]
    : ["video/webm;codecs=vp9,opus", "video/webm;codecs=vp8,opus", "video/webm",
       "video/mp4;codecs=avc1,mp4a.40.2", "video/mp4"];
  var mime = types.find(function (t) { return window.MediaRecorder && MediaRecorder.isTypeSupported(t); });
  var fallback = audioOnly ? "audio/webm" : "video/webm";
  var recInit = mime ? { mimeType: mime } : {};
  if (encOpts && encOpts.videoBitsPerSecond && !audioOnly) {
    recInit.videoBitsPerSecond = encOpts.videoBitsPerSecond;
    recInit.audioBitsPerSecond = 128000;
  }
  var rec = new MediaRecorder(stream, recInit);
  var actualMime = mime || fallback;
  var ext = actualMime.indexOf("mp4") !== -1 ? "mp4" : "webm";
  var chunks = [];
  rec.ondataavailable = function (e) {
    if (e.data && e.data.size) {
      chunks.push(e.data);
      if (onChunk) onChunk(e.data);
    }
  };
  rec.onstop = function () {
    var blob = new Blob(chunks, { type: actualMime });
    blob._ext = ext;
    onComplete(blob);
  };
  rec._ext = ext;
  rec.start(timesliceMs || 1000);
  return rec;
}

/* ==========================================================================
   Calidad de grabación — perfiles, prueba inicial y subida segura por partes

   La calidad de GRABACIÓN (el archivo local que sube a postPod) es
   independiente de la calidad de la SALA (lo que ven los demás por LiveKit).
   Una prueba de ~5 s en la pantalla previa decide el perfil de grabación;
   a la sala siempre se publica una versión reducida (≤720p) con simulcast.
   ========================================================================== */

var REC_PROFILES = [
  { id: "1080p8", quality: "1080p", width: 1920, height: 1080, frameRate: 30, bitrate: 8000000, desc: "1080p · calidad máxima (~8 Mbps)" },
  { id: "1080p5", quality: "1080p", width: 1920, height: 1080, frameRate: 30, bitrate: 5000000, desc: "1080p (~5 Mbps)" },
  { id: "720p25", quality: "720p",  width: 1280, height: 720,  frameRate: 30, bitrate: 2500000, desc: "720p (~2.5 Mbps)" },
  { id: "720p15", quality: "720p",  width: 1280, height: 720,  frameRate: 30, bitrate: 1500000, desc: "720p · ligera (~1.5 Mbps)" },
];

function recProfileById(id) {
  return REC_PROFILES.find(function (p) { return p.id === id; }) || REC_PROFILES[2];
}

/* Decisión de la prueba: nunca por debajo de 720p, y "equipo justo" fuerza
   720p aunque la subida alcance para más. */
function decideRecProfile(upMbps, device) {
  if (!device.ok1080 || !device.fluid) {
    return upMbps >= 2 ? "720p25" : "720p15";
  }
  if (upMbps >= 8) return "1080p8";
  if (upMbps >= 4) return "1080p5";
  if (upMbps >= 2) return "720p25";
  return "720p15";
}

/* Sube un blob de ~2.5 MB a un endpoint que lo descarta y mide Mbps.
   Un POST chico primero "calienta" la conexión para no medir el handshake. */
async function measureUploadMbps(token) {
  var qs = token ? ("?token=" + encodeURIComponent(token)) : "";
  function randomBlob(bytes) {
    var buf = new Uint8Array(bytes);
    for (var off = 0; off < bytes; off += 65536) {
      crypto.getRandomValues(buf.subarray(off, Math.min(off + 65536, bytes)));
    }
    return new Blob([buf]);
  }
  try {
    await fetch("/api/net-test" + qs, { method: "POST", credentials: "same-origin", body: randomBlob(128 * 1024) });
    var size = 2.5 * 1024 * 1024;
    var payload = randomBlob(size);
    var t0 = performance.now();
    var resp = await fetch("/api/net-test" + qs, { method: "POST", credentials: "same-origin", body: payload });
    var secs = (performance.now() - t0) / 1000;
    if (!resp.ok || secs <= 0) return null;
    return (size * 8) / secs / 1e6;
  } catch (_) {
    return null;
  }
}

/* Prueba del equipo: graba ~3 s a 1080p con MediaRecorder desde el track de
   cámara y mide los fps reales que llegan (requestVideoFrameCallback) — si el
   equipo no aguanta capturar + codificar 1080p, los fps caen. */
async function measureDevice1080(videoTrack) {
  var out = { ok1080: false, fluid: true, fps: 0 };
  if (!videoTrack) return out;
  var settings = videoTrack.getSettings ? videoTrack.getSettings() : {};
  out.ok1080 = (settings.height || 0) >= 1080;
  var probe = null;
  try { probe = videoTrack.clone(); } catch (_) { return out; }
  var stream = new MediaStream([probe]);
  var v = document.createElement("video");
  v.muted = true; v.playsInline = true; v.srcObject = stream;
  v.style.position = "fixed"; v.style.left = "-9999px"; v.style.width = "10px";
  document.body.appendChild(v);
  var frames = 0;
  var supportsRVFC = typeof v.requestVideoFrameCallback === "function";
  function onFrame() { frames++; if (supportsRVFC) v.requestVideoFrameCallback(onFrame); }
  try {
    await v.play().catch(function () {});
    if (supportsRVFC) v.requestVideoFrameCallback(onFrame);
    var rec = null;
    try {
      rec = new MediaRecorder(stream, { videoBitsPerSecond: 8000000 });
      rec.start(500);
    } catch (_) {}
    var t0 = performance.now();
    await new Promise(function (r) { setTimeout(r, 3000); });
    var secs = (performance.now() - t0) / 1000;
    if (rec && rec.state !== "inactive") { try { rec.stop(); } catch (_) {} }
    if (supportsRVFC) {
      out.fps = frames / secs;
      var target = Math.min(settings.frameRate || 30, 30);
      out.fluid = out.fps >= Math.min(24, target * 0.8);
    }
  } finally {
    try { probe.stop(); } catch (_) {}
    v.srcObject = null;
    v.remove();
  }
  return out;
}

/* Corre la prueba completa (~5 s: subida y equipo en paralelo) sobre el
   stream de la vista previa. Devuelve { profileId, upMbps, device }. */
async function runRecordingPreflight(previewStream, token, opts) {
  opts = opts || {};
  var videoTrack = previewStream ? previewStream.getVideoTracks()[0] : null;
  var results = await Promise.all([
    measureUploadMbps(token),
    measureDevice1080(videoTrack),
  ]);
  var upMbps = results[0];
  var device = results[1];
  // La llamada también sube video a la sala (~1.7 Mbps + capas de simulcast):
  // esa parte de la subida no queda para la grabación.
  var ROOM_UPLOAD_MBPS = 2.5;
  // Sin medida de subida (endpoint caído): decidir solo por el equipo.
  var effectiveUp = (upMbps == null) ? 4 : Math.max(0, upMbps - ROOM_UPLOAD_MBPS);
  if (opts.guest) {
    // Invitados: margen (la grabación usa como mucho ~65% de lo que queda
    // libre, la conexión de un invitado varía más) y tope de 720p, para
    // que su subida vaya al día y pueda irse apenas termina la sesión.
    effectiveUp = effectiveUp * 0.65;
  }
  var profileId = decideRecProfile(effectiveUp, device);
  if (opts.guest && recProfileById(profileId).quality === "1080p") profileId = "720p25";
  return { profileId: profileId, upMbps: upMbps, device: device };
}

/* --- Cola de chunks persistida en IndexedDB -------------------------------
   Si la pestaña se cierra a mitad de la subida, los chunks pendientes quedan
   guardados y se recuperan al volver a entrar a la sesión. */
var _recIdbPromise = null;
function _recIdb() {
  if (_recIdbPromise) return _recIdbPromise;
  _recIdbPromise = new Promise(function (resolve) {
    if (!window.indexedDB) return resolve(null);
    var req = indexedDB.open("prodpod_rec", 1);
    req.onupgradeneeded = function () {
      var db = req.result;
      var store = db.createObjectStore("chunks", { keyPath: "id", autoIncrement: true });
      store.createIndex("skey", "skey");
    };
    req.onsuccess = function () { resolve(req.result); };
    req.onerror = function () { resolve(null); };
  });
  return _recIdbPromise;
}
function _idbPut(rec) {
  return _recIdb().then(function (db) {
    if (!db) return null;
    return new Promise(function (resolve) {
      try {
        var tx = db.transaction("chunks", "readwrite");
        var req = tx.objectStore("chunks").add(rec);
        req.onsuccess = function () { resolve(req.result); };
        req.onerror = function () { resolve(null); };
      } catch (_) { resolve(null); }
    });
  });
}
function _idbAllFor(skey) {
  return _recIdb().then(function (db) {
    if (!db) return [];
    return new Promise(function (resolve) {
      try {
        var tx = db.transaction("chunks", "readonly");
        var req = tx.objectStore("chunks").index("skey").getAll(skey);
        req.onsuccess = function () { resolve(req.result || []); };
        req.onerror = function () { resolve([]); };
      } catch (_) { resolve([]); }
    });
  });
}
function _idbDelete(ids) {
  if (!ids.length) return Promise.resolve();
  return _recIdb().then(function (db) {
    if (!db) return;
    return new Promise(function (resolve) {
      try {
        var tx = db.transaction("chunks", "readwrite");
        var store = tx.objectStore("chunks");
        ids.forEach(function (id) { if (id != null) store.delete(id); });
        tx.oncomplete = resolve;
        tx.onerror = resolve;
      } catch (_) { resolve(); }
    });
  });
}

/* --- Uploader compartido (host e invitado) --------------------------------
   - manda cada lote con su offset absoluto (reintento seguro, sin duplicar)
   - si la cola crece (red lenta), sube MÁS LENTO durante la llamada para no
     pelearle ancho de banda a la sala, y termina de subir al final
   - guarda lo pendiente en IndexedDB por si se cierra la pestaña */
/* Respaldo grabado por el servidor: cada participante lo pide para sí al
   empezar a grabar. Si el servidor no lo tiene encendido, no pasa nada. */
function _requestServerBackup(sid, token) {
  var qs = token ? ("?token=" + encodeURIComponent(token)) : "";
  fetch("/api/sessions/" + sid + "/backup/start" + qs, {
    method: "POST", credentials: "same-origin",
    headers: { "Content-Type": "application/json" }, body: "{}",
  }).catch(function () {});
}

/* "unos 12 minutos", "menos de un minuto"… para los avisos de subida. */
function etaText(secs) {
  if (secs == null) return "";
  if (secs < 60) return "menos de un minuto";
  var m = Math.round(secs / 60);
  if (m < 60) return "unos " + m + (m === 1 ? " minuto" : " minutos");
  var h = Math.floor(m / 60), r = m % 60;
  return "unas " + h + (h === 1 ? " hora" : " horas") + (r ? " y " + r + " min" : "");
}

function _newTakeId() {
  try { return crypto.randomUUID(); }
  catch (_) { return "t" + Date.now().toString(36) + Math.random().toString(36).slice(2, 10); }
}

/* ==========================================================================
   Cintillos del director (mismo contrato que la app de Mac)
   overlay_inject: {type, event_type, payload, event_id, file_path,
   duration_seconds} — duration 0 = hasta overlay_remove.
   ========================================================================== */

var CINTILLO_TYPES = ["sponsor", "banner", "segment"];

function cintilloTitle(ov) {
  var p = ov.payload || {};
  if (ov.event_type === "sponsor") return p.sponsor_name || "Sponsor";
  if (ov.event_type === "banner")  return p.name || p.title || "";
  return p.title || "";
}
function cintilloText(ov) {
  var p = ov.payload || {};
  if (ov.event_type === "sponsor") return p.sponsor_copy || "";
  if (ov.event_type === "banner")  return p.title || "";
  return p.subtitle || "";
}
function fmtCountdown(s) {
  s = Math.max(0, Math.round(+s || 0));
  var m = Math.floor(s / 60), r = s % 60;
  return m > 0 ? (m + ":" + String(r).padStart(2, "0")) : (r + "s");
}

function _dropOverlay(activeOverlays, eventId) {
  var i = activeOverlays.findIndex(function (o) { return o.event_id === eventId; });
  if (i !== -1) {
    if (activeOverlays[i]._tick) clearInterval(activeOverlays[i]._tick);
    activeOverlays.splice(i, 1);
  }
}

/* Alta de un overlay: respeta duration_seconds si viene (0 = hasta que lo
   quiten); si no viene, la tabla histórica. El countdown cuenta de verdad. */
function _admitOverlay(activeOverlays, msg) {
  _dropOverlay(activeOverlays, msg.event_id);  // por si llega repetido
  activeOverlays.push({
    event_id: msg.event_id,
    event_type: msg.event_type,
    payload: msg.payload || {},
    file_path: msg.file_path || null,
    remaining: null,
  });
  var ov = activeOverlays[activeOverlays.length - 1];  // proxy reactivo
  if (msg.event_type === "countdown") {
    var secs = Math.max(0, +((msg.payload || {}).seconds) || 0);
    var endsAt = Date.now() + secs * 1000;
    ov.remaining = secs;
    ov._tick = setInterval(function () {
      ov.remaining = Math.max(0, Math.ceil((endsAt - Date.now()) / 1000));
      if (ov.remaining <= 0) _dropOverlay(activeOverlays, msg.event_id);
    }, 400);
    return;
  }
  var ms;
  if (msg.duration_seconds != null && msg.duration_seconds !== "") {
    ms = (+msg.duration_seconds || 0) * 1000;
  } else {
    var table = { banner: 10000, segment: 12000, comment: 10000, sponsor: 15000, graphic: 10000 };
    ms = table[msg.event_type] != null ? table[msg.event_type] : 10000;
  }
  if (ms > 0) {
    setTimeout(function () { _dropOverlay(activeOverlays, msg.event_id); }, ms);
  }
}


/* ==========================================================================
   Teleprompter (thePod 0.11) — mismo contrato que la app de Mac.
   Mensaje de sala: {type:"teleprompter", action:"show"|"hide", target:"all"|identity,
   title, text, speed: slow|normal|fast, size: quarter|half|full, countdown: seg, event_id}
   Con countdown > 0 TODOS ven el aviso ("Viene X en 3 s · ATENTO PATRICIO") y, al terminar,
   solo el destinatario ve el texto corriendo.
   ========================================================================== */

var TP_WPM = { slow: 95, normal: 135, fast: 180 };

function _tpSetup(myIdentity, nameOf) {
  var tp = reactive({
    notice: null,        // {title, who, remaining}
    active: null,        // {event_id, title, text, speed, size, paused, startedAt, pauseAt, durationMs}
    scrollKey: 0,
  });
  var _noticeTick = null, _showTimer = null, _hideTimer = null;

  function _durationMs(text, speed) {
    var words = Math.max(8, (text || "").trim().split(/\s+/).length);
    return Math.round(words / (TP_WPM[speed] || 135) * 60000) + 2500;
  }
  function show(msg) {
    clearTimeout(_hideTimer);
    tp.active = {
      event_id: msg.event_id, title: msg.title || "", text: msg.text || "",
      speed: msg.speed || "normal", size: msg.size || "half",
      paused: false, durationMs: _durationMs(msg.text, msg.speed || "normal"),
    };
    tp.scrollKey++;
    // Se va solo cuando termina de correr (más 4 s de margen), salvo que lo cierren antes
    _hideTimer = setTimeout(function () { if (tp.active && tp.active.event_id === msg.event_id) tp.active = null; }, tp.active.durationMs + 4000);
  }
  function handle(msg) {
    if (msg.type !== "teleprompter") return false;
    if (msg.action === "hide") {
      if (!msg.event_id || (tp.active && tp.active.event_id === msg.event_id)) tp.active = null;
      tp.notice = null;
      return true;
    }
    var mine = msg.target === "all" || msg.target === myIdentity.value;
    var secs = Math.max(0, +msg.countdown || 0);
    clearInterval(_noticeTick); clearTimeout(_showTimer);
    if (secs > 0) {
      var who = msg.target === "all" ? "" : (nameOf(msg.target) || "").toUpperCase();
      tp.notice = { title: msg.title || "Teleprompter", who: who, remaining: secs };
      var endsAt = Date.now() + secs * 1000;
      _noticeTick = setInterval(function () {
        var r = Math.ceil((endsAt - Date.now()) / 1000);
        if (tp.notice) tp.notice.remaining = Math.max(0, r);
        if (r <= 0) { clearInterval(_noticeTick); tp.notice = null; }
      }, 200);
      if (mine) _showTimer = setTimeout(function () { show(msg); }, secs * 1000);
    } else if (mine) {
      show(msg);
    }
    return true;
  }
  function pause() { if (tp.active) tp.active.paused = !tp.active.paused; }
  function restart() { if (tp.active) { tp.active.paused = false; tp.scrollKey++; } }
  function close() { tp.active = null; clearTimeout(_hideTimer); }
  return { tp: tp, tpHandle: handle, tpPause: pause, tpRestart: restart, tpClose: close };
}

/* Capa visual (igual en host e invitado). Va dentro del contenedor del video. */
var TP_TEMPLATE = `
      <div v-if="tp.notice" class="tp-notice">
        <div class="tp-notice-num">{{ tp.notice.remaining }}</div>
        <div class="tp-notice-text">Viene <b>{{ tp.notice.title }}</b> en {{ tp.notice.remaining }} s<span v-if="tp.notice.who"> · ATENTO {{ tp.notice.who }}</span></div>
      </div>
      <div v-if="tp.active" class="tp-panel" :class="['tp-' + tp.active.size, { paused: tp.active.paused }]">
        <div class="tp-head">
          <span class="tp-title">🎬 {{ tp.active.title || 'Teleprompter' }}</span>
          <span class="tp-btns">
            <button class="ghost" @click="tpPause">{{ tp.active.paused ? '▶ Seguir' : '⏸ Pausa' }}</button>
            <button class="ghost" @click="tpRestart">↺ Desde el inicio</button>
            <button class="ghost" @click="tpClose">✕</button>
          </span>
        </div>
        <div class="tp-scroll">
          <div class="tp-text" :key="tp.scrollKey" :style="{ animationDuration: tp.active.durationMs + 'ms', animationPlayState: tp.active.paused ? 'paused' : 'running' }">{{ tp.active.text }}</div>
        </div>
      </div>`;

function createChunkUploader(opts) {
  // opts: { sid, token, trackType, takeId, onStatus(st), sendData(state, bytes) }
  var skey = "s" + opts.sid + ":" + (opts.token || "host") + ":" + (opts.trackType || "video");
  var queue = [];          // [{ idbId, offset, blob }]
  var nextOffset = 0;      // bytes generados localmente
  var ackedBytes = 0;      // bytes confirmados por el servidor
  var pendingBytes = 0;
  var ext = ".webm";
  var timer = null;
  var uploading = false;
  var nextFlushAt = 0;
  var retries = 0;
  var state = { state: "idle", sentBytes: 0, pendingBytes: 0, retries: 0, error: "" };
  var BACKLOG_CATCHUP = 16 * 1024 * 1024;
  // Ritmo de producción del video (bytes/s), medido sobre lo que entrega el
  // MediaRecorder. La subida en vivo se fija como múltiplo de este ritmo.
  var producedBytes = 0;
  var producedSince = 0;
  var PROD_RATE_DEFAULT = 0.6 * 1024 * 1024;   // hasta tener medida real
  var MIN_UPLOAD_RATE = 256 * 1024;
  var MAX_BATCH = 8 * 1024 * 1024;

  // Velocidad real de subida (últimos ~30 s) para estimar cuánto falta.
  var ackLog = [];   // [{t, bytes}]
  function _uploadRate() {
    var now = Date.now();
    while (ackLog.length && now - ackLog[0].t > 30000) ackLog.shift();
    if (ackLog.length < 2) return 0;
    var bytes = 0;
    for (var i = 1; i < ackLog.length; i++) bytes += ackLog[i].bytes;
    var secs = (ackLog[ackLog.length - 1].t - ackLog[0].t) / 1000;
    return secs > 0 ? bytes / secs : 0;
  }

  function emit() {
    state.sentBytes = ackedBytes;
    state.pendingBytes = pendingBytes;
    state.retries = retries;
    var rate = _uploadRate();
    state.etaSeconds = (rate > 0 && pendingBytes > 0) ? Math.round(pendingBytes / rate) : null;
    if (opts.onStatus) opts.onStatus(state);
  }

  function setExt(e) { ext = e || ".webm"; }

  function push(blob) {
    var rec = { idbId: null, offset: nextOffset, blob: blob };
    nextOffset += blob.size;
    pendingBytes += blob.size;
    if (!producedSince) producedSince = Date.now();
    producedBytes += blob.size;
    queue.push(rec);
    _idbPut({ skey: skey, offset: rec.offset, ext: ext, take: opts.takeId || null, blob: blob }).then(function (id) { rec.idbId = id; });
    emit();
  }

  function _url() {
    return "/api/sessions/" + opts.sid + "/recordings/stream";
  }

  async function _postBatch(entries, finalize, durationSeconds) {
    var form = new FormData();
    if (entries.length) {
      form.append("chunk", new Blob(entries.map(function (e) { return e.blob; })), "chunk" + ext);
      form.append("offset", String(entries[0].offset));
    }
    if (opts.token) form.append("token", opts.token);
    if (opts.takeId) form.append("take_id", opts.takeId);
    form.append("track_type", opts.trackType || "video");
    form.append("ext", ext);
    if (finalize) {
      form.append("finalize", "1");
      form.append("duration_seconds", String(durationSeconds || 0));
    }
    var resp = await fetch(_url(), { method: "POST", credentials: "same-origin", body: form });
    var data = null;
    try { data = await resp.json(); } catch (_) {}
    if (resp.status === 409 && data) {
      // El servidor tiene menos bytes de los que ya dimos por confirmados:
      // reencolar desde bytes_received lo que todavía tengamos.
      var br = data.bytes_received || 0;
      if (br < (entries.length ? entries[0].offset : ackedBytes)) {
        throw new Error("el servidor perdió parte de la grabación ya subida");
      }
      return { resync: br };
    }
    if (!resp.ok) throw new Error((data && data.error) || ("HTTP " + resp.status));
    return data || {};
  }

  function _takeBatch(capBytes) {
    var batch = [];
    var size = 0;
    for (var i = 0; i < queue.length; i++) {
      batch.push(queue[i]);
      size += queue[i].blob.size;
      if (capBytes && size >= capBytes) break;
    }
    return batch;
  }

  function _ackBatch(batch) {
    var bytes = 0;
    batch.forEach(function (e) { bytes += e.blob.size; });
    queue.splice(0, batch.length);
    pendingBytes -= bytes;
    ackedBytes = batch[batch.length - 1].offset + batch[batch.length - 1].blob.size;
    ackLog.push({ t: Date.now(), bytes: bytes });
    _idbDelete(batch.map(function (e) { return e.idbId; }));
    retries = 0;
  }

  async function _flushOnce(capBytes) {
    if (uploading || !queue.length) return false;
    uploading = true;
    try {
      var batch = _takeBatch(capBytes);
      var data = await _postBatch(batch, false);
      if (data.resync != null) {
        // el servidor va atrás dentro de este mismo lote: reintenta entero
        // (el server trunca al offset y reescribe — sin duplicados)
        retries++;
        return false;
      }
      _ackBatch(batch);
      if (state.state !== "finalizing") state.state = "streaming";
      emit();
      if (opts.sendData) opts.sendData("streaming", ackedBytes, pendingBytes, state.etaSeconds);
      return true;
    } catch (e) {
      retries++;
      emit();
      return false;
    } finally {
      uploading = false;
    }
  }

  function start() {
    state.state = "streaming";
    ackedBytes = 0;
    emit();
    if (timer) clearInterval(timer);
    timer = setInterval(function () {
      // La subida en vivo va SIEMPRE por encima del ritmo al que se produce
      // el video (×1.5; ×3 si hay atraso para ponerse al día), así la cola
      // no crece sin límite. El tope solo existe para no acaparar toda la
      // conexión que necesita la llamada; si la red da menos, va a lo que dé.
      if (uploading || !queue.length) return;
      var now = Date.now();
      if (now < nextFlushAt) return;
      var elapsed = producedSince ? (now - producedSince) / 1000 : 0;
      var prodRate = elapsed >= 5 ? producedBytes / elapsed : PROD_RATE_DEFAULT;
      var factor = pendingBytes >= BACKLOG_CATCHUP ? 3.0 : 1.5;
      var rate = Math.max(prodRate * factor, MIN_UPLOAD_RATE);
      var cap = Math.min(MAX_BATCH, Math.max(rate * 4, 512 * 1024));
      var batchBytes = 0;
      for (var i = 0; i < queue.length && batchBytes < cap; i++) batchBytes += queue[i].blob.size;
      nextFlushAt = now + (batchBytes / rate) * 1000;
      _flushOnce(cap);
    }, 1000);
  }

  async function finalize(durationSeconds) {
    if (timer) { clearInterval(timer); timer = null; }
    state.state = "finalizing";
    emit();
    var attempts = 0;
    while (queue.length) {
      var ok = await _flushOnce(8 * 1024 * 1024);
      emit();
      if (!ok) {
        attempts++;
        if (attempts > 40) {
          state.state = "error";
          state.error = "No se pudo terminar de subir. Lo pendiente quedó guardado en este navegador.";
          emit();
          if (opts.sendData) opts.sendData("error", ackedBytes);
          return false;
        }
        await new Promise(function (r) { setTimeout(r, Math.min(500 * Math.pow(1.5, attempts), 5000)); });
      }
    }
    attempts = 0;
    while (true) {
      try {
        await _postBatch([], true, durationSeconds);
        break;
      } catch (e) {
        attempts++;
        if (attempts > 8) {
          state.state = "error";
          state.error = "Error al finalizar: " + e.message;
          emit();
          if (opts.sendData) opts.sendData("error", ackedBytes);
          return false;
        }
        await new Promise(function (r) { setTimeout(r, Math.min(500 * Math.pow(1.5, attempts), 5000)); });
      }
    }
    state.state = "done";
    emit();
    if (opts.sendData) opts.sendData("done", ackedBytes, 0, 0);
    return true;
  }

  /* Reconstruye la cola desde registros de IndexedDB (recuperación tras un
     cierre de pestaña), conservando los offsets absolutos originales. */
  function seed(rows) {
    rows.forEach(function (r) {
      queue.push({ idbId: r.id, offset: r.offset, blob: r.blob });
      pendingBytes += r.blob.size;
    });
    if (rows.length) {
      var last = rows[rows.length - 1];
      nextOffset = last.offset + last.blob.size;
      ackedBytes = rows[0].offset;
      if (rows[0].ext) ext = rows[0].ext;
    }
    emit();
  }

  return { push: push, start: start, finalize: finalize, setExt: setExt,
           seed: seed, status: state, skey: skey };
}

/* Al entrar a una sesión: si quedaron chunks de una grabación interrumpida
   (pestaña cerrada a mitad de subida), termina de subirlos y finaliza esa
   grabación para que no se pierda. */
async function recoverPendingUpload(sid, token, trackType) {
  var skey = "s" + sid + ":" + (token || "host") + ":" + (trackType || "video");
  var rows = await _idbAllFor(skey);
  if (!rows.length) return false;
  rows.sort(function (a, b) { return a.offset - b.offset; });
  // La toma interrumpida conserva su take_id: los offsets se corresponden
  // con SU archivo de streaming en el servidor, no con el de otra toma.
  var up = createChunkUploader({ sid: sid, token: token, trackType: trackType,
                                 takeId: rows[0].take || null });
  up.seed(rows);
  return up.finalize(0);
}

/* ========================================================================== */

var StudioView = {
  props: { session: Object, user: Object, onBack: Function },
  setup: function (props) {
    var participants = ref([]);
    var remoteMap = reactive({});   // identity -> { name, speaking, meter, mutedIndicator }
    var error = ref("");
    var busy = ref(false);
    var recording = ref(props.session.status === "recording");
    var sessionEnded = ref(props.session.status === "finished" || props.session.status === "archived");
    var recordingStart = ref(null);
    var timecode = ref(0);
    var timerHandle = null;

    var room = null;
    var localVideoEl = ref(null);
    var _rawMicTrack = null;      // micrófono sin procesar (para grabar)
    var localStream = null;

    // ---- Pre-join state: device picker + camera/mic preview ----
    var prejoinVideoEl = ref(null);
    var prejoinStream = null;
    var devices = reactive({ cameras: [], mics: [] });
    var deviceSelection = reactive({
      cameraId: localStorage.getItem("prodpod.cameraId") || "",
      micId: localStorage.getItem("prodpod.micId") || "",
    });
    var prejoinMeter = ref(0);
    var prejoinMeterStop = null;
    var prejoinError = ref("");

    // ---- Mic check wizard ----
    // 10-second capture that measures peak + average loudness, suggests a
    // gain compensation, and (on apply) routes the live mic through a
    // GainNode before publishing. Per-device, persisted in localStorage.
    var micCheckRunning = ref(false);
    var micCheckCountdown = ref(0);  // seconds remaining (10..0)
    var micCheckResult = ref(null);  // {peak_dbfs, avg_dbfs, suggested_db}
    var micCheckAppliedGain = ref(0); // currently applied gain in dB (mirrors localStorage)

    function _readMicGainFor(deviceId) {
      var raw = localStorage.getItem("prodpod.micCheckGainDb_" + (deviceId || "default"));
      var n = parseFloat(raw);
      return isFinite(n) ? n : 0;
    }
    function _writeMicGainFor(deviceId, db) {
      localStorage.setItem("prodpod.micCheckGainDb_" + (deviceId || "default"), String(db));
    }
    // Sync `micCheckAppliedGain` to whichever mic is currently selected.
    watch(function () { return deviceSelection.micId; }, function (id) {
      micCheckAppliedGain.value = _readMicGainFor(id);
      micCheckResult.value = null;  // a different mic invalidates the last reading
    }, { immediate: true });

    // Run a 10-second analysis on the active prejoinStream's mic track.
    // We use AnalyserNode.getFloatTimeDomainData so we can compute true peak
    // and full-band RMS in linear amplitude, then convert to dBFS. We do not
    // implement BS.1770 K-weighting — for a one-click podcast "studio" the
    // full-band RMS is close enough and the user's expectation is just
    // "is my voice too hot or too quiet?". The display label avoids "LUFS"
    // accordingly.
    var _micCheckCancel = null;
    async function runMicCheck() {
      if (micCheckRunning.value) return;
      if (!prejoinStream) {
        prejoinError.value = "Activa cámara/micrófono primero.";
        return;
      }
      var track = prejoinStream.getAudioTracks()[0];
      if (!track) {
        prejoinError.value = "No hay micrófono activo.";
        return;
      }
      micCheckRunning.value = true;
      micCheckResult.value = null;
      micCheckCountdown.value = 10;

      var AC = window.AudioContext || window.webkitAudioContext;
      var ctx = new AC();
      var src = ctx.createMediaStreamSource(new MediaStream([track]));
      var an = ctx.createAnalyser();
      an.fftSize = 2048;
      src.connect(an);
      var buf = new Float32Array(an.fftSize);

      var peakAbs = 0;
      var sumSquares = 0;
      var sampleCount = 0;
      var stopped = false;

      function tick() {
        if (stopped) return;
        an.getFloatTimeDomainData(buf);
        for (var i = 0; i < buf.length; i++) {
          var v = buf[i];
          if (v < 0) v = -v;
          if (v > peakAbs) peakAbs = v;
          sumSquares += buf[i] * buf[i];
        }
        sampleCount += buf.length;
        if (!stopped) requestAnimationFrame(tick);
      }
      tick();

      var startedAt = Date.now();
      var timer = setInterval(function () {
        var rem = Math.max(0, 10 - Math.floor((Date.now() - startedAt) / 1000));
        micCheckCountdown.value = rem;
      }, 200);

      _micCheckCancel = function () {
        stopped = true;
        clearInterval(timer);
        try { ctx.close(); } catch (_) {}
        micCheckRunning.value = false;
        micCheckCountdown.value = 0;
      };

      await new Promise(function (resolve) { setTimeout(resolve, 10_000); });
      if (stopped) return;
      stopped = true;
      clearInterval(timer);
      try { ctx.close(); } catch (_) {}

      // Convert to dBFS. Floor at -90 dB so an empty mic doesn't show -Infinity.
      function dbfs(amp) {
        if (!(amp > 0)) return -90;
        return Math.max(-90, 20 * Math.log10(amp));
      }
      var rms = sampleCount ? Math.sqrt(sumSquares / sampleCount) : 0;
      var peakDb = dbfs(peakAbs);
      var avgDb = dbfs(rms);
      // Target average loudness = -18 dBFS (close to a -16 LUFS podcast aim
      // when run through postPod's loudnorm, which we can rely on if the
      // user opts into Speech Enhancement at export time).
      var TARGET = -18;
      // Cap the suggestion: never recommend more than +18 dB (would amplify
      // noise floor beyond usability) or less than -12 dB (likely the user
      // is shouting and should move the mic, not ask us to attenuate).
      var raw = TARGET - avgDb;
      // If the speaker barely produced signal (< -55 dBFS avg), don't pretend
      // we can save it with gain — the mic is probably muted or very far.
      var suggested;
      if (avgDb < -55) suggested = null;
      else suggested = Math.max(-12, Math.min(18, Math.round(raw)));

      micCheckResult.value = {
        peak_dbfs: Math.round(peakDb * 10) / 10,
        avg_dbfs: Math.round(avgDb * 10) / 10,
        suggested_db: suggested,
      };
      micCheckRunning.value = false;
      micCheckCountdown.value = 0;
      _micCheckCancel = null;
    }

    function cancelMicCheck() {
      if (_micCheckCancel) _micCheckCancel();
    }

    function applyMicCheckGain() {
      if (!micCheckResult.value || micCheckResult.value.suggested_db == null) return;
      var db = micCheckResult.value.suggested_db;
      _writeMicGainFor(deviceSelection.micId, db);
      micCheckAppliedGain.value = db;
    }

    function resetMicCheckGain() {
      _writeMicGainFor(deviceSelection.micId, 0);
      micCheckAppliedGain.value = 0;
    }

    async function listDevices() {
      try {
        var all = await navigator.mediaDevices.enumerateDevices();
        devices.cameras = all.filter(function (d) { return d.kind === "videoinput"; });
        devices.mics    = all.filter(function (d) { return d.kind === "audioinput"; });
        if (!deviceSelection.cameraId && devices.cameras.length) {
          deviceSelection.cameraId = devices.cameras[0].deviceId;
        }
        if (!deviceSelection.micId && devices.mics.length) {
          deviceSelection.micId = devices.mics[0].deviceId;
        }
      } catch (e) { prejoinError.value = "No se pudieron listar dispositivos: " + e.message; }
    }

    async function startPrejoinPreview() {
      stopPrejoinPreview();
      prejoinError.value = "";
      // First attempt: use the saved device selection if any. If that fails
      // (e.g. saved deviceId no longer exists → "Invalid constraint" /
      // "OverconstrainedError"), retry with browser-default devices and
      // forget the stale selection.
      async function _grab(useStored) {
        // Se pide 1080p30 "ideal": si la cámara no llega, el navegador da lo
        // máximo que tenga. Esta captura es la que evalúa la prueba de calidad.
        var video = { width: { ideal: 1920 }, height: { ideal: 1080 }, frameRate: { ideal: 30 } };
        if (useStored && deviceSelection.cameraId) video.deviceId = { exact: deviceSelection.cameraId };
        var constraints = {
          video: video,
          audio: (useStored && deviceSelection.micId)
            ? { deviceId: { exact: deviceSelection.micId } } : true,
        };
        return navigator.mediaDevices.getUserMedia(constraints);
      }
      try {
        try {
          prejoinStream = await _grab(true);
        } catch (firstErr) {
          // Common transient: stored deviceId stale → retry with defaults.
          if (firstErr && (firstErr.name === "OverconstrainedError"
                       || /constraint/i.test(firstErr.message || ""))) {
            // Wipe the bad selection so next reload doesn't repeat the failure.
            deviceSelection.cameraId = "";
            deviceSelection.micId = "";
            try { localStorage.removeItem("prodpod.cameraId"); } catch (_) {}
            try { localStorage.removeItem("prodpod.micId"); } catch (_) {}
            prejoinStream = await _grab(false);
          } else {
            throw firstErr;
          }
        }
        await nextTick();
        if (prejoinVideoEl.value) prejoinVideoEl.value.srcObject = prejoinStream;
        var micTrack = prejoinStream.getAudioTracks()[0];
        if (micTrack) {
          prejoinMeterStop = _attachMeter({ mediaStreamTrack: micTrack }, function (lvl) {
            prejoinMeter.value = lvl;
          });
        }
        // After permission granted the device labels become populated.
        await listDevices();
        // Prueba de calidad de grabación (~5 s), en paralelo a la vista previa.
        if (recPreflight.state === "idle") runRecPreflight();
      } catch (e) {
        prejoinError.value = "Cámara/mic no accesibles: " + e.message;
      }
    }

    function stopPrejoinPreview() {
      if (prejoinMeterStop) { prejoinMeterStop(); prejoinMeterStop = null; }
      prejoinMeter.value = 0;
      if (prejoinStream) {
        prejoinStream.getTracks().forEach(function (t) { try { t.stop(); } catch (_) {} });
        prejoinStream = null;
      }
      if (prejoinVideoEl.value) prejoinVideoEl.value.srcObject = null;
    }

    watch(function () { return deviceSelection.cameraId; }, function (v) {
      if (v) localStorage.setItem("prodpod.cameraId", v);
      if (prejoinStream) startPrejoinPreview();
    });
    watch(function () { return deviceSelection.micId; }, function (v) {
      if (v) localStorage.setItem("prodpod.micId", v);
      if (prejoinStream) startPrejoinPreview();
    });
    var localMuted = ref(false);
    var gateOn = ref(_gatePref());
    function toggleGate() { gateOn.value = !gateOn.value; _setGatePref(gateOn.value); if (micGainCtx && micGainCtx.setGate) micGainCtx.setGate(gateOn.value); }
    var localCamOff = ref(false);
    var connected = ref(false);
    var localMeter = ref(0);
    var localSpeaking = ref(false);
    var localMeterStop = null;
    var layoutMode = ref("grid");   // "grid" | "spotlight"
    var spotlightId = ref(null);    // identity of the spotlighted participant (or "__local__")


    // Al detener: cuenta regresiva grande (3, 2, 1) antes de apagar cámara y
    // micrófono, en vez de cortarlos de golpe. La grabación ya se detuvo en
    // el instante exacto del "detener"; esto es solo la transición visual.
    var endCountdown = ref(null);
    var camsOffAfterRec = ref(false);
    function startEndCountdown() {
      if (endCountdown.value !== null || camsOffAfterRec.value) return;
      endCountdown.value = 3;
      var t = setInterval(function () {
        endCountdown.value -= 1;
        if (endCountdown.value <= 0) {
          clearInterval(t);
          endCountdown.value = null;
          camsOffAfterRec.value = true;
          if (room) {
            try { room.localParticipant.setCameraEnabled(false); } catch (_) {}
            try { room.localParticipant.setMicrophoneEnabled(false); } catch (_) {}
          }
        }
      }, 1000);
    }
    // ---- Director signals (host receives these) ----
    var activeOverlays = reactive([]);
    var cintilloOverlays = computed(function () {
      return activeOverlays.filter(function (o) { return CINTILLO_TYPES.indexOf(o.event_type) !== -1; });
    });
    var otherOverlays = computed(function () {
      return activeOverlays.filter(function (o) { return CINTILLO_TYPES.indexOf(o.event_type) === -1; });
    });
    function ovLogoUrl(ov) {
      if (!ov.file_path) return null;
      return "/api/sessions/" + props.session.id + "/director/assets/" +
             encodeURIComponent(String(ov.file_path).split("/").pop());
    }
    var activeCue = ref(null);
    var cueTimer = null;
    var ifbActive = ref(false);
    var directorConnected = ref(false);
    var _spotlightTimer = null;
    var micGainCtx = null;  // AudioContext that wraps the published mic with a GainNode (mic-check)
    var recorder = null;
    // Screen share state: only one local share at a time. screenSharing tracks
    // the *local* state. remoteScreen tracks who else is sharing right now
    // (limit is enforced client-side: if anyone is already sharing, we refuse
    // to start a second one).
    var screenSharing = ref(false);     // I am sharing
    var screenRecordOnly = ref(false);  // I am sharing but NOT publishing to LiveKit
    var screenStream = null;            // local MediaStream from getDisplayMedia
    var screenRecorder = null;          // MediaRecorder for the screen
    var _screenUploader = null;         // subida por chunks de la pantalla
    var _screenStartMs = null;          // inicio del share, para duration_seconds
    var screenPub = null;               // LiveKit screen track publication
    var remoteScreen = ref(null);       // {identity, name} of the participant currently sharing
    // Soundboard triggers are logged with their offset from record-start
    // (replacing the old MediaRecorder-on-Web-Audio approach).
    var triggerLog = [];
    var recordingStartedAtMs = null;
    var practiceMode = ref(localStorage.getItem("prodpod.practiceMode") === "1");
    watch(practiceMode, function (v) {
      localStorage.setItem("prodpod.practiceMode", v ? "1" : "0");
      sendData({ type: "practice_mode", active: v });
    });
    var handsRaised = reactive({});  // identity -> bool (from hand_raise data msgs)
    // ---- Calidad de GRABACIÓN: la decide la prueba de la pantalla previa.
    // La calidad de la SALA es independiente (≤720p con simulcast, LiveKit
    // adapta lo que recibe cada uno).
    var recPreflight = reactive({
      state: "idle",     // idle | testing | done
      upMbps: null,
      fps: 0,
      profileId: null,   // techo que dio la prueba
      choiceId: null,    // elección final (nunca por encima del techo)
    });
    var recProfileChoices = computed(function () {
      if (!recPreflight.profileId) return REC_PROFILES;
      var idx = REC_PROFILES.findIndex(function (p) { return p.id === recPreflight.profileId; });
      return REC_PROFILES.slice(Math.max(idx, 0));
    });
    function recProfile() {
      return recProfileById(recPreflight.choiceId || recPreflight.profileId || "720p25");
    }
    function _recCaptureOpts() {
      var p = recProfile();
      return { width: p.width, height: p.height, frameRate: p.frameRate };
    }
    async function runRecPreflight() {
      if (recPreflight.state === "testing" || !prejoinStream) return;
      recPreflight.state = "testing";
      try {
        var r = await runRecordingPreflight(prejoinStream, null);
        recPreflight.upMbps = r.upMbps;
        recPreflight.fps = r.device.fps;
        recPreflight.profileId = r.profileId;
        recPreflight.choiceId = r.profileId;
      } catch (_) {
        recPreflight.profileId = "720p25";
        recPreflight.choiceId = "720p25";
      }
      recPreflight.state = "done";
    }
    async function persistRecQuality() {
      var p = recProfile();
      try {
        await fetch("/api/sessions/" + props.session.id + "/recording-quality", {
          method: "POST", credentials: "same-origin",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ quality: p.quality, bitrate: p.bitrate }),
        });
      } catch (_) {}
    }
    function _roomPublishLayers() {
      // Capas bajas del simulcast; la capa alta es el track publicado (≤720p).
      return [
        { width: 320, height: 180, encoding: { maxBitrate: 200000, maxFramerate: 15 } },
        { width: 640, height: 360, encoding: { maxBitrate: 500000, maxFramerate: 24 } },
      ];
    }
    var myIdentity = ref("");
    // Teleprompter: quién es quién (identity → nombre) para los avisos
    function _tpNameOf(identity) {
      if (identity === myIdentity.value) return props.user.display_name || props.user.username;
      var r = remoteMap[identity]; if (r && r.name) return r.name;
      var p = participants.value.find(function (x) { return "participant_" + x.id === identity; });
      return p ? p.display_name : "";
    }
    var _tpH = _tpSetup(myIdentity, _tpNameOf);
    // Teleprompter del guion (prePod): el host lo dispara a quien le toca cuando la grabación llega al minuto
    var _tpScript = [];
    var _tpFired = {};
    async function loadTeleprompterScript() {
      try {
        var d = await api("/api/sessions/" + props.session.id + "/teleprompter");
        _tpScript = (d.sections || []).filter(function (x) { return x.offset_seconds != null; });
        _tpPeople = d.participants || [];
        if (_tpScript.length && window.toast) window.toast({ type: "info", text: "🎬 " + _tpScript.length + " teleprompter del guion listos", duration: 4000 });
      } catch (_) { _tpScript = []; }
    }
    var _tpPeople = [];
    function _tpIdentityFor(speaker) {
      var sp = (speaker || "").trim().toLowerCase();
      if (!sp) return "all";
      // 1) usuario o nombre exacto (lo que elige prePod en «lo lee»); 2) parecido por nombre
      var exact = _tpPeople.find(function (p) {
        return (p.username || "").toLowerCase() === sp || (p.display_name || "").toLowerCase() === sp;
      });
      if (exact) return exact.identity;
      var hit = _tpPeople.find(function (p) {
        var n = (p.display_name || "").toLowerCase();
        return n && (n.indexOf(sp) === 0 || sp.indexOf(n) === 0 || n.split(" ")[0] === sp.split(" ")[0]);
      });
      return hit ? hit.identity : "all";
    }
    function _checkTeleprompterTimers() {
      if (!recording.value || recordingStartedAtMs == null || !_tpScript.length) return;
      var now = (Date.now() - recordingStartedAtMs) / 1000;
      _tpScript.forEach(function (sec) {
        var at = +sec.offset_seconds - 3;   // 3 s de aviso antes
        if (_tpFired[sec.id] || now < at || now > at + 2) return;
        _tpFired[sec.id] = true;
        var msg = { type: "teleprompter", action: "show", event_id: "s" + sec.id, target: _tpIdentityFor(sec.speaker_key || sec.speaker),
                    title: "Guion · " + (sec.speaker || ""), text: sec.content || "", speed: sec.speed || "normal",
                    size: sec.size || "half", countdown: 3 };
        sendData(msg);
        _tpH.tpHandle(msg);   // también para mí (el host)
      });
    }
    var _tpInterval = null;
    watch(recording, function (val) {
      if (val) { _tpFired = {}; loadTeleprompterScript(); _tpInterval = setInterval(_checkTeleprompterTimers, 500); }
      else if (_tpInterval) { clearInterval(_tpInterval); _tpInterval = null; }
    });

    var readyMap = reactive({});     // identity -> bool
    var ownReady = ref(false);
    var countdown = ref(null);       // null | 3 | 2 | 1 | 0
    var countdownHandle = null;

    var participantUploads = reactive({});
    var allUploadsComplete = computed(function () {
      var keys = Object.keys(participantUploads);
      return keys.length > 0 && keys.every(function (k) { return participantUploads[k].state === "done"; });
    });
    var guestCuesVisible = ref(true);
    function toggleGuestCues() {
      guestCuesVisible.value = !guestCuesVisible.value;
      sendData({ type: "cue_visibility", show: guestCuesVisible.value });
    }

    var showInvite = ref(false);
    var inviteForm = reactive({ display_name: "", role: "guest" });
    var inviteLinks = ref([]);

    var sounds = ref([]);
    var playingPad = ref(null);
    var audioPool = {};   // filename -> HTMLAudioElement
    var padPlayState = reactive({});  // filename -> {progress: 0..1}
    var padVolumes = reactive(JSON.parse(localStorage.getItem("prodpod.padVolumes") || "{}"));
    function setPadVolume(filename, vol) {
      padVolumes[filename] = vol;
      localStorage.setItem("prodpod.padVolumes", JSON.stringify(padVolumes));
      var a = audioPool[filename];
      if (a) a.volume = vol;
    }
    var soundLimits = reactive({ max_kb: 150, max_duration_seconds: 4, max_total: 15, allowed_exts: [".mp3", ".wav", ".ogg", ".m4a"] });
    var soundUploadStatus = ref("");
    var showAddSound = ref(false);
    var newSound = reactive({ name: "", shortcut_key: "", color: "#5a8bff" });

    var chat = ref([]);
    // En teléfono/tablet el panel lateral se abre por pestañas: chat, personas, sponsors
    var sideTab = ref(null);
    var chatSeenH = ref(0);
    var chatUnreadH = computed(function () { return sideTab.value === "chat" ? 0 : Math.max(0, chat.value.length - chatSeenH.value); });
    function openSide(t) {
      sideTab.value = sideTab.value === t ? null : t;
      if (sideTab.value === "chat") chatSeenH.value = chat.value.length;
    }
    watch(function () { return chat.value.length; }, function (n) { if (sideTab.value === "chat") chatSeenH.value = n; });
    var _hostWake = null;
    async function hostKeepAwake() {
      try { if ("wakeLock" in navigator && !_hostWake) { _hostWake = await navigator.wakeLock.request("screen"); _hostWake.addEventListener("release", function () { _hostWake = null; }); } } catch (_) {}
    }
    function hostVisibility() { if (document.visibilityState === "visible" && connected.value) hostKeepAwake(); }
    document.addEventListener("visibilitychange", hostVisibility);
    onBeforeUnmount(function () {
      document.removeEventListener("visibilitychange", hostVisibility);
      try { if (_hostWake) _hostWake.release(); } catch (_) {}
    });
    var chatInput = ref("");
    // Backstage chat: hosts-only side channel.
    var backstageChat = ref([]);
    var backstageInput = ref("");
    var chatChannel = ref("main");  // active tab in the chat panel
    var hostIdentities = ref([]);   // LiveKit identities to target backstage at

    var finishedRecordings = ref([]);
    var triggerStats = reactive({ count: 0 });
    var exportStatus = ref("");
    var exporting = ref(false);
    var allExported = computed(function () {
      var recs = finishedRecordings.value;
      return recs.length > 0 && recs.every(function (r) { return !!r.exported_to_postpod_at; });
    });

    // Live streams (RTMP to YouTube/Twitch via LiveKit Egress)
    var streams = ref([]);
    var rtmpPresets = ref([]);
    var showStream = ref(false);
    var streamForm = reactive({ platform: "", rtmp_url: "", stream_key: "" });
    var streamStatus = ref("");
    var streamBusy = ref(false);

    // AMA (amaPod) integration
    var amaPanel = ref(false);
    var amaEmbedUrl = ref("");
    var amaEventId = ref(null);
    var amaBusy = ref(false);

    async function startAma() {
      amaBusy.value = true;
      try {
        var data = await api("/api/sessions/" + props.session.id + "/ama/start", { method: "POST" });
        amaEventId.value = data.event_id;
        amaEmbedUrl.value = data.embed_url;
        amaPanel.value = true;
      } catch (e) {
        window.toast({ type: "error", text: "Error al iniciar AMA: " + e.message });
      }
      amaBusy.value = false;
    }

    function closeAma() {
      amaPanel.value = false;
    }

    function handleAmaMessage(ev) {
      if (!ev.data || ev.data.source !== "amapod") return;
      var msg = ev.data;
      if (msg.type === "ama_participant_active") {
        window.toast({ type: "info", text: (msg.display_name || "Participante") + " al aire en Q&A" });
      } else if (msg.type === "ama_participant_removed") {
        window.toast({ type: "info", text: "Participante salio de Q&A" });
      } else if (msg.type === "ama_session_ended") {
        window.toast({ type: "info", text: "Sesion de Q&A finalizada" });
        amaPanel.value = false;
        amaEmbedUrl.value = "";
        amaEventId.value = null;
      }
    }

    window.addEventListener("message", handleAmaMessage);

    // Sponsor teleprompter state
    var sponsorMarkers = ref([]);
    var sponsorAlertId = ref(null);
    var sponsorCountdown = ref(null);
    var sponsorDismissed = reactive({});
    var _sponsorTimers = {};

    async function loadSponsorMarkers() {
      try {
        var all = await api("/api/sessions/" + props.session.id + "/chapter-markers");
        sponsorMarkers.value = all.filter(function (m) { return m.kind === "sponsor" && m.sponsor_name; });
      } catch (_) {}
    }

    function _sponsorFmtTC(sec) {
      if (sec == null) return "--:--";
      var m = Math.floor(sec / 60);
      var s = Math.floor(sec % 60);
      return m + ":" + String(s).padStart(2, "0");
    }

    function _checkSponsorTimers() {
      if (!recording.value || recordingStartedAtMs == null) return;
      var now = (Date.now() - recordingStartedAtMs) / 1000;
      sponsorMarkers.value.forEach(function (m) {
        var off = m.planned_offset_seconds != null ? m.planned_offset_seconds : m.tl_offset_seconds;
        var timeUntil = off - now;
        var key = m.id;
        if (sponsorDismissed[key]) return;
        if (timeUntil <= 60 && timeUntil > 0 && sponsorAlertId.value !== key && !_sponsorTimers["alert_" + key]) {
          sponsorAlertId.value = key;
          _sponsorTimers["alert_" + key] = true;
          if (window.toast) window.toast({ type: "warn", text: "📢 Sponsor \"" + m.sponsor_name + "\" en " + Math.ceil(timeUntil) + "s", duration: 5000 });
        }
        if (timeUntil <= 3 && timeUntil > -1 && !_sponsorTimers["cd_" + key]) {
          _sponsorTimers["cd_" + key] = true;
          sponsorCountdown.value = { id: key, name: m.sponsor_name, sec: Math.ceil(Math.max(0, timeUntil)) };
          var cdI = setInterval(function () {
            if (!sponsorCountdown.value || sponsorCountdown.value.id !== key) { clearInterval(cdI); return; }
            var rem = off - ((Date.now() - recordingStartedAtMs) / 1000);
            if (rem <= 0) {
              sponsorCountdown.value = null;
              clearInterval(cdI);
              // auto-mark chapter
              if (!practiceMode.value) {
                api("/api/sessions/" + props.session.id + "/chapter-markers", {
                  method: "POST", body: { tl_offset_seconds: off, label: "SPONSOR: " + m.sponsor_name },
                }).catch(function () {});
              }
            } else {
              sponsorCountdown.value.sec = Math.ceil(rem);
            }
          }, 250);
        }
      });
    }

    var _sponsorInterval = null;
    watch(recording, function (val) {
      if (val) {
        loadSponsorMarkers();
        _sponsorInterval = setInterval(_checkSponsorTimers, 500);
      } else {
        if (_sponsorInterval) { clearInterval(_sponsorInterval); _sponsorInterval = null; }
        sponsorAlertId.value = null;
        sponsorCountdown.value = null;
      }
    });

    async function delaySponsor(m) {
      try {
        var res = await api("/api/sessions/" + props.session.id + "/chapter-markers/" + m.id + "/delay", {
          method: "PATCH", body: { delay_seconds: 90 },
        });
        m.tl_offset_seconds = res.tl_offset_seconds;
        m.planned_offset_seconds = res.planned_offset_seconds;
        sponsorAlertId.value = null;
        delete _sponsorTimers["alert_" + m.id];
        delete _sponsorTimers["cd_" + m.id];
        if (window.toast) window.toast({ type: "success", text: "Sponsor retrasado +90s" });
      } catch (e) {
        if (window.toast) window.toast({ type: "error", text: e.message });
      }
    }

    function dismissSponsor(m) {
      sponsorDismissed[m.id] = true;
      if (sponsorAlertId.value === m.id) sponsorAlertId.value = null;
    }

    async function loadParticipants() {
      try { participants.value = await api("/api/sessions/" + props.session.id + "/participants"); }
      catch (e) { error.value = e.message; }
    }

    // True if the current user is either the session creator (host) OR has
    // role co-host in the participants table. Drives visibility of the
    // Backstage tab (server enforces the same rule on the chat endpoints).
    var canBackstage = computed(function () {
      if (props.user.username === props.session.created_by) return true;
      return participants.value.some(function (p) {
        return p.username === props.user.username && p.role === "co-host";
      });
    });

    // Browser notification when the tab is hidden (e.g. user is in another
    // tab) — also gentle no-op if the user denied the permission.
    function _maybeBrowserNotify(text) {
      if (typeof Notification === "undefined") return;
      if (document.visibilityState !== "hidden") return;
      if (Notification.permission === "granted") {
        try { new Notification("prodPod · " + props.session.title, { body: text, silent: false }); } catch (_) {}
      } else if (Notification.permission === "default") {
        Notification.requestPermission();  // ask once for next time
      }
    }

    async function loadSounds() {
      try {
        sounds.value = await api("/api/sessions/" + props.session.id + "/sounds");
        audioPool = {};
        sounds.value.forEach(function (s) {
          if (!s.filename) return;
          var a = new Audio(s.url);
          a.preload = "auto";
          a.volume = padVolumes[s.filename] != null ? padVolumes[s.filename] : 1.0;
          audioPool[s.filename] = a;
        });
      } catch (e) { error.value = e.message; }
      try {
        var lim = await api("/api/sessions/" + props.session.id + "/sounds/limits");
        Object.assign(soundLimits, lim);
      } catch (_) {}
    }

    async function addCustomPad() {
      if (!newSound.name.trim()) return;
      try {
        await api("/api/sessions/" + props.session.id + "/sounds", {
          method: "POST",
          body: {
            name: newSound.name.trim(),
            shortcut_key: (newSound.shortcut_key || "").toUpperCase().slice(0, 1),
            color: newSound.color,
          },
        });
        showAddSound.value = false;
        newSound.name = ""; newSound.shortcut_key = ""; newSound.color = "#5a8bff";
        await loadSounds();
      } catch (e) { podSwal.error(e.message); }
    }

    async function deleteCustomPad(s) {
      if (!await podSwal.confirm("¿Eliminar el pad \"" + s.name + "\"?")) return;
      try {
        await api("/api/sessions/" + props.session.id + "/sounds/" + s.id, { method: "DELETE" });
        await loadSounds();
      } catch (e) { podSwal.error(e.message); }
    }

    function onPadDrop(s, ev) {
      var f = ev.dataTransfer && ev.dataTransfer.files && ev.dataTransfer.files[0];
      if (!f) return;
      // Reuse uploadSound by faking the event shape it expects.
      uploadSound(s, { target: { files: [f], value: "" } });
    }

    async function uploadSound(s, ev) {
      var f = ev.target.files && ev.target.files[0];
      if (!f) return;
      soundUploadStatus.value = "";
      // Client-side early checks
      if (f.size > (soundLimits.max_kb || 150) * 1024) {
        soundUploadStatus.value = "❌ archivo muy grande: " + Math.round(f.size/1024) + "KB (máx " + soundLimits.max_kb + "KB)";
        ev.target.value = ""; return;
      }
      var ext = "." + (f.name.split(".").pop() || "").toLowerCase();
      if (soundLimits.allowed_exts && soundLimits.allowed_exts.indexOf(ext) === -1) {
        soundUploadStatus.value = "❌ tipo no soportado: " + ext;
        ev.target.value = ""; return;
      }

      // Optional: check duration in the browser before uploading
      try {
        var dur = await new Promise(function (resolve, reject) {
          var blobUrl = URL.createObjectURL(f);
          var a = new Audio();
          a.addEventListener("loadedmetadata", function () {
            URL.revokeObjectURL(blobUrl);
            resolve(a.duration);
          });
          a.addEventListener("error", function () { URL.revokeObjectURL(blobUrl); reject(new Error("audio inválido")); });
          a.src = blobUrl;
        });
        if (dur > (soundLimits.max_duration_seconds || 4)) {
          soundUploadStatus.value = "❌ dura " + dur.toFixed(1) + "s (máx " + soundLimits.max_duration_seconds + "s)";
          ev.target.value = ""; return;
        }
      } catch (_) { /* continue; server will also validate */ }

      soundUploadStatus.value = "subiendo " + s.name + "…";
      try {
        var form = new FormData();
        form.append("file", f);
        var resp = await fetch("/api/sessions/" + props.session.id + "/sounds/" + s.id + "/upload", {
          method: "POST", credentials: "same-origin", body: form,
        });
        var data = await resp.json();
        if (!resp.ok) { throw new Error(data.error || resp.statusText); }
        // Update local state + preload new audio
        s.url = data.url;
        s.filename = data.filename;
        s.is_default = 0;
        audioPool[s.filename] = new Audio(s.url);
        audioPool[s.filename].preload = "auto";
        soundUploadStatus.value = "✓ " + s.name + " actualizado (" + Math.round(data.size_bytes/1024) + "KB)";
        setTimeout(function () { soundUploadStatus.value = ""; }, 3000);
      } catch (e) {
        soundUploadStatus.value = "❌ " + e.message;
      } finally {
        ev.target.value = "";
      }
    }

    async function loadChat() {
      try {
        var msgs = await api("/api/sessions/" + props.session.id + "/chat?channel=main");
        chat.value = msgs.map(function (m) { return { id: m.id, author: m.author_name, text: m.message_text, ts: m.timestamp }; });
      } catch (_) {}
      // Backstage only loads if user is host/co-host (server returns 403 otherwise).
      try {
        var bs = await api("/api/sessions/" + props.session.id + "/chat?channel=backstage");
        backstageChat.value = bs.map(function (m) { return { id: m.id, author: m.author_name, text: m.message_text, ts: m.timestamp }; });
      } catch (_) { /* not a host → ignore silently */ }
      try {
        hostIdentities.value = await api("/api/sessions/" + props.session.id + "/host-identities");
      } catch (_) {}
    }

    async function loadRecordings() {
      try { finishedRecordings.value = await api("/api/sessions/" + props.session.id + "/recordings"); }
      catch (_) {}
      try {
        var s = await api("/api/sessions/" + props.session.id + "/sound-triggers/stats");
        triggerStats.count = s.count || 0;
      } catch (_) {}
    }

    async function loadStreams() {
      try { streams.value = await api("/api/sessions/" + props.session.id + "/streams"); }
      catch (_) {}
    }
    async function loadRtmpPresets() {
      try { rtmpPresets.value = await api("/api/rtmp-presets"); }
      catch (_) {}
    }
    function applyStreamPreset(preset) {
      streamForm.platform = preset.key;
      streamForm.rtmp_url = preset.rtmp_url;
    }
    async function startStream() {
      if (streamBusy.value) return;
      if (!streamForm.rtmp_url || !streamForm.stream_key) {
        streamStatus.value = "❌ URL RTMP y stream key son obligatorios";
        return;
      }
      streamBusy.value = true;
      streamStatus.value = "iniciando egress…";
      try {
        var body = {
          platform: streamForm.platform,
          rtmp_url: streamForm.rtmp_url,
          stream_key: streamForm.stream_key,
        };
        await api("/api/sessions/" + props.session.id + "/streams", {
          method: "POST", body: body,
        });
        streamStatus.value = "✓ en vivo";
        streamForm.stream_key = "";
        showStream.value = false;
        await loadStreams();
      } catch (e) {
        streamStatus.value = "❌ " + e.message;
      } finally {
        streamBusy.value = false;
      }
    }
    async function stopStream(s) {
      if (!await podSwal.confirm("¿Detener el stream en " + (s.platform || "plataforma") + "?")) return;
      try {
        await api("/api/sessions/" + props.session.id + "/streams/" + s.id, { method: "DELETE" });
        await loadStreams();
      } catch (e) { error.value = e.message; }
    }
    var activeStreams = computed(function () {
      return streams.value.filter(function (s) { return s.status === "active" || s.status === "starting"; });
    });

    async function showDiagnostic() {
      try {
        var d = await api("/api/debug/session/" + props.session.id + "/room-state");
        var mySide = room ? Array.from(room.remoteParticipants.values()).map(function(p){return p.identity;}) : [];
        var lkSide = (d.livekit_participants || []).map(function(p){return p.identity || JSON.stringify(p);});
        var localState = "no hay objeto room (no entraste)";
        var localRoomName = "—";
        if (room) {
          localState = room.state || "?";
          localRoomName = room.name || "(sin nombre)";
        }
        var msg = "📊 ESTADO DE LA SALA\n\n" +
          "Sesión que mira el diagnóstico: #" + d.session_id + " — " + d.title + "\n" +
          "URL actual del navegador: " + window.location.pathname + window.location.search + "\n" +
          "ID que tu UI cree estar mostrando: #" + props.session.id + "\n\n" +
          "Sala LiveKit (DB): " + (d.db_room_name || "(sin nombre)") + "\n" +
          "Sala LiveKit a la que tu navegador conectó: " + localRoomName + "\n" +
          "Estado actual del Room en tu navegador: " + localState + "\n" +
          "Flag 'connected' en tu UI: " + (typeof connected !== "undefined" && connected.value ? "SÍ" : "NO") + "\n\n" +
          "👤 Participantes en la base de datos:\n  • " +
            d.db_participants.map(function(p){return p.display_name + " ("+p.role+", "+p.status+")";}).join("\n  • ") + "\n\n" +
          "🎥 Participantes que LiveKit ve en la sala (lo que importa):\n  " +
            (lkSide.length ? "• " + lkSide.join("\n  • ") : "(NADIE — la sala está vacía o no existe en LiveKit)") + "\n\n" +
          "👁 Lo que tu navegador ve como remotos en este momento:\n  " +
            (mySide.length ? "• " + mySide.join("\n  • ") : "(nadie)");
        podSwal.info(msg, "Estado de la sala");
      } catch (e) { podSwal.error("Error consultando estado: " + e.message); }
    }

    async function exportToPostpod() {
      if (exporting.value) return;
      exporting.value = true;
      exportStatus.value = "ESPERANDO QUE ESTÉN DISPONIBLES…";
      try {
        var connectedCount = participants.value.filter(function (p) {
          return p.status === "connected" || p.status === "active" || p.status === "left" || p.status === "disconnected";
        }).length;
        if (connectedCount < 1) connectedCount = 1;
        var maxWait = 60;
        var waited = 0;
        while (waited < maxWait) {
          await loadRecordings();
          var videoCount = finishedRecordings.value.filter(function (r) { return r.track_type === "video"; }).length;
          if (videoCount >= connectedCount) break;
          exportStatus.value = "ESPERANDO QUE ESTÉN DISPONIBLES… (" + videoCount + "/" + connectedCount + " pistas)";
          await new Promise(function (ok) { setTimeout(ok, 3000); });
          waited += 3;
        }
        exportStatus.value = "enviando pistas a postPod…";
        var r = await api("/api/sessions/" + props.session.id + "/recordings/export-to-postpod", { method: "POST" });
        if (r.exported === 0 && r.failed === 0) {
          exportStatus.value = "✓ Todas las pistas ya fueron enviadas a postPod";
        } else {
          exportStatus.value = "✓ " + r.exported + " enviada(s)" +
            (r.failed ? " · " + r.failed + " falló" : "") +
            (r.project && r.project.slug ? " → proyecto " + r.project.slug : "");
        }
        await loadRecordings();
      } catch (e) {
        exportStatus.value = "❌ " + e.message;
      } finally {
        exporting.value = false;
        setTimeout(function () { exportStatus.value = ""; }, 8000);
      }
    }

    function playLocalSound(s) {
      var a = audioPool[s.filename];
      if (!a) return;
      a.volume = padVolumes[s.filename] != null ? padVolumes[s.filename] : 1.0;
      try { a.currentTime = 0; a.play(); } catch (_) {}
      playingPad.value = s.key;
      var dur = a.duration || 1;
      _duckFor(Math.round((dur || 1) * 1000) + 200);
      padPlayState[s.filename] = { progress: 0 };
      function tick() {
        var st = padPlayState[s.filename];
        if (!st) return;
        if (a.paused || a.ended) { delete padPlayState[s.filename]; return; }
        st.progress = (a.currentTime / (a.duration || dur));
        requestAnimationFrame(tick);
      }
      requestAnimationFrame(tick);
      setTimeout(function () { if (playingPad.value === s.key) playingPad.value = null; }, 400);
    }

    // Duck remote audio (other participants' voices) while a soundboard is
    // playing — softens the voices to ~30% so the SFX is audible.
    var duckTimers = new Map();   // duckId -> timeoutId
    var duckStack = 0;            // ref-counted in case multiple sounds overlap
    function _setRemoteAudioGain(g) {
      var els = document.querySelectorAll('audio[data-duckable="1"]');
      els.forEach(function (el) { try { el.volume = g; } catch (_) {} });
    }
    function _duckFor(ms) {
      duckStack++;
      _setRemoteAudioGain(0.3);
      var id = setTimeout(function () {
        duckStack = Math.max(0, duckStack - 1);
        if (duckStack === 0) _setRemoteAudioGain(1.0);
      }, Math.max(200, ms));
      duckTimers.set(id, id);
    }

    function stopAllSounds() {
      Object.keys(audioPool).forEach(function (fn) {
        var a = audioPool[fn];
        try { a.pause(); a.currentTime = 0; } catch (_) {}
        delete padPlayState[fn];
      });
      playingPad.value = null;
    }

    // ----- Screen share -----
    async function startScreenShare(recordOnly) {
      if (screenSharing.value) return;
      if (remoteScreen.value && !recordOnly) {
        await podSwal.error(
          "Ya hay alguien compartiendo pantalla (" + remoteScreen.value.name + "). Solo una pantalla a la vez.",
          "No se pudo iniciar"
        );
        return;
      }
      try {
        // No system audio per the suite policy.
        screenStream = await navigator.mediaDevices.getDisplayMedia({
          video: { width: { ideal: 1920 }, height: { ideal: 1080 }, frameRate: { ideal: 18, max: 20 } },
          audio: false,
        });
      } catch (e) {
        // User cancelled the picker → silent. Real failures show an error.
        if (e && e.name !== "NotAllowedError" && e.name !== "AbortError") {
          await podSwal.error("No pude capturar la pantalla: " + e.message);
        }
        return;
      }

      screenSharing.value = true;
      screenRecordOnly.value = !!recordOnly;

      // Local preview into the screen card.
      nextTick(function () {
        var host = document.querySelector("[data-screen-host]");
        if (host && screenStream) {
          var v = document.createElement("video");
          v.autoplay = true; v.playsInline = true; v.muted = true;
          v.style.width = "100%"; v.style.height = "100%";
          v.style.objectFit = "contain"; v.style.background = "#000";
          v.srcObject = screenStream;
          host.innerHTML = ""; host.appendChild(v);
        }
      });

      // Publish to LiveKit unless record-only.
      if (!recordOnly && room) {
        try {
          screenPub = await room.localParticipant.publishTrack(
            screenStream.getVideoTracks()[0],
            {
              name: "screen",
              source: LK.Track.Source.ScreenShare,
              videoCodec: "vp8",
              videoEncoding: { maxBitrate: 2_500_000, maxFramerate: 18 },
            }
          );
        } catch (e) {
          // If publish fails, fall back to record-only and tell the user.
          screenRecordOnly.value = true;
          if (window.toast) window.toast({ type: "warn", text: "No pude publicar a LiveKit; sigo grabando local." });
        }
      }

      // Local MediaRecorder for the upload to postPod. La pantalla sube por
      // /recordings/stream con offset (igual que la cámara): si la conexión
      // se corta no se pierde. En ensayo se graba y descarta, sin subir.
      try {
        _screenStartMs = Date.now();
        if (practiceMode.value) {
          _screenUploader = null;
          screenRecorder = _startRecorder(screenStream, function () {}, 1000);
        } else {
          _screenUploader = createChunkUploader({
            sid: props.session.id,
            token: null,
            trackType: "screen",
            takeId: _newTakeId(),
          });
          screenRecorder = _startRecorder(screenStream, function () {}, 1000, false, function (data) {
            _screenUploader.push(data);
          });
          _screenUploader.setExt(screenRecorder._ext ? ("." + screenRecorder._ext) : ".webm");
          _screenUploader.start();
        }
      } catch (e) {
        // Best-effort — keep the share going even if recording fails.
        screenRecorder = null;
        _screenUploader = null;
      }

      // If the user clicks "Stop sharing" on the browser bar, the track ends.
      var t = screenStream.getVideoTracks()[0];
      if (t) t.addEventListener("ended", function () { stopScreenShare(); });

      if (window.toast) window.toast({
        type: "info",
        text: recordOnly ? "📺 Grabando pantalla (solo local)" : "📺 Compartiendo y grabando pantalla",
      });
    }

    async function stopScreenShare() {
      if (!screenSharing.value && !screenStream) return;
      // Stop the recorder first so the final chunk gets uploaded.
      if (screenRecorder) {
        await new Promise(function (resolve) {
          screenRecorder.onstop = resolve;
          try { screenRecorder.stop(); } catch (_) { resolve(); }
        });
        screenRecorder = null;
      }
      if (_screenUploader) {
        var secs = _screenStartMs ? (Date.now() - _screenStartMs) / 1000 : 0;
        var up = _screenUploader;
        _screenUploader = null;
        up.finalize(secs).then(function (ok) {
          if (window.toast) {
            window.toast(ok ? { type: "success", text: "📺 Grabación de pantalla subida" }
                            : { type: "error", text: "No se pudo subir la grabación de pantalla" });
          }
        });
      }
      _screenStartMs = null;
      if (screenPub && room) {
        try { await room.localParticipant.unpublishTrack(screenPub.track || screenPub.videoTrack); } catch (_) {}
        screenPub = null;
      }
      if (screenStream) {
        try { screenStream.getTracks().forEach(function (t) { t.stop(); }); } catch (_) {}
        screenStream = null;
      }
      screenSharing.value = false;
      screenRecordOnly.value = false;
      // Clear the local preview from the screen card.
      var host = document.querySelector("[data-screen-host]");
      if (host && (!remoteScreen.value)) host.innerHTML = "";
    }

    async function askStartScreenShare() {
      if (!navigator.mediaDevices || !navigator.mediaDevices.getDisplayMedia) {
        await podSwal.error("Tu navegador no soporta compartir pantalla.");
        return;
      }
      var r = await window.Swal.fire({
        title: "📺 Pantalla",
        text: "¿Cómo quieres compartirla?",
        showCancelButton: true,
        showDenyButton: true,
        confirmButtonText: "📡 Compartir y grabar",
        denyButtonText: "💾 Solo grabar local",
        cancelButtonText: "Cancelar",
        background: getComputedStyle(document.documentElement).getPropertyValue("--ink-panel") || "#161922",
        color: getComputedStyle(document.documentElement).getPropertyValue("--paper") || "#fff",
        confirmButtonColor: getComputedStyle(document.documentElement).getPropertyValue("--signal") || "#ff3b3b",
      });
      if (r.isConfirmed)      startScreenShare(false);
      else if (r.isDenied)    startScreenShare(true);
    }

    function sendData(msg) {
      if (!room) return;
      try { room.localParticipant.publishData(_encodeMsg(msg), LK.DataPacket_Kind.RELIABLE); } catch (_) {}
    }

    function onDataReceived(payload, participant) {
      var msg = _decodeMsg(payload);
      if (!msg) return;
      if (_tpH.tpHandle(msg)) return;
      if (msg.type === "sound_trigger" && msg.filename) {
        var s = sounds.value.find(function (x) { return x.filename === msg.filename; });
        if (s) playLocalSound(s);
      } else if (msg.type === "chat") {
        if (msg.channel === "backstage") {
          backstageChat.value.push({ id: msg.id, author: msg.author, text: msg.text, ts: msg.ts });
          nextTick(function () {
            var el = document.getElementById("backstage-scroll");
            if (el) el.scrollTop = el.scrollHeight;
          });
        } else {
          chat.value.push({ id: msg.id, author: msg.author, text: msg.text, ts: msg.ts });
          scrollChatBottom();
        }
      } else if (msg.type === "upload_status") {
        participantUploads[msg.identity] = { state: msg.state, bytes: msg.bytes || 0, pending: msg.pending || 0, eta: msg.eta == null ? null : msg.eta };
      } else if (msg.type === "ready_toggle") {
        readyMap[msg.identity] = !!msg.ready;
        if (props.user.username === props.session.created_by && !_hasDirector()) maybeFireCountdown();
      } else if (msg.type === "ready_request") {
        // Alguien (p. ej. un director recién conectado) pide los estados.
        sendData({ type: "ready_toggle", identity: myIdentity.value, ready: ownReady.value });
      } else if (msg.type === "countdown_start") {
        beginCountdown(msg.start_at_ms);
      } else if (msg.type === "recording_stop") {
        finishRecording();
        startEndCountdown();
      } else if (msg.type === "hand_raise") {
        handsRaised[msg.identity] = !!msg.up;
        if (msg.up && window.toast) {
          var who = (msg.identity || "").replace("participant_", "P");
          window.toast({ type: "info", text: "✋ " + who + " levantó la mano" });
        }
      } else if (msg.type === "practice_mode") {
        practiceMode.value = !!msg.active;
      } else if (msg.type === "kick" && room && room.localParticipant &&
                 msg.target_identity === room.localParticipant.identity) {
        error.value = "El host te desconectó.";
        disconnect();
      } else if (msg.type === "overlay_inject") {
        _admitOverlay(activeOverlays, msg);
      } else if (msg.type === "overlay_remove") {
        _dropOverlay(activeOverlays, msg.event_id);
      } else if (msg.type === "director_cue") {
        var cueMap = { "CERRAR TEMA": "wrap-up", "SIGUIENTE TEMA": "next-topic", "PAUSA": "break", "MÁS RÁPIDO": "speed-up", "MÁS LENTO": "slow-down", "LEER ANUNCIO": "ad-read", "CUSTOM": "custom" };
        if (msg.target === "all" || msg.target === myIdentity.value) {
          activeCue.value = { cue: msg.cue, text: msg.text || "", cssClass: cueMap[msg.cue] || "custom" };
          clearTimeout(cueTimer);
          cueTimer = setTimeout(function () { activeCue.value = null; }, 6000);
        }
      } else if (msg.type === "ifb_start") {
        if (msg.targets === "all_hosts" || (Array.isArray(msg.targets) && msg.targets.indexOf(myIdentity.value) !== -1)) {
          ifbActive.value = true;
          var ifbAudio = document.querySelector('audio[data-ifb="1"]');
          if (ifbAudio) ifbAudio.volume = 1.0;
        }
      } else if (msg.type === "ifb_stop") {
        ifbActive.value = false;
        var ifbAudio2 = document.querySelector('audio[data-ifb="1"]');
        if (ifbAudio2) ifbAudio2.volume = 0;
      } else if (msg.type === "force_mute") {
        if (msg.target === myIdentity.value && room) {
          room.localParticipant.setMicrophoneEnabled(false);
          localMuted.value = true;
          if (window.toast) window.toast({ type: "warn", text: "El director te muteó" });
        }
      } else if (msg.type === "director_chat") {
        if (window.toast) window.toast({ type: "info", text: "Director: " + (msg.text || "") });
      }
    }

    var ownHandUp = ref(false);
    function toggleHand() {
      if (!myIdentity.value) return;
      ownHandUp.value = !ownHandUp.value;
      handsRaised[myIdentity.value] = ownHandUp.value;
      sendData({ type: "hand_raise", identity: myIdentity.value, up: ownHandUp.value });
    }

    function triggerSound(s, ev) {
      playLocalSound(s);
      // Alt+click = "cue" — sólo se escucha en tus auriculares, no se
      // transmite al room ni se loggea como trigger.
      var isCue = ev && (ev.altKey || ev.metaKey);
      if (isCue) return;
      if (recording.value && recordingStartedAtMs != null && s.filename) {
        var off = (Date.now() - recordingStartedAtMs) / 1000;
        triggerLog.push({ filename: s.filename, tl_offset_seconds: off });
      }
      sendData({ type: "sound_trigger", filename: s.filename, key: s.key });
    }

    function scrollChatBottom() {
      nextTick(function () {
        var el = document.getElementById("chat-scroll");
        if (el) el.scrollTop = el.scrollHeight;
      });
    }

    async function sendChat() {
      var text = chatInput.value.trim();
      if (!text) return;
      try {
        var saved = await api("/api/sessions/" + props.session.id + "/chat", {
          method: "POST", body: { text: text, channel: "main" },
        });
        chat.value.push({ id: saved.id, author: saved.author_name, text: saved.message_text, ts: saved.timestamp });
        sendData({ type: "chat", channel: "main", id: saved.id, author: saved.author_name, text: saved.message_text, ts: saved.timestamp });
        chatInput.value = "";
        scrollChatBottom();
      } catch (e) { error.value = e.message; }
    }

    async function sendBackstage() {
      var text = backstageInput.value.trim();
      if (!text) return;
      try {
        var saved = await api("/api/sessions/" + props.session.id + "/chat", {
          method: "POST", body: { text: text, channel: "backstage" },
        });
        backstageChat.value.push({ id: saved.id, author: saved.author_name, text: saved.message_text, ts: saved.timestamp });
        // Targeted data publish: only the host/co-host identities receive it
        // in real time. Guests' clients never get the message even via LiveKit.
        var msg = { type: "chat", channel: "backstage", id: saved.id, author: saved.author_name, text: saved.message_text, ts: saved.timestamp };
        if (room) {
          try {
            var dests = (hostIdentities.value || []).filter(function (i) { return i !== myIdentity.value; });
            await room.localParticipant.publishData(_encodeMsg(msg), LK.DataPacket_Kind.RELIABLE,
              dests.length ? { destinationIdentities: dests } : undefined);
          } catch (_) {}
        }
        backstageInput.value = "";
        nextTick(function () {
          var el = document.getElementById("backstage-scroll");
          if (el) el.scrollTop = el.scrollHeight;
        });
      } catch (e) {
        error.value = e.message;
      }
    }

    async function connect() {
      if (!LK) { error.value = "LiveKit client no cargado"; return; }
      // Don't let the user re-enter a session that already finished. The
      // recordings list + export button are still visible, but no new
      // microphone/camera capture is possible.
      if (sessionEnded.value) {
        await podSwal.info(
          "Esta sesión ya finalizó. Puedes ver y exportar las grabaciones, pero no se puede volver a entrar al estudio.",
          "Sesión finalizada"
        );
        return;
      }
      try {
        busy.value = true;
        // Defensive: if a previous room object is still around (e.g. user
        // double-clicked Entrar, or a prior connect failed mid-way), tear it
        // down before grabbing the camera again. Otherwise the new
        // setMicrophoneEnabled() can collide with the orphaned tracks and
        // the mic comes up dead.
        if (room) {
          try { await room.disconnect(); } catch (_) {}
          room = null;
          localStream = null;
        }
        // Free up the device used for the pre-join preview before LiveKit
        // grabs it again — Safari refuses to share the camera with two
        // independent getUserMedia sessions.
        stopPrejoinPreview();

        var tokenData = await api("/api/sessions/" + props.session.id + "/my-token");
        myIdentity.value = "participant_" + tokenData.participant_id;
        var newRoom = new LK.Room({
          adaptiveStream: true,
          dynacast: true,
          // La cámara se captura a la resolución de GRABACIÓN (hasta 1080p);
          // a la sala se publica un clon reducido a ≤720p (ver más abajo).
          videoCaptureDefaults: { resolution: _recCaptureOpts() },
          publishDefaults: {
            simulcast: true,
            videoSimulcastLayers: _roomPublishLayers(),
            videoCodec: "vp8",
            videoEncoding: { maxBitrate: 1700000, maxFramerate: 30 },
          },
        });

        newRoom.on(LK.RoomEvent.ParticipantConnected, function (p) {
          var name = p.name || p.identity;
          if (p.identity && p.identity.startsWith("director_")) {
            directorConnected.value = true;
            if (window.toast) window.toast({ type: "info", text: "Director conectado" });
            // El director entró tarde: reenviarle mi estado de PREPARADO.
            sendData({ type: "ready_toggle", identity: myIdentity.value, ready: ownReady.value });
          } else {
            if (window.toast) window.toast({ type: "info", text: name + " entró al estudio" });
          }
          _maybeBrowserNotify(name + " entró al estudio");
          loadParticipants();
        });
        newRoom.on(LK.RoomEvent.TrackSubscribed, function (track, pub, participant) {
          var id = participant.identity;
          if (id.startsWith("director_")) {
            if (track.kind === LK.Track.Kind.Audio) {
              var ifbEl = track.attach();
              ifbEl.dataset.ifb = "1";
              ifbEl.volume = ifbActive.value ? 1.0 : 0;
              document.body.appendChild(ifbEl);
            }
            return;
          }
          if (!remoteMap[id]) remoteMap[id] = { name: participant.name || id, meter: 0, speaking: false };
          // ScreenShare arrives as a video track with source=ScreenShare. We
          // mount it into a dedicated big card on top of the participant grid.
          var isScreen = (track.source === LK.Track.Source.ScreenShare) ||
                         (pub && pub.source === LK.Track.Source.ScreenShare);
          if (isScreen) {
            remoteScreen.value = { identity: id, name: participant.name || id };
            nextTick(function () {
              var host = document.querySelector("[data-screen-host]");
              if (host) {
                var el = track.attach();
                el.style.width = "100%"; el.style.height = "100%";
                el.style.objectFit = "contain"; el.style.background = "#000";
                host.innerHTML = ""; host.appendChild(el);
              }
            });
            return;
          }
          if (track.kind === LK.Track.Kind.Video) {
            _mountRemoteVideo(id, track);
          } else if (track.kind === LK.Track.Kind.Audio) {
            var a = track.attach();
            a.dataset.duckable = "1";
            document.body.appendChild(a);
            var stop = _attachMeter(track, function (lvl) {
              if (remoteMap[id]) remoteMap[id].meter = lvl;
            });
            remoteMap[id]._stopMeter = stop;
          }
        });
        newRoom.on(LK.RoomEvent.TrackUnsubscribed, function (track, pub, participant) {
          if (participant && participant.identity && participant.identity.startsWith("director_")) {
            track.detach().forEach(function (el) { el.remove(); });
            ifbActive.value = false;
            document.querySelectorAll('audio[data-ifb="1"]').forEach(function (el) { el.remove(); });
            return;
          }
          track.detach().forEach(function (el) { el.remove(); });
          var isScreen = (track.source === LK.Track.Source.ScreenShare) ||
                         (pub && pub.source === LK.Track.Source.ScreenShare);
          if (isScreen && remoteScreen.value && participant && remoteScreen.value.identity === participant.identity) {
            remoteScreen.value = null;
          }
        });
        newRoom.on(LK.RoomEvent.ParticipantDisconnected, function (p) {
          var name = p.name || p.identity;
          if (p.identity && p.identity.startsWith("director_")) {
            directorConnected.value = false;
          }
          if (window.toast) window.toast({ type: "warn", text: name + " se desconectó" });
          _maybeBrowserNotify(name + " se desconectó");
          if (remoteMap[p.identity] && remoteMap[p.identity]._stopMeter) remoteMap[p.identity]._stopMeter();
          delete remoteMap[p.identity];
          if (remoteScreen.value && remoteScreen.value.identity === p.identity) remoteScreen.value = null;
          loadParticipants();
        });
        newRoom.on(LK.RoomEvent.ActiveSpeakersChanged, function (speakers) {
          var active = {};
          speakers.forEach(function (s) { active[s.identity] = true; });
          Object.keys(remoteMap).forEach(function (id) { remoteMap[id].speaking = !!active[id]; });
          var me = newRoom.localParticipant && newRoom.localParticipant.identity;
          localSpeaking.value = me ? !!active[me] : false;
          if (layoutMode.value === "spotlight" && speakers.length) {
            var top = speakers[0].identity;
            var candidate = (top === me) ? "__local__" : top;
            if (candidate !== spotlightId.value) {
              clearTimeout(_spotlightTimer);
              _spotlightTimer = setTimeout(function () { spotlightId.value = candidate; }, 1000);
            }
          }
        });
        newRoom.on(LK.RoomEvent.DataReceived, onDataReceived);
        // If the room itself disconnects (network drop, kicked, etc.) we cut
        // any in-flight screen share immediately. The screen would otherwise
        // keep recording locally without a way to publish.
        newRoom.on(LK.RoomEvent.Disconnected, function (reason) {
          // The LiveKit session ended outside our control (kicked, server
          // shutdown, host stopped, network failure, etc.). Run the full
          // cleanup so we don't keep a half-alive recording / screen share
          // / camera handle / orphaned audio elements lying around.
          var msg = "Te desconectaste de la sala";
          if (reason && typeof reason === "string") msg += " (" + reason + ")";
          if (window.toast) window.toast({ type: "warn", text: msg });
          // Don't await — we're in an event callback.
          disconnect().catch(function () {});
        });

        await newRoom.connect(tokenData.livekit_ws_url, tokenData.livekit_token);
        // setCameraEnabled / setMicrophoneEnabled return the publication once
        // the track is fully created and published. Using those return values
        // avoids the race where getTrackPublication() is called before the
        // track is registered.
        var micOpts = deviceSelection.micId   ? { deviceId: deviceSelection.micId }   : undefined;
        var camOpts = deviceSelection.cameraId ? { deviceId: deviceSelection.cameraId } : undefined;
        var micPub = await newRoom.localParticipant.setMicrophoneEnabled(true, micOpts);
        var camPub = await newRoom.localParticipant.setCameraEnabled(true, camOpts);

        // Separar grabación y sala: la captura quedó a la resolución de
        // grabación (hasta 1080p). Guardamos ese track completo para el
        // MediaRecorder y a la sala le mandamos un clon reducido a ≤720p.
        _fullResCamTrack = camPub && camPub.track ? camPub.track.mediaStreamTrack : null;
        if (_fullResCamTrack) {
          var camSet = _fullResCamTrack.getSettings ? _fullResCamTrack.getSettings() : {};
          if ((camSet.height || 0) > 720) {
            try {
              var roomTrack = _fullResCamTrack.clone();
              await roomTrack.applyConstraints({ width: { ideal: 1280 }, height: { ideal: 720 } });
              await camPub.track.replaceTrack(roomTrack, true);
              _roomCamTrack = roomTrack;
            } catch (_) {
              // Si el navegador no reduce el clon, la sala recibe la captura
              // completa con el bitrate capado — la grabación no cambia.
            }
          }
        }

        // Apply mic-check gain (if any) by re-routing the published mic
        // track through a Web Audio GainNode. We replaceTrack on LiveKit's
        // LocalAudioTrack so peers see the same publication ID — no
        // re-negotiation. Skip for ≈0 dB to avoid the extra graph.
        var savedMicGainDb = _readMicGainFor(deviceSelection.micId);
        var rawMicTrack = micPub && micPub.track ? micPub.track.mediaStreamTrack : null;
        _rawMicTrack = rawMicTrack;   // la grabación usa este (sin puerta ni ganancia); la sala recibe el procesado
        if (rawMicTrack) {
          try {
            micGainCtx = _micChain(rawMicTrack, savedMicGainDb, gateOn.value);
            await micPub.track.replaceTrack(micGainCtx.track);
          } catch (_) {
            // Fall through silently — peers still hear the unprocessed mic.
            try { if (micGainCtx) micGainCtx.close(); } catch (__) {}
            micGainCtx = null;
          }
        }

        // Para la grabación usamos el track de captura COMPLETO (no el clon
        // reducido que ve la sala) y el micrófono SIN la puerta (postPod la aplica mejor después).
        var camTrack = _fullResCamTrack;
        var micTrack = rawMicTrack;
        if (camTrack && micTrack) localStream = new MediaStream([camTrack, micTrack]);
        else if (camTrack)        localStream = new MediaStream([camTrack]);
        else if (micTrack)        localStream = new MediaStream([micTrack]);
        if (!localStream && window.toast) window.toast({ type: "warn", text: "No se pudo capturar stream local para grabación" });
        if (micTrack) {
          localMeterStop = _attachMeter({ mediaStreamTrack: micTrack }, function (lvl) {
            localMeter.value = lvl;
          });
        }

        room = newRoom;
        connected.value = true;     // first: makes the participants-grid render
        hostKeepAwake();
        await nextTick();           // wait for <video ref="localVideoEl"> to mount
        if (localVideoEl.value && camPub && camPub.track) {
          try { camPub.track.attach(localVideoEl.value); } catch (_) {}
        }

        await loadParticipants();
        await loadChat();
        persistRecQuality();  // guarda la calidad de grabación para el director

        // Mount tracks from participants already in the room
        function mountExistingRemotes() {
          if (!room) return;
          room.remoteParticipants.forEach(function (p) {
            var id = p.identity;
            if (id.startsWith("director_")) return;
            p.trackPublications.forEach(function (pub) {
              if (!pub.track || pub.track.kind !== LK.Track.Kind.Video) return;
              if (pub.source === LK.Track.Source.ScreenShare) return;
              var host = document.querySelector('[data-remote-id="' + id + '"]');
              if (host && !host.querySelector("video")) {
                _mountRemoteVideo(id, pub.track);
              }
            });
          });
        }
        setTimeout(mountExistingRemotes, 1500);
        setTimeout(mountExistingRemotes, 4000);
      } catch (e) {
        error.value = "No se pudo conectar al estudio: " + e.message;
      } finally {
        busy.value = false;
      }
    }

    async function disconnect() {
      // Full state cleanup so a stale session never survives into a new one.
      stopLocalRecorders();
      // Tracks propios de la separación grabación/sala: LiveKit no los
      // conoce como suyos, así que los soltamos nosotros.
      if (_roomCamTrack) { try { _roomCamTrack.stop(); } catch (_) {} _roomCamTrack = null; }
      if (_fullResCamTrack) { try { _fullResCamTrack.stop(); } catch (_) {} _fullResCamTrack = null; }
      // Screen share: stop recorder + unpublish + release stream.
      if (screenSharing.value || screenStream || screenRecorder) {
        try { await stopScreenShare(); } catch (_) {}
      }
      // Soundboard: silence any pad still playing.
      try { stopAllSounds && stopAllSounds(); } catch (_) {}
      // Timers and pending state.
      if (countdownHandle) { clearTimeout(countdownHandle); countdownHandle = null; }
      countdown.value = null;
      if (timerHandle) { clearInterval(timerHandle); timerHandle = null; }
      if (localMeterStop) { localMeterStop(); localMeterStop = null; }
      if (micGainCtx) {
        try { micGainCtx.close(); } catch (_) {}
        micGainCtx = null;
      }
      // Recording / ready state.
      recording.value = false;
      ownReady.value = false;
      Object.keys(readyMap).forEach(function (k) { delete readyMap[k]; });
      Object.keys(handsRaised).forEach(function (k) { delete handsRaised[k]; });
      ownHandUp.value = false;
      remoteScreen.value = null;
      // Remote track meters (kept by participant identity).
      Object.keys(remoteMap).forEach(function (id) {
        if (remoteMap[id] && remoteMap[id]._stopMeter) {
          try { remoteMap[id]._stopMeter(); } catch (_) {}
        }
        delete remoteMap[id];
      });
      // Detached audio elements piling up under <body> (one per remote audio
      // track) — clean those too.
      document.querySelectorAll('audio[data-duckable="1"]').forEach(function (el) {
        try { el.pause(); } catch (_) {}
        try { el.remove(); } catch (_) {}
      });
      // Notify server we're leaving
      try { await fetch("/api/sessions/" + props.session.id + "/leave", { method: "POST" }); } catch (_) {}
      // Disconnect the room. LiveKit unpublishes and stops its own
      // mediaStreamTracks cleanly so the browser releases the camera/mic.
      if (room) {
        try { await room.disconnect(); } catch (_) {}
        room = null;
      }
      localStream = null;
      connected.value = false;
      // Restore the original tab title.
      try { document.title = "prodPod"; } catch (_) {}
    }

    async function toggleMute() {
      if (!room) return;
      var next = !localMuted.value;
      await room.localParticipant.setMicrophoneEnabled(!next);
      localMuted.value = next;
      // La grabación usa el micrófono crudo: silenciarlo también ahí (si no, se grabaría la tos que quisiste tapar)
      if (_hostRecStream) _hostRecStream.getAudioTracks().forEach(function (t) { t.enabled = !next; });
    }
    async function toggleCam() {
      if (!room) return;
      var next = !localCamOff.value;
      await room.localParticipant.setCameraEnabled(!next);
      localCamOff.value = next;
    }

    /* ---------- recording (ready + countdown + sync start) ---------- */

    function _hasDirector() {
      // Director "presente" = conectado AHORA a la sala de LiveKit, no
      // apenas registrado con ese rol (pudo entrar una vez e irse).
      if (!room) return false;
      var found = false;
      room.remoteParticipants.forEach(function (p) {
        if (p.identity && p.identity.startsWith("director_")) found = true;
      });
      return found;
    }

    function connectedIdentities() {
      var ids = [];
      // Include my own identity
      if (myIdentity.value) ids.push(myIdentity.value);
      participants.value.forEach(function (p) {
        if (p.status === "connected" && p.username !== props.user.username) {
          ids.push("participant_" + p.id);
        }
      });
      return ids;
    }

    function isReady(identity) {
      if (identity === myIdentity.value) return ownReady.value;
      return !!readyMap[identity];
    }

    function allConnectedReady() {
      var ids = connectedIdentities();
      if (ids.length === 0) return false;
      return ids.every(isReady);
    }

    function maybeFireCountdown() {
      if (recording.value || countdown.value !== null) return;
      if (!allConnectedReady()) return;
      var startAt = Date.now() + 3500;
      sendData({ type: "countdown_start", start_at_ms: startAt });
      beginCountdown(startAt);
    }

    function beginCountdown(startAtMs) {
      if (recording.value || countdown.value !== null) return;
      if (countdownHandle) clearTimeout(countdownHandle);
      function tick() {
        var rem = startAtMs - Date.now();
        if (rem <= 0) {
          countdown.value = 0;
          beginRecordingNow();
          countdownHandle = setTimeout(function () { countdown.value = null; }, 700);
          return;
        }
        countdown.value = Math.ceil(rem / 1000);
        countdownHandle = setTimeout(tick, 100);
      }
      tick();
    }

    async function beginRecordingNow() {
      // Host hits /start for DB status; guests just record locally
      // (in practice mode no /start so the DB status doesn't change either).
      if (!practiceMode.value && props.user.username === props.session.created_by) {
        try { await api("/api/sessions/" + props.session.id + "/start", { method: "POST" }); } catch (_) {}
      }
      recording.value = true;
      recordingStart.value = Date.now();
      recordingStartedAtMs = Date.now();
      triggerLog = [];
      timecode.value = 0;
      if (timerHandle) clearInterval(timerHandle);
      timerHandle = setInterval(function () {
        timecode.value = (Date.now() - recordingStart.value) / 1000;
        // Title bar timer so the user sees the elapsed time even from
        // another tab.
        document.title = (practiceMode.value ? "🟡 ENSAYO " : "● REC ") +
          formatTC(timecode.value) + " — " + props.session.title;
      }, 250);
      startLocalRecorders();
      if (practiceMode.value && window.toast) {
        window.toast({ type: "warn", text: "Modo ensayo: nada se subirá al servidor." });
      }
      if (!practiceMode.value) _requestServerBackup(props.session.id, null);
    }

    var _hostRecStream = null;
    var _fullResCamTrack = null;   // captura completa (hasta 1080p) — para grabar
    var _roomCamTrack = null;      // clon reducido ≤720p — lo que ve la sala

    var _hostUploader = null;
    var hostUploadStatus = reactive({ state: "idle", sizeMB: "", error: "" });
    var hostStreamedBytes = ref(0);
    var hostPendingMB = ref(0);
    var hostEta = ref(null);
    var hostDoneSeen = ref(false);

    function startLocalRecorders() {
      if (room) {
        var camPub = room.localParticipant.getTrackPublication(LK.Track.Source.Camera);
        var micPub = room.localParticipant.getTrackPublication(LK.Track.Source.Microphone);
        // Grabar SIEMPRE desde la captura completa, no desde el clon de la sala.
        var camTrack = (_fullResCamTrack && _fullResCamTrack.readyState === "live")
          ? _fullResCamTrack
          : (camPub && camPub.track ? camPub.track.mediaStreamTrack : null);
        // Micrófono crudo: tras replaceTrack, micPub.track.mediaStreamTrack es el de la sala (con auto-silencio).
        var micTrack = (_rawMicTrack && _rawMicTrack.readyState === "live")
          ? _rawMicTrack
          : (micPub && micPub.track ? micPub.track.mediaStreamTrack : null);
        var tracks = [];
        if (camTrack && camTrack.readyState === "live") tracks.push(camTrack.clone());
        if (micTrack && micTrack.readyState === "live") tracks.push(micTrack.clone());
        if (tracks.length > 0) {
          _hostRecStream = new MediaStream(tracks);
          localStream = _hostRecStream;
        }
        if (!camTrack && micTrack && window.toast) {
          window.toast({ type: "warn", text: "⚠ Grabando SOLO AUDIO — cámara no disponible" });
        }
      }
      if (!recorder && localStream) {
        // ENSAYO: se graba local para probar el flujo, pero los chunks se
        // descartan — nada llega al servidor.
        if (practiceMode.value) {
          _hostUploader = null;
          recorder = _startRecorder(localStream, function () {}, 1000, false, null,
                                    { videoBitsPerSecond: recProfile().bitrate });
          return;
        }
        _hostUploader = createChunkUploader({
          sid: props.session.id,
          token: null,
          trackType: "video",
          takeId: _newTakeId(),
          onStatus: function (st) {
            hostStreamedBytes.value = st.sentBytes;
            hostPendingMB.value = st.pendingBytes / (1024 * 1024);
            hostEta.value = st.etaSeconds;
            if (st.state === "error") {
              hostUploadStatus.state = "error";
              hostUploadStatus.error = st.error;
            }
          },
          sendData: function (stt, bytes, pending, eta) {
            sendData({ type: "upload_status", identity: myIdentity.value, state: stt, bytes: bytes, pending: pending || 0, eta: eta == null ? null : eta });
          },
        });
        recorder = _startRecorder(localStream, function () {}, 1000, false, function (data) {
          _hostUploader.push(data);
        }, { videoBitsPerSecond: recProfile().bitrate });
        _hostUploader.setExt(recorder._ext ? ("." + recorder._ext) : ".webm");
        _hostUploader.start();
        hostUploadStatus.state = "streaming";
        hostStreamedBytes.value = 0;
      }
    }

    async function stopLocalRecorders() {
      if (recorder) {
        await new Promise(function (resolve) {
          recorder.onstop = resolve;
          try { recorder.stop(); } catch (_) { resolve(); }
        });
        recorder = null;
      }
      if (_hostRecStream) {
        _hostRecStream.getTracks().forEach(function (t) { t.stop(); });
        _hostRecStream = null;
      }
      if (_hostUploader) {
        hostUploadStatus.state = "finalizing";
        var ok = await _hostUploader.finalize(timecode.value);
        if (ok) {
          hostUploadStatus.state = "done";
          hostUploadStatus.sizeMB = (hostStreamedBytes.value / (1024 * 1024)).toFixed(1);
        }
        _hostUploader = null;
      }
    }

    async function markChapter() {
      if (!recording.value || recordingStartedAtMs == null) return;
      var off = (Date.now() - recordingStartedAtMs) / 1000;
      var label = await podSwal.prompt("Etiqueta del momento (opcional):", "");
      if (label === null) return;
      label = (label || "").trim();
      if (practiceMode.value) {
        if (window.toast) window.toast({ type: "warn", text: "Modo ensayo: el marker no se guarda." });
        return;
      }
      try {
        await api("/api/sessions/" + props.session.id + "/chapter-markers", {
          method: "POST", body: { tl_offset_seconds: off, label: label },
        });
        var t = formatTC(off);
        if (window.toast) window.toast({ type: "success", text: "📍 Momento marcado en " + t.hh + ":" + t.mm + ":" + t.ss });
      } catch (e) {
        if (window.toast) window.toast({ type: "error", text: "No se pudo marcar: " + e.message });
      }
    }

    async function flushTriggerLog() {
      if (!triggerLog.length) return;
      var batch = triggerLog.slice();
      triggerLog = [];
      if (practiceMode.value) return;  // ensayo: no subir
      try {
        await api("/api/sessions/" + props.session.id + "/sound-triggers", {
          method: "POST", body: { triggers: batch },
        });
      } catch (_) { /* best-effort */ }
    }

    function toggleReady() {
      if (recording.value || countdown.value !== null) return;
      ownReady.value = !ownReady.value;
      readyMap[myIdentity.value] = ownReady.value;
      sendData({ type: "ready_toggle", identity: myIdentity.value, ready: ownReady.value });
      if (props.user.username === props.session.created_by && !_hasDirector()) maybeFireCountdown();
    }

    async function stopRecording() {
      if (!recording.value) return;
      try {
        // En ensayo NO se llama /stop: la sesión no debe quedar 'finished'.
        if (!practiceMode.value && props.user.username === props.session.created_by) {
          try { await api("/api/sessions/" + props.session.id + "/stop", { method: "POST" }); } catch (_) {}
        }
        sendData({ type: "recording_stop" });
        finishRecording();
        startEndCountdown();
      } catch (e) { error.value = e.message; }
    }

    async function finishRecording() {
      if (!recording.value) return;
      recording.value = false;
      if (!practiceMode.value) sessionEnded.value = true;
      if (timerHandle) { clearInterval(timerHandle); timerHandle = null; }
      await stopLocalRecorders();
      flushTriggerLog();
      recordingStartedAtMs = null;
      // Restore the original tab title
      document.title = props.session.title + " — prodPod";
      // Clear ready state — no new take in this session
      ownReady.value = false;
      Object.keys(readyMap).forEach(function (k) { delete readyMap[k]; });
      if (room) {
        try { await room.localParticipant.setCameraEnabled(false); } catch (_) {}
        try { await room.localParticipant.setMicrophoneEnabled(false); } catch (_) {}
      }
      if (!practiceMode.value) {
        // Poll up to ~30s for uploads to land. Stop as soon as we see anything.
        var attempts = 0;
        var poll = setInterval(function () {
          attempts++;
          loadRecordings().then(function () {
            if (finishedRecordings.value.length > 0 || attempts >= 10) clearInterval(poll);
          });
        }, 3000);
        setTimeout(loadRecordings, 1000);
      }
    }

    /* ---------- invite / kick ---------- */

    async function createInvite() {
      if (!inviteForm.display_name.trim()) return;
      try {
        var r = await api("/api/sessions/" + props.session.id + "/invite", {
          method: "POST",
          body: { display_name: inviteForm.display_name.trim(), role: inviteForm.role },
        });
        inviteLinks.value.unshift(r);
        inviteForm.display_name = "";
        await loadParticipants();
      } catch (e) { error.value = e.message; }
    }
    async function copyInvite(link) {
      try { await navigator.clipboard.writeText(link.invite_url); podSwal.toast("Link copiado", "success"); }
      catch (_) { await podSwal.prompt("Copia este link:", link.invite_url); }
    }

    async function copyRsvpLink(p) {
      try { await navigator.clipboard.writeText(p.source_rsvp_url); podSwal.toast("Link RSVP copiado", "success"); }
      catch (_) { await podSwal.prompt("Copia este link RSVP:", p.source_rsvp_url); }
    }

    async function forceMute(p) {
      try {
        await api("/api/sessions/" + props.session.id + "/participants/" + p.id + "/force-mute", { method: "POST" });
        sendData({ type: "force_mute", target: "participant_" + p.id });
        if (window.toast) window.toast({ type: "info", text: p.display_name + " muteado" });
      } catch (_) {}
    }

    async function kickParticipant(p) {
      if (!await podSwal.confirm("¿Quitar a " + p.display_name + "?")) return;
      try {
        sendData({ type: "kick", target_identity: "participant_" + p.id });
        await api("/api/sessions/" + props.session.id + "/participants/" + p.id, { method: "DELETE" });
        await loadParticipants();
      } catch (e) { error.value = e.message; }
    }

    function onKey(ev) {
      if (!connected.value) return;
      var t = ev.target;
      if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA")) return;
      var key = ev.key.toUpperCase();
      var s = sounds.value.find(function (x) { return x.shortcut_key === key; });
      if (s) { ev.preventDefault(); triggerSound(s); }
    }

    onMounted(function () {
      loadParticipants();
      loadSounds();
      loadChat();
      loadRecordings();
      loadStreams();
      loadRtmpPresets();
      loadSponsorMarkers();
      // Pre-join: list devices early; preview starts as soon as the user
      // gives camera/mic permission (auto-prompt or manual button).
      listDevices();
      startPrejoinPreview();
      window.addEventListener("keydown", onKey);
      // Si quedó una subida a medias de una visita anterior (pestaña cerrada
      // durante la grabación), termina de subirla ahora.
      recoverPendingUpload(props.session.id, null, "video").then(function (ok) {
        if (ok && window.toast) window.toast({ type: "success", text: "Se recuperó y subió una grabación pendiente" });
      });
    });
    function _beaconLeave() {
      try {
        navigator.sendBeacon("/api/sessions/" + props.session.id + "/leave",
          new Blob([JSON.stringify({})] , { type: "application/json" }));
      } catch (_) {}
    }
    window.addEventListener("beforeunload", _beaconLeave);
    onBeforeUnmount(function () {
      window.removeEventListener("beforeunload", _beaconLeave);
      window.removeEventListener("keydown", onKey);
      window.removeEventListener("message", handleAmaMessage);
      if (timerHandle) clearInterval(timerHandle);
      stopPrejoinPreview();
      disconnect();
      document.title = "prodPod";
    });

    // Initial tab title for this studio
    document.title = props.session.title + " — prodPod";

    function toggleLayout() {
      if (layoutMode.value === "grid") {
        layoutMode.value = "spotlight";
        if (!spotlightId.value) spotlightId.value = "__local__";
      } else {
        layoutMode.value = "grid";
        clearTimeout(_spotlightTimer);
      }
      _reattachAllVideos();
    }
    function _reattachAllVideos() {
      nextTick(function () {
        if (!room) return;
        if (localVideoEl.value) {
          var camPub = room.localParticipant.getTrackPublication(LK.Track.Source.Camera);
          if (camPub && camPub.track) {
            try { camPub.track.attach(localVideoEl.value); } catch (_) {}
          }
        }
        room.remoteParticipants.forEach(function (p) {
          p.trackPublications.forEach(function (pub) {
            if (pub.track && pub.track.kind === LK.Track.Kind.Video) {
              var isScreen = pub.source === LK.Track.Source.ScreenShare;
              if (isScreen) {
                var host = document.querySelector("[data-screen-host]");
                if (host) {
                  var el = pub.track.attach();
                  el.style.width = "100%"; el.style.height = "100%";
                  el.style.objectFit = "contain"; el.style.background = "#000";
                  host.innerHTML = ""; host.appendChild(el);
                }
              } else {
                _mountRemoteVideo(p.identity, pub.track);
              }
            }
          });
        });
      });
    }
    function spotlightParticipant() {
      if (!spotlightId.value || spotlightId.value === "__local__") return null;
      var p = participants.value.find(function (pp) {
        return "participant_" + pp.id === spotlightId.value || pp.username === spotlightId.value;
      });
      return p || null;
    }
    function pinSpotlight(identity) {
      spotlightId.value = identity;
      clearTimeout(_spotlightTimer);
      _reattachAllVideos();
    }

    // Wrap the back-handler so we synchronously close the LiveKit room
    // before letting the parent unmount us. Without this, room.disconnect()
    // fires async after the unmount and the other participant keeps seeing
    // us in the room for several seconds.
    async function safeBack() {
      await disconnect();
      if (props.onBack) props.onBack();
    }

    return {
      participants: participants, remoteMap: remoteMap, error: error, busy: busy,
      recording: recording, sessionEnded: sessionEnded, timecode: timecode, formatTC: formatTC, initials: initials,
      connected: connected, connect: connect, disconnect: disconnect, safeBack: safeBack,
      localVideoEl: localVideoEl, localMuted: localMuted, localCamOff: localCamOff, localMeter: localMeter,
      localSpeaking: localSpeaking,
      toggleMute: toggleMute, toggleCam: toggleCam, gateOn: gateOn, toggleGate: toggleGate,
      toggleReady: toggleReady, stopRecording: stopRecording,
      ownReady: ownReady, readyMap: readyMap, countdown: countdown, myIdentity: myIdentity,
      showInvite: showInvite, inviteForm: inviteForm, inviteLinks: inviteLinks,
      createInvite: createInvite, copyInvite: copyInvite, copyRsvpLink: copyRsvpLink, forceMute: forceMute, kickParticipant: kickParticipant,
      sounds: sounds, playingPad: playingPad, triggerSound: triggerSound,
      padPlayState: padPlayState, padVolumes: padVolumes, setPadVolume: setPadVolume,
      stopAllSounds: stopAllSounds, onPadDrop: onPadDrop,
      soundLimits: soundLimits, soundUploadStatus: soundUploadStatus, uploadSound: uploadSound,
      showAddSound: showAddSound, newSound: newSound, addCustomPad: addCustomPad, deleteCustomPad: deleteCustomPad,
      chat: chat, chatInput: chatInput, sendChat: sendChat,
      backstageChat: backstageChat, backstageInput: backstageInput,
      sendBackstage: sendBackstage, chatChannel: chatChannel,
      finishedRecordings: finishedRecordings, loadRecordings: loadRecordings,
      triggerStats: triggerStats,
      exportToPostpod: exportToPostpod, exportStatus: exportStatus, exporting: exporting, allExported: allExported,
      hostUploadStatus: hostUploadStatus, hostStreamedBytes: hostStreamedBytes,
      participantUploads: participantUploads, allUploadsComplete: allUploadsComplete,
      guestCuesVisible: guestCuesVisible, toggleGuestCues: toggleGuestCues,
      showDiagnostic: showDiagnostic,
      streams: streams, rtmpPresets: rtmpPresets, showStream: showStream, streamForm: streamForm,
      streamStatus: streamStatus, streamBusy: streamBusy, activeStreams: activeStreams,
      applyStreamPreset: applyStreamPreset, startStream: startStream, stopStream: stopStream,
      sponsorMarkers: sponsorMarkers, sponsorAlertId: sponsorAlertId,
      sponsorCountdown: sponsorCountdown, sponsorDismissed: sponsorDismissed,
      delaySponsor: delaySponsor, dismissSponsor: dismissSponsor,
      loadSponsorMarkers: loadSponsorMarkers, _sponsorFmtTC: _sponsorFmtTC,
      isHost: props.user.username === props.session.created_by,
      canBackstage: canBackstage,
      hasSharedProject: !!props.session.shared_project_id,
      // Pre-join exports
      prejoinVideoEl: prejoinVideoEl, devices: devices, deviceSelection: deviceSelection,
      prejoinMeter: prejoinMeter, prejoinError: prejoinError,
      startPrejoinPreview: startPrejoinPreview,
      // Mic check wizard
      micCheckRunning: micCheckRunning, micCheckCountdown: micCheckCountdown,
      micCheckResult: micCheckResult, micCheckAppliedGain: micCheckAppliedGain,
      runMicCheck: runMicCheck, cancelMicCheck: cancelMicCheck,
      applyMicCheckGain: applyMicCheckGain, resetMicCheckGain: resetMicCheckGain,
      practiceMode: practiceMode, markChapter: markChapter,
      recPreflight: recPreflight, recProfileChoices: recProfileChoices,
      recProfile: recProfile, hostPendingMB: hostPendingMB, hostEta: hostEta, etaText: etaText, hostDoneSeen: hostDoneSeen, endCountdown: endCountdown, camsOffAfterRec: camsOffAfterRec,
      handsRaised: handsRaised, ownHandUp: ownHandUp, toggleHand: toggleHand,
      screenSharing: screenSharing, screenRecordOnly: screenRecordOnly, remoteScreen: remoteScreen,
      askStartScreenShare: askStartScreenShare, stopScreenShare: stopScreenShare,
      layoutMode: layoutMode, spotlightId: spotlightId, toggleLayout: toggleLayout,
      spotlightParticipant: spotlightParticipant, pinSpotlight: pinSpotlight,
      activeOverlays: activeOverlays, cintilloOverlays: cintilloOverlays, otherOverlays: otherOverlays,
      ovLogoUrl: ovLogoUrl, cintilloTitle: cintilloTitle, cintilloText: cintilloText, fmtCountdown: fmtCountdown,
      activeCue: activeCue, ifbActive: ifbActive, directorConnected: directorConnected,
      tp: _tpH.tp, tpPause: _tpH.tpPause, tpRestart: _tpH.tpRestart, tpClose: _tpH.tpClose,
      amaPanel: amaPanel, amaEmbedUrl: amaEmbedUrl, amaEventId: amaEventId, amaBusy: amaBusy,
      sideTab: sideTab, openSide: openSide, chatUnreadH: chatUnreadH,
      startAma: startAma, closeAma: closeAma,
    };
  },
  template: `
    <div class="studio host-studio" :class="[{ 'side-open': !!sideTab, 'is-connected': connected }, sideTab ? 'tab-' + sideTab : '']">
      <div class="studio-top" :class="{ recording: recording }">
        <button class="ghost hs-back" @click="safeBack">← <span class="d-only">Sesiones</span></button>
        <h3>{{ session.title }}</h3>
        <span class="badge-id d-only">#{{ session.id }}</span>
        <a v-if="session.source_url && session.source_slug && session.source_episode_id"
           :href="session.source_url + '/#/podcasts/' + session.source_slug + '/episodes/' + session.source_episode_id"
           target="_blank" class="ghost d-only" style="font-size:11px;padding:3px 8px;margin-left:6px;text-decoration:none;"
           title="Abrir episodio en prePod">📋 prePod</a>
        <div class="spacer"></div>
        <div class="timecode mono" :class="{ 'hs-idle': !recording }">{{ formatTC(timecode) }}</div>
        <div v-if="connected" class="vu-master d-only">
          <span class="vu-label">MIC</span>
          <div class="vu-h" :style="'--vu:' + localMeter"></div>
        </div>
        <span v-if="ifbActive" class="ifb-indicator">🎧 Director hablándote...</span>
        <span v-if="directorConnected" class="director-badge">🎬 Director</span>
        <label v-if="!recording && countdown === null && isHost" class="practice-toggle d-only"
               :title="'En modo ensayo nada se sube al servidor — solo prueba.'">
          <input type="checkbox" v-model="practiceMode">
          <span>Ensayo</span>
        </label>
        <span v-if="practiceMode" class="rehearsal-badge">🟡 ENSAYO</span>
        <span v-if="!connected && recPreflight.state === 'testing'" class="quality-pick d-only"
              title="Midiendo tu subida y tu equipo (~5 s)">📶 Probando calidad…</span>
        <select v-else-if="!connected && recPreflight.state === 'done'" v-model="recPreflight.choiceId" class="quality-pick d-only"
                :title="'La prueba puso el máximo (' + recPreflight.profileId + '). Puedes bajarla, no subirla.'">
          <option v-for="p in recProfileChoices" :key="p.id" :value="p.id">REC {{ p.desc }}</option>
        </select>
        <template v-if="sessionEnded">
          <span class="session-done-badge" title="La grabación de esta sesión ya finalizó">✓ FINALIZADA</span>
        </template>
        <template v-else-if="!recording && countdown === null">
          <button class="primary rec-btn" @click="toggleReady" :disabled="!connected"
                  :style="ownReady ? 'background: var(--signal); color:#fff;' : ''">
            {{ ownReady ? "✓ Listo" : "● Prepararse" }}
          </button>
        </template>
        <button v-if="connected" class="ghost d-only" style="margin-right: 8px;"
                :class="{ primary: ownHandUp }" @click="toggleHand"
                title="Levantar/bajar la mano">✋</button>
        <button v-if="recording" class="ghost d-only" style="margin-right: 8px;"
                @click="markChapter"
                title="Marcar momento durante la grabación">📍 Momento</button>
        <button v-if="recording" class="rec-btn" style="background: var(--signal); color: #fff;"
                @click="stopRecording" :disabled="!isHost" :title="isHost ? 'Detener' : 'Sólo el host puede detener'">
          ■ Detener
        </button>

        <span v-if="activeStreams.length" class="tally live" style="margin-left: 8px;" :title="activeStreams.length + ' stream(s) activos'">
          <span class="dot"></span>EN VIVO
        </span>
        <button v-if="connected && !screenSharing" class="ghost d-only" style="margin-left: 8px;"
                :disabled="!!remoteScreen"
                :title="remoteScreen ? ('Ya está compartiendo ' + remoteScreen.name) : 'Compartir o grabar pantalla'"
                @click="askStartScreenShare">📺 Pantalla</button>
        <button v-if="connected && screenSharing" class="ghost d-only" style="margin-left: 8px; background: rgba(255,59,59,0.16); color: #ff7373;"
                @click="stopScreenShare" :title="screenRecordOnly ? 'Detener (solo grabando local)' : 'Dejar de compartir'">
          ■ {{ screenRecordOnly ? 'Detener pantalla' : 'Dejar de compartir' }}
        </button>
        <button v-if="isHost && connected" class="ghost d-only" style="margin-left: 8px;" @click="showStream = true" title="Transmitir a RTMP">📡 Stream</button>
        <button v-if="isHost" class="ghost d-only" style="margin-left: 8px;" @click="showDiagnostic" title="Ver quién está conectado a la sala según LiveKit">🔍 Diagnóstico</button>
        <button v-if="!connected" class="primary d-only" style="margin-left: 8px; padding: 6px 14px;" @click="connect" :disabled="busy" title="Conectar este navegador a la sala de LiveKit">
          {{ busy ? "Conectando…" : "🟢 Conectar" }}
        </button>
      </div>

      <div v-if="hostUploadStatus.state === 'streaming'" class="upload-banner" style="background:var(--bg-2);border-bottom:2px solid var(--accent);padding:6px 16px;text-align:center;font-size:12px;">
        Subiendo en tiempo real · {{ (hostStreamedBytes / (1024*1024)).toFixed(1) }} MB enviados<span v-if="hostPendingMB > 0.5"> · falta {{ hostPendingMB.toFixed(1) }} MB</span>
      </div>
      <div v-if="endCountdown !== null" class="end-countdown">
        <div class="end-countdown-title">La grabación terminó</div>
        <div class="end-countdown-sub">Apagamos cámara y micrófono en</div>
        <div class="end-countdown-num">{{ endCountdown }}</div>
      </div>
      <div v-if="hostUploadStatus.state === 'finalizing'" class="upload-overlay">
        <div class="upload-overlay-box">
          <div class="upload-overlay-icon">⏳</div>
          <h2>Terminando de subir tu grabación…</h2>
          <p class="upload-overlay-big">{{ hostPendingMB > 0.05 ? "Faltan " + hostPendingMB.toFixed(1) + " MB" : "Casi listo" }}</p>
          <p v-if="hostEta && hostPendingMB > 0.05" class="upload-overlay-eta">Tiempo estimado: {{ etaText(hostEta) }}</p>
          <p class="muted">No cierres esta pestaña ni apagues el computador hasta que diga «Listo». Puedes dejarla abierta y seguir con lo tuyo.</p>
        </div>
      </div>
      <div v-if="hostUploadStatus.state === 'done' && !hostDoneSeen" class="upload-overlay">
        <div class="upload-overlay-box">
          <div class="upload-overlay-icon ok">✓</div>
          <h2>Listo, tu grabación llegó completa</h2>
          <p class="muted">{{ hostUploadStatus.sizeMB }} MB enviados. Ya puedes salir; se enviará sola a postPod cuando lleguen las de todos.</p>
          <button class="primary" @click="hostDoneSeen = true">Entendido</button>
        </div>
      </div>
      <div v-if="hostUploadStatus.state === 'error'" class="upload-banner" style="background:#5a1a1a;border-bottom:2px solid red;padding:8px 16px;text-align:center;font-weight:700;color:#f66;">
        ✕ Error al subir grabación: {{ hostUploadStatus.error }}
      </div>

      <div v-if="activeCue" class="director-cue" :class="activeCue.cssClass">
        {{ activeCue.cue }}
        <div v-if="activeCue.text" style="font-size: 13px; font-weight: 400; margin-top: 4px;">{{ activeCue.text }}</div>
      </div>
${TP_TEMPLATE}

      <div v-if="cintilloOverlays.length" class="cintillo-layer">
        <div v-for="ov in cintilloOverlays" :key="ov.event_id" class="cintillo" :class="ov.event_type">
          <div v-if="ovLogoUrl(ov)" class="c-logo"><img :src="ovLogoUrl(ov)" alt=""></div>
          <div class="c-bars">
            <div class="c-title">{{ cintilloTitle(ov) }}</div>
            <div v-if="cintilloText(ov)" class="c-text">{{ cintilloText(ov) }}</div>
          </div>
        </div>
      </div>
      <div v-if="otherOverlays.length" class="director-overlay">
        <div v-for="ov in otherOverlays" :key="ov.event_id" class="overlay-card" :class="ov.event_type">
          <template v-if="ov.event_type === 'comment'">
            <div class="ov-author">{{ ov.payload.author }} · {{ ov.payload.platform }}</div>
            <div class="ov-text">{{ ov.payload.text }}</div>
          </template>
          <template v-else-if="ov.event_type === 'countdown'">
            <div class="ov-label">{{ ov.payload.label }}</div>
            <div class="ov-timer">{{ fmtCountdown(ov.remaining) }}</div>
          </template>
        </div>
      </div>

      <div class="studio-main">
        <div v-if="error" class="error">{{ error }}</div>

        <div v-if="!connected" class="prejoin">
          <div class="prejoin-card">
            <div class="prejoin-preview">
              <video ref="prejoinVideoEl" autoplay muted playsinline></video>
              <div v-if="!prejoinVideoEl || !prejoinVideoEl.srcObject" class="prejoin-placeholder">
                <div style="font-size: 56px; opacity: 0.3; margin-bottom: 8px;">🎥</div>
                <button class="primary" @click="startPrejoinPreview">Activar cámara/mic</button>
                <div v-if="prejoinError" class="error" style="margin-top: 14px;">{{ prejoinError }}</div>
              </div>
              <div class="prejoin-vu" :title="'Nivel de mic: ' + prejoinMeter + '%'">
                <div class="vu-h" :style="'--vu:' + prejoinMeter"></div>
              </div>
            </div>
            <div class="prejoin-controls">
              <h3 style="margin: 0 0 4px;">Prueba tu equipo antes de entrar</h3>
              <p class="muted" style="margin: 0 0 18px; font-size: 12px;">
                Habla frente al micrófono y mira que el medidor se mueva. Al entrar te conectas a la sesión con estos equipos.
              </p>
              <div class="form-row" style="margin-bottom: 12px;">
                <label>📷 Cámara</label>
                <select v-model="deviceSelection.cameraId">
                  <option v-for="d in devices.cameras" :key="d.deviceId" :value="d.deviceId">
                    {{ d.label || ('Cámara ' + d.deviceId.slice(0, 6)) }}
                  </option>
                </select>
              </div>
              <div class="form-row" style="margin-bottom: 12px;">
                <label>🎤 Micrófono</label>
                <select v-model="deviceSelection.micId">
                  <option v-for="d in devices.mics" :key="d.deviceId" :value="d.deviceId">
                    {{ d.label || ('Mic ' + d.deviceId.slice(0, 6)) }}
                  </option>
                </select>
              </div>

              <div class="mic-check-panel d-only" style="margin: 0 0 18px; padding: 12px; border: 1px solid var(--ink-line); border-radius: 8px; background: var(--ink-sunken, rgba(0,0,0,0.18));">
                <div style="display: flex; align-items: center; gap: 8px; margin-bottom: 8px;">
                  <span class="eyebrow">MIC CHECK</span>
                  <span v-if="micCheckAppliedGain"
                        class="role-chip"
                        :style="{ background: 'var(--signal)', color: '#fff', fontSize: '10px' }">
                    APLICADO {{ micCheckAppliedGain > 0 ? '+' : '' }}{{ micCheckAppliedGain }} dB
                  </span>
                </div>

                <button v-if="!micCheckRunning"
                        class="ghost"
                        @click="runMicCheck"
                        :disabled="!deviceSelection.micId"
                        style="width: 100%; padding: 8px; font-size: 13px;">
                  🎤 Probar micrófono (10s)
                </button>
                <div v-else style="text-align: center; padding: 6px 0;">
                  <div class="mono" style="font-size: 22px; font-weight: 600;">{{ micCheckCountdown }}s</div>
                  <div class="muted" style="font-size: 12px;">Habla normalmente al mic…</div>
                  <button class="ghost" @click="cancelMicCheck" style="margin-top: 6px; font-size: 11px;">Cancelar</button>
                </div>

                <div v-if="micCheckResult && !micCheckRunning" style="margin-top: 10px; font-size: 12px;">
                  <div style="display: flex; gap: 14px; margin-bottom: 8px;">
                    <div><span class="muted">Pico</span><br><strong class="mono">{{ micCheckResult.peak_dbfs }} dBFS</strong></div>
                    <div><span class="muted">Promedio</span><br><strong class="mono">{{ micCheckResult.avg_dbfs }} dBFS</strong></div>
                  </div>

                  <div v-if="micCheckResult.suggested_db == null" class="muted" style="margin-bottom: 6px;">
                    Señal muy baja — verifica que el mic no esté en silencio o muy lejos.
                  </div>
                  <template v-else-if="micCheckResult.suggested_db === 0">
                    <div style="margin-bottom: 6px;">✓ Tu micrófono ya está bien nivelado.</div>
                  </template>
                  <template v-else>
                    <div style="margin-bottom: 8px;">
                      Sugerencia:
                      <strong>{{ micCheckResult.suggested_db > 0 ? '+' : '' }}{{ micCheckResult.suggested_db }} dB</strong>
                      ({{ micCheckResult.suggested_db > 0 ? 'tu voz está baja, te subimos' : 'tu voz está muy fuerte, bajamos' }})
                    </div>
                    <div style="display: flex; gap: 6px;">
                      <button class="primary" style="font-size: 12px; padding: 6px 10px;" @click="applyMicCheckGain">Aplicar</button>
                      <button class="ghost" style="font-size: 12px; padding: 6px 10px;" @click="runMicCheck">Reintentar</button>
                      <div class="spacer"></div>
                      <button v-if="micCheckAppliedGain" class="ghost" style="font-size: 12px; padding: 6px 10px;" @click="resetMicCheckGain">Quitar ajuste</button>
                    </div>
                  </template>
                </div>

                <div v-if="!micCheckResult && micCheckAppliedGain && !micCheckRunning" style="margin-top: 8px;">
                  <button class="ghost" style="font-size: 12px; padding: 4px 10px;" @click="resetMicCheckGain">Quitar ajuste guardado</button>
                </div>
              </div>

              <div style="margin-top: 10px; font-size: 12px;">
                <div v-if="recPreflight.state === 'testing'" class="muted">📶 Probando tu conexión y tu equipo (~5 s)…</div>
                <div v-else-if="recPreflight.state === 'done'">
                  ✓ Tu grabación irá en <strong>{{ recProfile().quality }}</strong>
                  <span class="muted" v-if="recPreflight.upMbps"> · subida {{ recPreflight.upMbps.toFixed(1) }} Mbps</span>
                  <span class="muted" v-if="recPreflight.fps"> · {{ Math.round(recPreflight.fps) }} fps</span>
                </div>
              </div>

              <p class="upload-heads-up">⏳ Al terminar la grabación, quédate en esta página hasta que diga «Listo»: tu grabación termina de subirse y te mostramos cuánto falta.</p>
              <button class="primary" @click="connect" :disabled="busy" style="width: 100%; padding: 14px;">
                {{ busy ? "Conectando…" : "Entrar al estudio" }}
              </button>
            </div>
          </div>
        </div>

        <div v-if="connected && layoutMode === 'spotlight'" class="spotlight-layout">
          <div class="spotlight-main">
            <div v-if="screenSharing || remoteScreen" class="screen-card spotlight-screen">
              <div class="screen-host" data-screen-host></div>
              <div class="screen-label">
                <span class="dot"></span>
                <span class="who">📺 {{ screenSharing ? (screenRecordOnly ? 'Tú · solo grabando' : 'Tú · compartiendo') : (remoteScreen ? remoteScreen.name + ' está compartiendo' : '') }}</span>
                <button v-if="screenSharing" class="ghost" @click="stopScreenShare">■ Detener</button>
              </div>
            </div>
            <template v-else>
              <div v-if="spotlightId === '__local__'" class="participant-card spotlight-card" :class="{ speaking: localSpeaking }">
                <video ref="localVideoEl" autoplay muted playsinline></video>
                <div v-if="localCamOff" class="initials" style="position: absolute;">{{ initials(user.display_name || user.username) }}</div>
                <div class="label">
                  <span>{{ user.display_name || user.username }}</span>
                  <span class="role-chip">TÚ</span>
                </div>
                <div v-if="localMuted" class="muted-icon">🔇</div>
                <div class="vu" :style="'--vu:' + localMeter"></div>
              </div>
              <div v-else-if="spotlightParticipant()" class="participant-card spotlight-card" :class="{ speaking: remoteMap[spotlightId] && remoteMap[spotlightId].speaking }">
                <div :data-remote-id="spotlightId" style="width: 100%; height: 100%;">
                  <div class="initials" :style="{ background: spotlightParticipant().avatar_color }">{{ initials(spotlightParticipant().display_name) }}</div>
                </div>
                <div class="label">
                  <span>{{ spotlightParticipant().display_name }}</span>
                  <span class="role-chip">{{ spotlightParticipant().role }}</span>
                </div>
                <div class="vu" :style="'--vu:' + ((remoteMap[spotlightId] && remoteMap[spotlightId].meter) || 0)"></div>
              </div>
            </template>
          </div>
          <div class="spotlight-sidebar">
            <div class="participant-card thumb-card" :class="{ speaking: localSpeaking }" @click="pinSpotlight('__local__')">
              <video ref="localVideoEl" autoplay muted playsinline></video>
              <div v-if="localCamOff" class="initials" style="position: absolute;">{{ initials(user.display_name || user.username) }}</div>
              <div class="label"><span>{{ user.display_name || user.username }}</span><span class="role-chip">TÚ</span></div>
              <div v-if="localMuted" class="muted-icon">🔇</div>
            </div>
            <template v-for="p in participants.filter(pp => pp.username !== user.username && pp.status === 'connected' && pp.role !== 'director')" :key="'side-' + p.id">
              <div class="participant-card thumb-card"
                   :class="{ speaking: remoteMap['participant_' + p.id] && remoteMap['participant_' + p.id].speaking, hand: handsRaised['participant_' + p.id] }"
                   @click="pinSpotlight('participant_' + p.id)">
                <div :data-remote-id="'participant_' + p.id" style="width: 100%; height: 100%;">
                  <div class="initials" :style="{ background: p.avatar_color }">{{ initials(p.display_name) }}</div>
                </div>
                <div class="label"><span>{{ p.display_name }}</span><span class="role-chip">{{ p.role }}</span></div>
              </div>
            </template>
          </div>
        </div>

        <div v-if="connected && (screenSharing || remoteScreen) && layoutMode !== 'spotlight'" class="screen-card">
          <div class="screen-host" data-screen-host></div>
          <div class="screen-label">
            <span class="dot"></span>
            <span class="who">📺 {{ screenSharing ? (screenRecordOnly ? 'Tú · solo grabando' : 'Tú · compartiendo') : (remoteScreen ? remoteScreen.name + ' está compartiendo' : '') }}</span>
            <button v-if="screenSharing" class="ghost" @click="stopScreenShare">■ Detener</button>
          </div>
        </div>

        <div v-if="connected && layoutMode === 'grid'" class="participants-grid">
          <div class="participant-card" :class="{ speaking: localSpeaking }">
            <video ref="localVideoEl" autoplay muted playsinline></video>
            <div v-if="localCamOff" class="initials" style="position: absolute;">{{ initials(user.display_name || user.username) }}</div>
            <div class="label">
              <span>{{ user.display_name || user.username }}</span>
              <span class="role-chip">TÚ</span>
              <span v-if="ownReady && !recording" class="role-chip" style="background: var(--signal); color:#fff;">LISTO</span>
            </div>
            <div v-if="localMuted" class="muted-icon">🔇</div>
            <div class="vu" :style="'--vu:' + localMeter"></div>
            <div v-if="camsOffAfterRec" class="tile-upload">
              <template v-if="hostUploadStatus.state === 'done'"><div class="tu-ok">✓ Listo</div><div class="tu-sub">Grabación completa</div></template>
              <template v-else-if="hostUploadStatus.state === 'error'"><div class="tu-bad">✕ Error al subir</div></template>
              <template v-else-if="hostUploadStatus.state === 'idle'"><div class="tu-sub">Sin grabación</div></template>
              <template v-else>
                <div class="tu-main">Subiendo…</div>
                <div class="tu-sub">{{ hostPendingMB > 0.05 ? "Faltan " + hostPendingMB.toFixed(0) + " MB" : "Casi listo" }}<span v-if="hostEta && hostPendingMB > 0.05"> · {{ etaText(hostEta) }}</span></div>
              </template>
            </div>
          </div>

          <div v-for="p in participants.filter(pp => pp.username !== user.username && pp.status === 'connected' && pp.role !== 'director')"
               :key="p.id"
               class="participant-card"
               :class="{ speaking: remoteMap['participant_' + p.id] && remoteMap['participant_' + p.id].speaking,
                         hand: handsRaised['participant_' + p.id] }">
            <div :data-remote-id="'participant_' + p.id" style="width: 100%; height: 100%;">
              <div class="initials" :style="{ background: p.avatar_color }">{{ initials(p.display_name) }}</div>
            </div>
            <div class="label">
              <span>{{ p.display_name }}</span>
              <span class="role-chip">{{ p.role }}</span>
              <span v-if="readyMap['participant_' + p.id] && !recording" class="role-chip" style="background: var(--signal); color:#fff;">LISTO</span>
            </div>
            <div class="vu" :style="'--vu:' + ((remoteMap['participant_' + p.id] && remoteMap['participant_' + p.id].meter) || 0)"></div>
            <div v-if="camsOffAfterRec" class="tile-upload">
              <template v-if="!participantUploads['participant_' + p.id]"><div class="tu-sub">Esperando estado de subida…</div></template>
              <template v-else-if="participantUploads['participant_' + p.id].state === 'done'"><div class="tu-ok">✓ Listo</div><div class="tu-sub">Grabación completa</div></template>
              <template v-else-if="participantUploads['participant_' + p.id].state === 'error'"><div class="tu-bad">✕ Error al subir</div></template>
              <template v-else>
                <div class="tu-main">Subiendo…</div>
                <div class="tu-sub">{{ participantUploads['participant_' + p.id].pending > 50000 ? "Faltan " + (participantUploads['participant_' + p.id].pending / 1048576).toFixed(0) + " MB" : "Casi listo" }}<span v-if="participantUploads['participant_' + p.id].eta"> · {{ etaText(participantUploads['participant_' + p.id].eta) }}</span></div>
              </template>
            </div>
          </div>

          <div v-for="p in participants.filter(pp => pp.status === 'invited')"
               :key="'inv-' + p.id"
               class="participant-card"
               style="opacity: 0.4;">
            <div class="initials">{{ initials(p.display_name) }}</div>
            <div class="label"><span>{{ p.display_name }}</span><span class="role-chip">pendiente</span></div>
          </div>
        </div>

        <div v-if="countdown !== null" class="countdown-overlay">
          <div class="countdown-num">{{ countdown > 0 ? countdown : '●' }}</div>
          <div class="countdown-label">{{ countdown > 0 ? 'preparándose…' : 'GRABANDO' }}</div>
        </div>

        <div v-if="sessionEnded || finishedRecordings.length" class="recordings-panel">
          <div class="recordings-head">
            <div class="recordings-title">
              <span class="label">Grabaciones</span>
              <span class="track-count">{{ finishedRecordings.length }} pista(s)</span>
            </div>
            <div class="recordings-actions">
              <button class="btn-secondary" @click="loadRecordings" title="Recargar lista de pistas">↻ Recargar</button>
              <a v-if="finishedRecordings.length" :href="'/api/sessions/' + session.id + '/recordings/bundle.zip'"
                 class="btn-secondary" download>↓ ZIP</a>
              <button v-if="!recording && !directorConnected" class="btn-export"
                      :class="{ exported: allExported }"
                      :disabled="exporting || !finishedRecordings.length" @click="exportToPostpod"
                      title="Enviar pistas a postPod para editar">
                {{ exporting ? "↗ enviando…" : allExported ? "✓ Ya enviado a postPod" : "↗ Enviar a postPod" }}
              </button>
            </div>
          </div>
          <div v-if="exportStatus" class="export-status">{{ exportStatus }}</div>
          <div v-if="!finishedRecordings.length" class="muted" style="padding: 12px; text-align: center;">
            Aún no llegaron pistas al servidor. Espera unos segundos y toca ↻ Recargar.
          </div>
          <div v-else class="recordings-list">
            <div v-for="r in finishedRecordings" :key="r.id" class="recording-row">
              <span class="rec-name mono">{{ r.filename }}</span>
              <span class="rec-meta">{{ r.track_type }} · {{ Math.round((r.size_bytes||0)/1024) }} KB</span>
              <span v-if="r.exported_to_postpod_at" class="rec-chip exported" title="Enviada a postPod">↗ postPod</span>
              <a :href="r.url + '?download=1'" class="btn-secondary tight" download>↓</a>
            </div>
          </div>
          <div v-if="triggerStats.count > 0" class="muted" style="margin-top: 10px; padding: 8px 12px; background: var(--ink-sunken); border-radius: 4px; font-size: 12px;">
            🎚 <strong>{{ triggerStats.count }} disparo(s) de soundboard</strong> registrados durante la sesión — se envían junto con las pistas a postPod en su timestamp exacto.
          </div>
        </div>
      </div>

      <aside class="studio-side hs-side">
        <div class="hs-sheet-head">
          <button :class="{ on: sideTab === 'chat' }" @click="openSide('chat')">Chat</button>
          <button :class="{ on: sideTab === 'people' }" @click="openSide('people')">Personas</button>
          <button v-if="sponsorMarkers.length" :class="{ on: sideTab === 'sponsors' }" @click="openSide('sponsors')">Sponsors</button>
          <div class="spacer"></div>
          <button class="hs-close" @click="sideTab = null">Cerrar</button>
        </div>
        <div class="hs-sound">
          <div class="sb-head">
            <span class="label">Soundboard</span>
            <div class="spacer"></div>
            <button class="ghost" style="padding: 3px 9px; font-size: 10px;" @click="stopAllSounds" title="Detener todos los sonidos">■ Stop all</button>
            <span class="tiny" style="margin-left: 6px;">⌥ click = cue</span>
          </div>
          <div class="sb-grid" :class="{ compact: layoutMode === 'spotlight' }">
            <div v-for="s in sounds" :key="s.id" class="sb-pad-wrap"
                 @dragover.prevent
                 @drop.prevent="onPadDrop(s, $event)">
              <button class="sb-pad"
                      :class="{ playing: playingPad === s.shortcut_key || (s.filename && padPlayState[s.filename]), empty: !s.filename }"
                      :style="{ '--pad-color': s.color, '--pad-progress': ((s.filename && padPlayState[s.filename] ? padPlayState[s.filename].progress : 0) * 100) + '%' }"
                      @click="triggerSound(s, $event)"
                      :title="s.name + (s.shortcut_key ? ' (' + s.shortcut_key + ')' : '') + ' — Alt+click para cue'">
                <span>{{ s.name }}</span>
                <span class="key">{{ s.shortcut_key || '—' }}</span>
              </button>
              <input v-if="s.filename" type="range" class="sb-pad-vol"
                     min="0" max="1" step="0.01"
                     :value="padVolumes[s.filename] != null ? padVolumes[s.filename] : 1"
                     @input="setPadVolume(s.filename, parseFloat($event.target.value))"
                     :title="'Volumen ' + Math.round(((padVolumes[s.filename] != null ? padVolumes[s.filename] : 1) * 100)) + '%'"
                     @click.stop>
              <label class="sb-pad-upload" :title="'Subir (máx ' + (soundLimits.max_kb || 150) + 'KB · ' + (soundLimits.max_duration_seconds || 4) + 's) — o arrastra archivo aquí'">
                ⬆
                <input type="file" accept="audio/*" @change="(ev) => uploadSound(s, ev)" style="display: none;">
              </label>
              <button v-if="!s.is_default" class="sb-pad-delete" @click.stop="deleteCustomPad(s)" title="Eliminar pad">✕</button>
            </div>
            <button v-if="sounds.length < (soundLimits.max_total || 15)" class="sb-pad add-new" @click="showAddSound = true" :title="'Agregar pad (' + sounds.length + '/' + (soundLimits.max_total || 15) + ')'">
              ＋
            </button>
          </div>
          <div v-if="soundUploadStatus" class="muted" style="margin-top: 6px; font-size: 11px;">{{ soundUploadStatus }}</div>

          <div v-if="showAddSound" class="modal-backdrop" @click.self="showAddSound = false">
            <div class="modal" style="width: 380px;">
              <div class="eyebrow">NUEVO PAD</div>
              <h3>Agregar sonido personalizado</h3>
              <p class="muted" style="margin-bottom: 14px;">Primero nombrá el pad, después subí el archivo con ⬆.</p>
              <div class="form-row" style="margin-bottom: 12px;">
                <label>Nombre</label>
                <input type="text" v-model="newSound.name" @keyup.enter="addCustomPad" autofocus placeholder="Ej: Cortina">
              </div>
              <div class="form-row" style="margin-bottom: 12px;">
                <label>Atajo (1 letra)</label>
                <input type="text" v-model="newSound.shortcut_key" maxlength="1" style="text-transform: uppercase;">
              </div>
              <div class="form-row">
                <label>Color</label>
                <input type="color" v-model="newSound.color" style="width: 56px; height: 36px; padding: 2px;">
              </div>
              <div class="row right" style="margin-top: 18px; gap: 8px;">
                <button class="ghost" @click="showAddSound = false">Cancelar</button>
                <button class="primary" @click="addCustomPad" :disabled="!newSound.name.trim()">Crear pad</button>
              </div>
            </div>
          </div>
        </div>

        <div class="hs-people">
          <div class="sb-head">
            <span class="label">Participantes</span>
            <span class="tiny">{{ participants.length }}/{{ session.max_participants }}</span>
            <div class="spacer"></div>
            <button class="icon ghost" @click="showInvite = true" title="Invitar">＋</button>
          </div>
          <div v-for="p in participants" :key="p.id" class="invite-row" style="flex-wrap:wrap;">
            <span class="who">{{ p.display_name }}</span>
            <span class="status-chip" :class="p.status">{{ p.status }}</span>
            <button v-if="p.username !== user.username" class="icon ghost" @click="forceMute(p)" title="Mutear" style="font-size:11px;">🔇</button>
            <button v-if="p.username !== user.username" class="icon danger" @click="kickParticipant(p)" title="Quitar">✕</button>
            <div v-if="isHost && (p.invite_url || p.source_rsvp_url)" style="width:100%;display:flex;gap:4px;margin-top:2px;">
              <button v-if="p.invite_url" class="ghost" style="font-size:10px;padding:1px 6px;"
                      @click="copyInvite(p)" title="Copiar link de invitación prodPod">📎 Invite</button>
              <button v-if="p.source_rsvp_url" class="ghost" style="font-size:10px;padding:1px 6px;"
                      @click="copyRsvpLink(p)" title="Copiar link RSVP de prePod">📋 RSVP</button>
            </div>
          </div>
        </div>

        <div v-if="inviteLinks.length" class="hs-people">
          <div class="sb-head"><span class="label">Links generados</span></div>
          <div v-for="l in inviteLinks" :key="l.invite_token" class="invite-row" style="cursor: pointer;" @click="copyInvite(l)" title="Click para copiar">
            <span class="who">{{ l.invite_url }}</span>
            <span class="join-pill">copiar</span>
          </div>
        </div>

        <div v-if="isHost && Object.keys(participantUploads).length" class="hs-people">
          <div class="sb-head"><span class="label">Subidas invitados</span></div>
          <div v-for="(u, id) in participantUploads" :key="id" style="display:flex;align-items:center;gap:6px;margin-bottom:4px;font-size:11px;padding:0 2px;">
            <span style="min-width:24px;">{{ id.replace('participant_', 'P') }}</span>
            <span v-if="u.state === 'streaming'" style="color:var(--accent);">↑ {{ (u.bytes / (1024*1024)).toFixed(1) }} MB</span>
            <span v-else-if="u.state === 'done'" style="color:#6c6;font-weight:700;">✓ {{ (u.bytes / (1024*1024)).toFixed(1) }} MB</span>
            <span v-else-if="u.state === 'error'" style="color:#f66;font-weight:700;">✕ Error</span>
            <span v-else style="color:var(--paper-dim);">{{ u.state }}</span>
          </div>
        </div>

        <div v-if="isHost" class="hs-people" style="padding:4px 2px;">
          <label style="display:flex;align-items:center;gap:6px;font-size:11px;color:var(--paper-dim);cursor:pointer;">
            <input type="checkbox" :checked="guestCuesVisible" @change="toggleGuestCues" style="margin:0;" />
            Invitados ven cues
          </label>
        </div>

        <div v-if="sponsorMarkers.length" class="sponsor-teleprompter hs-sponsors">
          <div class="sb-head">
            <span class="label">📢 Sponsors</span>
            <span class="tiny">{{ sponsorMarkers.length }}</span>
          </div>
          <div v-for="m in sponsorMarkers" :key="'sp-' + m.id"
               class="sponsor-block"
               :class="{ alert: sponsorAlertId === m.id, dismissed: sponsorDismissed[m.id] }">
            <div class="sponsor-header">
              <img v-if="m.sponsor_logo_url" :src="m.sponsor_logo_url" class="sponsor-logo">
              <div class="sponsor-info">
                <strong>{{ m.sponsor_name }}</strong>
                <span class="mono sponsor-time">{{ _sponsorFmtTC(m.planned_offset_seconds != null ? m.planned_offset_seconds : m.tl_offset_seconds) }}</span>
              </div>
              <div v-if="isHost && !sponsorDismissed[m.id]" class="sponsor-actions">
                <button class="ghost" style="font-size: 10px; padding: 2px 6px;" @click="delaySponsor(m)" title="Retrasar 90s">+90s</button>
                <button class="ghost" style="font-size: 10px; padding: 2px 6px;" @click="dismissSponsor(m)" title="Omitir">✕</button>
              </div>
            </div>
            <div v-if="m.sponsor_copy && !sponsorDismissed[m.id]" class="sponsor-copy-text">
              <div class="sponsor-copy-label">TELEPROMPTER</div>
              {{ m.sponsor_copy }}
            </div>
          </div>
          <div v-if="sponsorCountdown" class="sponsor-countdown-bar">
            <div class="sponsor-countdown-num">{{ sponsorCountdown.sec }}</div>
            <div class="sponsor-countdown-name">{{ sponsorCountdown.name }}</div>
          </div>
        </div>

        <div class="hs-chat" style="flex: 1; display: flex; flex-direction: column; min-height: 200px;">
          <div class="sb-head" style="display: flex; align-items: center; gap: 8px;">
            <span class="label" style="cursor: pointer;"
                  :style="{ opacity: chatChannel === 'main' ? 1 : 0.55 }"
                  @click="chatChannel = 'main'">Chat en vivo</span>
            <span v-if="canBackstage" class="label" style="cursor: pointer;"
                  :style="{ opacity: chatChannel === 'backstage' ? 1 : 0.55 }"
                  @click="chatChannel = 'backstage'"
                  title="Solo host y co-hosts">🎩 Backstage</span>
            <span class="tiny">{{ chatChannel === 'backstage' ? backstageChat.length : chat.length }}</span>
          </div>
          <div v-show="chatChannel === 'main'" id="chat-scroll" style="flex: 1; overflow-y: auto; background: var(--ink-sunken); border: 1px solid var(--ink-line); border-radius: var(--r-md); padding: 8px; margin-bottom: 6px; min-height: 100px; font-size: 12px;">
            <div v-for="m in chat" :key="m.id" style="margin-bottom: 6px;">
              <strong style="color: var(--signal);">{{ m.author }}:</strong>
              <span style="color: var(--paper);">{{ m.text }}</span>
            </div>
            <div v-if="chat.length === 0" class="muted" style="text-align: center; padding: 20px;">(sin mensajes)</div>
          </div>
          <div v-show="canBackstage && chatChannel === 'backstage'" id="backstage-scroll" style="flex: 1; overflow-y: auto; background: rgba(255,180,0,0.06); border: 1px solid rgba(255,180,0,0.35); border-radius: var(--r-md); padding: 8px; margin-bottom: 6px; min-height: 100px; font-size: 12px;">
            <div class="muted" style="font-size: 11px; margin-bottom: 6px;">Privado: solo host y co-hosts.</div>
            <div v-for="m in backstageChat" :key="m.id" style="margin-bottom: 6px;">
              <strong style="color: #ffb84d;">{{ m.author }}:</strong>
              <span style="color: var(--paper);">{{ m.text }}</span>
            </div>
            <div v-if="backstageChat.length === 0" class="muted" style="text-align: center; padding: 20px;">(sin mensajes)</div>
          </div>
          <div v-if="chatChannel === 'main'" style="display: flex; gap: 4px;">
            <input type="text" v-model="chatInput" @keyup.enter="sendChat" placeholder="Mensaje..." style="flex: 1; font-size: 12px; padding: 6px 10px;">
            <button class="primary" @click="sendChat" :disabled="!chatInput.trim()" style="padding: 6px 12px;">↑</button>
          </div>
          <div v-else-if="canBackstage" style="display: flex; gap: 4px;">
            <input type="text" v-model="backstageInput" @keyup.enter="sendBackstage" placeholder="Mensaje al equipo..." style="flex: 1; font-size: 12px; padding: 6px 10px;">
            <button class="primary" @click="sendBackstage" :disabled="!backstageInput.trim()" style="padding: 6px 12px;">↑</button>
          </div>
        </div>
      </aside>

      <div class="controls-bar hs-controls">
        <button v-if="connected" class="hs-btn" :class="{ muted: localMuted }" @click="toggleMute"><span class="hs-ico">{{ localMuted ? "🔇" : "🎤" }}</span><span class="hs-txt">Micrófono</span></button>
        <button v-if="connected" class="hs-btn" :class="{ 'cam-off': localCamOff }" @click="toggleCam"><span class="hs-ico">{{ localCamOff ? "📷" : "🎥" }}</span><span class="hs-txt">Cámara</span></button>
        <button v-if="connected" class="hs-btn" :class="{ on: gateOn }" @click="toggleGate" :title="gateOn ? 'Cuando no hablas, los demás no oyen tus ruidos (teclas, perro). Toca para apagar.' : 'Apagado: los demás te oyen siempre. Toca para encender.'"><span class="hs-ico">{{ gateOn ? "🚪" : "🚪" }}</span><span class="hs-txt">{{ gateOn ? "Auto-silencio" : "Sin auto-sil." }}</span></button>
        <button v-if="connected && recording" class="hs-btn m-only" @click="markChapter"><span class="hs-ico">📍</span><span class="hs-txt">Momento</span></button>
        <button v-if="connected" class="hs-btn m-only" :class="{ on: sideTab === 'chat' }" @click="openSide('chat')">
          <span class="hs-ico">💬</span><span class="hs-txt">Chat</span><span v-if="chatUnreadH" class="gc-badge">{{ chatUnreadH }}</span>
        </button>
        <button v-if="connected" class="hs-btn m-only" :class="{ on: sideTab === 'people' }" @click="openSide('people')"><span class="hs-ico">👥</span><span class="hs-txt">Personas</span></button>
        <button v-if="connected && sponsorMarkers.length" class="hs-btn m-only" :class="{ on: sideTab === 'sponsors' }" @click="openSide('sponsors')"><span class="hs-ico">📢</span><span class="hs-txt">Sponsors</span></button>
        <button v-if="connected" class="layout-toggle d-only" @click="toggleLayout" :title="layoutMode === 'grid' ? 'Cambiar a vista de speaker' : 'Cambiar a grilla'">{{ layoutMode === 'grid' ? '◫' : '⊞' }}</button>
        <button v-if="connected && isHost" class="d-only" @click="amaPanel ? closeAma() : startAma()" :disabled="amaBusy" :class="{ primary: amaPanel }" title="Q&A con audiencia">❓ AMA</button>
        <div class="spacer"></div>
        <span v-if="connected" class="join-pill d-only">EN VIVO · {{ (participants.filter(p => p.status === 'connected').length) }} conectado(s)</span>
        <button v-if="connected" class="ghost hs-leave" @click="disconnect">Salir<span class="d-only"> del estudio</span></button>
      </div>

      <div v-if="showStream" class="modal-backdrop" @click.self="showStream = false">
        <div class="modal" style="width: 480px;">
          <div class="eyebrow">TRANSMISIÓN EN VIVO</div>
          <h3>Enviar el estudio a RTMP</h3>
          <p class="muted" style="margin-bottom: 14px;">
            El compositor de LiveKit arma una grilla con los participantes y la empuja a YouTube/Twitch/etc.
            Los participantes deben estar conectados antes de iniciar.
          </p>

          <div v-if="activeStreams.length" style="margin-bottom: 14px; padding: 10px; border: 1px solid var(--ink-line); border-radius: var(--r-md);">
            <div class="tiny" style="margin-bottom: 6px;">STREAMS ACTIVOS</div>
            <div v-for="s in activeStreams" :key="s.id" class="invite-row">
              <span class="who">{{ s.platform || 'rtmp' }} · {{ s.rtmp_url }}</span>
              <span class="status-chip connected">{{ s.status }}</span>
              <button class="icon danger" @click="stopStream(s)" title="Detener">■</button>
            </div>
          </div>

          <div class="form-row" style="margin-bottom: 10px;">
            <label>Plataforma</label>
            <div class="row" style="gap: 6px; flex-wrap: wrap;">
              <button v-for="p in rtmpPresets" :key="p.key" class="ghost"
                      :class="{ primary: streamForm.platform === p.key }"
                      @click="applyStreamPreset(p)"
                      style="padding: 6px 10px; font-size: 12px;">
                {{ p.name }}
              </button>
            </div>
          </div>
          <div class="form-row" style="margin-bottom: 10px;">
            <label>URL del ingest RTMP</label>
            <input type="text" v-model="streamForm.rtmp_url" placeholder="rtmp://a.rtmp.youtube.com/live2/">
          </div>
          <div class="form-row">
            <label>Stream key</label>
            <input type="password" v-model="streamForm.stream_key" autocomplete="off" placeholder="xxxx-xxxx-xxxx-xxxx">
          </div>

          <div v-if="streamStatus" class="tiny muted" style="margin-top: 10px;">{{ streamStatus }}</div>

          <div class="row right" style="margin-top: 20px; gap: 8px;">
            <button class="ghost" @click="showStream = false">Cerrar</button>
            <button class="primary" @click="startStream"
                    :disabled="streamBusy || !streamForm.rtmp_url || !streamForm.stream_key">
              {{ streamBusy ? "Iniciando…" : "● Transmitir" }}
            </button>
          </div>
        </div>
      </div>

      <div v-if="amaPanel && amaEmbedUrl" class="modal-backdrop" @click.self="closeAma" style="align-items:flex-end;justify-content:flex-end;padding:16px">
        <div style="width:380px;height:calc(100vh - 80px);background:var(--ink-panel);border:1px solid var(--ink-line);border-radius:var(--r-lg);overflow:hidden;display:flex;flex-direction:column">
          <div style="padding:8px 12px;display:flex;align-items:center;gap:8px;border-bottom:1px solid var(--ink-line)">
            <span style="font-weight:600;font-size:13px">❓ amaPod — Q&A</span>
            <span class="spacer"></span>
            <button class="ghost" @click="closeAma" style="font-size:11px;padding:4px 8px">Cerrar</button>
          </div>
          <iframe :src="amaEmbedUrl" style="flex:1;border:none;width:100%"></iframe>
        </div>
      </div>

      <div v-if="showInvite" class="modal-backdrop" @click.self="showInvite = false">
        <div class="modal">
          <div class="eyebrow">INVITAR PARTICIPANTE</div>
          <h3>Generar link de invitación</h3>
          <p class="muted" style="margin-bottom: 18px;">El link se puede compartir con cualquiera — no necesitan cuenta.</p>
          <div class="form-row" style="margin-bottom: 12px;">
            <label>Nombre visible</label>
            <input type="text" v-model="inviteForm.display_name" @keyup.enter="createInvite" autofocus placeholder="Ana García">
          </div>
          <div class="form-row">
            <label>Rol</label>
            <select v-model="inviteForm.role">
              <option value="guest">Invitado</option>
              <option value="co-host">Co-host</option>
            </select>
          </div>
          <div class="row right" style="margin-top: 20px; gap: 8px;">
            <button class="ghost" @click="showInvite = false">Cerrar</button>
            <button class="primary" @click="createInvite" :disabled="!inviteForm.display_name.trim()">Generar link</button>
          </div>
        </div>
      </div>
    </div>
  `,
};

/* ==========================================================================
   Invite landing (public — ?invite=TOKEN)
   ========================================================================== */

var InviteView = {
  props: { token: String, onJoined: Function },
  setup: function (props) {
    var invite = ref(null);
    var error = ref("");
    var busy = ref(false);
    var name = ref("");
    var waitingForHost = ref(false);
    var pollTimer = ref(null);

    async function load() {
      try {
        invite.value = await api("/api/invite/" + props.token);
        name.value = invite.value.display_name;
        if (invite.value.expired) return;
        if (invite.value.role === "guest" && !invite.value.host_present) {
          waitingForHost.value = true;
          startPolling();
        }
      }
      catch (e) { error.value = e.message; }
    }

    function startPolling() {
      if (pollTimer.value) return;
      pollTimer.value = setInterval(async () => {
        try {
          var res = await api("/api/invite/" + props.token);
          invite.value = res;
          if (res.expired) { stopPolling(); return; }
          if (res.host_present) { waitingForHost.value = false; stopPolling(); }
        } catch (_) {}
      }, 5000);
    }

    function stopPolling() {
      if (pollTimer.value) { clearInterval(pollTimer.value); pollTimer.value = null; }
    }

    async function join() {
      busy.value = true; error.value = "";
      try {
        var r = await api("/api/invite/" + props.token + "/join", {
          method: "POST",
          body: { display_name: name.value.trim() },
        });
        stopPolling();
        props.onJoined(Object.assign({ session_title: invite.value && invite.value.session_title }, r));
      } catch (e) { error.value = e.message; }
      finally { busy.value = false; }
    }

    onMounted(load);
    onBeforeUnmount(stopPolling);

    return { invite, error, busy, name, waitingForHost, join };
  },
  template: `
    <div class="login-wrapper invite-wrapper">
      <div class="login-card invite-card">
        <div class="eyebrow">Invitación a grabar</div>
        <h2 v-if="invite">{{ invite.session_title }}</h2>
        <h2 v-else>Cargando…</h2>
        <div v-if="invite && !invite.expired && invite.session_description" class="subtitle">{{ invite.session_description }}</div>

        <!-- Session expired -->
        <div v-if="invite && invite.expired" class="invite-state">
          <div class="invite-state-icon">⏹</div>
          <p class="invite-state-title">Esta grabación ya terminó</p>
          <p class="invite-state-text">El link ya no sirve. Si todavía tienen que grabar, pídele al anfitrión un link nuevo.</p>
        </div>

        <!-- Waiting for host -->
        <div v-else-if="waitingForHost" class="invite-state">
          <div class="invite-state-icon invite-pulse">⏳</div>
          <p class="invite-state-title">El anfitrión todavía no llega</p>
          <p class="invite-state-text">Deja esta página abierta: se habilita sola cuando entre. No hace falta recargar.</p>
        </div>

        <!-- Ready to join -->
        <template v-else-if="invite && !invite.expired">
          <ol class="invite-steps">
            <li><span>1</span>Escribe tu nombre</li>
            <li><span>2</span>Prueba tu cámara y micrófono</li>
            <li><span>3</span>Entra a la sala</li>
          </ol>
          <div v-if="error" class="error">{{ error }}</div>
          <div class="form-row">
            <label>Tu nombre</label>
            <input type="text" v-model="name" placeholder="Cómo quieres aparecer" autocomplete="name" enterkeyhint="go" @keyup.enter="name.trim() && !busy && join()">
          </div>
          <button class="primary invite-go" :disabled="busy || !name.trim()" @click="join">
            {{ busy ? "Un momento…" : "Continuar" }}
          </button>
          <p class="invite-note">Mejor con audífonos y en un lugar sin ruido.</p>
        </template>

        <div v-if="error && !invite" class="error">{{ error }}</div>
      </div>
    </div>
  `,
};

/* ==========================================================================
   Guest studio (after joining via invite link) — with recording + sound + chat
   ========================================================================== */

var GuestStudioView = {
  props: { joinData: Object, inviteToken: String },
  setup: function (props) {
    var localVideoEl = ref(null);

    // ---- Prueba de calidad de grabación en la pantalla previa ----
    var preflightVideoEl = ref(null);
    var _preflightStream = null;
    var _preflightMeterStop = null;
    var preMeter = ref(0);
    var recPreflight = reactive({ state: "idle", upMbps: null, fps: 0, profileId: null, choiceId: null });
    var recProfileChoices = computed(function () {
      if (!recPreflight.profileId) return REC_PROFILES;
      var idx = REC_PROFILES.findIndex(function (p) { return p.id === recPreflight.profileId; });
      return REC_PROFILES.slice(Math.max(idx, 0));
    });
    function recProfileG() {
      return recProfileById(recPreflight.choiceId || recPreflight.profileId || "720p25");
    }
    async function startGuestPreflight() {
      if (recPreflight.state !== "idle") return;
      recPreflight.state = "testing";
      try {
        _preflightStream = await navigator.mediaDevices.getUserMedia({
          video: { width: { ideal: 1920 }, height: { ideal: 1080 }, frameRate: { ideal: 30 } },
          audio: true,
        });
        await nextTick();
        if (preflightVideoEl.value) preflightVideoEl.value.srcObject = _preflightStream;
        var _preMic = _preflightStream.getAudioTracks()[0];
        if (_preMic) _preflightMeterStop = _attachMeter({ mediaStreamTrack: _preMic }, function (lvl) { preMeter.value = lvl; });
        var r = await runRecordingPreflight(_preflightStream, props.inviteToken, { guest: true });
        recPreflight.upMbps = r.upMbps;
        recPreflight.fps = r.device.fps;
        recPreflight.profileId = r.profileId;
        recPreflight.choiceId = r.profileId;
      } catch (_) {
        recPreflight.profileId = "720p25";
        recPreflight.choiceId = "720p25";
      }
      recPreflight.state = "done";
    }
    function stopGuestPreflight() {
      if (_preflightMeterStop) { try { _preflightMeterStop(); } catch (_) {} _preflightMeterStop = null; }
      if (_preflightStream) {
        _preflightStream.getTracks().forEach(function (t) { try { t.stop(); } catch (_) {} });
        _preflightStream = null;
      }
      if (preflightVideoEl.value) preflightVideoEl.value.srcObject = null;
    }
    async function persistRecQuality() {
      var p = recProfileG();
      try {
        await fetch("/api/sessions/" + props.joinData.session_id + "/recording-quality?token=" +
                    encodeURIComponent(props.inviteToken), {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ quality: p.quality, bitrate: p.bitrate }),
        });
      } catch (_) {}
    }
    var error = ref("");
    var busy = ref(false);
    var connectStep = ref("");
    var connected = ref(false);
    var localMuted = ref(false);
    var gateOn = ref(_gatePref());
    function toggleGate() { gateOn.value = !gateOn.value; _setGatePref(gateOn.value); if (micGainCtx && micGainCtx.setGate) micGainCtx.setGate(gateOn.value); }
    var micGainCtx = null;  // cadena de micrófono (ganancia + puerta) publicada a la sala
    var localCamOff = ref(false);
    var remoteMap = reactive({});
    var localMeter = ref(0);
    var localMeterStop = null;
    var localStream = null;
    var room = null;
    var recorder = null;
    var recording = ref(false);
    var timecode = ref(0);
    var timerHandle = null;
    var _savedCamPub = null;
    var _savedMicPub = null;

    var sounds = ref([]);
    var audioPool = {};
    var playingPad = ref(null);
    var chat = ref([]);
    var chatInput = ref("");
    var chatOpen = ref(false);
    var chatSeen = ref(0);
    var chatUnread = computed(function () { return chatOpen.value ? 0 : Math.max(0, chat.value.length - chatSeen.value); });
    function toggleChat() {
      chatOpen.value = !chatOpen.value;
      chatSeen.value = chat.value.length;
      if (chatOpen.value) scrollChatBottom();
    }
    watch(function () { return chat.value.length; }, function (n) { if (chatOpen.value) chatSeen.value = n; });
    var left = ref(false);
    var awayWhileRecording = ref(false);

    // Pantalla encendida mientras estás en la sala: si el teléfono se bloquea, Safari corta la cámara y la grabación.
    var _wakeLock = null;
    async function keepAwake() {
      try {
        if (!("wakeLock" in navigator) || _wakeLock) return;
        _wakeLock = await navigator.wakeLock.request("screen");
        _wakeLock.addEventListener("release", function () { _wakeLock = null; });
      } catch (_) {}
    }
    function releaseAwake() {
      try { if (_wakeLock) _wakeLock.release(); } catch (_) {}
      _wakeLock = null;
    }
    function onVisibility() {
      if (document.visibilityState === "hidden") {
        if (recording.value) awayWhileRecording.value = true;
      } else if (connected.value) {
        keepAwake();
      }
    }
    document.addEventListener("visibilitychange", onVisibility);

    var qualityText = computed(function () {
      if (recPreflight.state !== "done") return "";
      var p = recProfileG();
      if (p.id === "1080p8" || p.id === "1080p5") return "Tu conexión está muy bien: grabarás en alta calidad (1080p).";
      if (p.id === "720p25") return "Tu conexión está bien: grabarás en buena calidad (720p).";
      return "Tu conexión está justa: grabarás en calidad liviana (720p) para no cortarte.";
    });

    var triggerLog = [];
    var recordingStartedAtMs = null;
    var practiceMode = ref(localStorage.getItem("prodpod.practiceMode") === "1");
    watch(practiceMode, function (v) {
      localStorage.setItem("prodpod.practiceMode", v ? "1" : "0");
    });
    var myIdentity = ref("");
    function _tpNameOf(identity) {
      if (identity === myIdentity.value) return props.joinData.display_name || "";
      var r = remoteMap[identity]; return r && r.name ? r.name : "";
    }
    var _tpH = _tpSetup(myIdentity, _tpNameOf);

    var readyMap = reactive({});
    var ownReady = ref(false);
    var countdown = ref(null);
    var countdownHandle = null;


    // Al detener: cuenta regresiva grande (3, 2, 1) antes de apagar cámara y
    // micrófono, en vez de cortarlos de golpe. La grabación ya se detuvo en
    // el instante exacto del "detener"; esto es solo la transición visual.
    var endCountdown = ref(null);
    var camsOffAfterRec = ref(false);
    function startEndCountdown() {
      if (endCountdown.value !== null || camsOffAfterRec.value) return;
      endCountdown.value = 3;
      var t = setInterval(function () {
        endCountdown.value -= 1;
        if (endCountdown.value <= 0) {
          clearInterval(t);
          endCountdown.value = null;
          camsOffAfterRec.value = true;
          if (room) {
            try { room.localParticipant.setCameraEnabled(false); } catch (_) {}
            try { room.localParticipant.setMicrophoneEnabled(false); } catch (_) {}
          }
        }
      }, 1000);
    }
    // Director state
    var activeOverlays = reactive([]);
    var cintilloOverlays = computed(function () {
      return activeOverlays.filter(function (o) { return CINTILLO_TYPES.indexOf(o.event_type) !== -1; });
    });
    var otherOverlays = computed(function () {
      return activeOverlays.filter(function (o) { return CINTILLO_TYPES.indexOf(o.event_type) === -1; });
    });
    function ovLogoUrl(ov) {
      if (!ov.file_path) return null;
      return "/api/sessions/" + props.joinData.session_id + "/director/assets/" +
             encodeURIComponent(String(ov.file_path).split("/").pop()) +
             "?token=" + encodeURIComponent(props.inviteToken);
    }
    var activeCue = ref(null);
    var cueTimer = null;
    var ifbActive = ref(false);
    var directorConnected = ref(false);
    var guestCuesVisible = ref(true);
    var postRecording = computed(function () {
      return !recording.value && (uploadStatus.state === "finalizing" || uploadStatus.state === "done" || uploadStatus.state === "error");
    });

    async function loadSounds() {
      try {
        var resp = await fetch(
          "/api/sessions/" + props.joinData.session_id + "/sounds?token=" + encodeURIComponent(props.inviteToken)
        );
        if (!resp.ok) return;
        sounds.value = await resp.json();
        sounds.value.forEach(function (s) {
          var a = new Audio(s.url);
          a.preload = "auto";
          audioPool[s.filename] = a;
        });
      } catch (_) {}
    }

    async function flushTriggerLog() {
      if (!triggerLog.length) return;
      var batch = triggerLog.slice();
      triggerLog = [];
      try {
        await fetch(
          "/api/sessions/" + props.joinData.session_id +
          "/sound-triggers?token=" + encodeURIComponent(props.inviteToken),
          {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ triggers: batch, token: props.inviteToken }),
          }
        );
      } catch (_) {}
    }

    function playLocalSound(s) {
      var a = audioPool[s.filename];
      if (!a) return;
      try { a.currentTime = 0; a.play(); } catch (_) {}
      playingPad.value = s.shortcut_key;
      setTimeout(function () { if (playingPad.value === s.shortcut_key) playingPad.value = null; }, 400);
    }

    function sendData(msg) {
      if (!room) return;
      try { room.localParticipant.publishData(_encodeMsg(msg), LK.DataPacket_Kind.RELIABLE); } catch (_) {}
    }

    function scrollChatBottom() {
      nextTick(function () {
        var el = document.getElementById("guest-chat-scroll");
        if (el) el.scrollTop = el.scrollHeight;
      });
    }

    function onDataReceived(payload) {
      var msg = _decodeMsg(payload);
      if (!msg) return;
      if (_tpH.tpHandle(msg)) return;
      if (msg.type === "sound_trigger" && msg.filename) {
        var s = sounds.value.find(function (x) { return x.filename === msg.filename; });
        if (s) playLocalSound(s);
      } else if (msg.type === "chat") {
        // Guests never see backstage messages (server enforces, LiveKit
        // also targets only host identities — but defensively drop any
        // stray backstage frame here too).
        if (msg.channel === "backstage") return;
        chat.value.push({ id: msg.id, author: msg.author, text: msg.text, ts: msg.ts });
        scrollChatBottom();
      } else if (msg.type === "ready_toggle") {
        readyMap[msg.identity] = !!msg.ready;
      } else if (msg.type === "ready_request") {
        sendData({ type: "ready_toggle", identity: myIdentity.value, ready: ownReady.value });
      } else if (msg.type === "countdown_start") {
        beginCountdown(msg.start_at_ms);
      } else if (msg.type === "recording_stop") {
        finishRecording();
        startEndCountdown();
      } else if (msg.type === "practice_mode") {
        practiceMode.value = !!msg.active;
      } else if (msg.type === "kick" && room && room.localParticipant &&
                 msg.target_identity === room.localParticipant.identity) {
        error.value = "El host te desconectó.";
        leave();
      } else if (msg.type === "overlay_inject") {
        _admitOverlay(activeOverlays, msg);
      } else if (msg.type === "overlay_remove") {
        _dropOverlay(activeOverlays, msg.event_id);
      } else if (msg.type === "director_cue") {
        if (!guestCuesVisible.value) return;
        var gCueMap = { "CERRAR TEMA": "wrap-up", "SIGUIENTE TEMA": "next-topic", "PAUSA": "break", "MÁS RÁPIDO": "speed-up", "MÁS LENTO": "slow-down", "LEER ANUNCIO": "ad-read" };
        activeCue.value = { cue: msg.cue, cssClass: gCueMap[msg.cue] || "custom" };
        if (cueTimer) clearTimeout(cueTimer);
        cueTimer = setTimeout(function () { activeCue.value = null; }, 8000);
      } else if (msg.type === "cue_visibility") {
        guestCuesVisible.value = !!msg.show;
        if (!msg.show) activeCue.value = null;
      } else if (msg.type === "ifb_start") {
        ifbActive.value = true;
      } else if (msg.type === "ifb_stop") {
        ifbActive.value = false;
      } else if (msg.type === "force_mute") {
        if (msg.target === myIdentity.value && room) {
          room.localParticipant.setMicrophoneEnabled(false);
          localMuted.value = true;
          if (window.toast) window.toast({ type: "warn", text: "El director te muteó" });
        }
      } else if (msg.type === "director_chat") {
        if (window.toast) window.toast({ type: "info", text: "Director: " + (msg.text || "") });
      }
    }

    function beginCountdown(startAtMs) {
      if (recording.value || countdown.value !== null) return;
      if (countdownHandle) clearTimeout(countdownHandle);
      function tick() {
        var rem = startAtMs - Date.now();
        if (rem <= 0) {
          countdown.value = 0;
          beginRecordingNow();
          countdownHandle = setTimeout(function () { countdown.value = null; }, 700);
          return;
        }
        countdown.value = Math.ceil(rem / 1000);
        countdownHandle = setTimeout(tick, 100);
      }
      tick();
    }

    var _recStream = null;
    var _rawMicTrack = null;       // micrófono sin auto-silencio — para grabar
    var _fullResCamTrack = null;   // captura completa (hasta 1080p) — para grabar
    var _roomCamTrack = null;      // clon reducido ≤720p — lo que ve la sala

    function _buildRecordingStream() {
      var tracks = [];
      var camPub = room && room.localParticipant.getTrackPublication(LK.Track.Source.Camera) || _savedCamPub;
      var micPub = room && room.localParticipant.getTrackPublication(LK.Track.Source.Microphone) || _savedMicPub;
      // Grabar SIEMPRE desde la captura completa, no desde el clon de la sala.
      var camTrack = (_fullResCamTrack && _fullResCamTrack.readyState === "live")
        ? _fullResCamTrack
        : (camPub && camPub.track ? camPub.track.mediaStreamTrack : null);
      var micTrack = (_rawMicTrack && _rawMicTrack.readyState === "live")
        ? _rawMicTrack
        : (micPub && micPub.track ? micPub.track.mediaStreamTrack : null);
      if (camTrack && camTrack.readyState === "live") tracks.push(camTrack.clone());
      if (micTrack && micTrack.readyState === "live") tracks.push(micTrack.clone());
      if (tracks.length === 0) return null;
      return new MediaStream(tracks);
    }

    function beginRecordingNow() {
      recording.value = true;
      recordingStartedAtMs = Date.now();
      triggerLog = [];
      timecode.value = 0;
      if (timerHandle) clearInterval(timerHandle);
      var start = recordingStartedAtMs;
      timerHandle = setInterval(function () { timecode.value = (Date.now() - start) / 1000; }, 250);

      _recStream = _buildRecordingStream();
      var stream = _recStream;
      if (stream) {
        var hasCam = stream.getVideoTracks().length > 0;
        var hasMic = stream.getAudioTracks().length > 0;
        recordingCaps.hasCam = hasCam;
        recordingCaps.hasMic = hasMic;
        recorder = _startRecorder(stream, function () {}, 1000, false, _onRecordingChunk,
                                  { videoBitsPerSecond: recProfileG().bitrate });
        // ENSAYO: sin uploader — _onRecordingChunk descarta los chunks y
        // nada se sube al servidor.
        if (!practiceMode.value) {
          _startChunkStreaming(recorder._ext ? ("." + recorder._ext) : ".webm");
          _requestServerBackup(props.joinData.session_id, props.inviteToken);
        }
        if (!hasCam && window.toast) {
          window.toast({ type: "warn", text: "⚠ Grabando SOLO AUDIO — tu cámara no está disponible" });
        }
      } else {
        if (window.toast) window.toast({ type: "error", text: "ERROR: no hay stream local — tu grabación NO se está capturando" });
      }
    }

    async function finishRecording() {
      if (!recording.value) return;
      recording.value = false;
      if (timerHandle) { clearInterval(timerHandle); timerHandle = null; }
      if (recorder) {
        await new Promise(function (resolve) {
          recorder.onstop = resolve;
          try { recorder.stop(); } catch (_) { resolve(); }
        });
        recorder = null;
      }
      await _finishUpload();
      flushTriggerLog();
      recordingStartedAtMs = null;
      ownReady.value = false;
      Object.keys(readyMap).forEach(function (k) { delete readyMap[k]; });
      if (_recStream) {
        _recStream.getTracks().forEach(function (t) { t.stop(); });
        _recStream = null;
      }
      if (room) {
        try { await room.localParticipant.setCameraEnabled(false); } catch (_) {}
        try { await room.localParticipant.setMicrophoneEnabled(false); } catch (_) {}
      }
    }

    async function sendChat() {
      var text = chatInput.value.trim();
      if (!text) return;
      try {
        var resp = await fetch("/api/invite/" + props.inviteToken + "/chat", {
          method: "POST", headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ text: text }),
        });
        if (!resp.ok) throw new Error(await resp.text());
        var saved = await resp.json();
        chat.value.push({ id: saved.id, author: saved.author_name, text: saved.message_text, ts: saved.timestamp });
        sendData({ type: "chat", id: saved.id, author: saved.author_name, text: saved.message_text, ts: saved.timestamp });
        chatInput.value = "";
        scrollChatBottom();
      } catch (e) { error.value = e.message; }
    }

    function triggerSound(s) {
      playLocalSound(s);
      if (recording.value && recordingStartedAtMs != null && s.filename) {
        var off = (Date.now() - recordingStartedAtMs) / 1000;
        triggerLog.push({ filename: s.filename, tl_offset_seconds: off });
      }
      sendData({ type: "sound_trigger", filename: s.filename, key: s.shortcut_key });
    }

    var uploadStatus = reactive({ state: "idle", percent: 0, sizeMB: "", error: "" });
    var recordingCaps = reactive({ hasCam: true, hasMic: true });
    var streamedBytes = ref(0);
    var pendingMB = ref(0);
    var guestEta = ref(null);

    function _preventClose(e) { e.preventDefault(); e.returnValue = ""; }

    var _uploader = null;
    var _chunkRetries = ref(0);

    function _onRecordingChunk(data) {
      if (_uploader) _uploader.push(data);
    }

    async function _finishUpload() {
      if (!_uploader) return;
      uploadStatus.state = "finalizing";
      var ok = await _uploader.finalize(timecode.value);
      if (ok) {
        uploadStatus.state = "done";
        uploadStatus.sizeMB = (streamedBytes.value / (1024 * 1024)).toFixed(1);
        window.removeEventListener("beforeunload", _preventClose);
      } else {
        uploadStatus.error = _uploader.status.error || "No se pudo terminar de subir.";
      }
      _uploader = null;
    }

    function _startChunkStreaming(ext) {
      window.addEventListener("beforeunload", _preventClose);
      uploadStatus.state = "streaming";
      streamedBytes.value = 0;
      pendingMB.value = 0;
      _chunkRetries.value = 0;
      _uploader = createChunkUploader({
        sid: props.joinData.session_id,
        token: props.inviteToken,
        trackType: "video",
        takeId: _newTakeId(),
        onStatus: function (st) {
          streamedBytes.value = st.sentBytes;
          pendingMB.value = st.pendingBytes / (1024 * 1024);
          guestEta.value = st.etaSeconds;
          _chunkRetries.value = st.retries;
          if (st.state === "error") {
            uploadStatus.state = "error";
            uploadStatus.error = st.error;
          }
        },
        sendData: function (stt, bytes, pending, eta) {
          sendData({ type: "upload_status", identity: myIdentity.value, state: stt, bytes: bytes, pending: pending || 0, eta: eta == null ? null : eta });
        },
      });
      _uploader.setExt(ext);
      _uploader.start();
    }

    async function connect() {
      if (!LK) { error.value = "LiveKit client no cargado"; busy.value = false; return; }
      busy.value = true;
      error.value = "";
      connectStep.value = "Preparando…";
      try {
        myIdentity.value = "participant_" + props.joinData.participant_id;
        // La vista previa de la prueba suelta la cámara antes de que LiveKit
        // la vuelva a pedir (Safari no comparte el device entre dos gUM).
        stopGuestPreflight();
        var recProf = recProfileG();
        var newRoom = new LK.Room({
          adaptiveStream: true,
          dynacast: true,
          // Captura a la resolución de GRABACIÓN decidida por la prueba;
          // a la sala se publica un clon reducido a ≤720p (ver más abajo).
          videoCaptureDefaults: {
            resolution: { width: recProf.width, height: recProf.height, frameRate: recProf.frameRate },
          },
          publishDefaults: {
            simulcast: true,
            videoSimulcastLayers: [
              { width: 320, height: 180, encoding: { maxBitrate: 200_000,  maxFramerate: 15 } },
              { width: 640, height: 360, encoding: { maxBitrate: 500_000,  maxFramerate: 24 } },
            ],
            videoCodec: "vp8",
            videoEncoding: { maxBitrate: 1_700_000, maxFramerate: 30 },
          },
        });
        newRoom.on(LK.RoomEvent.TrackSubscribed, function (track, pub, participant) {
          var id = participant.identity;
          if (id.startsWith("director_")) return;
          if (pub.trackName === "ifb_audio") return;
          if (!remoteMap[id]) remoteMap[id] = { name: participant.name || id, meter: 0 };
          if (track.kind === LK.Track.Kind.Video) {
            _mountRemoteVideo(id, track);
          } else if (track.kind === LK.Track.Kind.Audio) {
            var a = track.attach();
            a.dataset.duckable = "1";
            document.body.appendChild(a);
            var stop = _attachMeter(track, function (lvl) {
              if (remoteMap[id]) remoteMap[id].meter = lvl;
            });
            remoteMap[id]._stopMeter = stop;
          }
        });
        newRoom.on(LK.RoomEvent.ParticipantConnected, function (p) {
          if (p.identity.startsWith("director_")) {
            directorConnected.value = true;
            // Director recién conectado: que sepa si ya estoy PREPARADO.
            sendData({ type: "ready_toggle", identity: myIdentity.value, ready: ownReady.value });
          }
        });
        newRoom.on(LK.RoomEvent.ParticipantDisconnected, function (p) {
          if (p.identity.startsWith("director_")) { directorConnected.value = false; return; }
          if (remoteMap[p.identity] && remoteMap[p.identity]._stopMeter) remoteMap[p.identity]._stopMeter();
          delete remoteMap[p.identity];
        });
        newRoom.on(LK.RoomEvent.TrackUnsubscribed, function (track) {
          if (track.kind === LK.Track.Kind.Audio) {
            var ifbEl = document.getElementById("ifb-audio-guest");
            if (ifbEl) { ifbEl.remove(); }
          }
        });
        newRoom.on(LK.RoomEvent.DataReceived, onDataReceived);

        // Helper: race against timeout so we don't hang forever silently.
        function withTimeout(p, ms, label) {
          return new Promise(function (resolve, reject) {
            var to = setTimeout(function () { reject(new Error(label + " sin respuesta tras " + (ms/1000) + "s")); }, ms);
            p.then(function (v) { clearTimeout(to); resolve(v); },
                   function (e) { clearTimeout(to); reject(e); });
          });
        }

        connectStep.value = "Conectando con el estudio…";
        await withTimeout(
          newRoom.connect(props.joinData.livekit_ws_url, props.joinData.livekit_token),
          15000,
          "WebSocket a LiveKit"
        );

        connectStep.value = "Activando tu micrófono…";
        var micPub = null, camPub = null;
        try { micPub = await withTimeout(newRoom.localParticipant.setMicrophoneEnabled(true), 30000, "Permiso de micrófono"); }
        catch (me) { error.value = me.message; }

        connectStep.value = "Activando tu cámara…";
        try { camPub = await withTimeout(newRoom.localParticipant.setCameraEnabled(true), 30000, "Permiso de cámara"); }
        catch (ce) { error.value = (error.value ? error.value + " · " : "") + ce.message; }
        _savedCamPub = camPub;
        _savedMicPub = micPub;

        // Separar grabación y sala: el track de captura completo queda para
        // el MediaRecorder; a la sala va un clon reducido a ≤720p.
        _fullResCamTrack = camPub && camPub.track ? camPub.track.mediaStreamTrack : null;
        if (_fullResCamTrack) {
          var camSet = _fullResCamTrack.getSettings ? _fullResCamTrack.getSettings() : {};
          if ((camSet.height || 0) > 720) {
            try {
              var roomTrack = _fullResCamTrack.clone();
              await roomTrack.applyConstraints({ width: { ideal: 1280 }, height: { ideal: 720 } });
              await camPub.track.replaceTrack(roomTrack, true);
              _roomCamTrack = roomTrack;
            } catch (_) { /* fallback: la sala recibe la captura completa capada por bitrate */ }
          }
        }

        connectStep.value = "Ya casi…";

        var camTrack = _fullResCamTrack;
        var micTrack = micPub && micPub.track ? micPub.track.mediaStreamTrack : null;
        _rawMicTrack = micTrack;
        // A la sala va el micrófono con la puerta (si está activa); la grabación local queda sin tocar.
        if (micTrack) {
          try {
            micGainCtx = _micChain(micTrack, 0, gateOn.value);
            await micPub.track.replaceTrack(micGainCtx.track);
          } catch (_) { try { if (micGainCtx) micGainCtx.close(); } catch (__) {} micGainCtx = null; }
        }
        if (camTrack && micTrack) localStream = new MediaStream([camTrack, micTrack]);
        else if (camTrack) localStream = new MediaStream([camTrack]);
        else if (micTrack) localStream = new MediaStream([micTrack]);
        if (!localStream && window.toast) window.toast({ type: "warn", text: "No se pudo capturar stream local para grabación" });
        if (micTrack) {
          localMeterStop = _attachMeter({ mediaStreamTrack: micTrack }, function (lvl) { localMeter.value = lvl; });
        }

        room = newRoom;
        connected.value = true;
        keepAwake();
        persistRecQuality();  // guarda la calidad de grabación para el director
        await nextTick();
        // Try several times to attach the local video — the <video> ref might
        // not be mounted on the very first tick depending on render timing.
        function attachLocal() {
          if (localVideoEl.value && camPub && camPub.track) {
            try { camPub.track.attach(localVideoEl.value); } catch (_) {}
          }
        }
        attachLocal();
        setTimeout(attachLocal, 200);
        setTimeout(attachLocal, 800);

        // Mount tracks from participants already in the room
        function mountExistingRemotes() {
          if (!room) return;
          room.remoteParticipants.forEach(function (p) {
            var id = p.identity;
            if (id.startsWith("director_")) return;
            if (!remoteMap[id]) remoteMap[id] = { name: p.name || id, meter: 0 };
            p.trackPublications.forEach(function (pub) {
              if (!pub.track) return;
              if (pub.track.kind === LK.Track.Kind.Video) {
                var host = document.querySelector('[data-remote-id="' + id + '"]');
                if (host && !host.querySelector("video")) {
                  _mountRemoteVideo(id, pub.track);
                }
              }
            });
          });
        }
        setTimeout(mountExistingRemotes, 1500);
        setTimeout(mountExistingRemotes, 4000);
        ownReady.value = true;
        readyMap[myIdentity.value] = true;
        sendData({ type: "ready_toggle", identity: myIdentity.value, ready: true });
      } catch (e) {
        error.value = "Error de conexión: " + e.message;
      } finally {
        busy.value = false;
        connectStep.value = "";
      }
    }

    async function toggleMute() {
      if (!room) return;
      var next = !localMuted.value;
      await room.localParticipant.setMicrophoneEnabled(!next);
      localMuted.value = next;
      // La grabación usa el micrófono crudo: silenciarlo también ahí
      if (_recStream) _recStream.getAudioTracks().forEach(function (t) { t.enabled = !next; });
    }
    async function toggleCam() {
      if (!room) return;
      var next = !localCamOff.value;
      await room.localParticipant.setCameraEnabled(!next);
      localCamOff.value = next;
    }
    async function leave() {
      if (micGainCtx) { try { micGainCtx.close(); } catch (_) {} micGainCtx = null; }
      if (recorder) { try { recorder.stop(); } catch (_) {} recorder = null; }
      if (countdownHandle) { clearTimeout(countdownHandle); countdownHandle = null; }
      if (localMeterStop) { localMeterStop(); localMeterStop = null; }
      if (_recStream) {
        _recStream.getTracks().forEach(function (t) { t.stop(); });
        _recStream = null;
      }
      try {
        await fetch("/api/sessions/" + props.joinData.session_id + "/leave-by-participant", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ participant_id: props.joinData.participant_id, token: props.inviteToken }),
        });
      } catch (_) {}
      if (room) { try { await room.disconnect(); } catch (_) {} }
      room = null;
      localStream = null;
      releaseAwake();
      connected.value = false;
      left.value = true;
    }

    onMounted(function () {
      loadSounds();
      startGuestPreflight();
      // Subida interrumpida en una visita anterior: recuperarla.
      recoverPendingUpload(props.joinData.session_id, props.inviteToken, "video").then(function (ok) {
        if (ok && window.toast) window.toast({ type: "success", text: "Se recuperó y subió una grabación pendiente" });
      });
    });
    onBeforeUnmount(function () {
      document.removeEventListener("visibilitychange", onVisibility);
      releaseAwake();
      if (timerHandle) clearInterval(timerHandle);
      stopGuestPreflight();
      if (_roomCamTrack) { try { _roomCamTrack.stop(); } catch (_) {} _roomCamTrack = null; }
      if (_fullResCamTrack) { try { _fullResCamTrack.stop(); } catch (_) {} _fullResCamTrack = null; }
      if (_recStream) {
        _recStream.getTracks().forEach(function (t) { t.stop(); });
        _recStream = null;
      }
      try {
        navigator.sendBeacon("/api/sessions/" + props.joinData.session_id + "/leave-by-participant",
          new Blob([JSON.stringify({ participant_id: props.joinData.participant_id, token: props.inviteToken })], { type: "application/json" }));
      } catch (_) {}
      if (room) room.disconnect().catch(function () {});
    });

    return { localVideoEl: localVideoEl, error: error, busy: busy, connected: connected,
             localMuted: localMuted, localCamOff: localCamOff, remoteMap: remoteMap,
             localMeter: localMeter, recording: recording, timecode: timecode, formatTC: formatTC,
             sounds: sounds, playingPad: playingPad, triggerSound: triggerSound,
             chat: chat, chatInput: chatInput, sendChat: sendChat,
             connect: connect, connectStep: connectStep, toggleMute: toggleMute, toggleCam: toggleCam, gateOn: gateOn, toggleGate: toggleGate, leave: leave, initials: initials,
             countdown: countdown, myIdentity: myIdentity, practiceMode: practiceMode,
             preflightVideoEl: preflightVideoEl, recPreflight: recPreflight,
             recProfileChoices: recProfileChoices, recProfileG: recProfileG, pendingMB: pendingMB, guestEta: guestEta, etaText: etaText, endCountdown: endCountdown, camsOffAfterRec: camsOffAfterRec,
             uploadStatus: uploadStatus, recordingCaps: recordingCaps, streamedBytes: streamedBytes, chunkRetries: _chunkRetries,
             postRecording: postRecording,
             activeOverlays: activeOverlays, cintilloOverlays: cintilloOverlays, otherOverlays: otherOverlays,
             ovLogoUrl: ovLogoUrl, cintilloTitle: cintilloTitle, cintilloText: cintilloText, fmtCountdown: fmtCountdown,
             activeCue: activeCue, ifbActive: ifbActive, directorConnected: directorConnected,
             tp: _tpH.tp, tpPause: _tpH.tpPause, tpRestart: _tpH.tpRestart, tpClose: _tpH.tpClose,
             preMeter: preMeter, chatOpen: chatOpen, chatUnread: chatUnread, toggleChat: toggleChat,
             left: left, awayWhileRecording: awayWhileRecording, qualityText: qualityText };
  },
  template: `
    <div class="studio guest-studio" :class="{ 'is-connected': connected, 'chat-open': chatOpen }">
      <div v-if="endCountdown !== null" class="end-countdown">
        <div class="end-countdown-title">La grabación terminó</div>
        <div class="end-countdown-sub">Apagamos cámara y micrófono en</div>
        <div class="end-countdown-num">{{ endCountdown }}</div>
      </div>
      <!-- Terminó: gracias -->
      <div v-if="left" class="guest-end">
        <div class="guest-end-icon">{{ error ? "✕" : "✓" }}</div>
        <h2>{{ error ? error : "¡Gracias por participar!" }}</h2>
        <p class="muted" v-if="!error">Ya puedes cerrar esta pestaña.</p>
      </div>
      <template v-else>
      <div class="studio-top" :class="{ recording: recording }">
        <div class="guest-title">
          <h3>{{ joinData.session_title || "Sala de grabación" }}</h3>
          <div class="guest-sub">Entras como <strong>{{ joinData.display_name }}</strong></div>
        </div>
        <div class="spacer"></div>
        <span v-if="practiceMode" class="rehearsal-badge">🟡 ENSAYO</span>
        <div v-if="recording" class="timecode mono">{{ formatTC(timecode) }}</div>
        <span v-if="connected && recording" class="tally live"><span class="dot"></span>GRABANDO</span>
        <div v-if="connected && !recording" class="vu-master">
          <span class="vu-label">MIC</span>
          <div class="vu-h" :style="'--vu:' + localMeter"></div>
        </div>
      </div>
      <div v-if="recording && !recordingCaps.hasCam" class="upload-banner guest-banner warn">
        ⚠ Grabando solo tu voz: tu cámara no está disponible
      </div>
      <div v-if="awayWhileRecording && recording" class="upload-banner guest-banner warn" @click="awayWhileRecording = false">
        ⚠ Saliste de esta pantalla mientras grababas. Quédate aquí y no bloquees el teléfono hasta que termine. <u>Entendido</u>
      </div>
      <div v-if="!postRecording && uploadStatus.state === 'streaming' && chunkRetries < 2" class="upload-banner guest-banner">
        Guardando tu grabación en el servidor · {{ (streamedBytes / (1024*1024)).toFixed(1) }} MB<span v-if="pendingMB > 0.5"> · faltan {{ pendingMB.toFixed(1) }} MB</span>
      </div>
      <div v-if="!postRecording && uploadStatus.state === 'streaming' && chunkRetries >= 2" class="upload-banner guest-banner warn">
        ⚠ Tu conexión está inestable. Tu grabación sigue guardándose en este aparato y se sube cuando mejore.
      </div>
      <div v-if="postRecording" class="guest-post">
        <div v-if="uploadStatus.state === 'finalizing'" class="guest-post-box">
          <div class="guest-post-icon">⏳</div>
          <h2>Terminando de subir tu grabación…</h2>
          <p class="guest-post-big">{{ pendingMB > 0.05 ? "Faltan " + pendingMB.toFixed(1) + " MB" : "Casi listo" }}</p>
          <p v-if="guestEta && pendingMB > 0.05" class="guest-post-eta">Tiempo estimado: {{ etaText(guestEta) }}</p>
          <p class="muted">No cierres esta pestaña ni bloquees el teléfono hasta que diga “listo”. Puedes dejarla abierta y seguir con lo tuyo.</p>
        </div>
        <div v-else-if="uploadStatus.state === 'done'" class="guest-post-box">
          <div class="guest-post-icon ok">✓</div>
          <h2>Listo, tu grabación llegó completa</h2>
          <p class="muted">{{ uploadStatus.sizeMB }} MB enviados. Ya puedes salir.</p>
          <button class="primary guest-post-btn" @click="leave">Salir</button>
        </div>
        <div v-else-if="uploadStatus.state === 'error'" class="guest-post-box">
          <div class="guest-post-icon bad">✕</div>
          <h2>No se pudo subir tu grabación</h2>
          <p style="color:#f66;">{{ uploadStatus.error }}</p>
          <p class="muted">No cierres esta pestaña: tu grabación sigue guardada aquí. Avísale al anfitrión.</p>
        </div>
      </div>
      <div v-if="!postRecording" class="studio-main">
        <div v-if="error" class="error guest-error">⚠ {{ error }}</div>
        <div v-if="!connected && !busy" class="prejoin">
          <div class="prejoin-card guest-prejoin">
            <div class="prejoin-controls">
              <h3 class="guest-prejoin-title">Revisa cómo te ves y te escuchas</h3>
              <div class="guest-preview">
                <video ref="preflightVideoEl" autoplay muted playsinline></video>
                <div class="guest-mic">
                  <span>🎤</span>
                  <div class="guest-mic-bar"><div :style="{ width: Math.min(100, Math.round(preMeter * 140)) + '%' }"></div></div>
                </div>
              </div>
              <p class="guest-hint">Habla un poco: la barra verde se mueve si tu micrófono funciona.</p>
              <div class="guest-quality">
                <span v-if="recPreflight.state === 'testing'" class="muted">📶 Revisando tu conexión (unos 5 segundos)…</span>
                <template v-else-if="recPreflight.state === 'done'">
                  <span>✓ {{ qualityText }}</span>
                  <details class="guest-quality-more">
                    <summary>Cambiar calidad</summary>
                    <select v-model="recPreflight.choiceId" class="quality-pick"
                            title="La prueba puso el máximo; puedes bajarla, no subirla.">
                      <option v-for="p in recProfileChoices" :key="p.id" :value="p.id">{{ p.desc }}</option>
                    </select>
                  </details>
                </template>
              </div>
              <ul class="guest-tips">
                <li>🎧 Usa audífonos para que no haya eco.</li>
                <li>📱 Apoya el teléfono y no cambies de app mientras graban.</li>
                <li>🔋 Mejor conectado al cargador.</li>
                <li><strong>⏳ Al terminar, quédate en esta página hasta que diga «Listo»:</strong> tu grabación termina de subirse (te mostramos cuánto falta).</li>
              </ul>
              <button class="primary guest-join" @click="connect" :disabled="recPreflight.state === 'testing'">
                {{ recPreflight.state === 'testing' ? "Revisando…" : "Entrar a la sala" }}
              </button>
            </div>
          </div>
        </div>
        <div v-else-if="busy" class="guest-busy">
          <div class="guest-spinner"></div>
          <div>{{ connectStep || "Un momento…" }}</div>
          <div class="muted" style="font-size:13px;">Si tu navegador pregunta, permite la cámara y el micrófono.</div>
        </div>
        <div v-else class="participants-grid guest-grid" :class="'n' + Object.keys(remoteMap).length">
          <div class="participant-card guest-self">
            <video ref="localVideoEl" autoplay muted playsinline></video>
            <div v-if="localCamOff" class="initials" style="position:absolute;">{{ initials(joinData.display_name) }}</div>
            <div class="label">
              <span>{{ joinData.display_name }}</span>
              <span class="role-chip">TÚ</span>
            </div>
            <div v-if="localMuted" class="muted-icon">🔇</div>
            <div class="vu" :style="'--vu:' + localMeter"></div>
          </div>
          <div v-for="(t, id) in remoteMap" :key="id" class="participant-card">
            <div :data-remote-id="id" style="width:100%; height:100%;"></div>
            <div class="label">
              <span>{{ t.name || id }}</span>
            </div>
            <div class="vu" :style="'--vu:' + (t.meter || 0)"></div>
          </div>
          <div v-if="Object.keys(remoteMap).length === 0" class="guest-alone">Esperando a los demás…</div>
        </div>
        <div v-if="countdown !== null" class="countdown-overlay">
          <div class="countdown-num">{{ countdown > 0 ? countdown : '●' }}</div>
          <div class="countdown-label">{{ countdown > 0 ? 'EMPIEZA LA GRABACIÓN' : 'GRABANDO' }}</div>
        </div>
${TP_TEMPLATE}
        <div v-if="cintilloOverlays.length" class="cintillo-layer">
          <div v-for="ov in cintilloOverlays" :key="ov.event_id" class="cintillo" :class="ov.event_type">
            <div v-if="ovLogoUrl(ov)" class="c-logo"><img :src="ovLogoUrl(ov)" alt=""></div>
            <div class="c-bars">
              <div class="c-title">{{ cintilloTitle(ov) }}</div>
              <div v-if="cintilloText(ov)" class="c-text">{{ cintilloText(ov) }}</div>
            </div>
          </div>
        </div>
        <div v-if="otherOverlays.length" class="director-overlay">
          <div v-for="ov in otherOverlays" :key="ov.event_id" class="overlay-card" :class="ov.event_type">
            <template v-if="ov.event_type === 'comment'">
              <div class="ov-author">{{ ov.payload.author }}</div><div class="ov-text">{{ ov.payload.text }}</div>
            </template>
            <template v-else-if="ov.event_type === 'countdown'">
              <div class="ov-label">{{ ov.payload.label }}</div>
              <div class="ov-timer">{{ fmtCountdown(ov.remaining) }}</div>
            </template>
          </div>
        </div>
        <div v-if="activeCue" class="director-cue" :class="activeCue.cssClass">
          {{ activeCue.cue }}
        </div>
      </div>
      <aside v-if="!postRecording" class="studio-side guest-side">
        <div class="guest-side-head">
          <span class="label">Chat</span>
          <button class="ghost guest-side-close" @click="toggleChat">Cerrar</button>
        </div>
        <div v-if="sounds.length" class="guest-sounds">
          <div class="sb-head"><span class="label">Soundboard</span><span class="tiny">teclas</span></div>
          <div class="sb-grid">
            <button v-for="s in sounds" :key="s.id" class="sb-pad"
                    :class="{ playing: playingPad === s.shortcut_key }"
                    :style="{ '--pad-color': s.color }"
                    @click="triggerSound(s)">
              <span>{{ s.name }}</span>
              <span class="key">{{ s.shortcut_key }}</span>
            </button>
          </div>
        </div>
        <div class="guest-chat">
          <div class="sb-head guest-chat-head"><span class="label">Chat</span><span class="tiny">{{ chat.length }}</span></div>
          <div id="guest-chat-scroll" class="guest-chat-list">
            <div v-if="!chat.length" class="muted" style="font-size:13px;">Aquí aparecen los mensajes de la sala.</div>
            <div v-for="m in chat" :key="m.id" class="guest-chat-msg">
              <strong>{{ m.author }}</strong>
              <span>{{ m.text }}</span>
            </div>
          </div>
          <div class="guest-chat-input">
            <input type="text" v-model="chatInput" @keyup.enter="sendChat" placeholder="Escribe un mensaje…" enterkeyhint="send">
            <button class="primary" @click="sendChat" :disabled="!chatInput.trim()">↑</button>
          </div>
        </div>
      </aside>
      <div v-if="!postRecording" class="controls-bar guest-controls">
        <template v-if="connected">
          <button class="gc-btn" :class="{ muted: localMuted }" @click="toggleMute">
            <span class="gc-ico">{{ localMuted ? "🔇" : "🎤" }}</span><span class="gc-txt">{{ localMuted ? "Activar" : "Micrófono" }}</span>
          </button>
          <button class="gc-btn" :class="{ on: gateOn }" @click="toggleGate" :title="gateOn ? 'Cuando no hablas, los demás no oyen tus ruidos. Toca para apagar.' : 'Apagado: te oyen siempre. Toca para encender.'"><span>🚪</span><span class="gc-txt">{{ gateOn ? "Auto-silencio" : "Sin auto-sil." }}</span></button>
          <button class="gc-btn" :class="{ 'cam-off': localCamOff }" @click="toggleCam">
            <span class="gc-ico">{{ localCamOff ? "📷" : "🎥" }}</span><span class="gc-txt">{{ localCamOff ? "Activar" : "Cámara" }}</span>
          </button>
          <button class="gc-btn gc-chat" @click="toggleChat">
            <span class="gc-ico">💬</span><span class="gc-txt">Chat</span>
            <span v-if="chatUnread" class="gc-badge">{{ chatUnread }}</span>
          </button>
        </template>
        <span v-if="ifbActive" class="ifb-indicator">🎧 Te habla el director</span>
        <span v-else-if="directorConnected" class="director-badge">Director conectado</span>
        <div class="spacer"></div>
        <button class="ghost gc-leave" @click="leave">Salir</button>
      </div>
      </template>
    </div>
  `,
};

/* ==========================================================================
   Root
   ========================================================================== */

// ==========================================================================
// DirectorDashboard — session list filtered by podcast assignment
// ==========================================================================

var DirectorDashboard = {
  props: { user: Object, onOpenDirector: { type: Function, required: true }, onBack: { type: Function, required: true } },
  setup: function (props) {
    var sessions = ref([]);
    var loading = ref(true);
    var error = ref("");

    async function load() {
      loading.value = true;
      try {
        var all = await api("/api/sessions");
        var directorProjects = await api("/api/director/my-podcasts");
        var projectIds = directorProjects.map(function (d) { return d.shared_project_id; });
        sessions.value = all.filter(function (s) {
          return projectIds.indexOf(s.shared_project_id) !== -1;
        });
      } catch (e) { error.value = e.message; }
      finally { loading.value = false; }
    }

    var pollHandle = null;
    onMounted(function () {
      load();
      pollHandle = setInterval(load, 5000);
    });
    onBeforeUnmount(function () { if (pollHandle) clearInterval(pollHandle); });
    return { sessions: sessions, loading: loading, error: error, fmtDate: fmtDate };
  },
  template: '\
    <div class="container">\
      <div class="page-head">\
        <div>\
          <div class="eyebrow" style="color: var(--signal-cyan);">DIRECTOR · CONTROL ROOM</div>\
          <h2>Control <em style="color:var(--signal-cyan);font-style:italic;">room</em></h2>\
        </div>\
        <div class="spacer"></div>\
        <button class="ghost" @click="$props.onBack">← Dashboard</button>\
      </div>\
      <div v-if="error" class="error">{{ error }}</div>\
      <div v-if="loading" class="muted">Cargando sesiones…</div>\
      <div v-else-if="sessions.length === 0" class="empty-state">\
        <div class="icon" style="color: var(--signal-cyan);">🎬</div>\
        <div style="font-family:var(--font-display); font-size:18px; font-style:italic; margin-bottom:4px;">\
          No hay sesiones disponibles.\
        </div>\
        <div>Serás asignado como director a podcasts por los hosts.</div>\
      </div>\
      <div v-else class="sessions-list">\
        <div v-for="s in sessions" :key="s.id" class="session-tile"\
             :class="{ \'is-live\': (s.live_participants || []).length > 0 }"\
             @click="$props.onOpenDirector(s)"\
             style="border-left: 3px solid var(--signal-cyan);">\
          <span class="status" :class="s.status">{{ s.status }}</span>\
          <h3>{{ s.title }}</h3>\
          <div class="desc">{{ s.description || "—" }}</div>\
          <div v-if="(s.live_participants || []).length" class="live-chip">\
            <span class="dot"></span>\
            {{ s.live_participants.length }} EN VIVO · {{ s.live_participants.join(", ") }}\
          </div>\
          <div class="bottom">\
            <span class="tiny">{{ fmtDate(s.created_at) }}</span>\
            <span class="tiny" style="color: var(--signal-cyan);">DIRECTOR</span>\
          </div>\
        </div>\
      </div>\
    </div>\
  ',
};


// ==========================================================================
// DirectorView — Control Room (3-column layout)
// ==========================================================================

var DirectorView = {
  props: { session: Object, user: Object, onBack: { type: Function, required: true } },
  setup: function (props) {
    var error = ref("");
    var connected = ref(false);
    var room = null;
    var participants = ref([]);
    var remoteMap = reactive({});
    var activeOverlays = reactive([]);
    var timecode = ref(0);
    var timerHandle = null;
    var myIdentity = ref("");
    var streams = ref([]);

    // Recording control
    var recording = ref(props.session.status === "recording");
    var readyMap = reactive({});
    var countdown = ref(null);
    var countdownHandle = null;

    // Injection forms (comment / countdown — pestaña "Otros")
    var injectType = ref("comment");
    var injectFields = reactive({
      author: "", text: "", platform: "youtube",
      seconds: 180, label: "Volvemos en",
    });

    // ---- Cintillos (Sponsor / Podcast / Segmento), mismo contrato que la Mac ----
    var branding = ref({ podcast_name: "", podcast_logo_url: null, sponsors: [] });
    var cin = reactive({
      tab: "sponsor",          // sponsor | podcast | segment | otros
      sponsorIdx: 0,
      text: "",                // texto editable (copy del sponsor / momento del podcast)
      podTitle: "",            // título del cintillo de podcast (default: nombre)
      segTitle: "", segSubtitle: "",
      duration: 8,             // 8 | 15 | 30 | 0 (hasta quitarlo)
      busy: false,
    });
    var _assetCache = {};      // logo_url -> file_path (subido una vez por sesión)

    async function loadBranding() {
      try {
        branding.value = await api("/api/sessions/" + props.session.id + "/director/branding");
        if (!cin.podTitle) cin.podTitle = branding.value.podcast_name || "";
        _prefillSponsor();
      } catch (_) {}
    }
    function _prefillSponsor() {
      var sp = (branding.value.sponsors || [])[cin.sponsorIdx];
      if (cin.tab === "sponsor") cin.text = (sp && sp.copy) || "";
    }
    watch(function () { return cin.sponsorIdx; }, _prefillSponsor);
    watch(function () { return cin.tab; }, function (t) {
      if (t === "sponsor") _prefillSponsor();
      else if (t === "podcast") cin.text = "";
    });

    // Vista previa exacta: mismo objeto que se manda por overlay_inject.
    var cinPreview = computed(function () {
      if (cin.tab === "sponsor") {
        var sp = (branding.value.sponsors || [])[cin.sponsorIdx] || {};
        return {
      tpForm: tpForm, tpSponsorIdx: tpSponsorIdx, tpUseSponsor: tpUseSponsor, sendTeleprompter: sendTeleprompter, hideTeleprompter: hideTeleprompter, tpLastId: tpLastId, event_type: "sponsor", logo: sp.logo_url || null,
                 payload: { sponsor_name: sp.name || "Sponsor", sponsor_copy: cin.text, style: "cintillo" } };
      }
      if (cin.tab === "podcast") {
        return { event_type: "banner", logo: branding.value.podcast_logo_url,
                 payload: { name: cin.podTitle || branding.value.podcast_name || "Podcast", title: cin.text, style: "cintillo" } };
      }
      return { event_type: "segment", logo: null,
               payload: { title: cin.segTitle, subtitle: cin.segSubtitle, style: "cintillo" } };
    });

    async function _assetFor(logoUrl) {
      if (!logoUrl) return null;
      if (_assetCache[logoUrl]) return _assetCache[logoUrl];
      var res = await api("/api/sessions/" + props.session.id + "/director/assets/from-url", {
        method: "POST", body: { url: logoUrl },
      });
      _assetCache[logoUrl] = res.file_path;
      return res.file_path;
    }

    async function airCintillo() {
      var pv = cinPreview.value;
      if (!cintilloTitle(pv)) {
        if (window.toast) window.toast({ type: "warn", text: "Falta el título del cintillo" });
        return;
      }
      cin.busy = true;
      try {
        var file_path = null;
        try { file_path = await _assetFor(pv.logo); }
        catch (_) { /* sin logo: el cintillo sale igual */ }
        var res = await api("/api/sessions/" + props.session.id + "/director/inject", {
          method: "POST",
          body: { event_type: pv.event_type, payload: pv.payload,
                  file_path: file_path, duration_seconds: cin.duration },
        });
        var msg = { type: "overlay_inject", event_type: pv.event_type, payload: pv.payload,
                    event_id: res.event_id, file_path: file_path, duration_seconds: cin.duration };
        sendData(msg);
        _admitOverlay(activeOverlays, msg);
        if (window.toast) window.toast({ type: "success",
          text: "Al aire" + (cin.duration > 0 ? " (" + cin.duration + " s)" : " — hasta que lo quites") });
      } catch (e) {
        if (window.toast) window.toast({ type: "error", text: e.message });
      } finally {
        cin.busy = false;
      }
    }

    // Cue target
    var cueTarget = ref("all");

    // ---- Teleprompter inyectado por el director (texto libre o de un sponsor) ----
    var tpForm = reactive({ target: "all", title: "", text: "", speed: "normal", size: "half", countdown: 3 });
    var tpSponsorIdx = ref(-1);
    var tpLastId = ref(null);
    function tpUseSponsor() {
      var sp = (branding.value.sponsors || [])[tpSponsorIdx.value];
      if (!sp) return;
      tpForm.title = "Publicidad de " + (sp.name || "sponsor");
      tpForm.text = sp.copy || "";
    }
    async function sendTeleprompter() {
      var text = (tpForm.text || "").trim();
      if (!text) { if (window.toast) window.toast({ type: "warn", text: "Escribe el texto del teleprompter" }); return; }
      var eid = "d" + Date.now();
      var msg = { type: "teleprompter", action: "show", event_id: eid, target: tpForm.target,
                  title: tpForm.title || "Teleprompter", text: text, speed: tpForm.speed, size: tpForm.size,
                  countdown: Math.max(0, +tpForm.countdown || 0) };
      sendData(msg);
      tpLastId.value = eid;
      try {
        await api("/api/sessions/" + props.session.id + "/director/inject", {
          method: "POST", body: { event_type: "teleprompter", payload: { target: tpForm.target, title: msg.title, text: text, speed: tpForm.speed, size: tpForm.size } },
        });
      } catch (_) {}
      if (window.toast) window.toast({ type: "success", text: "🎬 Teleprompter enviado" + (msg.countdown ? " (aviso de " + msg.countdown + " s)" : "") });
    }
    function hideTeleprompter() {
      sendData({ type: "teleprompter", action: "hide", event_id: tpLastId.value || null, target: "all" });
      tpLastId.value = null;
    }

    // Soundboard
    var sounds = ref([]);
    var playingPad = reactive({});

    // Collapsed sections
    var expandedSection = ref("banner");

    // Cue visibility for guests
    var guestCuesVisible = ref(true);
    function toggleGuestCues() {
      guestCuesVisible.value = !guestCuesVisible.value;
      sendData({ type: "cue_visibility", show: guestCuesVisible.value });
    }

    // Upload status monitoring
    var participantUploads = reactive({});
    var allUploadsComplete = computed(function () {
      var keys = Object.keys(participantUploads);
      return keys.length > 0 && keys.every(function (k) { return participantUploads[k].state === "done"; });
    });

    function formatTC(s) {
      var h = Math.floor(s / 3600); var m = Math.floor((s % 3600) / 60); var sec = s % 60;
      return (h > 0 ? String(h).padStart(2, "0") + ":" : "") + String(m).padStart(2, "0") + ":" + String(sec).padStart(2, "0");
    }

    async function loadParticipants() {
      try { participants.value = await api("/api/sessions/" + props.session.id + "/participants"); }
      catch (_) {}
    }

    async function loadStreams() {
      try { streams.value = await api("/api/sessions/" + props.session.id + "/streams"); }
      catch (_) {}
    }

    async function loadSounds() {
      try { sounds.value = await api("/api/sessions/" + props.session.id + "/sounds"); }
      catch (_) {}
    }

    function sendData(msg) {
      if (!room) return;
      try { room.localParticipant.publishData(_encodeMsg(msg), LK.DataPacket_Kind.RELIABLE); }
      catch (_) {}
    }

    // --- Overlay injection (pestaña "Otros": comentario y countdown) ---
    async function injectOverlay() {
      var payload = {};
      var t = injectType.value;
      if (t === "comment") payload = { author: injectFields.author, text: injectFields.text, platform: injectFields.platform };
      else if (t === "countdown") payload = { seconds: injectFields.seconds, label: injectFields.label };
      else return;

      try {
        var res = await api("/api/sessions/" + props.session.id + "/director/inject", {
          method: "POST", body: { event_type: t, payload: payload },
        });
        var msg = { type: "overlay_inject", event_type: t, payload: payload, event_id: res.event_id };
        sendData(msg);
        _admitOverlay(activeOverlays, msg);
        if (window.toast) window.toast({ type: "success", text: "Overlay inyectado" });
      } catch (e) {
        if (window.toast) window.toast({ type: "error", text: e.message });
      }
    }

    async function removeOverlay(ov) {
      try {
        await api("/api/sessions/" + props.session.id + "/director/events/" + ov.event_id + "/remove", { method: "POST" });
        sendData({ type: "overlay_remove", event_id: ov.event_id });
        _dropOverlay(activeOverlays, ov.event_id);
      } catch (_) {}
    }

    // --- Cues ---
    async function sendCue(cue) {
      var target = cueTarget.value;
      try {
        await api("/api/sessions/" + props.session.id + "/director/cue", {
          method: "POST", body: { cue: cue, target: target },
        });
        sendData({ type: "director_cue", cue: cue, target: target, text: "" });
        if (window.toast) window.toast({ type: "success", text: "Cue enviado: " + cue });
      } catch (_) {}
    }

    // --- Force mute ---
    async function forceMute(p) {
      try {
        await api("/api/sessions/" + props.session.id + "/participants/" + p.id + "/force-mute", { method: "POST" });
        sendData({ type: "force_mute", target: "participant_" + p.id });
        if (window.toast) window.toast({ type: "info", text: p.display_name + " muteado" });
      } catch (_) {}
    }

    // --- Kick ---
    async function kickParticipant(p) {
      try {
        await api("/api/sessions/" + props.session.id + "/participants/" + p.id, { method: "DELETE" });
        sendData({ type: "kick", target_identity: "participant_" + p.id });
        loadParticipants();
      } catch (_) {}
    }

    // --- Export to postPod ---
    var exportStatus = ref("");
    var exporting = ref(false);
    async function exportToPostpod() {
      if (exporting.value) return;
      exporting.value = true;
      exportStatus.value = "enviando pistas a postPod…";
      try {
        var r = await api("/api/sessions/" + props.session.id + "/recordings/export-to-postpod", { method: "POST" });
        if (r.exported === 0 && r.failed === 0) {
          exportStatus.value = "✓ Ya enviadas a postPod";
        } else {
          exportStatus.value = "✓ " + r.exported + " enviada(s)" + (r.failed ? " · " + r.failed + " falló" : "");
        }
      } catch (e) {
        exportStatus.value = "❌ " + e.message;
      } finally {
        exporting.value = false;
        setTimeout(function () { exportStatus.value = ""; }, 8000);
      }
    }

    // --- IFB Push-to-Talk ---
    var ifbStream = null;
    var ifbRawTrack = null;
    var ifbPublished = false;
    var ifbActive = ref(false);

    async function ensureIFBTrack() {
      if (ifbPublished) return true;
      try {
        ifbStream = await navigator.mediaDevices.getUserMedia({ audio: true });
        ifbRawTrack = ifbStream.getAudioTracks()[0];
        ifbRawTrack.enabled = false;
        var lkTrack = new LK.LocalAudioTrack(ifbRawTrack);
        await room.localParticipant.publishTrack(lkTrack, { name: "ifb_audio", stream: "ifb" });
        ifbPublished = true;
        return true;
      } catch (e) {
        if (window.toast) window.toast({ type: "error", text: "No se pudo activar el micrófono IFB: " + e.message });
        return false;
      }
    }

    async function startIFB(targets) {
      var ok = await ensureIFBTrack();
      if (!ok) return;
      ifbRawTrack.enabled = true;
      ifbActive.value = true;
      sendData({ type: "ifb_start", targets: targets });
    }

    function stopIFB() {
      if (ifbRawTrack) ifbRawTrack.enabled = false;
      ifbActive.value = false;
      sendData({ type: "ifb_stop" });
    }

    // --- Sound trigger ---
    var sessionSounds = computed(function () {
      return sounds.value.filter(function (s) { return !s.director_only; });
    });
    var directorSounds = computed(function () {
      return sounds.value.filter(function (s) { return s.director_only; });
    });

    function triggerSound(s) {
      sendData({ type: "sound_trigger", filename: s.filename, key: s.shortcut_key });
      playingPad[s.id] = true;
      setTimeout(function () { playingPad[s.id] = false; }, 400);
    }

    // --- Director Chat ---
    var directorChat = ref([]);
    var directorChatInput = ref("");

    function _chatRow(r) {
      // El servidor guarda author_name/message_text; el front usa author/text.
      return { id: r.id, author: r.author_name || r.author || "",
               text: r.message_text || r.text || "" };
    }

    async function loadDirectorChat() {
      try {
        var rows = await api("/api/sessions/" + props.session.id + "/chat?channel=director");
        directorChat.value = (rows || []).map(_chatRow);
      } catch (_) {}
    }

    async function sendDirectorChat() {
      var text = (directorChatInput.value || "").trim();
      if (!text) return;
      try {
        var raw = await api("/api/sessions/" + props.session.id + "/chat", {
          method: "POST", body: { text: text, channel: "director" },
        });
        var msg = _chatRow(raw);
        directorChatInput.value = "";
        directorChat.value.push(msg);
        sendData({ type: "director_chat", id: msg.id, author: msg.author, text: msg.text });
        nextTick(function () {
          var el = document.getElementById("director-chat-scroll");
          if (el) el.scrollTop = el.scrollHeight;
        });
      } catch (e) {
        if (window.toast) window.toast({ type: "error", text: e.message });
      }
    }

    // --- Recording control ---
    var allParticipantsReady = computed(function () {
      var hosts = participants.value.filter(function(p) {
        return p.role === "host" || p.role === "co-host";
      });
      if (hosts.length === 0) return false;
      return hosts.every(function(p) { return !!readyMap["participant_" + p.id]; });
    });

    async function startRecording() {
      if (recording.value || countdown.value !== null) return;
      var startAt = Date.now() + 3500;
      sendData({ type: "countdown_start", start_at_ms: startAt });
      function tick() {
        var rem = startAt - Date.now();
        if (rem <= 0) {
          countdown.value = 0;
          recording.value = true;
          try { api("/api/sessions/" + props.session.id + "/start", { method: "POST" }); } catch (_) {}
          var started = Date.now();
          if (timerHandle) clearInterval(timerHandle);
          timerHandle = setInterval(function () {
            timecode.value = Math.floor((Date.now() - started) / 1000);
          }, 1000);
          countdownHandle = setTimeout(function () { countdown.value = null; }, 700);
          return;
        }
        countdown.value = Math.ceil(rem / 1000);
        countdownHandle = setTimeout(tick, 100);
      }
      tick();
    }

    async function stopRecording() {
      if (!recording.value) return;
      try { await api("/api/sessions/" + props.session.id + "/stop", { method: "POST" }); } catch (_) {}
      sendData({ type: "recording_stop" });
      recording.value = false;
      if (timerHandle) { clearInterval(timerHandle); timerHandle = null; }
      timecode.value = 0;
      Object.keys(readyMap).forEach(function (k) { delete readyMap[k]; });
    }

    // --- Connect to LiveKit ---
    async function connect() {
      try {
        var tokenData = await api("/api/sessions/" + props.session.id + "/director-token");
        myIdentity.value = "director_" + tokenData.participant_id;
        room = new LK.Room({ adaptiveStream: true, dynacast: true });
        room.on(LK.RoomEvent.DataReceived, function (payload) {
          var msg = _decodeMsg(payload);
          if (!msg) return;
          if (msg.type === "sound_trigger" && msg.filename) {
            var s = sounds.value.find(function (x) { return x.filename === msg.filename; });
            if (s) {
              playingPad[s.id] = true;
              setTimeout(function () { playingPad[s.id] = false; }, 400);
            }
          }
          if (msg.type === "ready_toggle") {
            readyMap[msg.identity] = !!msg.ready;
            loadParticipants();
          }
          if (msg.type === "upload_status") {
            participantUploads[msg.identity] = { state: msg.state, bytes: msg.bytes || 0, pending: msg.pending || 0, eta: msg.eta == null ? null : msg.eta };
          }
          if (msg.type === "director_chat" && msg.text) {
            directorChat.value.push({ id: msg.id, author: msg.author, text: msg.text });
            nextTick(function () {
              var el = document.getElementById("director-chat-scroll");
              if (el) el.scrollTop = el.scrollHeight;
            });
          }
        });
        room.on(LK.RoomEvent.TrackSubscribed, function (track, pub, participant) {
          var id = participant.identity;
          if (!remoteMap[id]) remoteMap[id] = { name: participant.name || id, meter: 0, speaking: false };
          if (track.kind === LK.Track.Kind.Video) {
            var vidEl = track.attach();
            vidEl.style.width = "100%"; vidEl.style.height = "100%"; vidEl.style.objectFit = "cover";
            var dirAttempts = 0;
            function tryMountDir() {
              var container = document.querySelector('[data-director-feed="' + id + '"]');
              if (container) { container.innerHTML = ""; container.appendChild(vidEl); return; }
              dirAttempts++;
              if (dirAttempts < 20) setTimeout(tryMountDir, 250);
            }
            nextTick(tryMountDir);
          } else if (track.kind === LK.Track.Kind.Audio) {
            var a = track.attach(); a.volume = 1.0;
            document.body.appendChild(a);
          }
        });
        room.on(LK.RoomEvent.TrackUnsubscribed, function (track) {
          track.detach().forEach(function (el) { el.remove(); });
        });
        room.on(LK.RoomEvent.ParticipantConnected, function () { loadParticipants(); });
        room.on(LK.RoomEvent.ParticipantDisconnected, function (p) {
          delete remoteMap[p.identity];
          loadParticipants();
        });
        room.on(LK.RoomEvent.ActiveSpeakersChanged, function (speakers) {
          var active = {};
          speakers.forEach(function (s) { active[s.identity] = true; });
          Object.keys(remoteMap).forEach(function (id) { remoteMap[id].speaking = !!active[id]; });
        });
        await room.connect(tokenData.livekit_ws_url, tokenData.livekit_token);
        connected.value = true;
        if (window.toast) window.toast({ type: "success", text: "Conectado al Control Room" });
        // Pedir a todos su estado de PREPARADO (por si el director entra tarde).
        setTimeout(function () {
          try { room.localParticipant.publishData(_encodeMsg({ type: "ready_request" }), LK.DataPacket_Kind.RELIABLE); } catch (_) {}
        }, 800);

        // Mount tracks from participants already in the room
        room.remoteParticipants.forEach(function (p) {
          var id = p.identity;
          if (!remoteMap[id]) remoteMap[id] = { name: p.name || id, meter: 0, speaking: false };
          p.trackPublications.forEach(function (pub) {
            if (pub.track && pub.track.kind === LK.Track.Kind.Video) {
              var vidEl = pub.track.attach();
              vidEl.style.width = "100%"; vidEl.style.height = "100%"; vidEl.style.objectFit = "cover";
              var att = 0;
              function tryM() {
                var container = document.querySelector('[data-director-feed="' + id + '"]');
                if (container) { container.innerHTML = ""; container.appendChild(vidEl); return; }
                att++;
                if (att < 20) setTimeout(tryM, 250);
              }
              nextTick(tryM);
            } else if (pub.track && pub.track.kind === LK.Track.Kind.Audio) {
              var a = pub.track.attach(); a.volume = 1.0;
              document.body.appendChild(a);
            }
          });
        });

        // Start timecode
        if (props.session.started_at) {
          var started = new Date(props.session.started_at + "Z").getTime();
          timerHandle = setInterval(function () {
            timecode.value = Math.floor((Date.now() - started) / 1000);
          }, 1000);
        }
      } catch (e) {
        error.value = e.message || "Error de conexión";
        if (window.toast) window.toast({ type: "error", text: error.value });
      }
    }

    function disconnect() {
      if (room) { room.disconnect(); room = null; }
      connected.value = false;
      if (timerHandle) { clearInterval(timerHandle); timerHandle = null; }
    }

    // --- Teléfono/tablet: paneles por pestaña (hoja inferior) y pantalla encendida ---
    var dTab = ref(null);
    var dChatSeen = ref(0);
    var dChatUnread = computed(function () { return dTab.value === "chat" ? 0 : Math.max(0, directorChat.value.length - dChatSeen.value); });
    function openDTab(t) {
      dTab.value = dTab.value === t ? null : t;
      if (dTab.value === "chat") {
        dChatSeen.value = directorChat.value.length;
        nextTick(function () { var el = document.getElementById("director-chat-scroll"); if (el) el.scrollTop = el.scrollHeight; });
      }
    }
    watch(function () { return directorChat.value.length; }, function (n) { if (dTab.value === "chat") dChatSeen.value = n; });
    var _dWake = null;
    async function dKeepAwake() {
      try { if ("wakeLock" in navigator && !_dWake) { _dWake = await navigator.wakeLock.request("screen"); _dWake.addEventListener("release", function () { _dWake = null; }); } } catch (_) {}
    }
    function dVisibility() { if (document.visibilityState === "visible" && connected.value) dKeepAwake(); }
    document.addEventListener("visibilitychange", dVisibility);
    watch(connected, function (v) { if (v) dKeepAwake(); else { try { if (_dWake) _dWake.release(); } catch (_) {} _dWake = null; } });
    var readyCount = computed(function () {
      return participants.value.filter(function (p) { return (p.role === "host" || p.role === "co-host") && readyMap["participant_" + p.id]; }).length;
    });
    var hostCount = computed(function () {
      return participants.value.filter(function (p) { return p.role === "host" || p.role === "co-host"; }).length;
    });

    onMounted(function () { loadParticipants(); loadStreams(); loadSounds(); loadDirectorChat(); loadBranding(); });
    onBeforeUnmount(function () {
      disconnect();
      document.removeEventListener("visibilitychange", dVisibility);
      try { if (_dWake) _dWake.release(); } catch (_) {}
    });

    return {
      dTab: dTab, openDTab: openDTab, dChatUnread: dChatUnread, readyCount: readyCount, hostCount: hostCount,
      error: error, connected: connected, connect: connect, disconnect: disconnect,
      participants: participants, remoteMap: remoteMap,
      activeOverlays: activeOverlays, removeOverlay: removeOverlay,
      timecode: timecode, formatTC: formatTC, streams: streams,
      recording: recording, readyMap: readyMap, countdown: countdown,
      allParticipantsReady: allParticipantsReady, startRecording: startRecording, stopRecording: stopRecording,
      injectType: injectType, injectFields: injectFields, injectOverlay: injectOverlay,
      branding: branding, cin: cin, cinPreview: cinPreview, airCintillo: airCintillo,
      cintilloTitle: cintilloTitle, cintilloText: cintilloText,
      expandedSection: expandedSection,
      sendCue: sendCue, cueTarget: cueTarget,
      guestCuesVisible: guestCuesVisible, toggleGuestCues: toggleGuestCues,
      forceMute: forceMute, kickParticipant: kickParticipant,
      sounds: sounds, sessionSounds: sessionSounds, directorSounds: directorSounds, triggerSound: triggerSound, playingPad: playingPad,
      ifbActive: ifbActive, startIFB: startIFB, stopIFB: stopIFB,
      directorChat: directorChat, directorChatInput: directorChatInput, sendDirectorChat: sendDirectorChat,
      participantUploads: participantUploads, allUploadsComplete: allUploadsComplete,
      exportToPostpod: exportToPostpod, exporting: exporting, exportStatus: exportStatus,
    };
  },
  template: '\
    <div class="control-room" :class="[{ \'dtab-open\': !!dTab, \'is-connected\': connected, \'is-rec\': recording }, dTab ? \'dtab-\' + dTab : \'\']">\
      <div class="cr-top">\
        <button class="ghost cr-back" @click="$props.onBack" style="flex-shrink:0;"><span class="d-only">← Sesiones</span><span class="m-only">←</span></button>\
        <h3 style="margin:0;">{{ session.title }}</h3>\
        <span class="badge-id d-only">#{{ session.id }}</span>\
        <div class="spacer"></div>\
        <div class="timecode" :class="{ \'cr-idle\': !recording }">{{ formatTC(timecode) }}</div>\
        <div v-for="st in streams" :key="st.id" class="stream-badge d-only" :class="st.status === \'active\' ? \'live\' : \'off\'">\
          {{ st.platform || "RTMP" }} {{ st.status === "active" ? "LIVE" : st.status }}\
        </div>\
        <button v-if="connected && !recording && countdown === null" class="primary cr-rec" @click="startRecording" style="flex-shrink:0;"\
                :disabled="!allParticipantsReady"\
                :style="allParticipantsReady ? \'background:var(--signal);\' : \'opacity:0.4;\'"\
                :title="allParticipantsReady ? \'Iniciar grabación\' : \'Esperando que los hosts den PREPARADO\'">● GRABAR</button>\
        <span v-else-if="countdown !== null" class="cr-count" style="font-size:22px;font-weight:bold;color:var(--signal);font-family:var(--font-mono);">\
          {{ countdown === 0 ? "¡REC!" : countdown }}\
        </span>\
        <button v-else-if="recording" class="ghost cr-rec" @click="stopRecording"\
                style="flex-shrink:0;color:var(--signal);border-color:var(--signal);">■ DETENER</button>\
        <button v-if="!connected" class="primary d-only" @click="connect" style="flex-shrink:0;">🟢 Conectar</button>\
        <button v-else class="ghost d-only" @click="disconnect" style="flex-shrink:0;">Desconectar</button>\
      </div>\
\
      <div class="cr-left">\
        <div class="cr-sheet-head">\
          <button :class="{ on: dTab === \'personas\' }" @click="openDTab(\'personas\')">Personas</button>\
          <button :class="{ on: dTab === \'chat\' }" @click="openDTab(\'chat\')">Chat</button>\
          <div class="spacer"></div>\
          <button class="cr-close" @click="dTab = null">Cerrar</button>\
        </div>\
        <div class="cr-sec cr-sec-personas">\
        <div class="eyebrow" style="padding:0 0 6px 2px;">PARTICIPANTES</div>\
        <div v-if="!participants.filter(function(x){ return x.role !== \'director\'; }).length" class="muted" style="font-size:12px;">Todavía no entra nadie a la sala.</div>\
        <div v-for="p in participants.filter(function(x){ return x.role !== \'director\'; })" :key="p.id" class="cr-participant">\
          <div class="cr-p-head">\
            <div class="cr-p-thumb" :data-director-thumb="\'participant_\' + p.id"></div>\
            <div class="cr-p-info">\
              <div class="cr-p-name">{{ p.display_name }}\
                <span v-if="readyMap[\'participant_\' + p.id]" style="color:var(--signal);font-size:9px;font-weight:700;margin-left:4px;">LISTO</span>\
              </div>\
              <div class="cr-p-role">{{ p.role }}<span v-if="p.recording_quality" :title="\'Calidad de grabación local decidida por la prueba inicial\'"> · REC {{ p.recording_quality }}<template v-if="p.recording_bitrate"> @ {{ (p.recording_bitrate / 1000000).toFixed(1) }} Mbps</template></span></div>\
            </div>\
          </div>\
          <div class="cr-p-actions">\
            <button class="ghost" @click="forceMute(p)" title="Mutear" style="font-size:12px;">🔇<span class="cr-m-txt"> Silenciar</span></button>\
            <button class="ghost" @click="kickParticipant(p)" title="Expulsar" style="font-size:12px; color:var(--signal);">✕<span class="cr-m-txt"> Sacar</span></button>\
          </div>\
        </div>\
        </div>\
\
        <div class="cr-sec cr-sec-ifb">\
        <div class="eyebrow" style="padding:10px 0 6px 2px;">IFB AUDIO <span class="cr-m-txt" style="text-transform:none;letter-spacing:0;color:var(--paper-dim);">· mantén presionado para hablarles al oído</span></div>\
        <button class="ptt-btn ptt-btn-all" :class="{ active: ifbActive }"\
                @mousedown="startIFB(\'all_hosts\')" @mouseup="stopIFB()" @mouseleave="ifbActive && stopIFB()"\
                @touchstart.prevent="startIFB(\'all_hosts\')" @touchend.prevent="stopIFB()" @touchcancel="stopIFB()" @contextmenu.prevent>🎧 PTT TODOS</button>\
        <div v-for="p in participants.filter(function(x){ return x.role === \'host\' || x.role === \'co-host\'; })" :key="\'ptt-\' + p.id" style="margin-bottom:4px;">\
          <button class="ptt-btn" style="width:100%;"\
                  @mousedown="startIFB([\'participant_\' + p.id])" @mouseup="stopIFB()" @mouseleave="ifbActive && stopIFB()"\
                  @touchstart.prevent="startIFB([\'participant_\' + p.id])" @touchend.prevent="stopIFB()" @touchcancel="stopIFB()" @contextmenu.prevent>🎧 {{ p.display_name }}</button>\
        </div>\
        </div>\
\
        <div class="cr-sec cr-sec-chat">\
        <div class="eyebrow" style="padding:10px 0 6px 2px;">DIRECTOR CHAT</div>\
        <div class="cr-chat-scroll" style="max-height:160px;overflow-y:auto;margin-bottom:6px;" id="director-chat-scroll">\
          <div v-for="m in directorChat" :key="m.id" class="cr-chat-msg" style="font-size:11px;margin-bottom:4px;">\
            <span style="font-weight:600;color:var(--signal-cyan);">{{ m.author }}:</span> {{ m.text }}\
          </div>\
          <div v-if="!directorChat.length" style="font-size:11px;color:var(--paper-dim);">Sin mensajes aún.</div>\
        </div>\
        <div class="cr-chat-input" style="display:flex;gap:4px;">\
          <input v-model="directorChatInput" placeholder="Mensaje..." class="input" style="flex:1;font-size:11px;padding:5px 8px;"\
                 @keyup.enter="sendDirectorChat" />\
          <button class="ghost" style="font-size:11px;padding:5px 8px;" @click="sendDirectorChat">Enviar</button>\
        </div>\
        </div>\
      </div>\
\
      <div class="cr-center">\
        <div v-if="!connected" class="cr-wait" style="display:flex;align-items:center;justify-content:center;height:100%;color:var(--paper-dim);font-family:var(--font-mono);font-size:13px;">\
          <span class="d-only">Conecta al Control Room para ver los feeds</span>\
          <div class="m-only cr-wait-m">\
            <div class="cr-wait-ico">🎬</div>\
            <div class="cr-wait-txt">Conéctate para ver a los participantes, dar grabar y mandar cintillos y cues.</div>\
            <button class="primary cr-connect-m" @click="connect">🟢 Conectar</button>\
          </div>\
        </div>\
        <div v-else class="cr-multiview" :class="\'n\' + participants.filter(function(x){ return x.role !== \'director\'; }).length">\
          <div v-for="p in participants.filter(function(x){ return x.role !== \'director\'; })" :key="p.id"\
               class="cr-feed" :class="{ spotlight: remoteMap[\'participant_\' + p.id] && remoteMap[\'participant_\' + p.id].speaking }">\
            <div :data-director-feed="\'participant_\' + p.id" style="width:100%;height:100%;"></div>\
            <div class="cr-feed-label">{{ p.display_name }}<span v-if="readyMap[\'participant_\' + p.id]" class="cr-feed-ready"> · LISTO</span></div>\
          </div>\
        </div>\
        <div v-if="connected" class="cr-m-status m-only">\
          <span v-if="recording" class="cr-m-rec">● GRABANDO</span>\
          <span v-else-if="countdown !== null" class="cr-m-rec">Empieza en {{ countdown }}</span>\
          <span v-else-if="hostCount === 0">Esperando a los anfitriones</span>\
          <span v-else-if="allParticipantsReady" style="color:var(--signal);">Todos preparados · puedes grabar</span>\
          <span v-else>Preparados {{ readyCount }} de {{ hostCount }}</span>\
          <span v-for="ov in activeOverlays" :key="ov.event_id" class="active-overlay-pill" @click="removeOverlay(ov)">{{ ov.event_type }} ✕</span>\
        </div>\
      </div>\
\
      <div class="cr-right">\
        <div class="cr-sheet-head">\
          <button :class="{ on: dTab === \'cintillos\' }" @click="openDTab(\'cintillos\')">Cintillos</button>\
          <button :class="{ on: dTab === \'cues\' }" @click="openDTab(\'cues\')">Cues</button>\
          <button :class="{ on: dTab === \'mas\' }" @click="openDTab(\'mas\')">Más</button>\
          <div class="spacer"></div>\
          <button class="cr-close" @click="dTab = null">Cerrar</button>\
        </div>\
        <div class="cr-sec cr-sec-cintillos">\
        <div class="eyebrow" style="padding:0 0 6px 2px;">CINTILLOS</div>\
\
        <div class="cr-tabs" style="display:flex;gap:4px;margin-bottom:8px;">\
          <button v-for="t in [[\'sponsor\',\'Sponsor\'],[\'podcast\',\'Podcast\'],[\'segment\',\'Segmento\'],[\'otros\',\'Otros\']]" :key="t[0]"\
                  class="ghost" style="flex:1;font-size:10px;padding:5px 2px;"\
                  :style="cin.tab === t[0] ? \'background:var(--accent);color:#1a1410;font-weight:700;\' : \'\'"\
                  @click="cin.tab = t[0]">{{ t[1] }}</button>\
        </div>\
\
        <div class="cr-section"><div class="cr-section-body">\
          <template v-if="cin.tab === \'sponsor\'">\
            <div v-if="!branding.sponsors.length" class="muted" style="font-size:11px;margin-bottom:6px;">Este episodio no tiene sponsors en prePod.</div>\
            <div v-else class="form-row">\
              <select v-model.number="cin.sponsorIdx" class="input" style="font-size:11px;padding:4px 6px;">\
                <option v-for="(sp, i) in branding.sponsors" :key="i" :value="i">{{ sp.name }}</option>\
              </select>\
            </div>\
            <div class="form-row"><input v-model="cin.text" placeholder="Texto del sponsor (editable)" class="input" /></div>\
          </template>\
          <template v-else-if="cin.tab === \'podcast\'">\
            <div class="form-row"><input v-model="cin.podTitle" placeholder="Título (nombre del podcast)" class="input" /></div>\
            <div class="form-row"><input v-model="cin.text" placeholder="Texto del momento" class="input" /></div>\
          </template>\
          <template v-else-if="cin.tab === \'segment\'">\
            <div class="form-row"><input v-model="cin.segTitle" placeholder="Título del segmento" class="input" /></div>\
            <div class="form-row"><input v-model="cin.segSubtitle" placeholder="Subtítulo" class="input" /></div>\
          </template>\
\
          <template v-if="cin.tab !== \'otros\'">\
            <div class="form-row">\
              <select v-model.number="cin.duration" class="input" style="font-size:11px;padding:4px 6px;">\
                <option :value="8">8 segundos</option>\
                <option :value="15">15 segundos</option>\
                <option :value="30">30 segundos</option>\
                <option :value="0">Hasta quitarlo</option>\
              </select>\
            </div>\
            <div class="cintillo-preview" style="margin:6px 0 0;height:56px;overflow:visible;">\
              <div class="cintillo" :class="cinPreview.event_type">\
                <div v-if="cinPreview.logo" class="c-logo"><img :src="cinPreview.logo" alt=""></div>\
                <div class="c-bars" style="min-width:180px;max-width:300px;">\
                  <div class="c-title" style="font-size:13px;">{{ cintilloTitle(cinPreview) || \'Título\' }}</div>\
                  <div v-if="cintilloText(cinPreview)" class="c-text" style="font-size:11px;">{{ cintilloText(cinPreview) }}</div>\
                </div>\
              </div>\
            </div>\
            <button class="cr-inject-btn" @click="airCintillo()" :disabled="cin.busy" style="margin-top:6px;">\
              {{ cin.busy ? "Subiendo logo…" : "📡 Poner al aire" }}\
            </button>\
          </template>\
\
          <template v-else>\
            <select v-model="injectType" class="input" style="font-size:11px;padding:4px 6px;margin-bottom:6px;">\
              <option value="comment">Comentario</option>\
              <option value="countdown">Countdown</option>\
            </select>\
            <template v-if="injectType === \'comment\'">\
              <div class="form-row"><input v-model="injectFields.author" placeholder="@usuario" class="input" /></div>\
              <div class="form-row"><input v-model="injectFields.text" placeholder="Texto del comentario" class="input" /></div>\
            </template>\
            <template v-else>\
              <div class="form-row"><input v-model.number="injectFields.seconds" type="number" placeholder="Segundos" class="input" /></div>\
              <div class="form-row"><input v-model="injectFields.label" placeholder="Etiqueta" class="input" /></div>\
            </template>\
            <button class="cr-inject-btn" @click="injectOverlay()">Inyectar {{ injectType }}</button>\
          </template>\
        </div></div>\
\
        <div v-if="activeOverlays.length" style="margin-top:8px;">\
          <div class="eyebrow" style="padding:0 0 4px 2px;">AL AIRE AHORA</div>\
          <div v-for="ov in activeOverlays" :key="ov.event_id" class="active-overlay-pill" style="margin-bottom:4px;cursor:pointer;" @click="removeOverlay(ov)" title="Quitar del aire">\
            {{ ov.event_type }} · {{ cintilloTitle(ov) || (ov.payload && (ov.payload.label || ov.payload.author)) || \'\' }} ✕\
          </div>\
        </div>\
        </div>\
\
        <div class="cr-sec cr-sec-cues">\
        <div class="eyebrow" style="padding:10px 0 6px 2px;">CUES</div>\
        <div style="margin-bottom:6px;">\
          <select v-model="cueTarget" class="input" style="font-size:11px;padding:4px 6px;">\
            <option value="all">Todos los hosts</option>\
            <option v-for="p in participants.filter(function(x){ return x.role === \'host\' || x.role === \'co-host\'; })" :key="p.id"\
                    :value="\'participant_\' + p.id">{{ p.display_name }}</option>\
          </select>\
        </div>\
        <div class="cr-cues">\
          <button class="cr-cue-btn wrap-up" @click="sendCue(\'CERRAR TEMA\')">CERRAR TEMA</button>\
          <button class="cr-cue-btn next-topic" @click="sendCue(\'SIGUIENTE TEMA\')">SIGUIENTE TEMA</button>\
          <button class="cr-cue-btn break" @click="sendCue(\'PAUSA\')">PAUSA</button>\
          <button class="cr-cue-btn speed-up" @click="sendCue(\'MÁS RÁPIDO\')">MÁS RÁPIDO</button>\
          <button class="cr-cue-btn slow-down" @click="sendCue(\'MÁS LENTO\')">MÁS LENTO</button>\
          <button class="cr-cue-btn ad-read" @click="sendCue(\'LEER ANUNCIO\')">LEER ANUNCIO</button>\
        </div>\
        <label style="display:flex;align-items:center;gap:6px;margin-top:8px;font-size:11px;color:var(--paper-dim);cursor:pointer;">\
          <input type="checkbox" :checked="guestCuesVisible" @change="toggleGuestCues" style="margin:0;" />\
          Invitados ven cues\
        </label>\
        </div>\
        <div class="cr-section">\
        <div class="eyebrow" style="padding:10px 0 6px 2px;">TELEPROMPTER</div>\
        <div style="display:flex;gap:6px;margin-bottom:6px;">\
          <select v-model="tpForm.target" class="input" style="font-size:11px;padding:4px 6px;flex:1;">\
            <option value="all">A todos</option>\
            <option v-for="p in participants" :key="\'tp\' + p.id" :value="\'participant_\' + p.id">{{ p.display_name }}</option>\
          </select>\
          <select v-if="branding.sponsors.length" v-model="tpSponsorIdx" @change="tpUseSponsor" class="input" style="font-size:11px;padding:4px 6px;flex:1;">\
            <option :value="-1">Texto de un sponsor…</option>\
            <option v-for="(sp, i) in branding.sponsors" :key="\'tps\' + i" :value="i">{{ sp.name }}</option>\
          </select>\
        </div>\
        <input v-model="tpForm.title" class="input" placeholder="Título (p. ej. Publicidad de Loma Verde)" style="font-size:11px;padding:4px 6px;margin-bottom:6px;width:100%;box-sizing:border-box;" />\
        <textarea v-model="tpForm.text" class="input" rows="4" placeholder="Texto que va a leer…" style="font-size:12px;padding:6px;width:100%;box-sizing:border-box;margin-bottom:6px;"></textarea>\
        <div style="display:flex;gap:6px;align-items:center;margin-bottom:6px;font-size:11px;color:var(--paper-dim);">\
          <select v-model="tpForm.speed" class="input" style="font-size:11px;padding:3px 5px;"><option value="slow">lenta</option><option value="normal">normal</option><option value="fast">rápida</option></select>\
          <select v-model="tpForm.size" class="input" style="font-size:11px;padding:3px 5px;"><option value="quarter">un cuarto</option><option value="half">media pantalla</option><option value="full">toda la pantalla</option></select>\
          <label style="display:flex;align-items:center;gap:4px;">aviso <input v-model.number="tpForm.countdown" type="number" min="0" max="10" class="input" style="width:44px;font-size:11px;padding:3px 5px;" /> s</label>\
        </div>\
        <div style="display:flex;gap:6px;">\
          <button class="cr-cue-btn ad-read" style="flex:1;" @click="sendTeleprompter">🎬 LANZAR TELEPROMPTER</button>\
          <button class="ghost" @click="hideTeleprompter" :disabled="!tpLastId" title="Quitar el teleprompter de las pantallas">Quitar</button>\
        </div>\
        <div class="muted" style="font-size:10px;margin-top:4px;">Todos ven el aviso con cuenta regresiva; el texto solo le aparece a quien elijas.</div>\
        </div>\
\
        <div class="cr-sec cr-sec-mas">\
        <div class="eyebrow" style="padding:10px 0 6px 2px;">SUBIDAS</div>\
        <div v-if="Object.keys(participantUploads).length === 0" style="font-size:11px;color:var(--paper-dim);">Sin datos aún</div>\
        <div v-for="(u, id) in participantUploads" :key="id" style="display:flex;align-items:center;gap:6px;margin-bottom:4px;font-size:11px;">\
          <span>{{ id.replace(\'participant_\', \'P\') }}</span>\
          <span v-if="u.state === \'streaming\'" style="color:var(--accent);">↑ {{ (u.bytes / (1024*1024)).toFixed(1) }} MB</span>\
          <span v-else-if="u.state === \'done\'" style="color:#6c6;font-weight:700;">✓ {{ (u.bytes / (1024*1024)).toFixed(1) }} MB</span>\
          <span v-else-if="u.state === \'error\'" style="color:#f66;font-weight:700;">✕ Error</span>\
          <span v-else style="color:var(--paper-dim);">{{ u.state }}</span>\
        </div>\
        <button v-if="!recording && allUploadsComplete" class="ghost" :disabled="exporting" @click="exportToPostpod"\
                style="margin-top:8px;width:100%;font-size:11px;padding:6px 0;border:1px solid var(--accent);border-radius:var(--r-sm);color:var(--accent);">\
          {{ exporting ? "enviando…" : "↗ Enviar a postPod" }}\
        </button>\
        <div v-if="exportStatus" style="font-size:10px;margin-top:4px;color:var(--paper-dim);">{{ exportStatus }}</div>\
\
        <div class="eyebrow" style="padding:10px 0 6px 2px;">SOUNDBOARD</div>\
        <div class="cr-sounds" style="display:grid;grid-template-columns:1fr 1fr;gap:4px;">\
          <button v-for="s in sessionSounds" :key="s.id" class="ghost"\
                  :style="\'background:\' + (playingPad[s.id] ? \'rgba(255,255,255,0.15)\' : (s.color || \'var(--ink-sunken)\')) + \';font-size:10px;padding:8px 4px;border-radius:var(--r-sm);color:#fff;text-shadow:0 1px 2px rgba(0,0,0,0.5);\'"\
                  @click="triggerSound(s)">{{ s.name }}</button>\
        </div>\
        <div v-if="directorSounds.length" style="margin-top:6px;">\
          <div class="eyebrow" style="padding:0 0 4px 2px;font-size:9px;color:var(--signal-cyan);">DIRECTOR ONLY</div>\
          <div class="cr-sounds" style="display:grid;grid-template-columns:1fr 1fr;gap:4px;">\
            <button v-for="s in directorSounds" :key="s.id" class="ghost"\
                    :style="\'border:1px solid var(--signal-cyan);background:\' + (playingPad[s.id] ? \'rgba(255,255,255,0.15)\' : (s.color || \'var(--ink-sunken)\')) + \';font-size:10px;padding:8px 4px;border-radius:var(--r-sm);color:#fff;text-shadow:0 1px 2px rgba(0,0,0,0.5);\'"\
                    @click="triggerSound(s)">{{ s.name }}</button>\
          </div>\
        </div>\
        <div class="cr-m-only-block">\
          <div class="eyebrow" style="padding:14px 0 6px 2px;">SALA</div>\
          <div v-for="st in streams" :key="st.id" class="stream-badge" :class="st.status === \'active\' ? \'live\' : \'off\'" style="margin-bottom:6px;">\
            {{ st.platform || "RTMP" }} {{ st.status === "active" ? "LIVE" : st.status }}\
          </div>\
          <button v-if="connected" class="ghost" style="width:100%;" @click="disconnect(); dTab = null;">Desconectar del Control Room</button>\
        </div>\
        </div>\
      </div>\
\
      <div class="cr-bottom">\
        <span v-if="recording" style="color:var(--signal);font-weight:700;font-family:var(--font-mono);font-size:12px;margin-right:8px;">● REC</span>\
        <div class="timecode">{{ formatTC(timecode) }}</div>\
        <div v-for="st in streams" :key="st.id" class="stream-badge" :class="st.status === \'active\' ? \'live\' : \'off\'">\
          {{ st.platform || "RTMP" }} {{ st.status === "active" ? "LIVE" : st.status }}\
        </div>\
        <div class="spacer"></div>\
        <div v-for="ov in activeOverlays" :key="ov.event_id" class="active-overlay-pill">\
          {{ ov.event_type }}\
        </div>\
      </div>\
\
      <div class="cr-mbar">\
        <button class="cr-mbtn cr-mbtn-ptt" :class="{ active: ifbActive }" :disabled="!connected"\
                @mousedown="startIFB(\'all_hosts\')" @mouseup="stopIFB()" @mouseleave="ifbActive && stopIFB()"\
                @touchstart.prevent="startIFB(\'all_hosts\')" @touchend.prevent="stopIFB()" @touchcancel="stopIFB()" @contextmenu.prevent>\
          <span class="cr-mico">🎧</span><span class="cr-mtxt">{{ ifbActive ? "Hablando…" : "Hablar" }}</span></button>\
        <button class="cr-mbtn" :class="{ on: dTab === \'cintillos\' }" @click="openDTab(\'cintillos\')"><span class="cr-mico">🏷️</span><span class="cr-mtxt">Cintillos</span><span v-if="activeOverlays.length" class="cr-mbadge">{{ activeOverlays.length }}</span></button>\
        <button class="cr-mbtn" :class="{ on: dTab === \'cues\' }" @click="openDTab(\'cues\')"><span class="cr-mico">🚦</span><span class="cr-mtxt">Cues</span></button>\
        <button class="cr-mbtn" :class="{ on: dTab === \'personas\' }" @click="openDTab(\'personas\')"><span class="cr-mico">👥</span><span class="cr-mtxt">Gente</span></button>\
        <button class="cr-mbtn" :class="{ on: dTab === \'chat\' }" @click="openDTab(\'chat\')"><span class="cr-mico">💬</span><span class="cr-mtxt">Chat</span><span v-if="dChatUnread" class="cr-mbadge">{{ dChatUnread }}</span></button>\
        <button class="cr-mbtn" :class="{ on: dTab === \'mas\' }" @click="openDTab(\'mas\')"><span class="cr-mico">⋯</span><span class="cr-mtxt">Más</span></button>\
      </div>\
    </div>\
  ',
};


// ----- Toast notifications -----
// Global, app-wide. Anything in the app can call window.toast({type, text, ms}).
// Lives in a singleton store at window.__toasts so it survives reactive scopes.
var ToastHost = {
  setup: function () {
    var items = ref(window.__toasts ? window.__toasts.list : []);
    if (!window.__toasts) {
      var list = ref([]);
      var nextId = 1;
      window.__toasts = {
        list: list,
        push: function (opts) {
          var id = nextId++;
          var t = Object.assign({ id: id, type: "info", text: "", ms: 4000 }, opts || {});
          list.value = list.value.concat(t);
          if (t.ms > 0) setTimeout(function () { window.__toasts.dismiss(id); }, t.ms);
          return id;
        },
        dismiss: function (id) {
          list.value = list.value.filter(function (x) { return x.id !== id; });
        },
      };
      window.toast = function (opts) {
        if (typeof opts === "string") opts = { text: opts };
        return window.__toasts.push(opts);
      };
      items = window.__toasts.list;
    }
    function dismiss(id) { window.__toasts.dismiss(id); }
    return { items: items, dismiss: dismiss };
  },
  template: `
    <div class="toast-host">
      <div v-for="t in items" :key="t.id" class="toast" :class="'toast-' + (t.type || 'info')"
           @click="dismiss(t.id)">
        <span v-if="t.type === 'success'">✓</span>
        <span v-else-if="t.type === 'error'">⚠</span>
        <span v-else-if="t.type === 'warn'">!</span>
        <span v-else>•</span>
        <span class="toast-text">{{ t.text }}</span>
      </div>
    </div>
  `,
};

var App = {
  components: {
    LoginView: LoginView, DashboardView: DashboardView,
    StudioView: StudioView, InviteView: InviteView, GuestStudioView: GuestStudioView,
    DirectorDashboard: DirectorDashboard, DirectorView: DirectorView,
    ToastHost: ToastHost,
  },
  setup: function () {
    var state = reactive({
      loading: true, user: null, route: "dashboard",
      currentSession: null, inviteToken: null, joinData: null,
    });
    var anyRecording = ref(false);
    var siblingApps = ref(null);
    var thepodUrl = ref("");

    function parseRoute() {
      var path = window.location.pathname;
      var m = path.match(/^\/invite\/([A-Za-z0-9_-]+)/);
      if (m) { state.inviteToken = m[1]; state.route = "invite"; return; }
      state.route = "dashboard";
    }

    async function checkAuth() {
      try { state.user = await api("/api/auth/me"); }
      catch (_) { state.user = null; }
      finally { state.loading = false; }
    }
    async function loadApps() {
      try {
        var d = await api("/api/config/apps");
        siblingApps.value = d.apps.filter(function (a) { return a.key !== d.current; });
        thepodUrl.value = d.thepod_url || "";
      } catch (_) {}
    }
    async function logout() {
      try { await api("/api/auth/logout", { method: "POST" }); } catch (_) {}
      state.user = null; state.currentSession = null;
    }
    var isDirector = ref(false);
    async function checkDirectorStatus() {
      try {
        var podcasts = await api("/api/director/my-podcasts");
        isDirector.value = podcasts.length > 0;
      } catch (_) {}
    }

    function onLoggedIn(u) { state.user = u; state.route = "dashboard"; checkDirectorStatus(); }
    function openSession(s) { state.currentSession = s; state.route = "studio"; }
    function onJoined(data) { state.joinData = data; }
    function openDirectorDash() { state.route = "director-dashboard"; }
    function onOpenDirector(s) { state.currentSession = s; state.route = "director"; }

    onMounted(function () {
      parseRoute();
      checkAuth().then(function () { if (state.user) checkDirectorStatus(); });
      loadApps();
      // Poll any live video element to update tally
      setInterval(function () {
        var v = document.querySelector(".studio-top.recording");
        anyRecording.value = !!v;
      }, 250);
    });

    return { state: state, anyRecording: anyRecording, siblingApps: siblingApps, thepodUrl: thepodUrl,
             isDirector: isDirector, onLoggedIn: onLoggedIn,
             openSession: openSession, onJoined: onJoined, logout: logout,
             openDirectorDash: openDirectorDash, onOpenDirector: onOpenDirector,
             backToDash: function () { state.route = "dashboard"; state.currentSession = null; } };
  },
  template: `
    <template v-if="state.loading">
      <div class="login-wrapper"><div class="muted">Cargando estudio…</div></div>
    </template>
    <template v-else-if="state.route === 'invite' && state.inviteToken">
      <template v-if="state.joinData">
        <GuestStudioView :join-data="state.joinData" :invite-token="state.inviteToken" />
      </template>
      <template v-else>
        <InviteView :token="state.inviteToken" :on-joined="onJoined" />
      </template>
    </template>
    <template v-else-if="!state.user">
      <LoginView :on-logged-in="onLoggedIn" />
    </template>
    <template v-else>
      <header class="app-header">
        <div class="brand">
          <a :href="thepodUrl || '#'" class="mark" title="Ir a thePod">prod<em>Pod</em></a>
          <span class="tag d-only">live booth · v0.1</span>
        </div>
        <div class="sibling-apps d-only" v-if="siblingApps">
          <a v-for="a in siblingApps" :key="a.key" :href="a.url" class="sibling-link" :title="'Ir a ' + a.name">
            <span class="ico" :data-app="a.key"></span>
            <span>{{ a.name }}</span>
          </a>
        </div>
        <div class="tally d-only" :class="{ live: anyRecording }">
          <span class="dot"></span>
          <span>{{ anyRecording ? 'ON AIR' : 'STANDBY' }}</span>
        </div>
        <div class="spacer"></div>
        <div v-if="state.route === 'studio'" class="d-only">
          <button class="ghost" @click="backToDash">← Sesiones</button>
        </div>
        <button v-if="isDirector && state.route !== 'director-dashboard' && state.route !== 'director'"
                class="ghost" style="color: var(--signal-cyan);" @click="openDirectorDash">🎬 Director</button>
        <div class="user-chip">
          <span class="tiny d-only">OP</span>
          <span class="name">{{ state.user.display_name || state.user.username }}</span>
          <button class="ghost" @click="logout">Salir</button>
        </div>
      </header>
      <StudioView v-if="state.route === 'studio'" :session="state.currentSession" :user="state.user" :on-back="backToDash" />
      <DirectorView v-else-if="state.route === 'director'" :session="state.currentSession" :user="state.user" :on-back="function() { state.route = 'director-dashboard'; state.currentSession = null; }" />
      <DirectorDashboard v-else-if="state.route === 'director-dashboard'" :user="state.user" :on-open-director="onOpenDirector" :on-back="backToDash" />
      <DashboardView v-else :on-open="openSession" />
    </template>
    <ToastHost />
  `,
};

createApp(App).mount("#app");
