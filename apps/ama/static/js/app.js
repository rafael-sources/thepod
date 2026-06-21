var { createApp, reactive, ref, computed, onMounted, onBeforeUnmount, watch, nextTick } = Vue;
var LK = window.LivekitClient;

// ── helpers ──────────────────────────────────────────────────────────

async function api(path, options) {
  options = options || {};
  var opts = { credentials: "same-origin", headers: { Accept: "application/json" } };
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

function initials(name) {
  if (!name) return "?";
  var parts = name.split(/\s+/).filter(Boolean);
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
  return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
}

function fmtDate(s) {
  if (!s) return "";
  try {
    return new Date(s.endsWith && s.endsWith("Z") ? s : s + "Z").toLocaleString("es", {
      day: "2-digit", month: "short", hour: "2-digit", minute: "2-digit",
    });
  } catch (_) { return s; }
}

function _encodeMsg(obj) { return new TextEncoder().encode(JSON.stringify(obj)); }
function _decodeMsg(payload) {
  try { return JSON.parse(new TextDecoder().decode(payload)); } catch (_) { return null; }
}

var _livekitWsUrl = null;
async function getLivekitWsUrl() {
  if (_livekitWsUrl) return _livekitWsUrl;
  var cfg = await api("/api/config/livekit");
  _livekitWsUrl = cfg.ws_url;
  return _livekitWsUrl;
}

// ── ToastHost ────────────────────────────────────────────────────────

var ToastHost = {
  setup: function () {
    var toasts = ref([]);
    var _id = 0;
    window.toast = function (opts) {
      var t = { id: ++_id, type: opts.type || "info", text: opts.text || "", ms: opts.ms || 3500 };
      toasts.value.push(t);
      setTimeout(function () { toasts.value = toasts.value.filter(function (x) { return x.id !== t.id; }); }, t.ms);
    };
    return { toasts: toasts };
  },
  template: '<div class="toast-host"><div v-for="t in toasts" :key="t.id" class="toast-item" :class="t.type" @click="toasts = toasts.filter(x => x.id !== t.id)">{{ t.text }}</div></div>'
};

// ── LoginView ────────────────────────────────────────────────────────

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
        var d = await api("/api/auth/login", { method: "POST", body: { username: username.value, password: password.value } });
        props.onLoggedIn(d);
      } catch (e) { error.value = e.message; }
      finally { busy.value = false; }
    }
    return { username: username, password: password, error: error, busy: busy, submit: submit };
  },
  template: '\
<div class="login-view">\
  <div class="login-card">\
    <h1 class="brand">ama<span class="brand-accent">Pod</span></h1>\
    <p class="login-subtitle">Eventos de preguntas en vivo</p>\
    <form @submit.prevent="submit">\
      <input type="text" v-model="username" placeholder="Usuario" autofocus>\
      <input type="password" v-model="password" placeholder="Contraseña" @keyup.enter="submit">\
      <button class="primary" :disabled="busy" type="submit">{{ busy ? "Entrando..." : "Entrar" }}</button>\
      <p v-if="error" class="error-text">{{ error }}</p>\
    </form>\
  </div>\
</div>'
};

// ── DashboardView ────────────────────────────────────────────────────

var DashboardView = {
  props: { user: Object, onLogout: Function },
  emits: ["open-event"],
  setup: function (props, ctx) {
    var events = ref([]);
    var templates = ref([]);
    var loading = ref(true);
    var showCreate = ref(false);
    var newTitle = ref("");
    var newDesc = ref("");
    var apps = ref([]);

    async function loadEvents() {
      loading.value = true;
      try { events.value = await api("/api/events"); } catch (_) {}
      try { templates.value = await api("/api/events/templates"); } catch (_) {}
      loading.value = false;
    }

    async function loadApps() {
      try {
        var cfg = await api("/api/config/apps");
        apps.value = (cfg.apps || []).filter(function (a) { return a.key !== "amapod" && a.url; });
      } catch (_) {}
    }

    async function createEvent() {
      if (!newTitle.value.trim()) return;
      try {
        var evt = await api("/api/events", { method: "POST", body: { title: newTitle.value, description: newDesc.value } });
        events.value.unshift(evt);
        showCreate.value = false;
        newTitle.value = "";
        newDesc.value = "";
        window.toast({ type: "success", text: "Evento creado" });
      } catch (e) { window.toast({ type: "error", text: e.message }); }
    }

    async function createFromTemplate(tid) {
      try {
        var evt = await api("/api/events/from-template/" + tid, { method: "POST" });
        events.value.unshift(evt);
        window.toast({ type: "success", text: "Evento creado desde plantilla" });
      } catch (e) { window.toast({ type: "error", text: e.message }); }
    }

    async function deleteEvent(eid) {
      var ok = await podSwal.confirm("Eliminar este evento?", { danger: true });
      if (!ok) return;
      try {
        await api("/api/events/" + eid, { method: "DELETE" });
        events.value = events.value.filter(function (e) { return e.id !== eid; });
      } catch (e) { window.toast({ type: "error", text: e.message }); }
    }

    function openEvent(e) { ctx.emit("open-event", e); }

    onMounted(function () { loadEvents(); loadApps(); });
    return { events: events, templates: templates, loading: loading, showCreate: showCreate,
             newTitle: newTitle, newDesc: newDesc, apps: apps,
             createEvent: createEvent, createFromTemplate: createFromTemplate,
             deleteEvent: deleteEvent, openEvent: openEvent, fmtDate: fmtDate };
  },
  template: '\
<div>\
  <header class="app-header">\
    <span class="brand">ama<span class="brand-accent">Pod</span></span>\
    <div class="sibling-apps">\
      <a v-for="a in apps" :key="a.key" :href="a.url" class="sibling-link"><span class="ico">{{ a.icon }}</span> {{ a.name }}</a>\
    </div>\
    <span class="spacer"></span>\
    <div class="user-chip">\
      <span class="name">{{ user && user.username }}</span>\
      <button class="ghost" @click="$props.onLogout">Salir</button>\
    </div>\
  </header>\
  <div class="dashboard-view">\
    <header class="dash-header">\
      <h1>Eventos</h1>\
      <button @click="showCreate = true" class="primary">+ Nuevo evento</button>\
    </header>\
    <div v-if="showCreate" class="create-modal-overlay" @click.self="showCreate = false">\
      <div class="create-modal">\
        <h2>Nuevo evento</h2>\
        <label>Titulo</label>\
        <input type="text" v-model="newTitle" placeholder="Titulo del evento" autofocus>\
        <label style="margin-top:10px">Descripcion</label>\
        <textarea v-model="newDesc" placeholder="Descripcion (opcional)" rows="3"></textarea>\
        <div class="modal-actions">\
          <button @click="showCreate = false">Cancelar</button>\
          <button class="primary" @click="createEvent" :disabled="!newTitle.trim()">Crear</button>\
        </div>\
      </div>\
    </div>\
    <div v-if="templates.length" class="templates-section">\
      <h3 class="tiny" style="margin-bottom:8px">PLANTILLAS</h3>\
      <div class="template-grid">\
        <div v-for="t in templates" :key="t.id" class="template-card" @click="createFromTemplate(t.id)">\
          {{ t.title }}\
        </div>\
      </div>\
    </div>\
    <div v-if="loading" class="loading">Cargando...</div>\
    <div v-else-if="!events.length" class="empty-state">No hay eventos. Crea el primero.</div>\
    <div v-else class="events-grid">\
      <div v-for="e in events" :key="e.id" class="event-card" @click="openEvent(e)">\
        <div class="event-status" :class="e.status">{{ e.status }}</div>\
        <h3>{{ e.title }}</h3>\
        <p class="event-desc">{{ e.description || "Sin descripcion" }}</p>\
        <div v-if="e.like_count || e.spectator_count" class="event-meta" style="margin-top:4px">&#10084; {{ e.like_count || 0 }} &middot; &#128065; {{ e.spectator_count || 0 }}</div>\
        <div class="event-meta">{{ fmtDate(e.created_at) }}</div>\
        <button v-if="e.status === \'created\'" class="icon danger" @click.stop="deleteEvent(e.id)" title="Eliminar" style="position:absolute;top:12px;right:12px">&#10005;</button>\
      </div>\
    </div>\
  </div>\
</div>'
};

