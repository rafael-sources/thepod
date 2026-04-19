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
      if (!confirm("¿Eliminar sesión \"" + s.title + "\"? Se borran invitados y grabaciones.")) return;
      try { await api("/api/sessions/" + s.id, { method: "DELETE" }); await load(); }
      catch (e) { error.value = e.message; }
    }
    onMounted(load);
    return { sessions: sessions, loading: loading, error: error, showCreate: showCreate, form: form,
             creating: creating, create: create, remove: remove, fmtDate: fmtDate };
  },
  template: `
    <div class="container">
      <div class="page-head">
        <div>
          <div class="eyebrow">SESIONES · LIVE BOOTH</div>
          <h2>Studio <em style="color:var(--signal);font-style:italic;">live</em></h2>
        </div>
        <div class="spacer"></div>
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
        <div v-for="s in sessions" :key="s.id" class="session-tile" @click="$props.onOpen(s)">
          <span class="status" :class="s.status">{{ s.status }}</span>
          <h3>{{ s.title }}</h3>
          <div class="desc">{{ s.description || "—" }}</div>
          <div class="bottom">
            <span class="tiny">{{ fmtDate(s.created_at) }} · {{ s.max_participants }}p</span>
            <button class="danger" @click="remove(s, $event)">Eliminar</button>
          </div>
        </div>
      </div>

      <div v-if="showCreate" class="modal-backdrop" @click.self="showCreate = false">
        <div class="modal">
          <div class="eyebrow">NUEVA SESIÓN</div>
          <h3>Configurar grabación</h3>
          <p class="muted" style="margin-bottom:18px;">Cada sesión crea una sala WebRTC aislada. Vos sos el host y podés invitar hasta 4 participantes.</p>
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
  nextTick(function () {
    var host = document.querySelector('[data-remote-id="' + identity + '"]');
    if (host) { host.innerHTML = ""; host.appendChild(el); }
  });
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
    var recordingStart = ref(null);
    var timecode = ref(0);
    var timerHandle = null;

    var room = null;
    var localVideoEl = ref(null);
    var localStream = null;
    var localMuted = ref(false);
    var localCamOff = ref(false);
    var connected = ref(false);
    var localMeter = ref(0);
    var localMeterStop = null;
    var recorder = null;
    var soundboardRecorder = null;
    var soundboardCtx = null;
    var soundboardDest = null;
    var soundboardBuffers = {};      // filename -> AudioBuffer
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
    var soundLimits = reactive({ max_kb: 150, max_duration_seconds: 4, max_total: 15, allowed_exts: [".mp3", ".wav", ".ogg", ".m4a"] });
    var soundUploadStatus = ref("");
    var showAddSound = ref(false);
    var newSound = reactive({ name: "", shortcut_key: "", color: "#5a8bff" });

    var chat = ref([]);
    var chatInput = ref("");

    var finishedRecordings = ref([]);
    var exportStatus = ref("");
    var exporting = ref(false);

    // Live streams (RTMP to YouTube/Twitch via LiveKit Egress)
    var streams = ref([]);
    var rtmpPresets = ref([]);
    var showStream = ref(false);
    var streamForm = reactive({ platform: "", rtmp_url: "", stream_key: "" });
    var streamStatus = ref("");
    var streamBusy = ref(false);

    async function loadParticipants() {
      try { participants.value = await api("/api/sessions/" + props.session.id + "/participants"); }
      catch (e) { error.value = e.message; }
    }

    async function loadSounds() {
      try {
        sounds.value = await api("/api/sessions/" + props.session.id + "/sounds");
        audioPool = {};
        sounds.value.forEach(function (s) {
          if (!s.filename) return;
          var a = new Audio(s.url);
          a.preload = "auto";
          audioPool[s.filename] = a;
        });
        preloadSoundboardBuffers();
      } catch (e) { error.value = e.message; }
      try {
        var lim = await api("/api/sessions/" + props.session.id + "/sounds/limits");
        Object.assign(soundLimits, lim);
      } catch (_) {}
    }

    async function preloadSoundboardBuffers() {
      if (!soundboardCtx) {
        try {
          var AC = window.AudioContext || window.webkitAudioContext;
          soundboardCtx = new AC();
          soundboardDest = soundboardCtx.createMediaStreamDestination();
        } catch (_) { return; }
      }
      for (var i = 0; i < sounds.value.length; i++) {
        var s = sounds.value[i];
        if (!s.filename || soundboardBuffers[s.filename]) continue;
        try {
          var resp = await fetch(s.url);
          var buf = await resp.arrayBuffer();
          var ab = await soundboardCtx.decodeAudioData(buf);
          soundboardBuffers[s.filename] = ab;
        } catch (_) {}
      }
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
      } catch (e) { alert(e.message); }
    }

    async function deleteCustomPad(s) {
      if (!confirm("¿Eliminar el pad \"" + s.name + "\"?")) return;
      try {
        await api("/api/sessions/" + props.session.id + "/sounds/" + s.id, { method: "DELETE" });
        await loadSounds();
      } catch (e) { alert(e.message); }
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
        var msgs = await api("/api/sessions/" + props.session.id + "/chat");
        chat.value = msgs.map(function (m) { return { id: m.id, author: m.author_name, text: m.message_text, ts: m.timestamp }; });
      } catch (_) {}
    }

    async function loadRecordings() {
      try { finishedRecordings.value = await api("/api/sessions/" + props.session.id + "/recordings"); }
      catch (_) {}
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
      if (!confirm("¿Detener el stream en " + (s.platform || "plataforma") + "?")) return;
      try {
        await api("/api/sessions/" + props.session.id + "/streams/" + s.id, { method: "DELETE" });
        await loadStreams();
      } catch (e) { error.value = e.message; }
    }
    var activeStreams = computed(function () {
      return streams.value.filter(function (s) { return s.status === "active" || s.status === "starting"; });
    });

    async function exportToPostpod() {
      if (exporting.value) return;
      exporting.value = true;
      exportStatus.value = "enviando pistas a postPod…";
      try {
        var r = await api("/api/sessions/" + props.session.id + "/recordings/export-to-postpod", { method: "POST" });
        if (r.exported === 0 && r.failed === 0) {
          exportStatus.value = "sin pistas nuevas para enviar";
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
      try { a.currentTime = 0; a.play(); } catch (_) {}
      playingPad.value = s.key;
      setTimeout(function () { if (playingPad.value === s.key) playingPad.value = null; }, 400);
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
        chat.value.push({ id: msg.id, author: msg.author, text: msg.text, ts: msg.ts });
        scrollChatBottom();
      } else if (msg.type === "ready_toggle") {
        readyMap[msg.identity] = !!msg.ready;
        // Host (session creator) decides when to fire the countdown
        if (props.user.username === props.session.created_by) maybeFireCountdown();
      } else if (msg.type === "countdown_start") {
        beginCountdown(msg.start_at_ms);
      } else if (msg.type === "recording_stop") {
        finishRecording();
      } else if (msg.type === "kick" && room && room.localParticipant &&
                 msg.target_identity === room.localParticipant.identity) {
        error.value = "El host te desconectó.";
        disconnect();
      }
    }

    function triggerSound(s) {
      playLocalSound(s);
      // Record this trigger into our own soundboard track (remote triggers don't get recorded)
      var ab = soundboardBuffers[s.filename];
      if (ab && soundboardCtx && soundboardDest) {
        try {
          if (soundboardCtx.state === "suspended") soundboardCtx.resume();
          var src = soundboardCtx.createBufferSource();
          src.buffer = ab;
          src.connect(soundboardDest);
          src.start();
        } catch (_) {}
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
          method: "POST", body: { text: text },
        });
        chat.value.push({ id: saved.id, author: saved.author_name, text: saved.message_text, ts: saved.timestamp });
        sendData({ type: "chat", id: saved.id, author: saved.author_name, text: saved.message_text, ts: saved.timestamp });
        chatInput.value = "";
        scrollChatBottom();
      } catch (e) { error.value = e.message; }
    }

    async function connect() {
      if (!LK) { error.value = "LiveKit client no cargado"; return; }
      try {
        busy.value = true;
        var tokenData = await api("/api/sessions/" + props.session.id + "/my-token");
        myIdentity.value = "participant_" + tokenData.participant_id;
        var newRoom = new LK.Room({ adaptiveStream: true, dynacast: true });

        newRoom.on(LK.RoomEvent.TrackSubscribed, function (track, pub, participant) {
          var id = participant.identity;
          if (!remoteMap[id]) remoteMap[id] = { name: participant.name || id, meter: 0, speaking: false };
          if (track.kind === LK.Track.Kind.Video) {
            _mountRemoteVideo(id, track);
          } else if (track.kind === LK.Track.Kind.Audio) {
            var a = track.attach();
            document.body.appendChild(a);
            // meter
            var stop = _attachMeter(track, function (lvl) {
              if (remoteMap[id]) remoteMap[id].meter = lvl;
            });
            remoteMap[id]._stopMeter = stop;
          }
        });
        newRoom.on(LK.RoomEvent.TrackUnsubscribed, function (track) {
          track.detach().forEach(function (el) { el.remove(); });
        });
        newRoom.on(LK.RoomEvent.ParticipantDisconnected, function (p) {
          if (remoteMap[p.identity] && remoteMap[p.identity]._stopMeter) remoteMap[p.identity]._stopMeter();
          delete remoteMap[p.identity];
        });
        newRoom.on(LK.RoomEvent.ActiveSpeakersChanged, function (speakers) {
          var active = {};
          speakers.forEach(function (s) { active[s.identity] = true; });
          Object.keys(remoteMap).forEach(function (id) { remoteMap[id].speaking = !!active[id]; });
        });
        newRoom.on(LK.RoomEvent.DataReceived, onDataReceived);

        await newRoom.connect(tokenData.livekit_ws_url, tokenData.livekit_token);
        await newRoom.localParticipant.setMicrophoneEnabled(true);
        await newRoom.localParticipant.setCameraEnabled(true);

        // Capture local stream for recording + meter
        try {
          localStream = await navigator.mediaDevices.getUserMedia({ video: true, audio: true });
          if (localVideoEl.value) localVideoEl.value.srcObject = localStream;
          localMeterStop = _attachMeter({ mediaStreamTrack: localStream.getAudioTracks()[0] }, function (lvl) {
            localMeter.value = lvl;
          });
        } catch (_) {
          // Fallback to LiveKit's tracks if getUserMedia isn't independently available
          var camPub = newRoom.localParticipant.getTrackPublication(LK.Track.Source.Camera);
          if (camPub && camPub.track && localVideoEl.value) camPub.track.attach(localVideoEl.value);
        }

        room = newRoom;
        connected.value = true;
        await loadParticipants();
        await loadChat();
      } catch (e) {
        error.value = "No se pudo conectar al estudio: " + e.message;
      } finally {
        busy.value = false;
      }
    }

    async function disconnect() {
      stopLocalRecorders();
      if (countdownHandle) { clearTimeout(countdownHandle); countdownHandle = null; }
      countdown.value = null;
      if (localMeterStop) { localMeterStop(); localMeterStop = null; }
      if (localStream) { localStream.getTracks().forEach(function (t) { t.stop(); }); localStream = null; }
      if (soundboardCtx) { try { soundboardCtx.close(); } catch (_) {} soundboardCtx = null; soundboardDest = null; soundboardBuffers = {}; }
      if (room) { try { await room.disconnect(); } catch (_) {} room = null; }
      connected.value = false;
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
      if (props.user.username === props.session.created_by) {
        try { await api("/api/sessions/" + props.session.id + "/start", { method: "POST" }); } catch (_) {}
      }
      recording.value = true;
      recordingStart.value = Date.now();
      timecode.value = 0;
      if (timerHandle) clearInterval(timerHandle);
      timerHandle = setInterval(function () {
        timecode.value = (Date.now() - recordingStart.value) / 1000;
      }, 250);
      startLocalRecorders();
    }

    function startLocalRecorders() {
      if (!recorder && localStream) {
        recorder = _startRecorder(localStream, function (blob) { uploadRecording(blob, "video"); }, 1000);
      }
      if (!soundboardRecorder && soundboardDest) {
        try {
          if (soundboardCtx && soundboardCtx.state === "suspended") soundboardCtx.resume();
          soundboardRecorder = _startRecorder(
            soundboardDest.stream,
            function (blob) { uploadRecording(blob, "soundboard"); },
            1000, true
          );
        } catch (_) {}
      }
    }

    function stopLocalRecorders() {
      if (recorder) { try { recorder.stop(); } catch (_) {} recorder = null; }
      if (soundboardRecorder) { try { soundboardRecorder.stop(); } catch (_) {} soundboardRecorder = null; }
    }

    async function uploadRecording(blob, trackType) {
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
      if (timerHandle) { clearInterval(timerHandle); timerHandle = null; }
      stopLocalRecorders();
      // Clear ready state for the next take
      ownReady.value = false;
      Object.keys(readyMap).forEach(function (k) { delete readyMap[k]; });
      setTimeout(loadRecordings, 2500);
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
      try { await navigator.clipboard.writeText(link.invite_url); alert("Link copiado"); }
      catch (_) { prompt("Copiá este link:", link.invite_url); }
    }

    async function kickParticipant(p) {
      if (!confirm("¿Quitar a " + p.display_name + "?")) return;
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
      window.addEventListener("keydown", onKey);
    });
    onBeforeUnmount(function () {
      window.removeEventListener("keydown", onKey);
      if (timerHandle) clearInterval(timerHandle);
      disconnect();
    });

    return {
      participants: participants, remoteMap: remoteMap, error: error, busy: busy,
      recording: recording, timecode: timecode, formatTC: formatTC, initials: initials,
      connected: connected, connect: connect, disconnect: disconnect,
      localVideoEl: localVideoEl, localMuted: localMuted, localCamOff: localCamOff, localMeter: localMeter,
      toggleMute: toggleMute, toggleCam: toggleCam,
      toggleReady: toggleReady, stopRecording: stopRecording,
      ownReady: ownReady, readyMap: readyMap, countdown: countdown, myIdentity: myIdentity,
      showInvite: showInvite, inviteForm: inviteForm, inviteLinks: inviteLinks,
      createInvite: createInvite, copyInvite: copyInvite, kickParticipant: kickParticipant,
      sounds: sounds, playingPad: playingPad, triggerSound: triggerSound,
      soundLimits: soundLimits, soundUploadStatus: soundUploadStatus, uploadSound: uploadSound,
      showAddSound: showAddSound, newSound: newSound, addCustomPad: addCustomPad, deleteCustomPad: deleteCustomPad,
      chat: chat, chatInput: chatInput, sendChat: sendChat,
      finishedRecordings: finishedRecordings,
      exportToPostpod: exportToPostpod, exportStatus: exportStatus, exporting: exporting,
      streams: streams, rtmpPresets: rtmpPresets, showStream: showStream, streamForm: streamForm,
      streamStatus: streamStatus, streamBusy: streamBusy, activeStreams: activeStreams,
      applyStreamPreset: applyStreamPreset, startStream: startStream, stopStream: stopStream,
      isHost: props.user.username === props.session.created_by,
      hasSharedProject: !!props.session.shared_project_id,
    };
  },
  template: `
    <div class="studio">
      <div class="studio-top" :class="{ recording: recording }">
        <button class="ghost" @click="onBack">← Sesiones</button>
        <h3>{{ session.title }}</h3>
        <span class="badge-id">#{{ session.id }}</span>
        <div class="spacer"></div>
        <div class="timecode mono">{{ formatTC(timecode) }}</div>
        <template v-if="!recording && countdown === null">
          <button class="primary rec-btn" @click="toggleReady" :disabled="!connected"
                  :style="ownReady ? 'background: var(--signal); color:#fff;' : ''">
            {{ ownReady ? "✓ Listo" : "● Prepararse" }}
          </button>
        </template>
        <button v-if="recording" class="rec-btn" style="background: var(--signal); color: #fff;"
                @click="stopRecording" :disabled="!isHost" :title="isHost ? 'Detener' : 'Sólo el host puede detener'">
          ■ Detener
        </button>

        <span v-if="activeStreams.length" class="tally live" style="margin-left: 8px;" :title="activeStreams.length + ' stream(s) activos'">
          <span class="dot"></span>EN VIVO
        </span>
        <button v-if="isHost && connected" class="ghost" style="margin-left: 8px;" @click="showStream = true" title="Transmitir a RTMP">📡 Stream</button>
      </div>

      <div class="studio-main">
        <div v-if="error" class="error">{{ error }}</div>

        <div v-if="!connected" style="text-align: center; padding: 80px 20px;">
          <div style="font-family: var(--font-display); font-size: 28px; font-weight: 500; margin-bottom: 10px;">Entrar al estudio</div>
          <p class="muted" style="max-width: 440px; margin: 0 auto 20px;">
            Al entrar se activan tu cámara y micrófono. Cuando grabes, tu track local se guarda y se sube al server al detener.
          </p>
          <button class="primary" @click="connect" :disabled="busy" style="padding: 14px 28px; font-size: 14px;">
            {{ busy ? "Conectando…" : "🎙 Entrar con cámara y micrófono" }}
          </button>
        </div>

        <div v-else class="participants-grid">
          <div class="participant-card">
            <video ref="localVideoEl" autoplay muted playsinline></video>
            <div v-if="localCamOff" class="initials" style="position: absolute;">{{ initials(user.display_name || user.username) }}</div>
            <div class="label">
              <span>{{ user.display_name || user.username }}</span>
              <span class="role-chip">VOS</span>
              <span v-if="ownReady && !recording" class="role-chip" style="background: var(--signal); color:#fff;">LISTO</span>
            </div>
            <div v-if="localMuted" class="muted-icon">🔇</div>
            <div class="meter"><div class="meter-fill" :style="{ width: localMeter + '%' }"></div></div>
          </div>

          <div v-for="p in participants.filter(pp => pp.username !== user.username && pp.status === 'connected')"
               :key="p.id"
               class="participant-card"
               :class="{ speaking: remoteMap['participant_' + p.id] && remoteMap['participant_' + p.id].speaking }">
            <div :data-remote-id="'participant_' + p.id" style="width: 100%; height: 100%;">
              <div class="initials" :style="{ background: p.avatar_color }">{{ initials(p.display_name) }}</div>
            </div>
            <div class="label">
              <span>{{ p.display_name }}</span>
              <span class="role-chip">{{ p.role }}</span>
              <span v-if="readyMap['participant_' + p.id] && !recording" class="role-chip" style="background: var(--signal); color:#fff;">LISTO</span>
            </div>
            <div class="meter"><div class="meter-fill" :style="{ width: ((remoteMap['participant_' + p.id] && remoteMap['participant_' + p.id].meter) || 0) + '%' }"></div></div>
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

        <div v-if="finishedRecordings.length" style="margin-top: 28px;">
          <div class="sb-head">
            <span class="label">Grabaciones</span>
            <span style="display:flex; gap:10px; align-items:center;">
              <span class="tiny">{{ finishedRecordings.length }} pista(s)</span>
              <a :href="'/api/sessions/' + session.id + '/recordings/bundle.zip'"
                 class="join-pill" download>↓ todas (ZIP)</a>
              <button v-if="isHost" class="join-pill"
                      :disabled="exporting" @click="exportToPostpod"
                      :title="'Enviar pistas a postPod'">
                {{ exporting ? "↗ enviando…" : "↗ Enviar a postPod" }}
              </button>
            </span>
          </div>
          <div v-if="exportStatus" class="tiny muted" style="margin-bottom: 6px;">{{ exportStatus }}</div>
          <div v-for="r in finishedRecordings" :key="r.id" class="invite-row">
            <span class="who mono">{{ r.filename }} · {{ r.track_type }}</span>
            <span class="status-chip connected">{{ Math.round((r.size_bytes||0)/1024) }}KB</span>
            <span v-if="r.exported_to_postpod_at" class="status-chip connected" title="Enviada a postPod">↗ postPod</span>
            <a :href="r.url + '?download=1'" class="join-pill" download>↓ bajar</a>
          </div>
        </div>
      </div>

      <aside class="studio-side">
        <div>
          <div class="sb-head">
            <span class="label">Soundboard</span>
            <span class="tiny">atajos · ⬆ reemplaza</span>
          </div>
          <div class="sb-grid">
            <div v-for="s in sounds" :key="s.id" class="sb-pad-wrap">
              <button class="sb-pad"
                      :class="{ playing: playingPad === s.shortcut_key, empty: !s.filename }"
                      :style="{ '--pad-color': s.color }"
                      @click="triggerSound(s)">
                <span>{{ s.name }}</span>
                <span class="key">{{ s.shortcut_key || '—' }}</span>
              </button>
              <label class="sb-pad-upload" :title="'Subir (máx ' + (soundLimits.max_kb || 150) + 'KB · ' + (soundLimits.max_duration_seconds || 4) + 's)'">
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

        <div style="flex: 1; display: flex; flex-direction: column; min-height: 200px;">
          <div class="sb-head"><span class="label">Chat en vivo</span><span class="tiny">{{ chat.length }}</span></div>
          <div id="chat-scroll" style="flex: 1; overflow-y: auto; background: var(--ink-sunken); border: 1px solid var(--ink-line); border-radius: var(--r-md); padding: 8px; margin-bottom: 6px; min-height: 100px; font-size: 12px;">
            <div v-for="m in chat" :key="m.id" style="margin-bottom: 6px;">
              <strong style="color: var(--signal);">{{ m.author }}:</strong>
              <span style="color: var(--paper);">{{ m.text }}</span>
            </div>
            <div v-if="chat.length === 0" class="muted" style="text-align: center; padding: 20px;">(sin mensajes)</div>
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

    async function load() {
      try { invite.value = await api("/api/invite/" + props.token); name.value = invite.value.display_name; }
      catch (e) { error.value = e.message; }
    }
    async function join() {
      busy.value = true; error.value = "";
      try {
        var r = await api("/api/invite/" + props.token + "/join", {
          method: "POST",
          body: { display_name: name.value.trim() },
        });
        props.onJoined(r);
      } catch (e) { error.value = e.message; }
      finally { busy.value = false; }
    }
    onMounted(load);
    return { invite: invite, error: error, busy: busy, name: name, join: join };
  },
  template: `
    <div class="login-wrapper">
      <div class="login-card" style="width: 440px;">
        <div class="eyebrow">INVITACIÓN · LIVE BOOTH</div>
        <h2 v-if="invite">{{ invite.session_title }}</h2>
        <h2 v-else>Cargando…</h2>
        <div v-if="invite" class="subtitle">{{ invite.session_description || "Te invitaron a grabar en prodPod." }}</div>
        <div v-if="error" class="error">{{ error }}</div>
        <div v-if="invite">
          <div class="form-row">
            <label>Tu nombre</label>
            <input type="text" v-model="name" placeholder="Cómo querés aparecer">
          </div>
          <button class="primary" :disabled="busy || !name.trim()" @click="join" style="width:100%; margin-top: 12px; padding: 12px;">
            {{ busy ? "Entrando…" : "🎙 Entrar al estudio" }}
          </button>
        </div>
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
    var busy = ref(true);
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

    var soundboardRecorder = null;
    var soundboardCtx = null;
    var soundboardDest = null;
    var soundboardBuffers = {};
    var myIdentity = ref("");
    var readyMap = reactive({});
    var ownReady = ref(false);
    var countdown = ref(null);
    var countdownHandle = null;

    async function loadSounds() {
      try {
        var resp = await fetch("/api/sessions/" + props.joinData.session_id + "/sounds");
        if (!resp.ok) return;
        sounds.value = await resp.json();
        sounds.value.forEach(function (s) {
          var a = new Audio(s.url);
          a.preload = "auto";
          audioPool[s.filename] = a;
        });
        preloadSoundboardBuffers();
      } catch (_) {}
    }

    async function preloadSoundboardBuffers() {
      if (!soundboardCtx) {
        try {
          var AC = window.AudioContext || window.webkitAudioContext;
          soundboardCtx = new AC();
          soundboardDest = soundboardCtx.createMediaStreamDestination();
        } catch (_) { return; }
      }
      for (var i = 0; i < sounds.value.length; i++) {
        var s = sounds.value[i];
        if (!s.filename || soundboardBuffers[s.filename]) continue;
        try {
          var r = await fetch(s.url);
          var ab = await r.arrayBuffer();
          soundboardBuffers[s.filename] = await soundboardCtx.decodeAudioData(ab);
        } catch (_) {}
      }
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
        chat.value.push({ id: msg.id, author: msg.author, text: msg.text, ts: msg.ts });
        scrollChatBottom();
      } else if (msg.type === "ready_toggle") {
        readyMap[msg.identity] = !!msg.ready;
      } else if (msg.type === "countdown_start") {
        beginCountdown(msg.start_at_ms);
      } else if (msg.type === "recording_stop") {
        finishRecording();
      } else if (msg.type === "kick" && room && room.localParticipant &&
                 msg.target_identity === room.localParticipant.identity) {
        error.value = "El host te desconectó.";
        leave();
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
      timecode.value = 0;
      if (timerHandle) clearInterval(timerHandle);
      var start = Date.now();
      timerHandle = setInterval(function () { timecode.value = (Date.now() - start) / 1000; }, 250);
      if (!recorder && localStream) {
        recorder = _startRecorder(localStream, function (blob) { uploadRecording(blob, "video"); }, 1000);
      }
      if (!soundboardRecorder && soundboardDest) {
        try {
          if (soundboardCtx && soundboardCtx.state === "suspended") soundboardCtx.resume();
          soundboardRecorder = _startRecorder(
            soundboardDest.stream,
            function (blob) { uploadRecording(blob, "soundboard"); },
            1000, true
          );
        } catch (_) {}
      }
    }

    function finishRecording() {
      if (!recording.value) return;
      recording.value = false;
      if (timerHandle) { clearInterval(timerHandle); timerHandle = null; }
      if (recorder) { try { recorder.stop(); } catch (_) {} recorder = null; }
      if (soundboardRecorder) { try { soundboardRecorder.stop(); } catch (_) {} soundboardRecorder = null; }
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
      var ab = soundboardBuffers[s.filename];
      if (ab && soundboardCtx && soundboardDest) {
        try {
          if (soundboardCtx.state === "suspended") soundboardCtx.resume();
          var src = soundboardCtx.createBufferSource();
          src.buffer = ab;
          src.connect(soundboardDest);
          src.start();
        } catch (_) {}
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
      try {
        myIdentity.value = "participant_" + props.joinData.participant_id;
        var newRoom = new LK.Room({ adaptiveStream: true, dynacast: true });
        newRoom.on(LK.RoomEvent.TrackSubscribed, function (track, pub, participant) {
          if (track.kind === LK.Track.Kind.Video) {
            _mountRemoteVideo(participant.identity, track);
            if (!remoteMap[participant.identity]) remoteMap[participant.identity] = { name: participant.name || participant.identity, meter: 0 };
          } else if (track.kind === LK.Track.Kind.Audio) {
            var a = track.attach();
            document.body.appendChild(a);
            var stop = _attachMeter(track, function (lvl) {
              if (!remoteMap[participant.identity]) remoteMap[participant.identity] = { name: participant.name || participant.identity, meter: 0 };
              remoteMap[participant.identity].meter = lvl;
            });
            if (!remoteMap[participant.identity]) remoteMap[participant.identity] = {};
            remoteMap[participant.identity]._stopMeter = stop;
          }
        });
        newRoom.on(LK.RoomEvent.ParticipantDisconnected, function (p) {
          if (remoteMap[p.identity] && remoteMap[p.identity]._stopMeter) remoteMap[p.identity]._stopMeter();
          delete remoteMap[p.identity];
        });
        newRoom.on(LK.RoomEvent.DataReceived, onDataReceived);

        await newRoom.connect(props.joinData.livekit_ws_url, props.joinData.livekit_token);
        await newRoom.localParticipant.setMicrophoneEnabled(true);
        await newRoom.localParticipant.setCameraEnabled(true);

        try {
          localStream = await navigator.mediaDevices.getUserMedia({ video: true, audio: true });
          if (localVideoEl.value) localVideoEl.value.srcObject = localStream;
          localMeterStop = _attachMeter({ mediaStreamTrack: localStream.getAudioTracks()[0] }, function (lvl) { localMeter.value = lvl; });
        } catch (_) {
          var camPub = newRoom.localParticipant.getTrackPublication(LK.Track.Source.Camera);
          if (camPub && camPub.track && localVideoEl.value) camPub.track.attach(localVideoEl.value);
        }

        room = newRoom;
        connected.value = true;
      } catch (e) {
        error.value = "Error de conexión: " + e.message;
      } finally {
        busy.value = false;
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
      if (soundboardRecorder) { try { soundboardRecorder.stop(); } catch (_) {} soundboardRecorder = null; }
      if (countdownHandle) { clearTimeout(countdownHandle); countdownHandle = null; }
      if (localMeterStop) { localMeterStop(); localMeterStop = null; }
      if (localStream) { localStream.getTracks().forEach(function (t) { t.stop(); }); localStream = null; }
      if (soundboardCtx) { try { soundboardCtx.close(); } catch (_) {} soundboardCtx = null; soundboardDest = null; soundboardBuffers = {}; }
      if (room) { try { await room.disconnect(); } catch (_) {} }
      window.location.href = "/";
    }

    onMounted(function () { connect(); loadSounds(); });
    onBeforeUnmount(function () { if (timerHandle) clearInterval(timerHandle); if (room) room.disconnect().catch(function () {}); });

    return { localVideoEl: localVideoEl, error: error, busy: busy, connected: connected,
             localMuted: localMuted, localCamOff: localCamOff, remoteMap: remoteMap,
             localMeter: localMeter, recording: recording, timecode: timecode, formatTC: formatTC,
             sounds: sounds, playingPad: playingPad, triggerSound: triggerSound,
             chat: chat, chatInput: chatInput, sendChat: sendChat,
             toggleMute: toggleMute, toggleCam: toggleCam, leave: leave, initials: initials,
             toggleReady: toggleReady, ownReady: ownReady, readyMap: readyMap, countdown: countdown,
             myIdentity: myIdentity };
  },
  template: `
    <div class="studio">
      <div class="studio-top" :class="{ recording: recording }">
        <h3>{{ joinData.display_name }} · invitado</h3>
        <span class="badge-id">{{ joinData.role }}</span>
        <div class="spacer"></div>
        <div v-if="recording" class="timecode mono">{{ formatTC(timecode) }}</div>
        <button v-if="connected && !recording && countdown === null" class="primary rec-btn"
                @click="toggleReady"
                :style="ownReady ? 'background: var(--signal); color:#fff;' : ''">
          {{ ownReady ? "✓ Listo" : "● Prepararse" }}
        </button>
        <span v-if="connected && recording" class="tally live"><span class="dot"></span>ON AIR</span>
      </div>
      <div class="studio-main">
        <div v-if="error" class="error">{{ error }}</div>
        <div v-if="busy" class="muted" style="text-align:center; padding: 60px;">Pidiendo permisos de cámara/micrófono…</div>
        <div v-else class="participants-grid">
          <div class="participant-card">
            <video ref="localVideoEl" autoplay muted playsinline></video>
            <div v-if="localCamOff" class="initials" style="position:absolute;">{{ initials(joinData.display_name) }}</div>
            <div class="label">
              <span>{{ joinData.display_name }}</span>
              <span class="role-chip">VOS</span>
              <span v-if="ownReady && !recording" class="role-chip" style="background: var(--signal); color:#fff;">LISTO</span>
            </div>
            <div v-if="localMuted" class="muted-icon">🔇</div>
            <div class="meter"><div class="meter-fill" :style="{ width: localMeter + '%' }"></div></div>
          </div>
          <div v-for="(t, id) in remoteMap" :key="id" class="participant-card">
            <div :data-remote-id="id" style="width:100%; height:100%;"></div>
            <div class="label">
              <span>{{ t.name || id }}</span>
              <span v-if="readyMap[id] && !recording" class="role-chip" style="background: var(--signal); color:#fff;">LISTO</span>
            </div>
            <div class="meter"><div class="meter-fill" :style="{ width: (t.meter || 0) + '%' }"></div></div>
          </div>
        </div>
        <div v-if="countdown !== null" class="countdown-overlay">
          <div class="countdown-num">{{ countdown > 0 ? countdown : '●' }}</div>
          <div class="countdown-label">{{ countdown > 0 ? 'preparándose…' : 'GRABANDO' }}</div>
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
        <div class="spacer"></div>
        <button class="ghost" @click="leave">Salir</button>
      </div>
    </div>
  `,
};

/* ==========================================================================
   Root
   ========================================================================== */

var App = {
  components: {
    LoginView: LoginView, DashboardView: DashboardView,
    StudioView: StudioView, InviteView: InviteView, GuestStudioView: GuestStudioView,
  },
  setup: function () {
    var state = reactive({
      loading: true, user: null, route: "dashboard",
      currentSession: null, inviteToken: null, joinData: null,
    });
    var anyRecording = ref(false);

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
    async function logout() {
      try { await api("/api/auth/logout", { method: "POST" }); } catch (_) {}
      state.user = null; state.currentSession = null;
    }
    function onLoggedIn(u) { state.user = u; state.route = "dashboard"; }
    function openSession(s) { state.currentSession = s; state.route = "studio"; }
    function onJoined(data) { state.joinData = data; state.route = "guest-studio"; }

    onMounted(function () {
      parseRoute();
      checkAuth();
      // Poll any live video element to update tally
      setInterval(function () {
        var v = document.querySelector(".studio-top.recording");
        anyRecording.value = !!v;
      }, 250);
    });

    return { state: state, anyRecording: anyRecording, onLoggedIn: onLoggedIn,
             openSession: openSession, onJoined: onJoined, logout: logout,
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
          <span class="mark">prod<em>Pod</em></span>
          <span class="tag">live booth · v0.1</span>
        </div>
        <div class="tally" :class="{ live: anyRecording }">
          <span class="dot"></span>
          <span>{{ anyRecording ? 'ON AIR' : 'STANDBY' }}</span>
        </div>
        <div class="spacer"></div>
        <div v-if="state.route === 'studio'">
          <button class="ghost" @click="backToDash">← Sesiones</button>
        </div>
        <div class="user-chip">
          <span class="tiny">OP</span>
          <span class="name">{{ state.user.display_name || state.user.username }}</span>
          <button class="ghost" @click="logout">Salir</button>
        </div>
      </header>
      <StudioView v-if="state.route === 'studio'" :session="state.currentSession" :user="state.user" :on-back="backToDash" />
      <DashboardView v-else :on-open="openSession" />
    </template>
  `,
};

createApp(App).mount("#app");
