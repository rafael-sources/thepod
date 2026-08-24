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
        <button class="ghost" @click="triggerImport" :disabled="importing" style="margin-right:8px;">
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
            <button class="ghost" style="font-size:11px;padding:3px 8px;" @click="exportSession(s, $event)">↓ Exportar</button>
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

/* Track-based recorder: records a MediaStream into a single webm blob. */
function _startRecorder(stream, onComplete, timesliceMs, audioOnly) {
  var types = audioOnly
    ? ["audio/webm;codecs=opus", "audio/webm"]
    : ["video/webm;codecs=vp9,opus", "video/webm;codecs=vp8,opus", "video/webm"];
  var mime = types.find(function (t) { return window.MediaRecorder && MediaRecorder.isTypeSupported(t); });
  var rec = new MediaRecorder(stream, mime ? { mimeType: mime } : {});
  var chunks = [];
  rec.ondataavailable = function (e) { if (e.data && e.data.size) chunks.push(e.data); };
  rec.onstop = function () {
    var blob = new Blob(chunks, { type: mime || (audioOnly ? "audio/webm" : "video/webm") });
    onComplete(blob);
  };
  rec.start(timesliceMs || 1000);
  return rec;
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
        var constraints = {
          video: (useStored && deviceSelection.cameraId)
            ? { deviceId: { exact: deviceSelection.cameraId } } : true,
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
    var localCamOff = ref(false);
    var connected = ref(false);
    var localMeter = ref(0);
    var localSpeaking = ref(false);
    var localMeterStop = null;
    var layoutMode = ref("grid");   // "grid" | "spotlight"
    var spotlightId = ref(null);    // identity of the spotlighted participant (or "__local__")

    // ---- Director signals (host receives these) ----
    var activeOverlays = reactive([]);
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
    var qualityPreset = ref(localStorage.getItem("prodpod.qualityPreset") || "med");
    watch(qualityPreset, function (v) {
      localStorage.setItem("prodpod.qualityPreset", v);
    });
    function _qualityCaptureOpts() {
      if (qualityPreset.value === "low")  return { width: 640,  height: 360, frameRate: 24 };
      if (qualityPreset.value === "high") return { width: 1280, height: 720, frameRate: 30 };
      return { width: 854, height: 480, frameRate: 24 };
    }
    function _qualityPublishLayers() {
      if (qualityPreset.value === "low") return [
        { width: 320, height: 180, encoding: { maxBitrate: 100000, maxFramerate: 12 } },
      ];
      if (qualityPreset.value === "high") return [
        { width: 320, height: 180, encoding: { maxBitrate: 200000, maxFramerate: 15 } },
        { width: 640, height: 360, encoding: { maxBitrate: 700000, maxFramerate: 24 } },
      ];
      return [
        { width: 320, height: 180, encoding: { maxBitrate: 150000, maxFramerate: 15 } },
        { width: 640, height: 360, encoding: { maxBitrate: 500000, maxFramerate: 24 } },
      ];
    }
    function _qualityMaxBitrate() {
      if (qualityPreset.value === "low")  return 600000;
      if (qualityPreset.value === "high") return 2500000;
      return 1200000;
    }
    var myIdentity = ref("");
    var readyMap = reactive({});     // identity -> bool
    var ownReady = ref(false);
    var countdown = ref(null);       // null | 3 | 2 | 1 | 0
    var countdownHandle = null;

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

      // Local MediaRecorder for the upload to postPod.
      try {
        screenRecorder = _startRecorder(
          screenStream,
          function (blob) { uploadRecording(blob, "screen"); },
          1000
        );
      } catch (e) {
        // Best-effort — keep the share going even if recording fails.
        screenRecorder = null;
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
        try { screenRecorder.stop(); } catch (_) {}
        screenRecorder = null;
      }
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
      } else if (msg.type === "ready_toggle") {
        readyMap[msg.identity] = !!msg.ready;
        // Host (session creator) decides when to fire the countdown
        if (props.user.username === props.session.created_by) maybeFireCountdown();
      } else if (msg.type === "countdown_start") {
        beginCountdown(msg.start_at_ms);
      } else if (msg.type === "recording_stop") {
        finishRecording();
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
        activeOverlays.push({ event_id: msg.event_id, event_type: msg.event_type, payload: msg.payload, file_path: msg.file_path });
      } else if (msg.type === "overlay_remove") {
        var idx = activeOverlays.findIndex(function (o) { return o.event_id === msg.event_id; });
        if (idx !== -1) activeOverlays.splice(idx, 1);
      } else if (msg.type === "director_cue") {
        var cueMap = { "WRAP UP": "wrap-up", "NEXT TOPIC": "next-topic", "BREAK": "break", "SPEED UP": "speed-up", "SLOW DOWN": "slow-down", "AD READ": "ad-read", "CUSTOM": "custom" };
        if (msg.target === "all" || msg.target === myIdentity.value) {
          activeCue.value = { cue: msg.cue, text: msg.text || "", cssClass: cueMap[msg.cue] || "custom" };
          clearTimeout(cueTimer);
          cueTimer = setTimeout(function () { activeCue.value = null; }, 6000);
        }
      } else if (msg.type === "ifb_start") {
        if (msg.targets === "all_hosts" || (Array.isArray(msg.targets) && msg.targets.indexOf(myIdentity.value) !== -1)) {
          ifbActive.value = true;
        }
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
          "Esta sesión ya finalizó. Podés ver y exportar las grabaciones, pero no se puede volver a entrar al estudio.",
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
          videoCaptureDefaults: { resolution: _qualityCaptureOpts() },
          publishDefaults: {
            simulcast: true,
            videoSimulcastLayers: _qualityPublishLayers(),
            videoCodec: "vp8",
            videoEncoding: {
              maxBitrate: _qualityMaxBitrate(),
              maxFramerate: _qualityCaptureOpts().frameRate,
            },
          },
        });

        newRoom.on(LK.RoomEvent.ParticipantConnected, function (p) {
          var name = p.name || p.identity;
          if (p.identity && p.identity.startsWith("director_")) {
            directorConnected.value = true;
            if (window.toast) window.toast({ type: "info", text: "Director conectado" });
          } else {
            if (window.toast) window.toast({ type: "info", text: name + " entró al estudio" });
          }
          _maybeBrowserNotify(name + " entró al estudio");
          loadParticipants();
        });
        newRoom.on(LK.RoomEvent.TrackSubscribed, function (track, pub, participant) {
          var id = participant.identity;
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
          if (track.kind === LK.Track.Kind.Audio && pub && pub.trackName === "ifb_audio") {
            var ifbEl = track.attach();
            ifbEl.dataset.ifb = "1";
            ifbEl.volume = 1.0;
            document.body.appendChild(ifbEl);
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
          if (pub && pub.trackName === "ifb_audio") {
            track.detach().forEach(function (el) { el.remove(); });
            ifbActive.value = false;
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

        // Apply mic-check gain (if any) by re-routing the published mic
        // track through a Web Audio GainNode. We replaceTrack on LiveKit's
        // LocalAudioTrack so peers see the same publication ID — no
        // re-negotiation. Skip for ≈0 dB to avoid the extra graph.
        var savedMicGainDb = _readMicGainFor(deviceSelection.micId);
        if (micPub && micPub.track && Math.abs(savedMicGainDb) > 0.5) {
          try {
            var rawTrack = micPub.track.mediaStreamTrack;
            var ACg = window.AudioContext || window.webkitAudioContext;
            micGainCtx = new ACg();
            var gSrc = micGainCtx.createMediaStreamSource(new MediaStream([rawTrack]));
            var gNode = micGainCtx.createGain();
            gNode.gain.value = Math.pow(10, savedMicGainDb / 20);
            var gDest = micGainCtx.createMediaStreamDestination();
            gSrc.connect(gNode).connect(gDest);
            var processed = gDest.stream.getAudioTracks()[0];
            await micPub.track.replaceTrack(processed);
          } catch (_) {
            // Fall through silently — peers still hear the unprocessed mic.
            try { if (micGainCtx) micGainCtx.close(); } catch (__) {}
            micGainCtx = null;
          }
        }

        var camTrack = camPub && camPub.track ? camPub.track.mediaStreamTrack : null;
        var micTrack = micPub && micPub.track ? micPub.track.mediaStreamTrack : null;
        if (camTrack && micTrack) localStream = new MediaStream([camTrack, micTrack]);
        else if (camTrack)        localStream = new MediaStream([camTrack]);
        if (micTrack) {
          localMeterStop = _attachMeter({ mediaStreamTrack: micTrack }, function (lvl) {
            localMeter.value = lvl;
          });
        }

        room = newRoom;
        connected.value = true;     // first: makes the participants-grid render
        await nextTick();           // wait for <video ref="localVideoEl"> to mount
        if (localVideoEl.value && camPub && camPub.track) {
          try { camPub.track.attach(localVideoEl.value); } catch (_) {}
        }

        await loadParticipants();
        await loadChat();
      } catch (e) {
        error.value = "No se pudo conectar al estudio: " + e.message;
      } finally {
        busy.value = false;
      }
    }

    async function disconnect() {
      // Full state cleanup so a stale session never survives into a new one.
      stopLocalRecorders();
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
    }
    async function toggleCam() {
      if (!room) return;
      var next = !localCamOff.value;
      await room.localParticipant.setCameraEnabled(!next);
      localCamOff.value = next;
    }

    /* ---------- recording (ready + countdown + sync start) ---------- */

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
    }

    function startLocalRecorders() {
      if (!recorder && localStream) {
        recorder = _startRecorder(localStream, function (blob) { uploadRecording(blob, "video"); }, 1000);
      }
    }

    function stopLocalRecorders() {
      if (recorder) { try { recorder.stop(); } catch (_) {} recorder = null; }
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

    async function uploadRecording(blob, trackType) {
      if (practiceMode.value) return;  // ensayo: descartar el blob
      try {
        var ext = (trackType === "soundboard") ? "webm" : "webm";
        var form = new FormData();
        form.append("file", blob, trackType + "." + ext);
        form.append("track_type", trackType);
        form.append("duration_seconds", String(timecode.value));
        await fetch("/api/sessions/" + props.session.id + "/recordings", {
          method: "POST", credentials: "same-origin", body: form,
        });
      } catch (e) { error.value = "upload falló: " + e.message; }
    }

    function toggleReady() {
      if (recording.value || countdown.value !== null) return;
      ownReady.value = !ownReady.value;
      readyMap[myIdentity.value] = ownReady.value;
      sendData({ type: "ready_toggle", identity: myIdentity.value, ready: ownReady.value });
      if (props.user.username === props.session.created_by) maybeFireCountdown();
    }

    async function stopRecording() {
      if (!recording.value) return;
      try {
        if (props.user.username === props.session.created_by) {
          try { await api("/api/sessions/" + props.session.id + "/stop", { method: "POST" }); } catch (_) {}
        }
        sendData({ type: "recording_stop" });
        finishRecording();
      } catch (e) { error.value = e.message; }
    }

    function finishRecording() {
      if (!recording.value) return;
      recording.value = false;
      if (!practiceMode.value) sessionEnded.value = true;
      if (timerHandle) { clearInterval(timerHandle); timerHandle = null; }
      stopLocalRecorders();
      flushTriggerLog();
      recordingStartedAtMs = null;
      // Restore the original tab title
      document.title = props.session.title + " — prodPod";
      // Clear ready state — no new take in this session
      ownReady.value = false;
      Object.keys(readyMap).forEach(function (k) { delete readyMap[k]; });
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

    async function kickParticipant(p) {
      if (!await podSwal.confirm("¿Quitar a " + p.display_name + "?")) return;
      try {
        // Signal first so they disconnect gracefully
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
    });
    onBeforeUnmount(function () {
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
      toggleMute: toggleMute, toggleCam: toggleCam,
      toggleReady: toggleReady, stopRecording: stopRecording,
      ownReady: ownReady, readyMap: readyMap, countdown: countdown, myIdentity: myIdentity,
      showInvite: showInvite, inviteForm: inviteForm, inviteLinks: inviteLinks,
      createInvite: createInvite, copyInvite: copyInvite, kickParticipant: kickParticipant,
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
      qualityPreset: qualityPreset,
      handsRaised: handsRaised, ownHandUp: ownHandUp, toggleHand: toggleHand,
      screenSharing: screenSharing, screenRecordOnly: screenRecordOnly, remoteScreen: remoteScreen,
      askStartScreenShare: askStartScreenShare, stopScreenShare: stopScreenShare,
      layoutMode: layoutMode, spotlightId: spotlightId, toggleLayout: toggleLayout,
      spotlightParticipant: spotlightParticipant, pinSpotlight: pinSpotlight,
      activeOverlays: activeOverlays, activeCue: activeCue, ifbActive: ifbActive, directorConnected: directorConnected,
      amaPanel: amaPanel, amaEmbedUrl: amaEmbedUrl, amaEventId: amaEventId, amaBusy: amaBusy,
      startAma: startAma, closeAma: closeAma,
    };
  },
  template: `
    <div class="studio">
      <div class="studio-top" :class="{ recording: recording }">
        <button class="ghost" @click="safeBack">← Sesiones</button>
        <h3>{{ session.title }}</h3>
        <span class="badge-id">#{{ session.id }}</span>
        <div class="spacer"></div>
        <div class="timecode mono">{{ formatTC(timecode) }}</div>
        <div v-if="connected" class="vu-master">
          <span class="vu-label">MIC</span>
          <div class="vu-h" :style="'--vu:' + localMeter"></div>
        </div>
        <span v-if="ifbActive" class="ifb-indicator">🎧 Director hablándote...</span>
        <span v-if="directorConnected" class="director-badge">🎬 Director</span>
        <label v-if="!recording && countdown === null && isHost" class="practice-toggle"
               :title="'En modo ensayo nada se sube al servidor — solo prueba.'">
          <input type="checkbox" v-model="practiceMode">
          <span>Ensayo</span>
        </label>
        <span v-if="practiceMode" class="rehearsal-badge">🟡 ENSAYO</span>
        <select v-if="!connected" v-model="qualityPreset" class="quality-pick"
                title="Calidad de captura — más alto = más CPU">
          <option value="low">Baja 360p</option>
          <option value="med">Media 480p</option>
          <option value="high">Alta 720p</option>
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
        <button v-if="connected" class="ghost" style="margin-right: 8px;"
                :class="{ primary: ownHandUp }" @click="toggleHand"
                title="Levantar/bajar la mano">✋</button>
        <button v-if="recording" class="ghost" style="margin-right: 8px;"
                @click="markChapter"
                title="Marcar momento durante la grabación">📍 Momento</button>
        <button v-if="recording" class="rec-btn" style="background: var(--signal); color: #fff;"
                @click="stopRecording" :disabled="!isHost" :title="isHost ? 'Detener' : 'Sólo el host puede detener'">
          ■ Detener
        </button>

        <span v-if="activeStreams.length" class="tally live" style="margin-left: 8px;" :title="activeStreams.length + ' stream(s) activos'">
          <span class="dot"></span>EN VIVO
        </span>
        <button v-if="connected && !screenSharing" class="ghost" style="margin-left: 8px;"
                :disabled="!!remoteScreen"
                :title="remoteScreen ? ('Ya está compartiendo ' + remoteScreen.name) : 'Compartir o grabar pantalla'"
                @click="askStartScreenShare">📺 Pantalla</button>
        <button v-if="connected && screenSharing" class="ghost" style="margin-left: 8px; background: rgba(255,59,59,0.16); color: #ff7373;"
                @click="stopScreenShare" :title="screenRecordOnly ? 'Detener (solo grabando local)' : 'Dejar de compartir'">
          ■ {{ screenRecordOnly ? 'Detener pantalla' : 'Dejar de compartir' }}
        </button>
        <button v-if="isHost && connected" class="ghost" style="margin-left: 8px;" @click="showStream = true" title="Transmitir a RTMP">📡 Stream</button>
        <button v-if="isHost" class="ghost" style="margin-left: 8px;" @click="showDiagnostic" title="Ver quién está conectado a la sala según LiveKit">🔍 Diagnóstico</button>
        <button v-if="!connected" class="primary" style="margin-left: 8px; padding: 6px 14px;" @click="connect" :disabled="busy" title="Conectar este navegador a la sala de LiveKit">
          {{ busy ? "Conectando…" : "🟢 Conectar" }}
        </button>
      </div>

      <div v-if="activeCue" class="director-cue" :class="activeCue.cssClass">
        {{ activeCue.cue }}
        <div v-if="activeCue.text" style="font-size: 13px; font-weight: 400; margin-top: 4px;">{{ activeCue.text }}</div>
      </div>

      <div v-if="activeOverlays.length" class="director-overlay">
        <div v-for="ov in activeOverlays" :key="ov.event_id" class="overlay-card" :class="ov.event_type">
          <template v-if="ov.event_type === 'banner'">
            <div class="ov-name">{{ ov.payload.name }}</div>
            <div class="ov-title">{{ ov.payload.title }}</div>
          </template>
          <template v-else-if="ov.event_type === 'segment'">
            <div class="ov-title">{{ ov.payload.title }}</div>
            <div class="ov-subtitle">{{ ov.payload.subtitle }}</div>
          </template>
          <template v-else-if="ov.event_type === 'comment'">
            <div class="ov-author">{{ ov.payload.author }} · {{ ov.payload.platform }}</div>
            <div class="ov-text">{{ ov.payload.text }}</div>
          </template>
          <template v-else-if="ov.event_type === 'countdown'">
            <div class="ov-label">{{ ov.payload.label }}</div>
            <div class="ov-timer">{{ ov.payload.seconds }}s</div>
          </template>
          <template v-else-if="ov.event_type === 'sponsor'">
            <div class="ov-sponsor-name">{{ ov.payload.sponsor_name }}</div>
            <div class="ov-title">{{ ov.payload.sponsor_copy }}</div>
          </template>
          <template v-else-if="ov.event_type === 'graphic'">
            <img v-if="ov.file_path" :src="'/api/sessions/' + session.id + '/director/assets/' + ov.file_path.split('/').pop()" />
            <div v-if="ov.payload.caption" class="ov-title">{{ ov.payload.caption }}</div>
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
              <h3 style="margin: 0 0 4px;">Probá tu equipo antes de entrar</h3>
              <p class="muted" style="margin: 0 0 18px; font-size: 12px;">
                Hablá frente al mic y mirá que el medidor responda. Al entrar conectás a la sesión con estos dispositivos.
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

              <div class="mic-check-panel" style="margin: 0 0 18px; padding: 12px; border: 1px solid var(--ink-line); border-radius: 8px; background: var(--ink-sunken, rgba(0,0,0,0.18));">
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

              <button class="primary" @click="connect" :disabled="busy" style="width: 100%; padding: 14px;">
                {{ busy ? "Conectando…" : "🎙 Entrar al estudio" }}
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
            <template v-for="p in participants.filter(pp => pp.username !== user.username && pp.status === 'connected')" :key="'side-' + p.id">
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
          </div>

          <div v-for="p in participants.filter(pp => pp.username !== user.username && pp.status === 'connected')"
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
              <button v-if="isHost" class="btn-export"
                      :class="{ exported: allExported }"
                      :disabled="exporting || !finishedRecordings.length" @click="exportToPostpod"
                      title="Enviar pistas a postPod para editar">
                {{ exporting ? "↗ enviando…" : allExported ? "✓ Ya enviado a postPod" : "↗ Enviar a postPod" }}
              </button>
            </div>
          </div>
          <div v-if="exportStatus" class="export-status">{{ exportStatus }}</div>
          <div v-if="!finishedRecordings.length" class="muted" style="padding: 12px; text-align: center;">
            Aún no llegaron pistas al servidor. Esperá unos segundos y dale ↻ Recargar.
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

      <aside class="studio-side">
        <div>
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

        <div>
          <div class="sb-head">
            <span class="label">Participantes</span>
            <span class="tiny">{{ participants.length }}/{{ session.max_participants }}</span>
            <div class="spacer"></div>
            <button class="icon ghost" @click="showInvite = true" title="Invitar">＋</button>
          </div>
          <div v-for="p in participants" :key="p.id" class="invite-row">
            <span class="who">{{ p.display_name }}</span>
            <span class="status-chip" :class="p.status">{{ p.status }}</span>
            <button v-if="p.username !== user.username" class="icon danger" @click="kickParticipant(p)" title="Quitar">✕</button>
          </div>
        </div>

        <div v-if="inviteLinks.length">
          <div class="sb-head"><span class="label">Links generados</span></div>
          <div v-for="l in inviteLinks" :key="l.invite_token" class="invite-row" style="cursor: pointer;" @click="copyInvite(l)" title="Click para copiar">
            <span class="who">{{ l.invite_url }}</span>
            <span class="join-pill">copiar</span>
          </div>
        </div>

        <div v-if="sponsorMarkers.length" class="sponsor-teleprompter">
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

        <div style="flex: 1; display: flex; flex-direction: column; min-height: 200px;">
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

      <div class="controls-bar">
        <button v-if="connected" :class="{ muted: localMuted }" @click="toggleMute">{{ localMuted ? "🔇" : "🎤" }}</button>
        <button v-if="connected" :class="{ 'cam-off': localCamOff }" @click="toggleCam">{{ localCamOff ? "📷" : "🎥" }}</button>
        <button v-if="connected" class="layout-toggle" @click="toggleLayout" :title="layoutMode === 'grid' ? 'Cambiar a vista de speaker' : 'Cambiar a grilla'">{{ layoutMode === 'grid' ? '◫' : '⊞' }}</button>
        <button v-if="connected && isHost" @click="amaPanel ? closeAma() : startAma()" :disabled="amaBusy" :class="{ primary: amaPanel }" title="Q&A con audiencia">❓ AMA</button>
        <div class="spacer"></div>
        <span v-if="connected" class="join-pill">EN VIVO · {{ (participants.filter(p => p.status === 'connected').length) }} conectado(s)</span>
        <button v-if="connected" class="ghost" @click="disconnect">Salir del estudio</button>
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
        props.onJoined(r);
      } catch (e) { error.value = e.message; }
      finally { busy.value = false; }
    }

    onMounted(load);
    onBeforeUnmount(stopPolling);

    return { invite, error, busy, name, waitingForHost, join };
  },
  template: `
    <div class="login-wrapper">
      <div class="login-card" style="width: 440px;">
        <div class="eyebrow">INVITACIÓN · LIVE BOOTH</div>
        <h2 v-if="invite">{{ invite.session_title }}</h2>
        <h2 v-else>Cargando…</h2>
        <div v-if="invite && !invite.expired" class="subtitle">{{ invite.session_description || "Te invitaron a grabar en prodPod." }}</div>

        <!-- Session expired -->
        <div v-if="invite && invite.expired" style="text-align: center; padding: 20px 0;">
          <div style="font-size: 32px; margin-bottom: 12px;">⏹</div>
          <p style="font-size: 15px; color: var(--paper-dim);">Esta sesión ya finalizó.<br>La invitación ya no es válida.</p>
        </div>

        <!-- Waiting for host -->
        <div v-else-if="waitingForHost" style="text-align: center; padding: 20px 0;">
          <div style="font-size: 32px; margin-bottom: 12px;">⏳</div>
          <p style="font-size: 15px; color: var(--paper-dim);">Esperando a que el host se conecte…</p>
          <p style="font-size: 12px; color: var(--paper-dim); margin-top: 8px;">La página se actualizará automáticamente.</p>
        </div>

        <!-- Ready to join -->
        <template v-else-if="invite && !invite.expired">
          <div v-if="error" class="error">{{ error }}</div>
          <div class="form-row">
            <label>Tu nombre</label>
            <input type="text" v-model="name" placeholder="Cómo quieres aparecer">
          </div>
          <button class="primary" :disabled="busy || !name.trim()" @click="join" style="width:100%; margin-top: 12px; padding: 12px;">
            {{ busy ? "Entrando…" : "🎙 Entrar al estudio" }}
          </button>
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
    var error = ref("");
    var busy = ref(false);
    var connectStep = ref("");
    var connected = ref(false);
    var localMuted = ref(false);
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

    var sounds = ref([]);
    var audioPool = {};
    var playingPad = ref(null);
    var chat = ref([]);
    var chatInput = ref("");

    var triggerLog = [];
    var recordingStartedAtMs = null;
    var practiceMode = ref(localStorage.getItem("prodpod.practiceMode") === "1");
    watch(practiceMode, function (v) {
      localStorage.setItem("prodpod.practiceMode", v ? "1" : "0");
    });
    var myIdentity = ref("");
    var readyMap = reactive({});
    var ownReady = ref(false);
    var countdown = ref(null);
    var countdownHandle = null;

    // Director state
    var activeOverlays = reactive([]);
    var activeCue = ref(null);
    var cueTimer = null;
    var ifbActive = ref(false);
    var directorConnected = ref(false);

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
      } else if (msg.type === "countdown_start") {
        beginCountdown(msg.start_at_ms);
      } else if (msg.type === "recording_stop") {
        finishRecording();
      } else if (msg.type === "practice_mode") {
        practiceMode.value = !!msg.active;
      } else if (msg.type === "kick" && room && room.localParticipant &&
                 msg.target_identity === room.localParticipant.identity) {
        error.value = "El host te desconectó.";
        leave();
      } else if (msg.type === "overlay_inject") {
        activeOverlays.push({ event_id: msg.event_id, event_type: msg.event_type, payload: msg.payload });
      } else if (msg.type === "overlay_remove") {
        var oi = activeOverlays.findIndex(function (o) { return o.event_id === msg.event_id; });
        if (oi !== -1) activeOverlays.splice(oi, 1);
      } else if (msg.type === "director_cue") {
        activeCue.value = msg;
        if (cueTimer) clearTimeout(cueTimer);
        cueTimer = setTimeout(function () { activeCue.value = null; }, 8000);
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

    function beginRecordingNow() {
      recording.value = true;
      recordingStartedAtMs = Date.now();
      triggerLog = [];
      timecode.value = 0;
      if (timerHandle) clearInterval(timerHandle);
      var start = recordingStartedAtMs;
      timerHandle = setInterval(function () { timecode.value = (Date.now() - start) / 1000; }, 250);
      if (!recorder && localStream) {
        recorder = _startRecorder(localStream, function (blob) { uploadRecording(blob, "video"); }, 1000);
      }
    }

    function finishRecording() {
      if (!recording.value) return;
      recording.value = false;
      if (timerHandle) { clearInterval(timerHandle); timerHandle = null; }
      if (recorder) { try { recorder.stop(); } catch (_) {} recorder = null; }
      flushTriggerLog();
      recordingStartedAtMs = null;
      ownReady.value = false;
      Object.keys(readyMap).forEach(function (k) { delete readyMap[k]; });
    }

    function toggleReady() {
      if (recording.value || countdown.value !== null) return;
      ownReady.value = !ownReady.value;
      readyMap[myIdentity.value] = ownReady.value;
      sendData({ type: "ready_toggle", identity: myIdentity.value, ready: ownReady.value });
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

    async function uploadRecording(blob, trackType) {
      try {
        var form = new FormData();
        form.append("file", blob, trackType + ".webm");
        form.append("track_type", trackType);
        form.append("token", props.inviteToken);
        form.append("duration_seconds", String(timecode.value));
        await fetch("/api/sessions/" + props.joinData.session_id + "/recordings?token=" + encodeURIComponent(props.inviteToken), {
          method: "POST", body: form,
        });
      } catch (e) { error.value = e.message; }
    }

    async function connect() {
      if (!LK) { error.value = "LiveKit client no cargado"; busy.value = false; return; }
      busy.value = true;
      error.value = "";
      connectStep.value = "preparando…";
      try {
        myIdentity.value = "participant_" + props.joinData.participant_id;
        var newRoom = new LK.Room({
          adaptiveStream: true,
          dynacast: true,
          videoCaptureDefaults: {
            resolution: { width: 854, height: 480, frameRate: 24 },
          },
          publishDefaults: {
            simulcast: true,
            videoSimulcastLayers: [
              { width: 320, height: 180, encoding: { maxBitrate: 150_000,  maxFramerate: 15 } },
              { width: 640, height: 360, encoding: { maxBitrate: 500_000,  maxFramerate: 24 } },
            ],
            videoCodec: "vp8",
            videoEncoding: { maxBitrate: 1_200_000, maxFramerate: 24 },
          },
        });
        newRoom.on(LK.RoomEvent.TrackSubscribed, function (track, pub, participant) {
          var id = participant.identity;
          if (track.kind === LK.Track.Kind.Audio && pub.trackName === "ifb_audio") {
            var ifbEl = track.attach(); ifbEl.volume = 1.0;
            ifbEl.id = "ifb-audio-guest";
            document.body.appendChild(ifbEl);
            return;
          }
          if (id.startsWith("director_")) return;
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
          if (p.identity.startsWith("director_")) directorConnected.value = true;
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

        connectStep.value = "1/4 conectando WebSocket a LiveKit…";
        await withTimeout(
          newRoom.connect(props.joinData.livekit_ws_url, props.joinData.livekit_token),
          15000,
          "WebSocket a LiveKit"
        );

        connectStep.value = "2/4 pidiendo permiso de micrófono…";
        var micPub = null, camPub = null;
        try { micPub = await withTimeout(newRoom.localParticipant.setMicrophoneEnabled(true), 30000, "Permiso de micrófono"); }
        catch (me) { error.value = me.message; }

        connectStep.value = "3/4 pidiendo permiso de cámara…";
        try { camPub = await withTimeout(newRoom.localParticipant.setCameraEnabled(true), 30000, "Permiso de cámara"); }
        catch (ce) { error.value = (error.value ? error.value + " · " : "") + ce.message; }

        connectStep.value = "4/4 montando streams locales…";

        var camTrack = camPub && camPub.track ? camPub.track.mediaStreamTrack : null;
        var micTrack = micPub && micPub.track ? micPub.track.mediaStreamTrack : null;
        if (camTrack && micTrack) localStream = new MediaStream([camTrack, micTrack]);
        else if (camTrack) localStream = new MediaStream([camTrack]);
        if (micTrack) {
          localMeterStop = _attachMeter({ mediaStreamTrack: micTrack }, function (lvl) { localMeter.value = lvl; });
        }

        room = newRoom;
        connected.value = true;
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
    }
    async function toggleCam() {
      if (!room) return;
      var next = !localCamOff.value;
      await room.localParticipant.setCameraEnabled(!next);
      localCamOff.value = next;
    }
    async function leave() {
      if (recorder) { try { recorder.stop(); } catch (_) {} recorder = null; }
      if (countdownHandle) { clearTimeout(countdownHandle); countdownHandle = null; }
      if (localMeterStop) { localMeterStop(); localMeterStop = null; }
      // Disconnect first (LK stops its tracks cleanly), then drop the
      // wrapper without re-stopping tracks — see StudioView rationale.
      if (room) { try { await room.disconnect(); } catch (_) {} }
      localStream = null;
      window.location.href = "/";
    }

    onMounted(function () { loadSounds(); });
    onBeforeUnmount(function () { if (timerHandle) clearInterval(timerHandle); if (room) room.disconnect().catch(function () {}); });

    return { localVideoEl: localVideoEl, error: error, busy: busy, connected: connected,
             localMuted: localMuted, localCamOff: localCamOff, remoteMap: remoteMap,
             localMeter: localMeter, recording: recording, timecode: timecode, formatTC: formatTC,
             sounds: sounds, playingPad: playingPad, triggerSound: triggerSound,
             chat: chat, chatInput: chatInput, sendChat: sendChat,
             connect: connect, connectStep: connectStep, toggleMute: toggleMute, toggleCam: toggleCam, leave: leave, initials: initials,
             toggleReady: toggleReady, ownReady: ownReady, readyMap: readyMap, countdown: countdown,
             myIdentity: myIdentity, practiceMode: practiceMode,
             activeOverlays: activeOverlays, activeCue: activeCue, ifbActive: ifbActive, directorConnected: directorConnected };
  },
  template: `
    <div class="studio">
      <div class="studio-top" :class="{ recording: recording }">
        <h3>{{ joinData.display_name }} · invitado</h3>
        <span class="badge-id">{{ joinData.role }}</span>
        <div class="spacer"></div>
        <div v-if="recording" class="timecode mono">{{ formatTC(timecode) }}</div>
        <div v-if="connected" class="vu-master">
          <span class="vu-label">MIC</span>
          <div class="vu-h" :style="'--vu:' + localMeter"></div>
        </div>
        <button v-if="connected && !recording && countdown === null" class="primary rec-btn"
                @click="toggleReady"
                :style="ownReady ? 'background: var(--signal); color:#fff;' : ''">
          {{ ownReady ? "✓ Listo" : "● Prepararse" }}
        </button>
        <span v-if="practiceMode" class="rehearsal-badge">🟡 ENSAYO</span>
        <span v-if="connected && recording" class="tally live"><span class="dot"></span>ON AIR</span>
      </div>
      <div class="studio-main">
        <div v-if="error" class="error" style="font-size: 16px; padding: 14px; background: #5a1a1a; color: #fff; border: 2px solid red;">⚠️ {{ error }}</div>
        <div v-if="!connected && !busy" class="prejoin">
          <div class="prejoin-card">
            <div class="prejoin-controls" style="text-align: center;">
              <h3 style="margin: 0 0 6px;">{{ joinData.display_name }}, listo para entrar</h3>
              <p class="muted" style="margin: 0 0 18px; font-size: 12px;">
                Activa cámara y micrófono para conectarte al estudio. Vas a poder probar todo antes de que empiecen a grabar.
              </p>
              <button class="primary" @click="connect" style="width: 100%; padding: 14px;">
                🎙 Activar cámara y entrar
              </button>
            </div>
          </div>
        </div>
        <div v-else-if="busy" class="muted" style="text-align:center; padding: 60px;">{{ connectStep || "Pidiendo permisos…" }}</div>
        <div v-else class="participants-grid">
          <div class="participant-card">
            <video ref="localVideoEl" autoplay muted playsinline></video>
            <div v-if="localCamOff" class="initials" style="position:absolute;">{{ initials(joinData.display_name) }}</div>
            <div class="label">
              <span>{{ joinData.display_name }}</span>
              <span class="role-chip">TÚ</span>
              <span v-if="ownReady && !recording" class="role-chip" style="background: var(--signal); color:#fff;">LISTO</span>
            </div>
            <div v-if="localMuted" class="muted-icon">🔇</div>
            <div class="vu" :style="'--vu:' + localMeter"></div>
          </div>
          <div v-for="(t, id) in remoteMap" :key="id" class="participant-card">
            <div :data-remote-id="id" style="width:100%; height:100%;"></div>
            <div class="label">
              <span>{{ t.name || id }}</span>
              <span v-if="readyMap[id] && !recording" class="role-chip" style="background: var(--signal); color:#fff;">LISTO</span>
            </div>
            <div class="vu" :style="'--vu:' + (t.meter || 0)"></div>
          </div>
        </div>
        <div v-if="countdown !== null" class="countdown-overlay">
          <div class="countdown-num">{{ countdown > 0 ? countdown : '●' }}</div>
          <div class="countdown-label">{{ countdown > 0 ? 'preparándose…' : 'GRABANDO' }}</div>
        </div>
        <div v-if="activeOverlays.length" class="director-overlay">
          <div v-for="ov in activeOverlays" :key="ov.event_id" class="overlay-card" :class="'overlay-' + ov.event_type">
            <template v-if="ov.event_type === 'banner'">
              <div class="ov-name">{{ ov.payload.name }}</div><div class="ov-title">{{ ov.payload.title }}</div>
            </template>
            <template v-else-if="ov.event_type === 'segment'">
              <div class="ov-name">{{ ov.payload.title }}</div><div class="ov-title">{{ ov.payload.subtitle }}</div>
            </template>
            <template v-else-if="ov.event_type === 'comment'">
              <div class="ov-name">{{ ov.payload.author }}</div><div class="ov-title">{{ ov.payload.text }}</div>
            </template>
            <template v-else-if="ov.event_type === 'sponsor'">
              <div class="ov-name">{{ ov.payload.sponsor_name }}</div><div class="ov-title">{{ ov.payload.sponsor_copy }}</div>
            </template>
            <template v-else>
              <div class="ov-name">{{ ov.event_type }}</div>
            </template>
          </div>
        </div>
        <div v-if="activeCue" class="director-cue" :class="(activeCue.cue || '').toLowerCase().replace(/ /g, '-')">
          {{ activeCue.cue }}
        </div>
      </div>
      <aside class="studio-side">
        <div>
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
        <div style="flex: 1; display: flex; flex-direction: column; min-height: 200px;">
          <div class="sb-head"><span class="label">Chat</span><span class="tiny">{{ chat.length }}</span></div>
          <div id="guest-chat-scroll" style="flex: 1; overflow-y: auto; background: var(--ink-sunken); border: 1px solid var(--ink-line); border-radius: var(--r-md); padding: 8px; margin-bottom: 6px; min-height: 100px; font-size: 12px;">
            <div v-for="m in chat" :key="m.id" style="margin-bottom: 6px;">
              <strong style="color: var(--signal);">{{ m.author }}:</strong>
              <span style="color: var(--paper);">{{ m.text }}</span>
            </div>
          </div>
          <div style="display: flex; gap: 4px;">
            <input type="text" v-model="chatInput" @keyup.enter="sendChat" placeholder="Mensaje..." style="flex: 1; font-size: 12px; padding: 6px 10px;">
            <button class="primary" @click="sendChat" :disabled="!chatInput.trim()" style="padding: 6px 12px;">↑</button>
          </div>
        </div>
      </aside>
      <div class="controls-bar">
        <button v-if="connected" :class="{ muted: localMuted }" @click="toggleMute">{{ localMuted ? "🔇" : "🎤" }}</button>
        <button v-if="connected" :class="{ 'cam-off': localCamOff }" @click="toggleCam">{{ localCamOff ? "📷" : "🎥" }}</button>
        <span v-if="ifbActive" class="ifb-indicator">IFB</span>
        <span v-if="directorConnected" class="director-badge">Director conectado</span>
        <div class="spacer"></div>
        <button class="ghost" @click="leave">Salir</button>
      </div>
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

    // Injection forms
    var injectType = ref("banner");
    var injectFields = reactive({
      name: "", title: "", subtitle: "",
      sponsor_name: "", sponsor_copy: "",
      author: "", text: "", platform: "youtube",
      seconds: 180, label: "Volvemos en",
      caption: "",
    });

    // Cue target
    var cueTarget = ref("all");

    // Soundboard
    var sounds = ref([]);
    var playingPad = reactive({});

    // Collapsed sections
    var expandedSection = ref("banner");

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

    // --- Overlay injection ---
    async function injectOverlay() {
      var payload = {};
      var t = injectType.value;
      if (t === "banner") payload = { name: injectFields.name, title: injectFields.title };
      else if (t === "segment") payload = { title: injectFields.title, subtitle: injectFields.subtitle };
      else if (t === "comment") payload = { author: injectFields.author, text: injectFields.text, platform: injectFields.platform };
      else if (t === "countdown") payload = { seconds: injectFields.seconds, label: injectFields.label };
      else if (t === "sponsor") payload = { sponsor_name: injectFields.sponsor_name, sponsor_copy: injectFields.sponsor_copy };
      else if (t === "graphic") payload = { caption: injectFields.caption };

      try {
        var res = await api("/api/sessions/" + props.session.id + "/director/inject", {
          method: "POST", body: { event_type: t, payload: payload },
        });
        sendData({ type: "overlay_inject", event_type: t, payload: payload, event_id: res.event_id });
        activeOverlays.push({ event_id: res.event_id, event_type: t, payload: payload });
        if (window.toast) window.toast({ type: "success", text: "Overlay inyectado" });
      } catch (e) {
        if (window.toast) window.toast({ type: "error", text: e.message });
      }
    }

    async function removeOverlay(ov) {
      try {
        await api("/api/sessions/" + props.session.id + "/director/events/" + ov.event_id + "/remove", { method: "POST" });
        sendData({ type: "overlay_remove", event_id: ov.event_id });
        var idx = activeOverlays.findIndex(function (o) { return o.event_id === ov.event_id; });
        if (idx !== -1) activeOverlays.splice(idx, 1);
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

    // --- IFB Push-to-Talk ---
    var ifbStream = null;
    var ifbTrack = null;
    var ifbActive = ref(false);

    async function startIFB(targets) {
      sendData({ type: "ifb_start", targets: targets });
      ifbActive.value = true;
      try {
        ifbStream = await navigator.mediaDevices.getUserMedia({ audio: true });
        var audioTrack = ifbStream.getAudioTracks()[0];
        ifbTrack = new LK.LocalAudioTrack(audioTrack);
        await room.localParticipant.publishTrack(ifbTrack, { name: "ifb_audio", stream: "ifb", source: LK.Track.Source.Microphone });
      } catch (e) {
        if (window.toast) window.toast({ type: "error", text: "No se pudo activar el micrófono IFB: " + e.message });
        ifbActive.value = false;
      }
    }

    function stopIFB() {
      sendData({ type: "ifb_stop" });
      ifbActive.value = false;
      if (ifbTrack) {
        try { room.localParticipant.unpublishTrack(ifbTrack); } catch (_) {}
        ifbTrack.stop();
        ifbTrack = null;
      }
      if (ifbStream) {
        ifbStream.getTracks().forEach(function (t) { t.stop(); });
        ifbStream = null;
      }
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

    async function loadDirectorChat() {
      try {
        directorChat.value = await api("/api/sessions/" + props.session.id + "/chat?channel=director");
      } catch (_) {}
    }

    async function sendDirectorChat() {
      var text = (directorChatInput.value || "").trim();
      if (!text) return;
      try {
        var msg = await api("/api/sessions/" + props.session.id + "/chat", {
          method: "POST", body: { text: text, channel: "director" },
        });
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

    onMounted(function () { loadParticipants(); loadStreams(); loadSounds(); loadDirectorChat(); });
    onBeforeUnmount(function () { disconnect(); });

    return {
      error: error, connected: connected, connect: connect, disconnect: disconnect,
      participants: participants, remoteMap: remoteMap,
      activeOverlays: activeOverlays, removeOverlay: removeOverlay,
      timecode: timecode, formatTC: formatTC, streams: streams,
      injectType: injectType, injectFields: injectFields, injectOverlay: injectOverlay,
      expandedSection: expandedSection,
      sendCue: sendCue, cueTarget: cueTarget,
      forceMute: forceMute, kickParticipant: kickParticipant,
      sounds: sounds, sessionSounds: sessionSounds, directorSounds: directorSounds, triggerSound: triggerSound, playingPad: playingPad,
      ifbActive: ifbActive, startIFB: startIFB, stopIFB: stopIFB,
      directorChat: directorChat, directorChatInput: directorChatInput, sendDirectorChat: sendDirectorChat,
    };
  },
  template: '\
    <div class="control-room">\
      <div class="cr-top">\
        <button class="ghost" @click="$props.onBack" style="flex-shrink:0;">← Sesiones</button>\
        <h3 style="margin:0;">{{ session.title }}</h3>\
        <span class="badge-id">#{{ session.id }}</span>\
        <div class="spacer"></div>\
        <div class="timecode">{{ formatTC(timecode) }}</div>\
        <div v-for="st in streams" :key="st.id" class="stream-badge" :class="st.status === \'active\' ? \'live\' : \'off\'">\
          {{ st.platform || "RTMP" }} {{ st.status === "active" ? "LIVE" : st.status }}\
        </div>\
        <button v-if="!connected" class="primary" @click="connect" style="flex-shrink:0;">🟢 Conectar</button>\
        <button v-else class="ghost" @click="disconnect" style="flex-shrink:0;">Desconectar</button>\
      </div>\
\
      <div class="cr-left">\
        <div class="eyebrow" style="padding:0 0 6px 2px;">PARTICIPANTES</div>\
        <div v-for="p in participants.filter(function(x){ return x.role !== \'director\'; })" :key="p.id" class="cr-participant">\
          <div class="cr-p-head">\
            <div class="cr-p-thumb" :data-director-feed="\'participant_\' + p.id"></div>\
            <div class="cr-p-info">\
              <div class="cr-p-name">{{ p.display_name }}</div>\
              <div class="cr-p-role">{{ p.role }}</div>\
            </div>\
          </div>\
          <div class="cr-p-actions">\
            <button class="ghost" @click="forceMute(p)" title="Mutear" style="font-size:12px;">🔇</button>\
            <button class="ghost" @click="kickParticipant(p)" title="Expulsar" style="font-size:12px; color:var(--signal);">✕</button>\
          </div>\
        </div>\
\
        <div class="eyebrow" style="padding:10px 0 6px 2px;">IFB AUDIO</div>\
        <button class="ptt-btn ptt-btn-all" :class="{ active: ifbActive }"\
                @mousedown="startIFB(\'all_hosts\')" @mouseup="stopIFB()" @mouseleave="ifbActive && stopIFB()">🎧 PTT TODOS</button>\
        <div v-for="p in participants.filter(function(x){ return x.role === \'host\' || x.role === \'co-host\'; })" :key="\'ptt-\' + p.id" style="margin-bottom:4px;">\
          <button class="ptt-btn" style="width:100%;"\
                  @mousedown="startIFB([\'participant_\' + p.id])" @mouseup="stopIFB()" @mouseleave="ifbActive && stopIFB()">🎧 {{ p.display_name }}</button>\
        </div>\
\
        <div class="eyebrow" style="padding:10px 0 6px 2px;">DIRECTOR CHAT</div>\
        <div style="max-height:160px;overflow-y:auto;margin-bottom:6px;" id="director-chat-scroll">\
          <div v-for="m in directorChat" :key="m.id" style="font-size:11px;margin-bottom:4px;">\
            <span style="font-weight:600;color:var(--signal-cyan);">{{ m.author }}:</span> {{ m.text }}\
          </div>\
          <div v-if="!directorChat.length" style="font-size:11px;color:var(--paper-dim);">Sin mensajes aún.</div>\
        </div>\
        <div style="display:flex;gap:4px;">\
          <input v-model="directorChatInput" placeholder="Mensaje..." class="input" style="flex:1;font-size:11px;padding:5px 8px;"\
                 @keyup.enter="sendDirectorChat" />\
          <button class="ghost" style="font-size:11px;padding:5px 8px;" @click="sendDirectorChat">Enviar</button>\
        </div>\
      </div>\
\
      <div class="cr-center">\
        <div v-if="!connected" style="display:flex;align-items:center;justify-content:center;height:100%;color:var(--paper-dim);font-family:var(--font-mono);font-size:13px;">\
          Conecta al Control Room para ver los feeds\
        </div>\
        <div v-else class="cr-multiview">\
          <div v-for="p in participants.filter(function(x){ return x.role !== \'director\'; })" :key="p.id"\
               class="cr-feed" :class="{ spotlight: remoteMap[\'participant_\' + p.id] && remoteMap[\'participant_\' + p.id].speaking }">\
            <div :data-director-feed="\'participant_\' + p.id" style="width:100%;height:100%;"></div>\
            <div class="cr-feed-label">{{ p.display_name }}</div>\
          </div>\
        </div>\
      </div>\
\
      <div class="cr-right">\
        <div class="eyebrow" style="padding:0 0 6px 2px;">INYECTAR OVERLAY</div>\
\
        <div class="cr-section">\
          <div class="cr-section-head" @click="expandedSection = expandedSection === \'banner\' ? \'\' : \'banner\'">BANNER ▾</div>\
          <div v-if="expandedSection === \'banner\'" class="cr-section-body">\
            <div class="form-row"><input v-model="injectFields.name" placeholder="Nombre" class="input" /></div>\
            <div class="form-row"><input v-model="injectFields.title" placeholder="Título" class="input" /></div>\
            <button class="cr-inject-btn" @click="injectType = \'banner\'; injectOverlay()">Inyectar Banner</button>\
          </div>\
        </div>\
\
        <div class="cr-section">\
          <div class="cr-section-head" @click="expandedSection = expandedSection === \'segment\' ? \'\' : \'segment\'">SEGMENTO ▾</div>\
          <div v-if="expandedSection === \'segment\'" class="cr-section-body">\
            <div class="form-row"><input v-model="injectFields.title" placeholder="Título segmento" class="input" /></div>\
            <div class="form-row"><input v-model="injectFields.subtitle" placeholder="Subtítulo" class="input" /></div>\
            <button class="cr-inject-btn" @click="injectType = \'segment\'; injectOverlay()">Inyectar Segmento</button>\
          </div>\
        </div>\
\
        <div class="cr-section">\
          <div class="cr-section-head" @click="expandedSection = expandedSection === \'comment\' ? \'\' : \'comment\'">COMENTARIO ▾</div>\
          <div v-if="expandedSection === \'comment\'" class="cr-section-body">\
            <div class="form-row"><input v-model="injectFields.author" placeholder="@usuario" class="input" /></div>\
            <div class="form-row"><input v-model="injectFields.text" placeholder="Texto del comentario" class="input" /></div>\
            <button class="cr-inject-btn" @click="injectType = \'comment\'; injectOverlay()">Inyectar Comentario</button>\
          </div>\
        </div>\
\
        <div class="cr-section">\
          <div class="cr-section-head" @click="expandedSection = expandedSection === \'countdown\' ? \'\' : \'countdown\'">COUNTDOWN ▾</div>\
          <div v-if="expandedSection === \'countdown\'" class="cr-section-body">\
            <div class="form-row"><input v-model.number="injectFields.seconds" type="number" placeholder="Segundos" class="input" /></div>\
            <div class="form-row"><input v-model="injectFields.label" placeholder="Etiqueta" class="input" /></div>\
            <button class="cr-inject-btn" @click="injectType = \'countdown\'; injectOverlay()">Inyectar Countdown</button>\
          </div>\
        </div>\
\
        <div class="cr-section">\
          <div class="cr-section-head" @click="expandedSection = expandedSection === \'sponsor\' ? \'\' : \'sponsor\'">SPONSOR ▾</div>\
          <div v-if="expandedSection === \'sponsor\'" class="cr-section-body">\
            <div class="form-row"><input v-model="injectFields.sponsor_name" placeholder="Nombre sponsor" class="input" /></div>\
            <div class="form-row"><input v-model="injectFields.sponsor_copy" placeholder="Copy" class="input" /></div>\
            <button class="cr-inject-btn" @click="injectType = \'sponsor\'; injectOverlay()">Inyectar Sponsor</button>\
          </div>\
        </div>\
\
        <div v-if="activeOverlays.length" style="margin-top:8px;">\
          <div class="eyebrow" style="padding:0 0 4px 2px;">ACTIVOS</div>\
          <div v-for="ov in activeOverlays" :key="ov.event_id" class="active-overlay-pill" style="margin-bottom:4px;cursor:pointer;" @click="removeOverlay(ov)">\
            {{ ov.event_type }} ✕\
          </div>\
        </div>\
\
        <div class="eyebrow" style="padding:10px 0 6px 2px;">CUES</div>\
        <div style="margin-bottom:6px;">\
          <select v-model="cueTarget" class="input" style="font-size:11px;padding:4px 6px;">\
            <option value="all">Todos los hosts</option>\
            <option v-for="p in participants.filter(function(x){ return x.role === \'host\' || x.role === \'co-host\'; })" :key="p.id"\
                    :value="\'participant_\' + p.id">{{ p.display_name }}</option>\
          </select>\
        </div>\
        <div class="cr-cues">\
          <button class="cr-cue-btn wrap-up" @click="sendCue(\'WRAP UP\')">WRAP UP</button>\
          <button class="cr-cue-btn next-topic" @click="sendCue(\'NEXT TOPIC\')">NEXT TOPIC</button>\
          <button class="cr-cue-btn break" @click="sendCue(\'BREAK\')">BREAK</button>\
          <button class="cr-cue-btn speed-up" @click="sendCue(\'SPEED UP\')">SPEED UP</button>\
          <button class="cr-cue-btn slow-down" @click="sendCue(\'SLOW DOWN\')">SLOW DOWN</button>\
          <button class="cr-cue-btn ad-read" @click="sendCue(\'AD READ\')">AD READ</button>\
        </div>\
\
        <div class="eyebrow" style="padding:10px 0 6px 2px;">SOUNDBOARD</div>\
        <div style="display:grid;grid-template-columns:1fr 1fr;gap:4px;">\
          <button v-for="s in sessionSounds" :key="s.id" class="ghost"\
                  :style="\'background:\' + (playingPad[s.id] ? \'rgba(255,255,255,0.15)\' : (s.color || \'var(--ink-sunken)\')) + \';font-size:10px;padding:8px 4px;border-radius:var(--r-sm);\'"\
                  @click="triggerSound(s)">{{ s.name }}</button>\
        </div>\
        <div v-if="directorSounds.length" style="margin-top:6px;">\
          <div class="eyebrow" style="padding:0 0 4px 2px;font-size:9px;color:var(--signal-cyan);">DIRECTOR ONLY</div>\
          <div style="display:grid;grid-template-columns:1fr 1fr;gap:4px;">\
            <button v-for="s in directorSounds" :key="s.id" class="ghost"\
                    :style="\'border:1px solid var(--signal-cyan);background:\' + (playingPad[s.id] ? \'rgba(255,255,255,0.15)\' : (s.color || \'var(--ink-sunken)\')) + \';font-size:10px;padding:8px 4px;border-radius:var(--r-sm);\'"\
                    @click="triggerSound(s)">{{ s.name }}</button>\
          </div>\
        </div>\
      </div>\
\
      <div class="cr-bottom">\
        <div class="timecode">{{ formatTC(timecode) }}</div>\
        <div v-for="st in streams" :key="st.id" class="stream-badge" :class="st.status === \'active\' ? \'live\' : \'off\'">\
          {{ st.platform || "RTMP" }} {{ st.status === "active" ? "LIVE" : st.status }}\
        </div>\
        <div class="spacer"></div>\
        <div v-for="ov in activeOverlays" :key="ov.event_id" class="active-overlay-pill">\
          {{ ov.event_type }}\
        </div>\
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
          <span class="tag">live booth · v0.1</span>
        </div>
        <div class="sibling-apps" v-if="siblingApps">
          <a v-for="a in siblingApps" :key="a.key" :href="a.url" class="sibling-link" :title="'Ir a ' + a.name">
            <span class="ico">{{ a.icon }}</span>
            <span>{{ a.name }}</span>
          </a>
        </div>
        <div class="tally" :class="{ live: anyRecording }">
          <span class="dot"></span>
          <span>{{ anyRecording ? 'ON AIR' : 'STANDBY' }}</span>
        </div>
        <div class="spacer"></div>
        <div v-if="state.route === 'studio'">
          <button class="ghost" @click="backToDash">← Sesiones</button>
        </div>
        <button v-if="isDirector && state.route !== 'director-dashboard' && state.route !== 'director'"
                class="ghost" style="color: var(--signal-cyan);" @click="openDirectorDash">🎬 Director</button>
        <div class="user-chip">
          <span class="tiny">OP</span>
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