// ── HostView ─────────────────────────────────────────────────────────

var HostView = {
  props: { event: Object, user: Object, onBack: Function },
  setup: function (props) {
    var eventData = ref(JSON.parse(JSON.stringify(props.event)));
    var phase = ref("prejoin");
    var room = ref(null);
    var connected = ref(false);
    var queue = ref([]);
    var requests = ref([]);
    var chatMessages = ref([]);
    var chatInput = ref("");
    var currentParticipant = ref(null);
    var isRecording = ref(false);
    var likeCount = ref(0);
    var spectatorCount = ref(0);
    var pollTimer = ref(null);
    var chatPollTimer = ref(null);

    var devices = ref({ cameras: [], mics: [] });
    var selectedCamera = ref("");
    var selectedMic = ref("");
    var previewStream = ref(null);

    var joinLink = computed(function () {
      return window.location.origin + "/join/" + eventData.value.id;
    });

    var watchLink = computed(function () {
      return window.location.origin + "/watch/" + eventData.value.id;
    });

    async function listDevices() {
      try {
        await navigator.mediaDevices.getUserMedia({ video: true, audio: true }).then(function (s) { s.getTracks().forEach(function (t) { t.stop(); }); });
        var devs = await navigator.mediaDevices.enumerateDevices();
        devices.value.cameras = devs.filter(function (d) { return d.kind === "videoinput"; });
        devices.value.mics = devs.filter(function (d) { return d.kind === "audioinput"; });
        if (devices.value.cameras.length && !selectedCamera.value) selectedCamera.value = devices.value.cameras[0].deviceId;
        if (devices.value.mics.length && !selectedMic.value) selectedMic.value = devices.value.mics[0].deviceId;
      } catch (e) { window.toast({ type: "error", text: "No se pudo acceder a la camara/microfono" }); }
    }

    async function startPreview() {
      stopPreview();
      try {
        var constraints = { video: selectedCamera.value ? { deviceId: { exact: selectedCamera.value } } : true, audio: false };
        var stream = await navigator.mediaDevices.getUserMedia(constraints);
        previewStream.value = stream;
        nextTick(function () {
          var el = document.getElementById("prejoin-video");
          if (el) { el.srcObject = stream; el.play().catch(function () {}); }
        });
      } catch (_) {}
    }

    function stopPreview() {
      if (previewStream.value) {
        previewStream.value.getTracks().forEach(function (t) { t.stop(); });
        previewStream.value = null;
      }
    }

    async function connectToRoom() {
      try {
        stopPreview();
        var wsUrl = await getLivekitWsUrl();
        var tokenData = await api("/api/events/" + eventData.value.id + "/host-token");
        var newRoom = new LK.Room({ adaptiveStream: true, dynacast: true });

        newRoom.on(LK.RoomEvent.TrackSubscribed, function (track, pub, participant) {
          if (track.kind === LK.Track.Kind.Video) {
            nextTick(function () {
              var el = document.getElementById("participant-video");
              if (el) { track.attach(el); }
            });
          } else if (track.kind === LK.Track.Kind.Audio) {
            var a = track.attach();
            document.body.appendChild(a);
          }
        });

        newRoom.on(LK.RoomEvent.TrackUnsubscribed, function (track) {
          track.detach().forEach(function (el) { el.remove(); });
        });

        newRoom.on(LK.RoomEvent.ParticipantConnected, function (p) {
          window.toast({ type: "info", text: (p.name || p.identity) + " se conecto" });
        });

        newRoom.on(LK.RoomEvent.ParticipantDisconnected, function (p) {
          window.toast({ type: "info", text: (p.name || p.identity) + " se desconecto" });
        });

        newRoom.on(LK.RoomEvent.DataReceived, function (payload) {
          var msg = _decodeMsg(payload);
          if (!msg) return;
          if (msg.type === "chat") {
            chatMessages.value.push(msg);
            scrollChat();
          }
        });

        newRoom.on(LK.RoomEvent.Disconnected, function () {
          connected.value = false;
          window.toast({ type: "error", text: "Desconectado de la sala" });
        });

        await newRoom.connect(wsUrl, tokenData.token);
        var camOpts = selectedCamera.value ? { deviceId: selectedCamera.value } : undefined;
        var micOpts = selectedMic.value ? { deviceId: selectedMic.value } : undefined;
        await newRoom.localParticipant.setCameraEnabled(true, camOpts);
        await newRoom.localParticipant.setMicrophoneEnabled(true, micOpts);

        room.value = newRoom;
        connected.value = true;
        phase.value = "live";

        nextTick(function () {
          var camPub = newRoom.localParticipant.getTrackPublication(LK.Track.Source.Camera);
          if (camPub && camPub.track) {
            var el = document.getElementById("host-video");
            if (el) camPub.track.attach(el);
          }
        });

        startPolling();
        startChatPolling();
      } catch (e) {
        window.toast({ type: "error", text: "Error al conectar: " + e.message });
      }
    }

    async function startEvent() {
      if (eventData.value.status === "created") {
        try {
          var updated = await api("/api/events/" + eventData.value.id + "/start", { method: "POST" });
          eventData.value = updated;
          window.toast({ type: "success", text: "Evento iniciado" });
        } catch (e) { window.toast({ type: "error", text: e.message }); }
      }
      await connectToRoom();
      if (!isRecording.value) {
        try { await startRecording(); } catch (_) {}
      }
    }

    async function finishEvent() {
      var ok = await podSwal.confirm("Finalizar el evento? Todos los participantes seran desconectados.");
      if (!ok) return;
      try {
        if (isRecording.value) await stopRecording();
        var updated = await api("/api/events/" + eventData.value.id + "/finish", { method: "POST" });
        eventData.value = updated;
        if (room.value) {
          room.value.localParticipant.publishData(_encodeMsg({ type: "event_ended" }), LK.DataPacket_Kind.RELIABLE);
          await room.value.disconnect();
          room.value = null;
        }
        connected.value = false;
        stopPolling();
        stopChatPolling();
        window.toast({ type: "success", text: "Evento finalizado" });
      } catch (e) { window.toast({ type: "error", text: e.message }); }
    }

    // ── Queue ──

    async function loadQueue() {
      try {
        queue.value = await api("/api/events/" + eventData.value.id + "/queue");
        var onAir = queue.value.find(function (p) { return p.status === "on_air"; });
        currentParticipant.value = onAir || null;
      } catch (_) {}
    }

    async function loadRequests() {
      try { requests.value = await api("/api/events/" + eventData.value.id + "/requests"); } catch (_) {}
    }

    async function loadStats() {
      try {
        var info = await api("/api/events/" + eventData.value.id + "/public-info");
        likeCount.value = info.like_count || 0;
        spectatorCount.value = info.spectator_count || 0;
      } catch (_) {}
    }

    function startPolling() {
      loadQueue();
      loadRequests();
      loadStats();
      pollTimer.value = setInterval(function () { loadQueue(); loadRequests(); loadStats(); }, 3000);
    }

    function stopPolling() {
      if (pollTimer.value) { clearInterval(pollTimer.value); pollTimer.value = null; }
    }

    async function approveRequest(pid) {
      try {
        await api("/api/events/" + eventData.value.id + "/approve/" + pid, { method: "POST" });
        loadQueue();
        loadRequests();
      } catch (e) { window.toast({ type: "error", text: e.message }); }
    }

    async function rejectRequest(pid) {
      try {
        await api("/api/events/" + eventData.value.id + "/reject/" + pid, { method: "POST" });
        loadRequests();
      } catch (e) { window.toast({ type: "error", text: e.message }); }
    }

    async function nextTurnAction() {
      try {
        var result = await api("/api/events/" + eventData.value.id + "/next", { method: "POST" });
        if (result.message) {
          window.toast({ type: "info", text: result.message });
        } else {
          window.toast({ type: "success", text: result.display_name + " al aire" });
          if (room.value) {
            room.value.localParticipant.publishData(
              _encodeMsg({ type: "turn_change", participant: result }),
              LK.DataPacket_Kind.RELIABLE
            );
          }
        }
        loadQueue();
      } catch (e) { window.toast({ type: "error", text: e.message }); }
    }

    async function skipTo(pid) {
      try {
        var result = await api("/api/events/" + eventData.value.id + "/skip/" + pid, { method: "POST" });
        window.toast({ type: "success", text: result.display_name + " al aire" });
        loadQueue();
      } catch (e) { window.toast({ type: "error", text: e.message }); }
    }

    async function removeParticipant(pid) {
      try {
        await api("/api/events/" + eventData.value.id + "/remove/" + pid, { method: "DELETE" });
        loadQueue();
      } catch (e) { window.toast({ type: "error", text: e.message }); }
    }

    async function censorParticipant(pid) {
      try {
        await api("/api/events/" + eventData.value.id + "/censor/" + pid, { method: "POST" });
        loadQueue();
        if (room.value) {
          room.value.localParticipant.publishData(
            _encodeMsg({ type: "censor", participant_id: pid }),
            LK.DataPacket_Kind.RELIABLE
          );
        }
      } catch (e) { window.toast({ type: "error", text: e.message }); }
    }

    async function uncensorParticipant(pid) {
      try {
        await api("/api/events/" + eventData.value.id + "/uncensor/" + pid, { method: "POST" });
        loadQueue();
        if (room.value) {
          room.value.localParticipant.publishData(
            _encodeMsg({ type: "uncensor", participant_id: pid }),
            LK.DataPacket_Kind.RELIABLE
          );
        }
      } catch (e) { window.toast({ type: "error", text: e.message }); }
    }

    // ── Recording ──

    async function startRecording() {
      try {
        await api("/api/events/" + eventData.value.id + "/recording/start", { method: "POST" });
        isRecording.value = true;
        window.toast({ type: "success", text: "Grabacion iniciada" });
      } catch (e) { window.toast({ type: "error", text: e.message }); }
    }

    async function stopRecording() {
      try {
        await api("/api/events/" + eventData.value.id + "/recording/stop", { method: "POST" });
        isRecording.value = false;
        window.toast({ type: "success", text: "Grabacion detenida" });
      } catch (e) { window.toast({ type: "error", text: e.message }); }
    }

    // ── Chat ──

    async function loadChat() {
      try { chatMessages.value = await api("/api/events/" + eventData.value.id + "/chat"); } catch (_) {}
    }

    function startChatPolling() {
      loadChat();
      chatPollTimer.value = setInterval(loadChat, 5000);
    }

    function stopChatPolling() {
      if (chatPollTimer.value) { clearInterval(chatPollTimer.value); chatPollTimer.value = null; }
    }

    async function sendChat() {
      var msg = chatInput.value.trim();
      if (!msg) return;
      chatInput.value = "";
      try {
        var sent = await api("/api/events/" + eventData.value.id + "/chat", { method: "POST", body: { message: msg } });
        chatMessages.value.push(sent);
        scrollChat();
        if (room.value) {
          room.value.localParticipant.publishData(
            _encodeMsg({ type: "chat", sender_name: sent.sender_name, message: sent.message, is_host: sent.is_host }),
            LK.DataPacket_Kind.RELIABLE
          );
        }
      } catch (e) { window.toast({ type: "error", text: e.message }); }
    }

    function scrollChat() {
      nextTick(function () {
        var el = document.querySelector(".chat-messages");
        if (el) el.scrollTop = el.scrollHeight;
      });
    }

    function copyJoinLink() {
      navigator.clipboard.writeText(joinLink.value).then(function () {
        window.toast({ type: "success", text: "Link de participante copiado" });
      });
    }

    function copyWatchLink() {
      navigator.clipboard.writeText(watchLink.value).then(function () {
        window.toast({ type: "success", text: "Link de espectador copiado" });
      });
    }

    var inQueueOnly = computed(function () {
      return queue.value.filter(function (p) { return p.status === "in_queue"; });
    });

    onMounted(function () {
      listDevices().then(startPreview);
    });

    onBeforeUnmount(function () {
      stopPreview();
      stopPolling();
      stopChatPolling();
      if (room.value) { room.value.disconnect(); room.value = null; }
    });

    watch(selectedCamera, function () { if (phase.value === "prejoin") startPreview(); });

    return {
      eventData: eventData, phase: phase, connected: connected,
      queue: queue, requests: requests, chatMessages: chatMessages, chatInput: chatInput,
      currentParticipant: currentParticipant, isRecording: isRecording, likeCount: likeCount, spectatorCount: spectatorCount,
      devices: devices, selectedCamera: selectedCamera, selectedMic: selectedMic,
      joinLink: joinLink, inQueueOnly: inQueueOnly,
      startEvent: startEvent, finishEvent: finishEvent,
      approveRequest: approveRequest, rejectRequest: rejectRequest,
      nextTurnAction: nextTurnAction, skipTo: skipTo, removeParticipant: removeParticipant,
      censorParticipant: censorParticipant, uncensorParticipant: uncensorParticipant,
      startRecording: startRecording, stopRecording: stopRecording,
      sendChat: sendChat, copyJoinLink: copyJoinLink, copyWatchLink: copyWatchLink, initials: initials,
    };
  },
  template: '\
<div v-if="phase === \'prejoin\'" class="prejoin">\
  <div class="prejoin-card">\
    <div class="prejoin-preview">\
      <video id="prejoin-video" autoplay muted playsinline style="transform:scaleX(-1)"></video>\
      <div v-if="!devices.cameras.length" class="prejoin-placeholder">Sin camara detectada</div>\
    </div>\
    <div class="prejoin-controls">\
      <h2 style="margin:0 0 4px">{{ eventData.title }}</h2>\
      <p class="muted">{{ eventData.description || "" }}</p>\
      <label>Camara</label>\
      <select v-model="selectedCamera">\
        <option v-for="d in devices.cameras" :key="d.deviceId" :value="d.deviceId">{{ d.label || "Camara " + d.deviceId.slice(0,6) }}</option>\
      </select>\
      <label>Microfono</label>\
      <select v-model="selectedMic">\
        <option v-for="d in devices.mics" :key="d.deviceId" :value="d.deviceId">{{ d.label || "Mic " + d.deviceId.slice(0,6) }}</option>\
      </select>\
      <div v-if="eventData.status === \'finished\'" style="margin-top:12px;padding:12px;background:var(--ink-hover);border-radius:8px">\
        <div style="text-align:center;margin-bottom:8px"><span class="muted">Evento finalizado</span></div>\
        <div style="display:flex;gap:16px;justify-content:center;font-size:13px">\
          <span>&#10084; {{ eventData.like_count || 0 }} likes</span>\
          <span>&#128065; {{ eventData.spectator_count || 0 }} espectadores</span>\
        </div>\
      </div>\
      <button v-else class="primary" @click="startEvent" style="margin-top:8px">Entrar al evento</button>\
      <div style="display:flex;gap:8px;margin-top:8px">\
        <button class="ghost" style="flex:1" @click="copyJoinLink" title="Copiar link de participante">&#128279; Link participar</button>\
        <button class="ghost" style="flex:1" @click="copyWatchLink" title="Copiar link de espectador">&#128065; Link ver</button>\
      </div>\
      <button class="ghost" @click="$props.onBack" style="margin-top:4px">Volver</button>\
    </div>\
  </div>\
</div>\
<div v-else class="host-layout">\
  <div class="host-header">\
    <button class="ghost" @click="$props.onBack" title="Volver">&#8592;</button>\
    <h2 style="font-size:16px;margin:0">{{ eventData.title }}</h2>\
    <span class="event-status" :class="eventData.status" style="margin-left:8px">{{ eventData.status }}</span>\
    <span v-if="isRecording" class="rec-indicator" style="margin-left:12px"><span class="rec-dot"></span> REC</span>\
    <span v-if="spectatorCount" class="muted" style="margin-left:12px;font-size:12px">&#128065; {{ spectatorCount }}</span>\
    <span v-if="likeCount" class="muted" style="margin-left:8px;font-size:12px">&#10084; {{ likeCount }}</span>\
    <span class="spacer"></span>\
    <button class="ghost" @click="copyJoinLink" title="Copiar link de participante">&#128279; Participar</button>\
    <button class="ghost" @click="copyWatchLink" title="Copiar link de espectador">&#128065; Ver</button>\
  </div>\
  <div class="video-area">\
    <div class="video-card" :class="currentParticipant ? \'split\' : \'host-solo\'">\
      <video id="host-video" autoplay muted playsinline style="transform:scaleX(-1)"></video>\
      <div class="video-label">Tu (Host)</div>\
    </div>\
    <div v-if="currentParticipant" class="video-card split">\
      <video id="participant-video" autoplay playsinline></video>\
      <div v-if="currentParticipant.is_censored" class="censor-overlay">Censurado</div>\
      <div class="video-label">{{ currentParticipant.display_name }}</div>\
    </div>\
  </div>\
  <div class="controls-bar">\
    <button class="primary" @click="nextTurnAction" :disabled="!inQueueOnly.length">Siguiente &#9654;</button>\
    <button v-if="currentParticipant && !currentParticipant.is_censored" class="danger" @click="censorParticipant(currentParticipant.id)">Censurar</button>\
    <button v-if="currentParticipant" class="danger" @click="removeParticipant(currentParticipant.id)" title="Expulsar participante">Expulsar</button>\
    <span class="spacer"></span>\
    <button v-if="!isRecording" @click="startRecording">&#9679; Grabar</button>\
    <button v-else class="danger" @click="stopRecording">&#9632; Parar grabacion</button>\
    <button class="danger" @click="finishEvent" :disabled="eventData.status === \'finished\'">Finalizar</button>\
  </div>\
  <div class="queue-sidebar">\
    <div class="queue-section">\
      <h3>SOLICITUDES ({{ requests.length }})</h3>\
      <div v-if="!requests.length" class="muted" style="padding:4px 0">Sin solicitudes</div>\
      <div v-for="r in requests" :key="r.id" class="request-item">\
        <div class="avatar">{{ initials(r.display_name) }}</div>\
        <div style="flex:1;min-width:0">\
          <span class="name">{{ r.display_name }}</span>\
          <div v-if="r.questions && r.questions.length" class="participant-questions">\
            <div v-for="(q, i) in r.questions" :key="i" class="pq-item">{{ q }}</div>\
          </div>\
        </div>\
        <div class="actions">\
          <button class="icon" @click="approveRequest(r.id)" title="Aprobar" style="color:var(--signal-cool)">&#10003;</button>\
          <button class="icon danger" @click="rejectRequest(r.id)" title="Rechazar">&#10005;</button>\
        </div>\
      </div>\
    </div>\
    <div class="queue-section">\
      <h3>COLA ({{ inQueueOnly.length }})</h3>\
      <div v-if="!inQueueOnly.length" class="muted" style="padding:4px 0">Cola vacia</div>\
      <div v-for="p in inQueueOnly" :key="p.id" class="queue-item">\
        <div class="avatar">{{ initials(p.display_name) }}</div>\
        <div style="flex:1;min-width:0">\
          <span class="name">{{ p.display_name }}</span>\
          <div v-if="p.questions && p.questions.length" class="participant-questions">\
            <div v-for="(q, i) in p.questions" :key="i" class="pq-item">{{ q }}</div>\
          </div>\
        </div>\
        <span v-if="p.is_preconnected" style="color:var(--signal);font-size:10px" title="Pre-conectado">&#9679;</span>\
        <div class="actions">\
          <button class="icon" @click="skipTo(p.id)" title="Saltar a este">&#9654;</button>\
          <button class="icon danger" @click="removeParticipant(p.id)" title="Remover">&#10005;</button>\
        </div>\
      </div>\
    </div>\
    <div v-if="currentParticipant" class="queue-section">\
      <h3>AL AIRE</h3>\
      <div class="queue-item on-air">\
        <div class="avatar">{{ initials(currentParticipant.display_name) }}</div>\
        <div style="flex:1;min-width:0">\
          <span class="name">{{ currentParticipant.display_name }}</span>\
          <div v-if="currentParticipant.questions && currentParticipant.questions.length" class="participant-questions">\
            <div v-for="(q, i) in currentParticipant.questions" :key="i" class="pq-item">{{ q }}</div>\
          </div>\
        </div>\
        <span class="on-air-badge">EN VIVO</span>\
      </div>\
    </div>\
    <div class="chat-panel">\
      <div class="queue-section"><h3>CHAT</h3></div>\
      <div class="chat-messages">\
        <div v-for="m in chatMessages" :key="m.id || m.sender_name + m.message" class="chat-msg">\
          <span class="sender" :class="{ host: m.is_host }">{{ m.sender_name }}:</span>\
          <span class="text"> {{ m.message }}</span>\
        </div>\
      </div>\
      <div class="chat-input">\
        <input type="text" v-model="chatInput" placeholder="Escribe un mensaje..." @keyup.enter="sendChat">\
        <button class="primary" @click="sendChat" :disabled="!chatInput.trim()">Enviar</button>\
      </div>\
    </div>\
  </div>\
</div>'
};

// ── JoinView ─────────────────────────────────────────────────────────

var JoinView = {
  props: { eventId: [Number, String] },
  emits: ["joined"],
  setup: function (props, ctx) {
    var eventInfo = ref(null);
    var loading = ref(true);
    var displayName = ref("");
    var photoUrl = ref("");
    var error = ref("");
    var busy = ref(false);
    var submitted = ref(false);
    var participantData = ref(null);

    async function loadEventInfo() {
      loading.value = true;
      try {
        eventInfo.value = await api("/api/events/" + props.eventId + "/public-info");
      } catch (e) {
        error.value = "Evento no encontrado";
      }
      loading.value = false;
    }

    async function requestAccess() {
      if (!displayName.value.trim()) return;
      error.value = "";
      busy.value = true;
      try {
        var result = await api("/api/events/" + props.eventId + "/request-access", {
          method: "POST",
          body: { name: displayName.value.trim(), photo_url: photoUrl.value || null },
        });
        participantData.value = result;
        submitted.value = true;
      } catch (e) {
        error.value = e.message;
      }
      busy.value = false;
    }

    onMounted(loadEventInfo);

    return {
      eventInfo: eventInfo, loading: loading, displayName: displayName,
      photoUrl: photoUrl, error: error, busy: busy, submitted: submitted,
      participantData: participantData, requestAccess: requestAccess,
    };
  },
  template: '\
<div class="join-view" v-if="!submitted">\
  <div v-if="loading" class="loading">Cargando evento...</div>\
  <div v-else-if="error && !eventInfo" class="join-card"><p class="error-text">{{ error }}</p></div>\
  <div v-else class="join-card">\
    <h1 class="brand" style="margin-bottom:4px">ama<span class="brand-accent">Pod</span></h1>\
    <h2 style="margin:0 0 4px">{{ eventInfo.title }}</h2>\
    <p class="event-desc" v-if="eventInfo.description">{{ eventInfo.description }}</p>\
    <p class="muted" style="margin-bottom:16px">Evento de {{ eventInfo.host_username }} &middot; {{ eventInfo.status === "active" ? "EN VIVO" : eventInfo.status }}</p>\
    <form @submit.prevent="requestAccess">\
      <label>Tu nombre</label>\
      <input type="text" v-model="displayName" placeholder="Nombre para mostrar" autofocus required>\
      <label style="margin-top:8px">Foto (opcional)</label>\
      <input type="url" v-model="photoUrl" placeholder="URL de tu foto">\
      <button class="primary" :disabled="busy || !displayName.trim()" type="submit" style="margin-top:12px">{{ busy ? "Enviando..." : "Solicitar acceso" }}</button>\
      <p v-if="error" class="error-text">{{ error }}</p>\
    </form>\
  </div>\
</div>\
<participant-view v-else :participant-data="participantData" :event-id="eventId" />'
};

// ── ParticipantView ──────────────────────────────────────────────────

var ParticipantView = {
  props: { participantData: Object, eventId: [Number, String] },
  setup: function (props) {
    var pdata = ref(props.participantData);
    var room = ref(null);
    var connected = ref(false);
    var lkToken = ref(null);
    var statusPoll = ref(null);
    var isCensored = ref(false);
    var waitingForTap = ref(false);
    var lkError = ref("");

    var statusLabel = computed(function () {
      if (!pdata.value) return "";
      switch (pdata.value.status) {
        case "pending": return "Tu solicitud fue enviada. Esperando aprobacion...";
        case "approved": case "in_queue": return "Estas en la cola. Posicion aproximada: " + (pdata.value.approximate_position || "en la cola");
        case "on_air": return "EN VIVO";
        case "done": return "Gracias por participar";
        case "rejected": return "Tu solicitud no fue aprobada";
        case "left": return "Has salido del evento";
        default: return pdata.value.status;
      }
    });

    var showVideo = computed(function () {
      return pdata.value && pdata.value.status === "on_air";
    });

    var showPreconnect = computed(function () {
      return pdata.value && pdata.value.is_preconnected && pdata.value.status === "in_queue";
    });

    var canAskQuestions = computed(function () {
      return pdata.value && (pdata.value.status === "pending" || pdata.value.status === "in_queue" || pdata.value.status === "approved");
    });

    var myQuestions = ref(["", "", ""]);
    var questionsSaved = ref(false);

    async function saveQuestions() {
      if (!pdata.value || !pdata.value.access_token) return;
      var qs = myQuestions.value.filter(function (q) { return q.trim(); });
      try {
        await api("/api/events/" + props.eventId + "/my-questions?token=" + pdata.value.access_token, {
          method: "PUT",
          body: { questions: qs },
        });
        questionsSaved.value = true;
        setTimeout(function () { questionsSaved.value = false; }, 2000);
      } catch (_) {}
    }

    watch(function () { return props.participantData; }, function (v) {
      if (v) {
        if (!v.access_token && pdata.value && pdata.value.access_token) {
          v.access_token = pdata.value.access_token;
        }
        pdata.value = v;
      }
    }, { deep: true });

    async function pollStatus() {
      if (!pdata.value || !pdata.value.access_token) return;
      try {
        var savedToken = pdata.value.access_token;
        var s = await api("/api/events/" + props.eventId + "/my-status?token=" + savedToken);
        var oldStatus = pdata.value.status;
        s.access_token = savedToken;
        pdata.value = s;
        isCensored.value = !!s.is_censored;

        if (s.is_preconnected && !connected.value && s.status === "in_queue") {
          getTokenAndConnect(false);
        }
        if (s.status === "on_air" && oldStatus !== "on_air") {
          waitingForTap.value = true;
        }
      } catch (_) {}
    }

    async function getTokenAndConnect(canPublish) {
      if (!pdata.value) return;
      try {
        var tokenData = await api("/api/events/" + props.eventId + "/participant-token/" + pdata.value.id + "?token=" + pdata.value.access_token);
        lkToken.value = tokenData.token;
        var wsUrl = await getLivekitWsUrl();
        var newRoom = new LK.Room({ adaptiveStream: true, dynacast: true });

        newRoom.on(LK.RoomEvent.TrackSubscribed, function (track, pub, participant) {
          if (participant.identity.startsWith("host_")) {
            if (track.kind === LK.Track.Kind.Video) {
              nextTick(function () {
                var el = document.getElementById("pv-host-video");
                if (el) track.attach(el);
              });
            } else if (track.kind === LK.Track.Kind.Audio) {
              var a = track.attach();
              document.body.appendChild(a);
            }
          }
        });

        newRoom.on(LK.RoomEvent.TrackUnsubscribed, function (track) {
          track.detach().forEach(function (el) { el.remove(); });
        });

        newRoom.on(LK.RoomEvent.DataReceived, function (payload) {
          var msg = _decodeMsg(payload);
          if (!msg) return;
          if (msg.type === "censor" && msg.participant_id === pdata.value.id) {
            isCensored.value = true;
          }
          if (msg.type === "uncensor" && msg.participant_id === pdata.value.id) {
            isCensored.value = false;
          }
          if (msg.type === "event_ended") {
            pdata.value.status = "left";
            if (newRoom) newRoom.disconnect();
          }
        });

        newRoom.on(LK.RoomEvent.Disconnected, function () {
          connected.value = false;
        });

        await newRoom.connect(wsUrl, tokenData.token);
        room.value = newRoom;
        connected.value = true;

        if (canPublish) {
          await enablePublish();
        }
      } catch (e) {
        lkError.value = "Error al conectar: " + e.message;
        window.toast({ type: "error", text: lkError.value });
      }
    }

    async function enablePublish() {
      if (!room.value) {
        lkError.value = "Sin conexion a la sala";
        return;
      }
      try {
        // Single getUserMedia for both audio+video avoids iOS Safari
        // invalidating the first track when the second is requested.
        var tracks = await LK.createLocalTracks({ audio: true, video: true });
        for (var i = 0; i < tracks.length; i++) {
          await room.value.localParticipant.publishTrack(tracks[i]);
        }
        nextTick(function () {
          for (var j = 0; j < tracks.length; j++) {
            if (tracks[j].kind === LK.Track.Kind.Video) {
              var el = document.getElementById("pv-local-video");
              if (el) tracks[j].attach(el);
            }
          }
          attachHostTracks();
        });
      } catch (e) {
        lkError.value = "No se pudo activar camara/microfono: " + e.message;
        window.toast({ type: "error", text: lkError.value });
      }
    }

    function attachHostTracks() {
      if (!room.value) return;
      room.value.remoteParticipants.forEach(function (p) {
        if (!p.identity.startsWith("host_")) return;
        p.trackPublications.forEach(function (pub) {
          if (!pub.track) return;
          if (pub.track.kind === LK.Track.Kind.Video) {
            var el = document.getElementById("pv-host-video");
            if (el) pub.track.attach(el);
          } else if (pub.track.kind === LK.Track.Kind.Audio) {
            var a = pub.track.attach();
            document.body.appendChild(a);
          }
        });
      });
    }

    async function goLive() {
      waitingForTap.value = false;
      lkError.value = "";
      // Always reconnect fresh from the user-tap context.
      // Preconnect may have gone stale (iOS suspends idle WebSockets).
      if (room.value) {
        try { room.value.disconnect(); } catch (_) {}
        room.value = null;
        connected.value = false;
      }
      await getTokenAndConnect(true);
    }

    function leaveEvent() {
      if (room.value) { room.value.disconnect(); room.value = null; }
      connected.value = false;
      stopPolling();
      pdata.value.status = "left";
    }

    function startPoll() {
      statusPoll.value = setInterval(pollStatus, 3000);
    }

    function stopPolling() {
      if (statusPoll.value) { clearInterval(statusPoll.value); statusPoll.value = null; }
    }

    onMounted(startPoll);
    onBeforeUnmount(function () {
      stopPolling();
      if (room.value) { room.value.disconnect(); room.value = null; }
    });

    return {
      pdata: pdata, connected: connected, statusLabel: statusLabel,
      showVideo: showVideo, showPreconnect: showPreconnect, isCensored: isCensored,
      waitingForTap: waitingForTap, goLive: goLive, leaveEvent: leaveEvent, lkError: lkError,
      canAskQuestions: canAskQuestions, myQuestions: myQuestions, saveQuestions: saveQuestions, questionsSaved: questionsSaved,
    };
  },
  template: '\
<div class="participant-view">\
  <div v-if="waitingForTap" class="participant-status" style="text-align:center">\
    <h1 class="brand" style="margin-bottom:16px">ama<span class="brand-accent">Pod</span></h1>\
    <h2>{{ pdata && pdata.display_name }}</h2>\
    <p style="margin-bottom:20px">El host te puso al aire</p>\
    <button class="primary" @click="goLive" style="font-size:18px;padding:14px 32px">Entrar en vivo</button>\
    <p class="muted" style="margin-top:12px;font-size:13px">Se activara tu camara y microfono</p>\
  </div>\
  <div v-else-if="showVideo" style="width:100%;max-width:900px">\
    <div style="display:flex;gap:8px;align-items:center;justify-content:center;flex-wrap:wrap">\
      <div class="video-card split">\
        <video id="pv-host-video" autoplay muted playsinline></video>\
        <div class="video-label">Host</div>\
      </div>\
      <div class="video-card split" style="position:relative">\
        <video id="pv-local-video" autoplay muted playsinline style="transform:scaleX(-1)"></video>\
        <div v-if="isCensored" class="censor-overlay">Tu audio y video fueron pausados</div>\
        <div class="video-label">Tu</div>\
      </div>\
    </div>\
    <div v-if="lkError" style="text-align:center;margin-top:12px;padding:10px;background:#fee;border-radius:8px;color:#c00;font-size:14px">{{ lkError }}</div>\
    <div style="text-align:center;margin-top:12px">\
      <span class="on-air-badge">EN VIVO</span>\
      <button class="primary" @click="goLive" style="margin-left:12px" v-if="lkError">Reintentar</button>\
      <button class="danger" @click="leaveEvent" style="margin-left:12px">Abandonar</button>\
    </div>\
  </div>\
  <div v-else class="participant-status">\
    <h1 class="brand" style="margin-bottom:16px">ama<span class="brand-accent">Pod</span></h1>\
    <h2>{{ pdata && pdata.display_name }}</h2>\
    <p>{{ statusLabel }}</p>\
    <div v-if="pdata && pdata.status === \'pending\'" style="margin-top:16px">\
      <div class="muted">Esperando que el host apruebe tu solicitud...</div>\
    </div>\
    <div v-if="showPreconnect" style="margin-top:12px">\
      <div class="muted">Pre-conectado. Tu turno esta cerca.</div>\
    </div>\
    <div v-if="canAskQuestions" style="margin-top:20px;width:100%;max-width:360px">\
      <h4 style="margin:0 0 8px;font-size:14px">Tus preguntas <span class="muted" style="font-weight:normal">(opcional, max 3)</span></h4>\
      <input type="text" v-model="myQuestions[0]" placeholder="Pregunta 1" style="margin-bottom:6px;width:100%;box-sizing:border-box">\
      <input type="text" v-model="myQuestions[1]" placeholder="Pregunta 2" style="margin-bottom:6px;width:100%;box-sizing:border-box">\
      <input type="text" v-model="myQuestions[2]" placeholder="Pregunta 3" style="margin-bottom:8px;width:100%;box-sizing:border-box">\
      <button class="primary" @click="saveQuestions" style="font-size:13px;padding:6px 16px">Guardar preguntas</button>\
      <span v-if="questionsSaved" style="color:var(--signal-cool);margin-left:8px;font-size:13px">&#10003; Guardado</span>\
    </div>\
    <div v-if="pdata && (pdata.status === \'done\' || pdata.status === \'left\' || pdata.status === \'rejected\')" style="margin-top:16px">\
      <div class="muted">Puedes cerrar esta ventana.</div>\
    </div>\
    <div v-if="pdata && (pdata.status === \'in_queue\' || pdata.status === \'pending\')" style="margin-top:16px">\
      <button class="ghost" @click="leaveEvent">Abandonar la cola</button>\
    </div>\
  </div>\
</div>'
};

// ── EmbedHostView ────────────────────────────────────────────────────

var EmbedHostView = {
  props: { eventId: Number, user: Object },
  setup: function (props) {
    var eventData = ref(null);
    var loading = ref(true);
    var queue = ref([]);
    var requests = ref([]);
    var chatMessages = ref([]);
    var chatInput = ref("");
    var currentParticipant = ref(null);
    var isRecording = ref(false);
    var pollTimer = ref(null);

    function notifyParent(type, payload) {
      if (window.parent !== window) {
        var msg = { source: "amapod", type: type };
        if (payload) for (var k in payload) msg[k] = payload[k];
        window.parent.postMessage(msg, "*");
      }
    }

    async function loadEvent() {
      loading.value = true;
      try {
        eventData.value = await api("/api/events/" + props.eventId);
      } catch (e) {
        window.toast({ type: "error", text: "Evento no encontrado" });
      }
      loading.value = false;
    }

    async function loadQueue() {
      if (!eventData.value) return;
      try {
        queue.value = await api("/api/events/" + props.eventId + "/queue");
        var onAir = queue.value.find(function (p) { return p.status === "on_air"; });
        currentParticipant.value = onAir || null;
      } catch (_) {}
    }

    async function loadRequests() {
      if (!eventData.value) return;
      try { requests.value = await api("/api/events/" + props.eventId + "/requests"); } catch (_) {}
    }

    async function loadChat() {
      if (!eventData.value) return;
      try { chatMessages.value = await api("/api/events/" + props.eventId + "/chat"); } catch (_) {}
    }

    function startPolling() {
      loadQueue();
      loadRequests();
      loadChat();
      pollTimer.value = setInterval(function () { loadQueue(); loadRequests(); loadChat(); }, 3000);
    }

    function stopPolling() {
      if (pollTimer.value) { clearInterval(pollTimer.value); pollTimer.value = null; }
    }

    async function approveRequest(pid) {
      try {
        await api("/api/events/" + props.eventId + "/approve/" + pid, { method: "POST" });
        loadQueue();
        loadRequests();
      } catch (e) { window.toast({ type: "error", text: e.message }); }
    }

    async function rejectRequest(pid) {
      try {
        await api("/api/events/" + props.eventId + "/reject/" + pid, { method: "POST" });
        loadRequests();
      } catch (e) { window.toast({ type: "error", text: e.message }); }
    }

    async function nextTurnAction() {
      try {
        var result = await api("/api/events/" + props.eventId + "/next", { method: "POST" });
        if (result.status === "on_air") {
          notifyParent("ama_participant_active", {
            livekit_room: eventData.value.livekit_room_name,
            participant_identity: "participant_" + result.id,
            display_name: result.display_name,
          });
        }
        if (result.message) {
          window.toast({ type: "info", text: result.message });
        }
        loadQueue();
      } catch (e) { window.toast({ type: "error", text: e.message }); }
    }

    async function censorParticipant(pid) {
      try {
        await api("/api/events/" + props.eventId + "/censor/" + pid, { method: "POST" });
        loadQueue();
      } catch (e) { window.toast({ type: "error", text: e.message }); }
    }

    async function uncensorParticipant(pid) {
      try {
        await api("/api/events/" + props.eventId + "/uncensor/" + pid, { method: "POST" });
        loadQueue();
      } catch (e) { window.toast({ type: "error", text: e.message }); }
    }

    async function removeParticipant(pid) {
      try {
        await api("/api/events/" + props.eventId + "/remove/" + pid, { method: "DELETE" });
        notifyParent("ama_participant_removed", { participant_identity: "participant_" + pid });
        loadQueue();
      } catch (e) { window.toast({ type: "error", text: e.message }); }
    }

    async function finishEvent() {
      if (!eventData.value) return;
      try {
        var updated = await api("/api/events/" + props.eventId + "/finish", { method: "POST" });
        eventData.value = updated;
        notifyParent("ama_session_ended", {});
        stopPolling();
      } catch (e) { window.toast({ type: "error", text: e.message }); }
    }

    async function startRecording() {
      try {
        await api("/api/events/" + props.eventId + "/recording/start", { method: "POST" });
        isRecording.value = true;
      } catch (e) { window.toast({ type: "error", text: e.message }); }
    }

    async function stopRecording() {
      try {
        await api("/api/events/" + props.eventId + "/recording/stop", { method: "POST" });
        isRecording.value = false;
      } catch (e) { window.toast({ type: "error", text: e.message }); }
    }

    async function sendChat() {
      var msg = chatInput.value.trim();
      if (!msg) return;
      chatInput.value = "";
      try {
        var sent = await api("/api/events/" + props.eventId + "/chat", { method: "POST", body: { message: msg } });
        chatMessages.value.push(sent);
      } catch (e) { window.toast({ type: "error", text: e.message }); }
    }

    var inQueueOnly = computed(function () {
      return queue.value.filter(function (p) { return p.status === "in_queue"; });
    });

    onMounted(function () {
      loadEvent().then(startPolling);
    });

    onBeforeUnmount(stopPolling);

    return {
      eventData: eventData, loading: loading,
      queue: queue, requests: requests, chatMessages: chatMessages, chatInput: chatInput,
      currentParticipant: currentParticipant, isRecording: isRecording, inQueueOnly: inQueueOnly,
      approveRequest: approveRequest, rejectRequest: rejectRequest,
      nextTurnAction: nextTurnAction, censorParticipant: censorParticipant,
      uncensorParticipant: uncensorParticipant, removeParticipant: removeParticipant,
      finishEvent: finishEvent, startRecording: startRecording, stopRecording: stopRecording,
      sendChat: sendChat, initials: initials,
    };
  },
  template: '\
<div class="embed-host-view">\
  <div v-if="loading" class="loading" style="padding:40px">Cargando...</div>\
  <template v-else-if="eventData">\
    <div class="embed-header">\
      <span class="brand" style="font-size:14px">ama<span class="brand-accent">Pod</span></span>\
      <span class="event-status" :class="eventData.status">{{ eventData.status }}</span>\
      <span v-if="isRecording" class="rec-indicator"><span class="rec-dot"></span> REC</span>\
      <span class="spacer"></span>\
      <button class="primary" @click="nextTurnAction" :disabled="!inQueueOnly.length" style="font-size:12px;padding:4px 10px">Siguiente</button>\
      <button v-if="!isRecording" @click="startRecording" style="font-size:12px;padding:4px 10px">&#9679; Rec</button>\
      <button v-else class="danger" @click="stopRecording" style="font-size:12px;padding:4px 10px">&#9632; Stop</button>\
      <button class="danger" @click="finishEvent" style="font-size:12px;padding:4px 10px">Fin</button>\
    </div>\
    <div class="embed-body">\
      <div v-if="currentParticipant" class="queue-section">\
        <h3>AL AIRE</h3>\
        <div class="queue-item on-air">\
          <div class="avatar">{{ initials(currentParticipant.display_name) }}</div>\
          <div style="flex:1;min-width:0">\
            <span class="name">{{ currentParticipant.display_name }}</span>\
            <div v-if="currentParticipant.questions && currentParticipant.questions.length" class="participant-questions">\
              <div v-for="(q, i) in currentParticipant.questions" :key="i" class="pq-item">{{ q }}</div>\
            </div>\
          </div>\
          <span class="on-air-badge" style="font-size:10px;padding:2px 8px">EN VIVO</span>\
          <button v-if="!currentParticipant.is_censored" class="icon danger" @click="censorParticipant(currentParticipant.id)" title="Censurar">&#128263;</button>\
          <button class="icon danger" @click="removeParticipant(currentParticipant.id)" title="Expulsar">&#10005;</button>\
        </div>\
      </div>\
      <div class="queue-section">\
        <h3>SOLICITUDES ({{ requests.length }})</h3>\
        <div v-for="r in requests" :key="r.id" class="request-item">\
          <div class="avatar">{{ initials(r.display_name) }}</div>\
          <div style="flex:1;min-width:0">\
            <span class="name">{{ r.display_name }}</span>\
            <div v-if="r.questions && r.questions.length" class="participant-questions">\
              <div v-for="(q, i) in r.questions" :key="i" class="pq-item">{{ q }}</div>\
            </div>\
          </div>\
          <button class="icon" @click="approveRequest(r.id)" style="color:var(--signal-cool)">&#10003;</button>\
          <button class="icon danger" @click="rejectRequest(r.id)">&#10005;</button>\
        </div>\
      </div>\
      <div class="queue-section">\
        <h3>COLA ({{ inQueueOnly.length }})</h3>\
        <div v-for="p in inQueueOnly" :key="p.id" class="queue-item">\
          <div class="avatar">{{ initials(p.display_name) }}</div>\
          <div style="flex:1;min-width:0">\
            <span class="name">{{ p.display_name }}</span>\
            <div v-if="p.questions && p.questions.length" class="participant-questions">\
              <div v-for="(q, i) in p.questions" :key="i" class="pq-item">{{ q }}</div>\
            </div>\
          </div>\
          <button class="icon danger" @click="removeParticipant(p.id)" title="Remover">&#10005;</button>\
        </div>\
      </div>\
      <div class="chat-panel">\
        <div class="queue-section"><h3>CHAT</h3></div>\
        <div class="chat-messages">\
          <div v-for="m in chatMessages" :key="m.id" class="chat-msg">\
            <span class="sender" :class="{ host: m.is_host }">{{ m.sender_name }}:</span>\
            <span class="text"> {{ m.message }}</span>\
          </div>\
        </div>\
        <div class="chat-input">\
          <input type="text" v-model="chatInput" placeholder="Mensaje..." @keyup.enter="sendChat">\
          <button class="primary" @click="sendChat" :disabled="!chatInput.trim()" style="font-size:12px">Enviar</button>\
        </div>\
      </div>\
    </div>\
  </template>\
</div>'
};

// ── SpectatorView ───────────────────────────────────────────────────

var SpectatorView = {
  props: { eventId: [Number, String] },
  setup: function (props) {
    var eventInfo = ref(null);
    var loading = ref(true);
    var error = ref("");
    var room = ref(null);
    var connected = ref(false);
    var likeCount = ref(0);
    var spectatorCount = ref(0);
    var likeBurst = ref([]);
    var _burstId = 0;
    var pollTimer = ref(null);

    async function loadEvent() {
      loading.value = true;
      try {
        eventInfo.value = await api("/api/events/" + props.eventId + "/public-info");
        likeCount.value = eventInfo.value.like_count || 0;
        spectatorCount.value = eventInfo.value.spectator_count || 0;
        if (eventInfo.value.status === "active") {
          await connectToRoom();
        }
      } catch (e) {
        error.value = "Evento no encontrado";
      }
      loading.value = false;
    }

    async function connectToRoom() {
      try {
        var tokenData = await api("/api/events/" + props.eventId + "/spectator-token", { method: "POST" });
        var wsUrl = await getLivekitWsUrl();
        var newRoom = new LK.Room({ adaptiveStream: true, dynacast: true });

        newRoom.on(LK.RoomEvent.TrackSubscribed, function (track) {
          if (track.kind === LK.Track.Kind.Video) {
            nextTick(function () {
              var el = document.getElementById("spec-video");
              if (el) track.attach(el);
            });
          } else if (track.kind === LK.Track.Kind.Audio) {
            var a = track.attach();
            document.body.appendChild(a);
          }
        });

        newRoom.on(LK.RoomEvent.TrackUnsubscribed, function (track) {
          track.detach().forEach(function (el) { el.remove(); });
        });

        newRoom.on(LK.RoomEvent.DataReceived, function (payload) {
          var msg = _decodeMsg(payload);
          if (msg && msg.type === "event_ended") {
            eventInfo.value.status = "finished";
            if (newRoom) newRoom.disconnect();
          }
        });

        newRoom.on(LK.RoomEvent.Disconnected, function () {
          connected.value = false;
        });

        await newRoom.connect(wsUrl, tokenData.token);
        room.value = newRoom;
        connected.value = true;

        pollTimer.value = setInterval(pollLikes, 5000);
      } catch (e) {
        error.value = "Error al conectar: " + e.message;
      }
    }

    async function pollLikes() {
      try {
        var info = await api("/api/events/" + props.eventId + "/public-info");
        likeCount.value = info.like_count || 0;
        spectatorCount.value = info.spectator_count || 0;
        if (info.status !== "active") {
          eventInfo.value.status = info.status;
          if (room.value) { room.value.disconnect(); room.value = null; }
          connected.value = false;
          if (pollTimer.value) { clearInterval(pollTimer.value); pollTimer.value = null; }
        }
      } catch (_) {}
    }

    async function sendLike() {
      var id = ++_burstId;
      likeBurst.value.push({ id: id, x: 20 + Math.random() * 60 });
      setTimeout(function () {
        likeBurst.value = likeBurst.value.filter(function (b) { return b.id !== id; });
      }, 1200);
      try {
        var res = await api("/api/events/" + props.eventId + "/like", { method: "POST" });
        likeCount.value = res.like_count;
      } catch (_) {}
    }

    function leave() {
      if (room.value) { room.value.disconnect(); room.value = null; }
      connected.value = false;
      if (pollTimer.value) { clearInterval(pollTimer.value); pollTimer.value = null; }
      eventInfo.value.status = "left";
    }

    onMounted(loadEvent);
    onBeforeUnmount(function () {
      if (pollTimer.value) { clearInterval(pollTimer.value); pollTimer.value = null; }
      if (room.value) { room.value.disconnect(); room.value = null; }
    });

    return {
      eventInfo: eventInfo, loading: loading, error: error,
      connected: connected, likeCount: likeCount, spectatorCount: spectatorCount,
      likeBurst: likeBurst, sendLike: sendLike, leave: leave,
    };
  },
  template: '\
<div class="spectator-view">\
  <div v-if="loading" class="loading" style="padding:40px">Cargando...</div>\
  <div v-else-if="error && !eventInfo" class="participant-status"><p class="error-text">{{ error }}</p></div>\
  <div v-else-if="eventInfo && eventInfo.status !== \'active\' && !connected" class="participant-status" style="text-align:center">\
    <h1 class="brand" style="margin-bottom:16px">ama<span class="brand-accent">Pod</span></h1>\
    <h2>{{ eventInfo.title }}</h2>\
    <p class="muted">{{ eventInfo.status === "finished" ? "Este evento ya finalizo" : "El evento aun no comienza" }}</p>\
  </div>\
  <template v-else>\
    <div class="spec-video-wrap" @click="sendLike">\
      <video id="spec-video" autoplay muted playsinline></video>\
      <div class="spec-overlay-top">\
        <span class="brand" style="font-size:14px">ama<span class="brand-accent">Pod</span></span>\
        <span class="spec-badge">EN VIVO</span>\
        <span class="spec-viewers">&#128065; {{ spectatorCount }}</span>\
      </div>\
      <div class="spec-overlay-bottom">\
        <h3 style="margin:0;font-size:15px">{{ eventInfo.title }}</h3>\
      </div>\
      <div class="spec-like-counter">&#10084; {{ likeCount }}</div>\
      <div v-for="b in likeBurst" :key="b.id" class="spec-like-float" :style="{ left: b.x + \'%\' }">&#10084;</div>\
    </div>\
    <div style="text-align:center;padding:8px">\
      <button class="ghost" @click="leave" style="font-size:13px">Salir</button>\
    </div>\
  </template>\
</div>'
};

// ── App ──────────────────────────────────────────────────────────────

var App = {
  components: {
    LoginView: LoginView, DashboardView: DashboardView, HostView: HostView,
    JoinView: JoinView, ParticipantView: ParticipantView, EmbedHostView: EmbedHostView,
    SpectatorView: SpectatorView, ToastHost: ToastHost,
  },
  setup: function () {
    var state = reactive({
      user: null,
      route: "loading",
      activeEvent: null,
      joinEventId: null,
      embedEventId: null,
      watchEventId: null,
    });

    function parseRoute() {
      var path = window.location.pathname;
      var m;
      m = path.match(/^\/join\/(\d+)$/);
      if (m) { state.joinEventId = parseInt(m[1]); state.route = "join"; return; }
      m = path.match(/^\/watch\/(\d+)$/);
      if (m) { state.watchEventId = parseInt(m[1]); state.route = "watch"; return; }
      m = path.match(/^\/embed\/(\d+)$/);
      if (m) { state.embedEventId = parseInt(m[1]); state.route = "embed"; return; }
    }

    async function checkAuth() {
      try {
        state.user = await api("/api/auth/me");
        parseRoute();
        if (state.route === "loading") state.route = "dashboard";
      } catch (_) {
        parseRoute();
        if (state.route === "loading") state.route = "login";
      }
    }

    function onLoggedIn(u) { state.user = u; state.route = "dashboard"; }
    function openEvent(e) { state.activeEvent = e; state.route = "host"; }
    function backToDashboard() { state.activeEvent = null; state.route = "dashboard"; }
    async function logout() {
      try { await api("/api/auth/logout", { method: "POST" }); } catch (_) {}
      state.user = null;
      state.route = "login";
    }

    onMounted(checkAuth);
    return { state: state, onLoggedIn: onLoggedIn, openEvent: openEvent, backToDashboard: backToDashboard, logout: logout };
  },
  template: '\
<div class="app-root">\
  <toast-host />\
  <login-view v-if="state.route === \'login\'" :on-logged-in="onLoggedIn" />\
  <dashboard-view v-else-if="state.route === \'dashboard\'" :user="state.user" @open-event="openEvent" :on-logout="logout" />\
  <host-view v-else-if="state.route === \'host\'" :event="state.activeEvent" :user="state.user" :on-back="backToDashboard" />\
  <join-view v-else-if="state.route === \'join\'" :event-id="state.joinEventId" />\
  <spectator-view v-else-if="state.route === \'watch\'" :event-id="state.watchEventId" />\
  <embed-host-view v-else-if="state.route === \'embed\'" :event-id="state.embedEventId" :user="state.user" />\
  <div v-else class="loading">Cargando...</div>\
</div>'
};

var _app = createApp(App);
_app.component("participant-view", ParticipantView);
_app.mount("#app");
