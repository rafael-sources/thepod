var { createApp, reactive, ref, computed, onMounted, onBeforeUnmount, watch, nextTick } = Vue;
var LK = window.LivekitClient;

/* thePod mobile: small or touch screen? (reactive) */
var _touchRef = null;
function useTouch() {
  if (!_touchRef) {
    _touchRef = ref(false);
    try {
      var mq = window.matchMedia("(max-width: 900px), (pointer: coarse)");
      _touchRef.value = mq.matches;
      (mq.addEventListener ? mq.addEventListener("change", function () { _touchRef.value = mq.matches; }) : mq.addListener(function () { _touchRef.value = mq.matches; }));
    } catch (_) {}
  }
  return _touchRef;
}
var M_ICONS = {
  events: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" aria-hidden="true"><rect x="4" y="4" width="16" height="16" rx="3"/><path d="M8 9h8M8 13h6M8 17h4"/></svg>',
  templates: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" aria-hidden="true"><rect x="4" y="4" width="7" height="7" rx="2"/><rect x="13" y="4" width="7" height="7" rx="2"/><rect x="4" y="13" width="7" height="7" rx="2"/><rect x="13" y="13" width="7" height="7" rx="2"/></svg>',
  me: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" aria-hidden="true"><circle cx="12" cy="9" r="4"/><path d="M4.5 20c1.5-4 4-6 7.5-6s6 2 7.5 6"/></svg>',
  back: '<svg viewBox="0 0 22 22" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M13 4l-7 7 7 7"/></svg>',
  plus: '<svg viewBox="0 0 26 26" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" aria-hidden="true"><path d="M13 5v16M5 13h16"/></svg>',
  hand: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M8 12V5.5a1.5 1.5 0 0 1 3 0V11M11 11V4.5a1.5 1.5 0 0 1 3 0V11M14 11V6a1.5 1.5 0 0 1 3 0v8"/><path d="M8 12l-2-2.5a1.4 1.4 0 0 0-2.3 1.6L7 16.5c1.2 2.2 2.8 3.5 5.5 3.5 3.3 0 4.5-2.2 4.5-5V9"/></svg>',
  queue: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" aria-hidden="true"><path d="M4 7h16M4 12h16M4 17h10"/></svg>',
  chat: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 6a2 2 0 0 1 2-2h12a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H9l-4 4v-4H6a2 2 0 0 1-2-2z"/></svg>',
  more: '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><circle cx="6" cy="12" r="2"/><circle cx="12" cy="12" r="2"/><circle cx="18" cy="12" r="2"/></svg>',
};
var EV_STATE = { created: { label: "Sin empezar", color: "#f4c770" }, active: { label: "En vivo", color: "#2dd4bf" }, finished: { label: "Terminado", color: "#9d9078" } };

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

/* «Instalar thePod» and «Avisos» rows of the «Yo» sheet (uses window.podPWA from pod-base.js) */
var PodPwaRows = {
  setup: function () {
    var P = window.podPWA || { enabled: false };
    var st = reactive({ enabled: !!P.enabled, canInstall: false, installed: false, isIOS: false, push: "unsupported", busy: false, msg: "", showIos: false });
    function refresh() {
      if (!st.enabled) return;
      st.canInstall = P.canInstall; st.installed = P.installed; st.isIOS = P.isIOS;
      Promise.resolve(P.pushState()).then(function (s) { st.push = s; });
    }
    function install() {
      if (st.canInstall) { P.install().then(function (ok) { st.msg = ok ? "Listo: busca «thePod» en tu pantalla de inicio." : ""; refresh(); }); }
      else st.showIos = !st.showIos;
    }
    function togglePush() {
      st.busy = true; st.msg = "";
      var p = st.push === "on" ? P.disablePush() : P.enablePush();
      p.then(function () { refresh(); st.msg = st.push === "on" ? "" : "Avisos activados en este teléfono."; })
       .catch(function (e) { st.msg = e.message || "No se pudo."; })
       .finally(function () { st.busy = false; });
    }
    function test() {
      st.busy = true;
      P.testPush().then(function (d) { st.msg = d.sent ? "Aviso enviado: debería sonar en un momento." : "No llegó a ningún teléfono."; })
       .catch(function () { st.msg = "No se pudo enviar."; }).finally(function () { st.busy = false; });
    }
    onMounted(function () { refresh(); P.onchange = refresh; });
    return { st: st, install: install, togglePush: togglePush, test: test };
  },
  template: '\
<template v-if="st.enabled">\
  <button v-if="!st.installed && (st.canInstall || st.isIOS)" type="button" class="m-opt" @click="install">\
    <span>📲</span>Instalar thePod en este teléfono\
  </button>\
  <p v-if="st.showIos" class="m-help">En Safari: toca <b>Compartir</b> (el cuadrado con la flecha) y luego <b>«Añadir a pantalla de inicio»</b>. Desde ahí abre como una app y puede recibir avisos.</p>\
  <button v-if="st.push === \'off\'" type="button" class="m-opt" :disabled="st.busy" @click="togglePush"><span>🔔</span>Activar avisos en este teléfono</button>\
  <template v-else-if="st.push === \'on\'">\
    <button type="button" class="m-opt" :disabled="st.busy" @click="test"><span>🔔</span>Avisos activados · tocar para probar</button>\
    <button type="button" class="m-opt" style="color:var(--paper-dim);" :disabled="st.busy" @click="togglePush">Desactivar avisos aquí</button>\
  </template>\
  <p v-else-if="st.push === \'needs-install\'" class="m-help">Para recibir avisos en iPhone, primero instala thePod (arriba).</p>\
  <p v-else-if="st.push === \'denied\'" class="m-help">Los avisos están bloqueados para este sitio en los ajustes del navegador.</p>\
  <p v-if="st.msg" class="m-help" aria-live="polite">{{ st.msg }}</p>\
</template>',
};

var DashboardView = {
  props: { user: Object, onLogout: Function },
  emits: ["open-event"],
  setup: function (props, ctx) {
    var touch = useTouch();
    var mTab = ref("events");
    var meOpen = ref(false);
    var appsOpen = ref(false);
    var thepodUrl = ref("");
    function mGo(t) { if (t === "me") { meOpen.value = true; return; } mTab.value = t; }
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
        thepodUrl.value = cfg.thepod_url || "";
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
             deleteEvent: deleteEvent, openEvent: openEvent, fmtDate: fmtDate,
             touch: touch, mTab: mTab, meOpen: meOpen, appsOpen: appsOpen, thepodUrl: thepodUrl, mGo: mGo, M_ICONS: M_ICONS, EV_STATE: EV_STATE };
  },
  template: '\
<div v-if="touch" class="m-shell">\
  <div class="m-top">\
    <h2 style="padding-left:10px;">{{ mTab === \'templates\' ? \'Plantillas\' : \'Eventos\' }}</h2>\
    <button type="button" class="m-appchip" aria-haspopup="dialog" @click="appsOpen = true">thePod · <b>ama</b> ▾</button>\
  </div>\
  <div class="m-scroll" v-if="mTab === \'events\'">\
    <div v-if="loading" class="loading">Cargando...</div>\
    <p v-else-if="!events.length" class="muted" style="padding:24px 4px;text-align:center;">No hay eventos. Toca «+» para crear el primero.</p>\
    <button v-for="e in events" :key="e.id" type="button" class="m-card" :style="{ borderLeftColor: (EV_STATE[e.status] || {}).color }" @click="openEvent(e)">\
      <div style="display:flex;align-items:baseline;gap:10px;">\
        <span class="m-state" :style="{ color: (EV_STATE[e.status] || {}).color }">{{ (EV_STATE[e.status] || { label: e.status }).label }}</span>\
        <span style="margin-left:auto;font-size:13px;color:var(--paper-soft);">{{ fmtDate(e.created_at) }}</span>\
      </div>\
      <div class="m-title">{{ e.title }}</div>\
      <div class="m-meta">\
        <span v-if="e.description" style="flex:1;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">{{ e.description }}</span>\
        <span v-if="e.like_count || e.spectator_count">&#10084; {{ e.like_count || 0 }} &middot; &#128065; {{ e.spectator_count || 0 }}</span>\
        <span v-if="e.status === \'created\'" class="m-chip" role="button" tabindex="0" style="margin-left:auto;color:var(--signal-hot);" @click.stop="deleteEvent(e.id)" @keydown.enter.stop="deleteEvent(e.id)">Eliminar</span>\
      </div>\
    </button>\
  </div>\
  <div class="m-scroll" v-else>\
    <p class="muted" style="padding:4px 2px 0;">Toca una plantilla para crear un evento con ese título y descripción.</p>\
    <p v-if="!templates.length" class="muted" style="padding:24px 4px;text-align:center;">Todavía no hay plantillas. Se guardan desde el escritorio.</p>\
    <button v-for="t in templates" :key="t.id" type="button" class="m-card" @click="createFromTemplate(t.id); mTab = \'events\'">\
      <div class="m-title" style="margin-top:0;">{{ t.title }}</div>\
    </button>\
  </div>\
  <button type="button" class="m-fab" aria-label="Nuevo evento" @click="showCreate = true"><span v-html="M_ICONS.plus"></span></button>\
  <nav class="m-tabs" aria-label="Secciones de amaPod">\
    <button type="button" :aria-current="mTab === \'events\' ? \'page\' : null" @click="mGo(\'events\')"><span class="m-ico" v-html="M_ICONS.events"></span>Eventos</button>\
    <button type="button" :aria-current="mTab === \'templates\' ? \'page\' : null" @click="mGo(\'templates\')"><span class="m-ico" v-html="M_ICONS.templates"></span>Plantillas</button>\
    <button type="button" @click="mGo(\'me\')"><span class="m-ico" v-html="M_ICONS.me"></span>Yo</button>\
  </nav>\
  <div v-if="showCreate" class="create-modal-overlay" @click.self="showCreate = false">\
    <div class="create-modal" role="dialog" aria-label="Nuevo evento">\
      <h2>Nuevo evento</h2>\
      <label>Título</label>\
      <input type="text" v-model="newTitle" placeholder="Título del evento" autofocus>\
      <label style="margin-top:10px">Descripción</label>\
      <textarea v-model="newDesc" placeholder="Descripción (opcional)" rows="3"></textarea>\
      <div class="modal-actions">\
        <button @click="showCreate = false">Cancelar</button>\
        <button class="primary" @click="createEvent" :disabled="!newTitle.trim()">Crear</button>\
      </div>\
    </div>\
  </div>\
  <div v-if="appsOpen" class="m-sheet-backdrop" @click.self="appsOpen = false">\
    <div class="m-sheet" role="dialog" aria-label="Cambiar de app">\
      <div class="m-sheet-grab"></div>\
      <h4>Estás en amaPod</h4>\
      <a v-for="a in apps" :key="a.key" class="m-opt" :href="a.url"><span class="ico" :data-app="a.key"></span>{{ a.name }}</a>\
      <a class="m-opt" :href="thepodUrl || \'/\'">thePod · inicio</a>\
    </div>\
  </div>\
  <div v-if="meOpen" class="m-sheet-backdrop" @click.self="meOpen = false">\
    <div class="m-sheet" role="dialog" aria-label="Mi cuenta">\
      <div class="m-sheet-grab"></div>\
      <h4>{{ user && user.username }}</h4>\
      <a class="m-opt" :href="(thepodUrl || \'\') + \'/perfil\'">Mi perfil: foto, nombre y contraseña</a>\
      <a class="m-opt" :href="(thepodUrl || \'\') + \'/docs/amapod\'">Cómo se usa amaPod</a>\
      <PodPwaRows />\
      <button type="button" class="m-opt" style="color:var(--signal-hot);" @click="$props.onLogout">Cerrar sesión</button>\
    </div>\
  </div>\
</div>\
<div v-else>\
  <header class="app-header">\
    <span class="brand">ama<span class="brand-accent">Pod</span></span>\
    <div class="sibling-apps d-only">\
      <a v-for="a in apps" :key="a.key" :href="a.url" class="sibling-link"><span class="ico" :data-app="a.key"></span> {{ a.name }}</a>\
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
      <button @click="showCreate = true" class="primary dash-new">+ Nuevo evento</button>\
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
        <div class="event-status" :class="e.status">{{ ({ created: "Sin empezar", active: "En vivo", finished: "Terminado" })[e.status] || e.status }}</div>\
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

// Chat moderation (host): approve, remove or block the author. Then notifies through the
// room (if any) so the audience reloads the chat without waiting.
function _chatModeration(eventId, reload, roomRef) {
  function notify() {
    var room = roomRef && roomRef.value;
    if (room) {
      try { room.localParticipant.publishData(_encodeMsg({ type: "chat_refresh" }), LK.DataPacket_Kind.RELIABLE); } catch (_) {}
    }
  }
  async function act(method, path) {
    try { await api("/api/events/" + eventId() + "/chat/" + path, { method: method }); }
    catch (e) { window.toast({ type: "error", text: e.message }); }
    await reload(); notify();
  }
  return {
    approveMsg: function (m) { return act("POST", m.id + "/approve"); },
    removeMsg: function (m) { return act("DELETE", String(m.id)); },
    blockMsg: function (m) { return act("POST", m.id + "/block"); },
  };
}

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

    // Mobile / iPad: a single panel section at a time
    var sideTab = ref("solicitudes");
    var seenRequests = ref(0);
    var seenChat = ref(0);
    var now = ref(Date.now());
    var ticker = null;
    var _wakeH = null;
    async function keepAwakeH() {
      try { if ("wakeLock" in navigator && !_wakeH) { _wakeH = await navigator.wakeLock.request("screen"); _wakeH.addEventListener("release", function () { _wakeH = null; }); } } catch (_) {}
    }
    function onVisH() { if (document.visibilityState === "visible" && phase.value === "live") keepAwakeH(); }
    function setTab(t) {
      sideTab.value = t;
      if (t === "solicitudes") seenRequests.value = requests.value.length;
      if (t === "chat") { seenChat.value = chatMessages.value.length; scrollChat(); }
    }
    var newRequests = computed(function () {
      if (sideTab.value === "solicitudes") return 0;
      return Math.max(0, requests.value.length - seenRequests.value);
    });
    var unreadChat = computed(function () {
      if (sideTab.value === "chat") return 0;
      return Math.max(0, chatMessages.value.length - seenChat.value);
    });
    var turnTime = computed(function () {
      var p = currentParticipant.value;
      if (!p || !p.turn_started_at) return "";
      var t = p.turn_started_at; var d = new Date(/Z$|[+-]\d\d:?\d\d$/.test(t) ? t : t.replace(" ", "T") + "Z");
      var sec = Math.max(0, Math.floor((now.value - d.getTime()) / 1000));
      if (isNaN(sec)) return "";
      return Math.floor(sec / 60) + ":" + String(sec % 60).padStart(2, "0");
    });
    function statusLabel(st) { return { created: "Sin empezar", active: "En vivo", finished: "Terminado" }[st] || st; }
    function shareLink(kind) {
      var url = kind === "join" ? joinLink.value : watchLink.value;
      var text = kind === "join" ? "Haz tu pregunta en vivo: " : "Mira el evento en vivo: ";
      if (navigator.share) { navigator.share({ title: eventData.value.title, text: text + eventData.value.title, url: url }).catch(function () {}); }
      else if (kind === "join") copyJoinLink(); else copyWatchLink();
    }

    var devices = ref({ cameras: [], mics: [] });
    var selectedCamera = ref("");
    var selectedMic = ref("");
    var previewStream = ref(null);

    var joinLink = computed(function () {
      return window.location.origin + (window.POD_BASE || "") + "/join/" + eventData.value.id;
    });

    var watchLink = computed(function () {
      return window.location.origin + (window.POD_BASE || "") + "/watch/" + eventData.value.id;
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
          } else if (msg.type === "chat_refresh") {
            loadChat();
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
        keepAwakeH();
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

    var chatLoaded = false;
    async function loadChat() {
      try {
        chatMessages.value = await api("/api/events/" + eventData.value.id + "/chat");
        if (!chatLoaded) { chatLoaded = true; seenChat.value = chatMessages.value.length; }
      } catch (_) {}
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
        if (room.value && sent.is_approved) {
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
      ticker = setInterval(function () { now.value = Date.now(); }, 1000);
      document.addEventListener("visibilitychange", onVisH);
    });

    onBeforeUnmount(function () {
      if (ticker) clearInterval(ticker);
      document.removeEventListener("visibilitychange", onVisH);
      if (_wakeH) { try { _wakeH.release(); } catch (_) {} _wakeH = null; }
      stopPreview();
      stopPolling();
      stopChatPolling();
      if (room.value) { room.value.disconnect(); room.value = null; }
    });

    watch(selectedCamera, function () { if (phase.value === "prejoin") startPreview(); });

    var _mod = _chatModeration(function () { return eventData.value.id; }, loadChat, room);

    return {
      approveMsg: _mod.approveMsg, removeMsg: _mod.removeMsg, blockMsg: _mod.blockMsg,
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
      sideTab: sideTab, setTab: setTab, newRequests: newRequests, unreadChat: unreadChat, turnTime: turnTime,
      statusLabel: statusLabel, shareLink: shareLink, watchLink: watchLink,
      M_ICONS: M_ICONS,
    };
  },
  template: '\
<div v-if="phase === \'prejoin\'" class="prejoin ama-prejoin">\
  <div class="prejoin-card">\
    <div class="prejoin-preview">\
      <video id="prejoin-video" autoplay muted playsinline style="transform:scaleX(-1)"></video>\
      <div v-if="!devices.cameras.length" class="prejoin-placeholder">Sin cámara detectada</div>\
    </div>\
    <div class="prejoin-controls">\
      <div class="pj-top"><button class="ghost pj-back" @click="$props.onBack">&#8592; Eventos</button><span class="event-status" :class="eventData.status">{{ statusLabel(eventData.status) }}</span></div>\
      <h2 class="pj-title">{{ eventData.title }}</h2>\
      <p v-if="eventData.description" class="muted pj-desc">{{ eventData.description }}</p>\
      <template v-if="eventData.status !== \'finished\'">\
        <label>Cámara</label>\
        <select v-model="selectedCamera">\
          <option v-for="d in devices.cameras" :key="d.deviceId" :value="d.deviceId">{{ d.label || "Cámara " + d.deviceId.slice(0,6) }}</option>\
        </select>\
        <label>Micrófono</label>\
        <select v-model="selectedMic">\
          <option v-for="d in devices.mics" :key="d.deviceId" :value="d.deviceId">{{ d.label || "Micrófono " + d.deviceId.slice(0,6) }}</option>\
        </select>\
      </template>\
      <div v-if="eventData.status === \'finished\'" class="pj-ended">\
        <div class="muted">Evento terminado</div>\
        <div class="pj-stats"><span>&#10084; {{ eventData.like_count || 0 }} me gusta</span><span>&#128065; {{ eventData.spectator_count || 0 }} espectadores</span></div>\
      </div>\
      <button v-else class="primary pj-go" @click="startEvent">{{ eventData.status === \'active\' ? \'Volver al evento\' : \'Empezar el evento\' }}</button>\
      <p v-if="eventData.status === \'created\'" class="muted pj-hint">Al empezar, se abre la sala y comienza la grabación.</p>\
      <div class="pj-share">\
        <button @click="shareLink(\'join\')">&#128279; Link para preguntar</button>\
        <button @click="shareLink(\'watch\')">&#128065; Link para mirar</button>\
      </div>\
    </div>\
  </div>\
</div>\
<div v-else class="host-layout ama-host">\
  <div class="host-header">\
    <button class="ghost hh-back" @click="$props.onBack" title="Volver">&#8592;</button>\
    <h2 class="hh-title">{{ eventData.title }}</h2>\
    <span class="event-status" :class="eventData.status">{{ statusLabel(eventData.status) }}</span>\
    <span v-if="isRecording" class="rec-indicator"><span class="rec-dot"></span> REC</span>\
    <span class="hh-stats"><span title="Espectadores">&#128065; {{ spectatorCount }}</span><span title="Me gusta">&#10084; {{ likeCount }}</span></span>\
    <span class="spacer d-only"></span>\
    <button class="ghost d-only" @click="copyJoinLink" title="Copiar link de participante">&#128279; Participar</button>\
    <button class="ghost d-only" @click="copyWatchLink" title="Copiar link de espectador">&#128065; Ver</button>\
  </div>\
  <div class="video-area" :class="{ \'has-guest\': currentParticipant }">\
    <div class="video-card host-card" :class="currentParticipant ? \'split\' : \'host-solo\'">\
      <video id="host-video" autoplay muted playsinline style="transform:scaleX(-1)"></video>\
      <div class="video-label">Tú</div>\
    </div>\
    <div v-if="currentParticipant" class="video-card split guest-card">\
      <video id="participant-video" autoplay playsinline></video>\
      <div v-if="currentParticipant.is_censored" class="censor-overlay">&#128263; Silenciado</div>\
      <div class="video-label">{{ currentParticipant.display_name }}</div>\
    </div>\
    <div v-if="!currentParticipant" class="stage-hint m-only">\
      <template v-if="inQueueOnly.length">Hay {{ inQueueOnly.length }} en la cola. Toca <b>Siguiente</b> para darle la palabra.</template>\
      <template v-else-if="requests.length">Tienes {{ requests.length }} {{ requests.length === 1 ? \'solicitud\' : \'solicitudes\' }} por revisar.</template>\
      <template v-else>Nadie en la cola todavía. Comparte el link para preguntar.</template>\
    </div>\
  </div>\
  <div v-if="currentParticipant" class="onair-strip m-only">\
    <span class="on-air-badge">Al aire</span>\
    <div class="oa-body">\
      <div class="oa-name">{{ currentParticipant.display_name }} <span v-if="turnTime" class="oa-time mono">{{ turnTime }}</span></div>\
      <div v-if="currentParticipant.questions && currentParticipant.questions.length" class="oa-q">{{ currentParticipant.questions[0] }}</div>\
    </div>\
  </div>\
  <div class="controls-bar">\
    <button class="primary hc-next" @click="nextTurnAction" :disabled="!inQueueOnly.length && !currentParticipant">{{ inQueueOnly.length ? \'Siguiente\' : (currentParticipant ? \'Terminar turno\' : \'Siguiente\') }} &#9654;</button>\
    <button v-if="currentParticipant && !currentParticipant.is_censored" class="hc-btn" @click="censorParticipant(currentParticipant.id)">&#128263; Silenciar</button>\
    <button v-if="currentParticipant && currentParticipant.is_censored" class="hc-btn on" @click="uncensorParticipant(currentParticipant.id)">&#128264; Devolver audio</button>\
    <button v-if="currentParticipant" class="danger hc-btn" @click="removeParticipant(currentParticipant.id)" title="Sacar de la sala">Sacar</button>\
    <span class="spacer d-only"></span>\
    <button v-if="!isRecording" class="d-only" @click="startRecording">&#9679; Grabar</button>\
    <button v-else class="danger d-only" @click="stopRecording">&#9632; Parar grabación</button>\
    <button class="danger d-only" @click="finishEvent" :disabled="eventData.status === \'finished\'">Terminar evento</button>\
  </div>\
  <div class="queue-sidebar" :class="\'tab-\' + sideTab">\
    <div class="queue-section hs-sol">\
      <h3>Solicitudes ({{ requests.length }})</h3>\
      <div v-if="!requests.length" class="muted hs-empty">Cuando alguien se anote para preguntar, aparece aquí para que lo apruebes.</div>\
      <div v-for="r in requests" :key="r.id" class="request-item">\
        <div class="avatar">{{ initials(r.display_name) }}</div>\
        <div class="qi-body">\
          <span class="name">{{ r.display_name }}</span>\
          <div v-if="r.questions && r.questions.length" class="participant-questions">\
            <div v-for="(q, i) in r.questions" :key="i" class="pq-item">{{ q }}</div>\
          </div>\
        </div>\
        <div class="actions">\
          <button class="icon ok" @click="approveRequest(r.id)" title="Aprobar" aria-label="Aprobar">&#10003;</button>\
          <button class="icon danger" @click="rejectRequest(r.id)" title="Rechazar" aria-label="Rechazar">&#10005;</button>\
        </div>\
      </div>\
    </div>\
    <div class="queue-section hs-cola">\
      <h3>Cola ({{ inQueueOnly.length }})</h3>\
      <div v-if="!inQueueOnly.length" class="muted hs-empty">La cola está vacía. Las solicitudes que apruebes pasan aquí.</div>\
      <div v-for="(p, idx) in inQueueOnly" :key="p.id" class="queue-item">\
        <div class="avatar">{{ idx + 1 }}</div>\
        <div class="qi-body">\
          <span class="name">{{ p.display_name }} <span v-if="p.is_preconnected" class="qi-ready" title="Listo, esperando">&#9679; listo</span></span>\
          <div v-if="p.questions && p.questions.length" class="participant-questions">\
            <div v-for="(q, i) in p.questions" :key="i" class="pq-item">{{ q }}</div>\
          </div>\
        </div>\
        <div class="actions">\
          <button class="icon" @click="skipTo(p.id)" title="Darle la palabra ahora" aria-label="Darle la palabra ahora">&#9654;</button>\
          <button class="icon danger" @click="removeParticipant(p.id)" title="Quitar de la cola" aria-label="Quitar de la cola">&#10005;</button>\
        </div>\
      </div>\
    </div>\
    <div v-if="currentParticipant" class="queue-section hs-aire">\
      <h3>Al aire</h3>\
      <div class="queue-item on-air">\
        <div class="avatar">{{ initials(currentParticipant.display_name) }}</div>\
        <div class="qi-body">\
          <span class="name">{{ currentParticipant.display_name }}</span>\
          <div v-if="currentParticipant.questions && currentParticipant.questions.length" class="participant-questions">\
            <div v-for="(q, i) in currentParticipant.questions" :key="i" class="pq-item">{{ q }}</div>\
          </div>\
        </div>\
        <span class="on-air-badge">En vivo</span>\
      </div>\
    </div>\
    <div class="chat-panel hs-chat">\
      <div class="queue-section"><h3>Chat</h3></div>\
      <div class="chat-messages">\
        <div v-if="!chatMessages.length" class="muted hs-empty">Todavía no hay mensajes.</div>\
        <div v-for="m in chatMessages" :key="m.id || m.sender_name + m.message" class="chat-msg" :class="{ pending: m.pending }">\
          <span class="sender" :class="{ host: m.is_host }">{{ m.sender_name }}:</span>\
          <span class="text"> {{ m.message }}</span>\
          <span v-if="m.id && !m.is_host" class="chat-mod">\
            <button v-if="m.pending" class="primary" @click="approveMsg(m)" title="Lo ven todos">Aprobar</button>\
            <button class="ghost" @click="removeMsg(m)" :title="m.pending ? \'No se publica\' : \'Quitar del chat\'">Quitar</button>\
            <button v-if="m.can_block" class="ghost danger" @click="blockMsg(m)" title="No puede escribir más en este evento y se borra todo lo suyo">Bloquear</button>\
          </span>\
        </div>\
      </div>\
      <div class="chat-input">\
        <input type="text" v-model="chatInput" placeholder="Escribe un mensaje..." @keyup.enter="sendChat" enterkeyhint="send">\
        <button class="primary" @click="sendChat" :disabled="!chatInput.trim()">Enviar</button>\
      </div>\
    </div>\
    <div class="queue-section hs-mas">\
      <h3>Compartir</h3>\
      <div class="mas-grid">\
        <button @click="shareLink(\'join\')">&#128279; Link para preguntar</button>\
        <button @click="shareLink(\'watch\')">&#128065; Link para mirar</button>\
      </div>\
      <h3 class="mas-h">Grabación</h3>\
      <button v-if="!isRecording" class="mas-wide" @click="startRecording">&#9679; Empezar a grabar</button>\
      <button v-else class="mas-wide" @click="stopRecording"><span class="rec-dot"></span> Grabando · parar</button>\
      <h3 class="mas-h">Evento</h3>\
      <button class="mas-wide danger-solid" @click="finishEvent" :disabled="eventData.status === \'finished\'">Terminar el evento</button>\
      <p class="muted mas-note">Se desconecta a todos y se detiene la grabación.</p>\
    </div>\
  </div>\
  <nav class="host-tabs m-only" aria-label="Panel del evento">\
    <button type="button" :class="{ on: sideTab === \'solicitudes\' }" :aria-current="sideTab === \'solicitudes\' ? \'page\' : null" @click="setTab(\'solicitudes\')"><span class="ht-ico" v-html="M_ICONS.hand"></span>Solicitudes<i v-if="requests.length" class="ht-badge" :class="{ hot: newRequests }" :aria-label="requests.length + \' por revisar\'">{{ requests.length }}</i></button>\
    <button type="button" :class="{ on: sideTab === \'cola\' }" :aria-current="sideTab === \'cola\' ? \'page\' : null" @click="setTab(\'cola\')"><span class="ht-ico" v-html="M_ICONS.queue"></span>Cola<i v-if="inQueueOnly.length" class="ht-badge" :aria-label="inQueueOnly.length + \' en la cola\'">{{ inQueueOnly.length }}</i></button>\
    <button type="button" :class="{ on: sideTab === \'chat\' }" :aria-current="sideTab === \'chat\' ? \'page\' : null" @click="setTab(\'chat\')"><span class="ht-ico" v-html="M_ICONS.chat"></span>Chat<i v-if="unreadChat" class="ht-badge hot" :aria-label="unreadChat + \' sin leer\'">{{ unreadChat }}</i></button>\
    <button type="button" :class="{ on: sideTab === \'mas\' }" :aria-current="sideTab === \'mas\' ? \'page\' : null" @click="setTab(\'mas\')"><span class="ht-ico" v-html="M_ICONS.more"></span>Más</button>\
  </nav>\
</div>'
};

// ── JoinView ─────────────────────────────────────────────────────────

var JoinView = {
  props: { eventId: [Number, String] },
  emits: ["joined"],
  setup: function (props) {
    var eventInfo = ref(null);
    var loading = ref(true);
    var displayName = ref("");
    var questions = ref(["", "", ""]);
    var error = ref("");
    var busy = ref(false);
    var submitted = ref(false);
    var participantData = ref(null);
    var KEY = "amapod.participante." + props.eventId;

    async function loadEventInfo() {
      loading.value = true;
      // Were you already signed up from this phone? (page reloads, Safari gets closed…)
      try {
        var saved = JSON.parse(localStorage.getItem(KEY) || "null");
        if (saved && saved.access_token) {
          var st = await api("/api/events/" + props.eventId + "/my-status?token=" + saved.access_token);
          if (st && ["pending", "approved", "in_queue", "on_air"].indexOf(st.status) !== -1) {
            st.access_token = saved.access_token;
            participantData.value = st;
            submitted.value = true;
            loading.value = false;
            return;
          }
          localStorage.removeItem(KEY);
        }
      } catch (_) { try { localStorage.removeItem(KEY); } catch (__) {} }
      try {
        eventInfo.value = await api("/api/events/" + props.eventId + "/public-info");
      } catch (e) {
        error.value = "No encontramos este evento. Revisa el link.";
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
          body: { name: displayName.value.trim() },
        });
        var qs = questions.value.map(function (q) { return q.trim(); }).filter(Boolean);
        if (qs.length) {
          try {
            await api("/api/events/" + props.eventId + "/my-questions?token=" + result.access_token, { method: "PUT", body: { questions: qs } });
          } catch (_) {}
        }
        result.display_name = displayName.value.trim();
        result.questions = qs;
        try { localStorage.setItem(KEY, JSON.stringify({ id: result.id, access_token: result.access_token })); } catch (_) {}
        participantData.value = result;
        submitted.value = true;
      } catch (e) {
        error.value = e.status === 409
          ? "Ya hay alguien anotado con ese nombre. Si eres tú, abre el link desde el mismo teléfono; si no, agrega tu apellido."
          : e.message;
      }
      busy.value = false;
    }

    onMounted(loadEventInfo);

    return {
      eventInfo: eventInfo, loading: loading, displayName: displayName, questions: questions,
      error: error, busy: busy, submitted: submitted,
      participantData: participantData, requestAccess: requestAccess,
    };
  },
  template: `
<div class="join-view ama-public" v-if="!submitted">
  <div v-if="loading" class="ama-loading"><div class="ama-spinner"></div></div>
  <div v-else-if="error && !eventInfo" class="join-card"><p class="error-text">{{ error }}</p></div>
  <div v-else class="join-card">
    <div class="ama-brand">ama<span class="brand-accent">Pod</span>
      <span v-if="eventInfo.status === 'active'" class="ama-live">EN VIVO</span>
    </div>
    <h2 class="ama-title">{{ eventInfo.title }}</h2>
    <p class="event-desc" v-if="eventInfo.description">{{ eventInfo.description }}</p>
    <template v-if="eventInfo.status === 'finished'">
      <div class="ama-state"><div class="ama-state-icon">⏹</div><p class="ama-state-title">Este evento ya terminó</p></div>
    </template>
    <template v-else>
      <ol class="ama-steps">
        <li><span>1</span>Anótate con tu nombre y tu pregunta</li>
        <li><span>2</span>Espera tu turno en esta página</li>
        <li><span>3</span>Sales al aire con tu cámara</li>
      </ol>
      <form @submit.prevent="requestAccess">
        <label>Tu nombre</label>
        <input type="text" v-model="displayName" placeholder="Cómo quieres aparecer" autocomplete="name" required>
        <label style="margin-top:6px">Tu pregunta</label>
        <textarea v-model="questions[0]" rows="2" placeholder="Escribe lo que quieres preguntar"></textarea>
        <details class="ama-more">
          <summary>Agregar otra pregunta</summary>
          <textarea v-model="questions[1]" rows="2" placeholder="Pregunta 2 (opcional)"></textarea>
          <textarea v-model="questions[2]" rows="2" placeholder="Pregunta 3 (opcional)"></textarea>
        </details>
        <button class="primary ama-go" :disabled="busy || !displayName.trim()" type="submit">{{ busy ? "Enviando…" : "Anotarme para preguntar" }}</button>
        <p v-if="error" class="error-text">{{ error }}</p>
      </form>
      <a class="ama-alt" :href="'/watch/' + eventId">Solo quiero mirar →</a>
    </template>
  </div>
</div>
<participant-view v-else :participant-data="participantData" :event-id="eventId" />`
};

// ── AudienceChat ─────────────────────────────────────────────────────
// Chat for viewers and people in the queue. Anyone not signed up joins with a name (the key stays
// stored in this browser). In moderated mode, what they write is visible only to that person and the
// host until the host approves it.

var AudienceChat = {
  props: { eventId: [Number, String], accessToken: String },
  setup: function (props) {
    var msgs = ref([]);
    var input = ref("");
    var name = ref("");
    var chatToken = ref("");
    var mode = ref("");
    var err = ref("");
    var sending = ref(false);
    var listEl = ref(null);
    var timer = null;
    var KEY = "amapod.chat." + props.eventId;
    try {
      var saved = JSON.parse(localStorage.getItem(KEY) || "null");
      if (saved && saved.chat_token) { chatToken.value = saved.chat_token; name.value = saved.name || ""; }
    } catch (_) {}

    var canWrite = computed(function () { return !!props.accessToken || !!chatToken.value; });
    function who() {
      if (props.accessToken) return { token: props.accessToken };
      if (chatToken.value) return { chat_token: chatToken.value };
      return {};
    }
    function query() {
      var w = who(), k = Object.keys(w)[0];
      return k ? "?" + k + "=" + encodeURIComponent(w[k]) : "";
    }
    function scroll() {
      nextTick(function () { var el = listEl.value; if (el) el.scrollTop = el.scrollHeight; });
    }
    async function load() {
      try {
        var before = msgs.value.length;
        msgs.value = await api("/api/events/" + props.eventId + "/chat" + query());
        if (msgs.value.length !== before) scroll();
      } catch (_) {}
    }
    async function join() {
      err.value = "";
      var n = name.value.trim();
      if (!n) { err.value = "Escribe tu nombre"; return; }
      try {
        var res = await api("/api/events/" + props.eventId + "/chat/join", { method: "POST", body: { name: n } });
        chatToken.value = res.chat_token; name.value = res.name;
        try { localStorage.setItem(KEY, JSON.stringify(res)); } catch (_) {}
      } catch (e) { err.value = e.message; }
    }
    async function send() {
      var text = input.value.trim();
      if (!text || sending.value) return;
      err.value = ""; sending.value = true;
      try {
        var body = who(); body.message = text;
        var m = await api("/api/events/" + props.eventId + "/chat", { method: "POST", body: body });
        input.value = "";
        msgs.value.push(m); scroll();
      } catch (e) { err.value = e.message; }
      sending.value = false;
    }
    function onRefresh() { load(); }

    onMounted(async function () {
      try { mode.value = (await api("/api/events/" + props.eventId + "/public-info")).chat_mode || "free"; } catch (_) { mode.value = "free"; }
      if (mode.value === "off") return;
      await load();
      timer = setInterval(load, 4000);
      window.addEventListener("amapod-chat", onRefresh);
    });
    onBeforeUnmount(function () {
      if (timer) clearInterval(timer);
      window.removeEventListener("amapod-chat", onRefresh);
    });
    return { msgs: msgs, input: input, name: name, mode: mode, err: err, sending: sending, listEl: listEl,
             canWrite: canWrite, join: join, send: send };
  },
  template: '\
<div v-if="mode && mode !== \'off\'" class="ama-chat">\
  <div class="ama-chat-head">Chat<span v-if="mode === \'moderated\'" class="muted"> · moderado</span></div>\
  <div class="ama-chat-list" ref="listEl">\
    <div v-if="!msgs.length" class="muted ama-chat-empty">Todavía no hay mensajes.</div>\
    <div v-for="m in msgs" :key="m.id" class="chat-msg" :class="{ pending: m.pending, mine: m.mine }">\
      <span class="sender" :class="{ host: m.is_host }">{{ m.is_host ? \'Anfitrión\' : m.sender_name }}:</span>\
      <span class="text"> {{ m.message }}</span>\
      <span v-if="m.pending" class="ama-chat-wait"> · esperando al anfitrión</span>\
    </div>\
  </div>\
  <form v-if="!canWrite" class="chat-input" @submit.prevent="join">\
    <input type="text" v-model="name" maxlength="40" placeholder="Tu nombre para escribir" autocomplete="nickname">\
    <button class="primary" type="submit" :disabled="!name.trim()">Entrar</button>\
  </form>\
  <form v-else class="chat-input" @submit.prevent="send">\
    <input type="text" v-model="input" maxlength="300" placeholder="Escribe un mensaje…" enterkeyhint="send">\
    <button class="primary" type="submit" :disabled="!input.trim() || sending">Enviar</button>\
  </form>\
  <p v-if="mode === \'moderated\' && canWrite" class="muted ama-chat-note">El anfitrión lee cada mensaje antes de que lo vean los demás.</p>\
  <p v-if="err" class="error-text ama-chat-note">{{ err }}</p>\
</div>'
};

// ── ParticipantView ──────────────────────────────────────────────────

var ParticipantView = {
  props: { participantData: Object, eventId: [Number, String] },
  setup: function (props) {
    var pdata = ref(props.participantData);
    var room = ref(null);
    var connected = ref(false);
    var statusPoll = ref(null);
    var isCensored = ref(false);
    var waitingForTap = ref(false);
    var lkError = ref("");
    var KEY = "amapod.participante." + props.eventId;

    var state = computed(function () {
      if (!pdata.value) return "pending";
      var s = pdata.value.status;
      if (s === "approved") return "in_queue";
      return s;
    });
    var showVideo = computed(function () { return state.value === "on_air"; });
    var nearTurn = computed(function () { return state.value === "in_queue" && !!pdata.value.is_preconnected; });
    var canAskQuestions = computed(function () { return ["pending", "in_queue"].indexOf(state.value) !== -1; });

    var myQuestions = ref(["", "", ""]);
    (function () {
      var qs = (props.participantData && props.participantData.questions) || [];
      for (var i = 0; i < 3; i++) myQuestions.value[i] = qs[i] || "";
    })();
    var questionsSaved = ref(false);
    var editing = ref(false);

    async function saveQuestions() {
      if (!pdata.value || !pdata.value.access_token) return;
      var qs = myQuestions.value.filter(function (q) { return q.trim(); });
      try {
        await api("/api/events/" + props.eventId + "/my-questions?token=" + pdata.value.access_token, { method: "PUT", body: { questions: qs } });
        questionsSaved.value = true;
        editing.value = false;
        setTimeout(function () { questionsSaved.value = false; }, 2000);
      } catch (_) {}
    }

    // Keep the screen on while waiting or on air
    var _wake = null;
    async function keepAwake() {
      try { if ("wakeLock" in navigator && !_wake) { _wake = await navigator.wakeLock.request("screen"); _wake.addEventListener("release", function () { _wake = null; }); } } catch (_) {}
    }
    function releaseAwake() { try { if (_wake) _wake.release(); } catch (_) {} _wake = null; }
    function onVisible() { if (document.visibilityState === "visible" && ["pending", "in_queue", "on_air"].indexOf(state.value) !== -1) { keepAwake(); pollStatus(); } }
    document.addEventListener("visibilitychange", onVisible);

    async function pollStatus() {
      if (!pdata.value || !pdata.value.access_token) return;
      try {
        var savedToken = pdata.value.access_token;
        var s = await api("/api/events/" + props.eventId + "/my-status?token=" + savedToken);
        var oldStatus = pdata.value.status;
        s.access_token = savedToken;
        pdata.value = s;
        isCensored.value = !!s.is_censored;
        if (!editing.value && s.questions) for (var i = 0; i < 3; i++) myQuestions.value[i] = s.questions[i] || "";
        if (s.is_preconnected && !connected.value && s.status === "in_queue") getTokenAndConnect(false);
        if (s.status === "on_air" && oldStatus !== "on_air") {
          waitingForTap.value = true;
          try { if (navigator.vibrate) navigator.vibrate([300, 150, 300]); } catch (_) {}
        }
        if (["done", "rejected", "left"].indexOf(s.status) !== -1) {
          try { localStorage.removeItem(KEY); } catch (_) {}
          releaseAwake();
          stopPolling();
        }
      } catch (_) {}
    }

    async function getTokenAndConnect(canPublish) {
      if (!pdata.value) return;
      try {
        var tokenData = await api("/api/events/" + props.eventId + "/participant-token/" + pdata.value.id + "?token=" + pdata.value.access_token);
        var wsUrl = await getLivekitWsUrl();
        var newRoom = new LK.Room({ adaptiveStream: true, dynacast: true });
        newRoom.on(LK.RoomEvent.TrackSubscribed, function (track, pub, participant) {
          if (participant.identity.startsWith("host_")) {
            if (track.kind === LK.Track.Kind.Video) {
              nextTick(function () { var el = document.getElementById("pv-host-video"); if (el) track.attach(el); });
            } else if (track.kind === LK.Track.Kind.Audio) {
              document.body.appendChild(track.attach());
            }
          }
        });
        newRoom.on(LK.RoomEvent.TrackUnsubscribed, function (track) { track.detach().forEach(function (el) { el.remove(); }); });
        newRoom.on(LK.RoomEvent.DataReceived, function (payload) {
          var msg = _decodeMsg(payload);
          if (!msg) return;
          if (msg.type === "censor" && msg.participant_id === pdata.value.id) isCensored.value = true;
          if (msg.type === "uncensor" && msg.participant_id === pdata.value.id) { isCensored.value = false; enablePublish(); }
          if (msg.type === "event_ended") { pdata.value.status = "left"; if (newRoom) newRoom.disconnect(); }
        });
        newRoom.on(LK.RoomEvent.Disconnected, function () { connected.value = false; });
        await newRoom.connect(wsUrl, tokenData.token);
        room.value = newRoom;
        connected.value = true;
        if (canPublish) await enablePublish();
      } catch (e) {
        lkError.value = "No se pudo conectar: " + e.message;
      }
    }

    async function enablePublish() {
      if (!room.value) { lkError.value = "Sin conexión con la sala"; return; }
      try {
        // A single camera+microphone request: iOS Safari invalidates the first one if requested separately.
        var tracks = await LK.createLocalTracks({ audio: true, video: true });
        for (var i = 0; i < tracks.length; i++) await room.value.localParticipant.publishTrack(tracks[i]);
        nextTick(function () {
          for (var j = 0; j < tracks.length; j++) {
            if (tracks[j].kind === LK.Track.Kind.Video) { var el = document.getElementById("pv-local-video"); if (el) tracks[j].attach(el); }
          }
          attachHostTracks();
        });
      } catch (e) {
        lkError.value = "No se pudo activar tu cámara o micrófono. Revisa los permisos del navegador y toca Reintentar.";
      }
    }

    function attachHostTracks() {
      if (!room.value) return;
      room.value.remoteParticipants.forEach(function (p) {
        if (!p.identity.startsWith("host_")) return;
        p.trackPublications.forEach(function (pub) {
          if (!pub.track) return;
          if (pub.track.kind === LK.Track.Kind.Video) { var el = document.getElementById("pv-host-video"); if (el) pub.track.attach(el); }
          else if (pub.track.kind === LK.Track.Kind.Audio) document.body.appendChild(pub.track.attach());
        });
      });
    }

    async function goLive() {
      waitingForTap.value = false;
      lkError.value = "";
      keepAwake();
      // Always reconnect from the tap: iOS suspends idle connections.
      if (room.value) { try { room.value.disconnect(); } catch (_) {} room.value = null; connected.value = false; }
      await getTokenAndConnect(true);
    }

    async function leaveEvent() {
      var wasOnAir = state.value === "on_air";
      if (!wasOnAir && !confirm("¿Seguro que quieres salir de la cola? Perderás tu lugar.")) return;
      if (room.value) { room.value.disconnect(); room.value = null; }
      connected.value = false;
      stopPolling();
      try { await api("/api/events/" + props.eventId + "/leave?token=" + pdata.value.access_token, { method: "POST" }); } catch (_) {}
      try { localStorage.removeItem(KEY); } catch (_) {}
      releaseAwake();
      pdata.value = Object.assign({}, pdata.value, { status: wasOnAir ? "done" : "left" });
    }

    function startPoll() { pollStatus(); statusPoll.value = setInterval(pollStatus, 3000); keepAwake(); }
    function stopPolling() { if (statusPoll.value) { clearInterval(statusPoll.value); statusPoll.value = null; } }

    onMounted(startPoll);
    onBeforeUnmount(function () {
      stopPolling();
      releaseAwake();
      document.removeEventListener("visibilitychange", onVisible);
      if (room.value) { room.value.disconnect(); room.value = null; }
    });

    return {
      pdata: pdata, state: state, connected: connected, showVideo: showVideo, nearTurn: nearTurn,
      isCensored: isCensored, waitingForTap: waitingForTap, goLive: goLive, leaveEvent: leaveEvent, lkError: lkError,
      canAskQuestions: canAskQuestions, myQuestions: myQuestions, saveQuestions: saveQuestions,
      questionsSaved: questionsSaved, editing: editing,
    };
  },
  template: `
<div class="participant-view ama-public" :class="{ 'is-live': showVideo }">
  <!-- Your turn -->
  <div v-if="waitingForTap" class="ama-call">
    <div class="ama-call-ring">🎙</div>
    <h2>¡Te toca, {{ pdata && pdata.display_name }}!</h2>
    <p>El anfitrión te dio la palabra.</p>
    <button class="primary ama-call-btn" @click="goLive">Salir al aire</button>
    <p class="muted">Se activan tu cámara y tu micrófono.</p>
  </div>

  <!-- On air -->
  <div v-else-if="showVideo" class="ama-onair">
    <div class="ama-onair-top"><span class="on-air-badge">EN VIVO</span><span class="muted">{{ pdata && pdata.display_name }}</span></div>
    <div class="ama-onair-stage">
      <div class="video-card ama-host-card">
        <video id="pv-host-video" autoplay playsinline muted></video>
        <div class="video-label">Anfitrión</div>
      </div>
      <div class="video-card ama-self-card">
        <video id="pv-local-video" autoplay muted playsinline style="transform:scaleX(-1)"></video>
        <div v-if="isCensored" class="censor-overlay">El anfitrión pausó tu cámara y micrófono</div>
        <div class="video-label">Tú</div>
      </div>
    </div>
    <div v-if="lkError" class="ama-error">{{ lkError }}</div>
    <div class="ama-onair-actions">
      <button class="primary" @click="goLive" v-if="lkError">Reintentar</button>
      <button class="ghost ama-end" @click="leaveEvent">Terminar mi turno</button>
    </div>
  </div>

  <!-- Waiting, in queue, finished -->
  <div v-else class="participant-status ama-wait">
    <div class="ama-brand">ama<span class="brand-accent">Pod</span></div>
    <template v-if="state === 'pending'">
      <div class="ama-state-icon ama-pulse">⏳</div>
      <h2>Listo, {{ pdata && pdata.display_name }}</h2>
      <p class="ama-lead">Tu solicitud llegó. El anfitrión la está revisando.</p>
    </template>
    <template v-else-if="state === 'in_queue' && nearTurn">
      <div class="ama-state-icon ama-pulse">🎧</div>
      <h2>¡Ya casi te toca!</h2>
      <p class="ama-lead">Estás entre los próximos. Ten a mano tus audífonos y quédate en esta página.</p>
    </template>
    <template v-else-if="state === 'in_queue'">
      <div class="ama-state-icon">🙋</div>
      <h2>Estás en la cola</h2>
      <p class="ama-lead">Tu lugar: {{ (pdata && pdata.approximate_position) || "en la cola" }}. Te avisamos aquí cuando te toque.</p>
    </template>
    <template v-else-if="state === 'done'">
      <div class="ama-state-icon">✓</div>
      <h2>¡Gracias por participar!</h2>
      <p class="ama-lead">Ya puedes cerrar esta página.</p>
    </template>
    <template v-else-if="state === 'rejected'">
      <div class="ama-state-icon">·</div>
      <h2>Esta vez no alcanzó</h2>
      <p class="ama-lead">El anfitrión no pudo tomar tu pregunta. Puedes seguir mirando el evento.</p>
    </template>
    <template v-else>
      <div class="ama-state-icon">·</div>
      <h2>Saliste de la cola</h2>
      <p class="ama-lead">Si quieres volver a preguntar, abre el link otra vez.</p>
    </template>

    <div v-if="canAskQuestions" class="ama-questions">
      <div class="ama-q-head">
        <span>Tus preguntas</span>
        <button v-if="!editing" class="ghost ama-q-edit" @click="editing = true">Editar</button>
      </div>
      <template v-if="!editing">
        <ol v-if="myQuestions.some(q => q.trim())" class="ama-q-list"><li v-for="(q, i) in myQuestions.filter(q => q.trim())" :key="i">{{ q }}</li></ol>
        <p v-else class="muted" style="margin:0">Todavía no escribiste tu pregunta. Ayuda al anfitrión a elegir: toca Editar.</p>
        <span v-if="questionsSaved" class="ama-saved">✓ Guardado</span>
      </template>
      <template v-else>
        <textarea v-model="myQuestions[0]" rows="2" placeholder="Pregunta 1"></textarea>
        <textarea v-model="myQuestions[1]" rows="2" placeholder="Pregunta 2 (opcional)"></textarea>
        <textarea v-model="myQuestions[2]" rows="2" placeholder="Pregunta 3 (opcional)"></textarea>
        <button class="primary" @click="saveQuestions">Guardar</button>
      </template>
    </div>

    <audience-chat v-if="pdata && pdata.access_token" :event-id="eventId" :access-token="pdata.access_token" />

    <ul v-if="canAskQuestions" class="ama-tips">
      <li>🎧 Con audífonos se escucha mejor y no hay eco.</li>
      <li>📱 No cierres esta página: aquí te avisamos cuando te toque.</li>
    </ul>
    <div class="ama-wait-actions">
      <a class="ghost ama-watch" :href="'/watch/' + eventId" target="_blank">Ver el evento en vivo</a>
      <button v-if="canAskQuestions" class="ghost ama-leave" @click="leaveEvent">Salir de la cola</button>
    </div>
  </div>
</div>`
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

    var _mod = _chatModeration(function () { return props.eventId; }, loadChat, null);

    return {
      approveMsg: _mod.approveMsg, removeMsg: _mod.removeMsg, blockMsg: _mod.blockMsg,
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
          <button v-else class="icon" @click="uncensorParticipant(currentParticipant.id)" title="Quitar censura" style="color:var(--signal-cool)">&#128264;</button>\
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
          <div v-for="m in chatMessages" :key="m.id" class="chat-msg" :class="{ pending: m.pending }">\
            <span class="sender" :class="{ host: m.is_host }">{{ m.sender_name }}:</span>\
            <span class="text"> {{ m.message }}</span>\
            <span v-if="m.id && !m.is_host" class="chat-mod">\
              <button v-if="m.pending" class="primary" @click="approveMsg(m)">Aprobar</button>\
              <button class="ghost" @click="removeMsg(m)">Quitar</button>\
              <button v-if="m.can_block" class="ghost danger" @click="blockMsg(m)" title="No puede escribir más en este evento">Bloquear</button>\
            </span>\
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
    var waitTimer = null;
    var tiles = ref([]);            // [{ id, name }] who has video
    var needsAudioTap = ref(false);
    var _tracks = {};

    async function loadEvent() {
      loading.value = true;
      try {
        eventInfo.value = await api("/api/events/" + props.eventId + "/public-info");
        likeCount.value = eventInfo.value.like_count || 0;
        spectatorCount.value = eventInfo.value.spectator_count || 0;
        if (eventInfo.value.status === "active") await connectToRoom();
        else if (eventInfo.value.status === "created") waitForStart();
      } catch (e) {
        error.value = "No encontramos este evento. Revisa el link.";
      }
      loading.value = false;
    }

    // If it hasn't started yet, the page connects on its own when it starts.
    function waitForStart() {
      if (waitTimer) return;
      waitTimer = setInterval(async function () {
        try {
          var info = await api("/api/events/" + props.eventId + "/public-info");
          eventInfo.value = info;
          if (info.status === "active") { clearInterval(waitTimer); waitTimer = null; await connectToRoom(); }
          if (info.status === "finished") { clearInterval(waitTimer); waitTimer = null; }
        } catch (_) {}
      }, 5000);
    }

    function mountTile(id) {
      nextTick(function () {
        var host = document.querySelector('[data-spec-id="' + id + '"]');
        var t = _tracks[id];
        if (host && t && !host.querySelector("video")) {
          var el = t.attach();
          el.setAttribute("playsinline", "");
          el.muted = true;
          host.appendChild(el);
        }
      });
    }

    async function connectToRoom() {
      try {
        var tokenData = await api("/api/events/" + props.eventId + "/spectator-token", { method: "POST" });
        var wsUrl = await getLivekitWsUrl();
        var newRoom = new LK.Room({ adaptiveStream: true, dynacast: true });
        // The host signals through the room when there are new approved messages: the chat reloads right away
        newRoom.on(LK.RoomEvent.DataReceived, function (payload) {
          var msg = _decodeMsg(payload);
          if (msg && (msg.type === "chat" || msg.type === "chat_refresh")) window.dispatchEvent(new Event("amapod-chat"));
        });
        newRoom.on(LK.RoomEvent.TrackSubscribed, function (track, pub, participant) {
          var id = participant.identity;
          if (track.kind === LK.Track.Kind.Video) {
            _tracks[id] = track;
            var name = id.startsWith("host_") ? "Anfitrión" : (participant.name || "Invitado");
            tiles.value = tiles.value.filter(function (t) { return t.id !== id; })
              .concat([{ id: id, name: name, host: id.startsWith("host_") }])
              .sort(function (a, b) { return (b.host ? 1 : 0) - (a.host ? 1 : 0); });
            mountTile(id);
          } else if (track.kind === LK.Track.Kind.Audio) {
            document.body.appendChild(track.attach());
          }
        });
        newRoom.on(LK.RoomEvent.TrackUnsubscribed, function (track, pub, participant) {
          track.detach().forEach(function (el) { el.remove(); });
          if (track.kind === LK.Track.Kind.Video) {
            delete _tracks[participant.identity];
            tiles.value = tiles.value.filter(function (t) { return t.id !== participant.identity; });
          }
        });
        newRoom.on(LK.RoomEvent.AudioPlaybackStatusChanged, function () { needsAudioTap.value = !newRoom.canPlaybackAudio; });
        newRoom.on(LK.RoomEvent.DataReceived, function (payload) {
          var msg = _decodeMsg(payload);
          if (msg && msg.type === "event_ended") { eventInfo.value.status = "finished"; if (newRoom) newRoom.disconnect(); }
        });
        newRoom.on(LK.RoomEvent.Disconnected, function () { connected.value = false; });
        await newRoom.connect(wsUrl, tokenData.token);
        room.value = newRoom;
        connected.value = true;
        needsAudioTap.value = !newRoom.canPlaybackAudio;
        pollTimer.value = setInterval(pollLikes, 5000);
      } catch (e) {
        error.value = "No se pudo conectar al evento. Revisa tu conexión y recarga la página.";
      }
    }

    async function enableAudio() {
      try { if (room.value) await room.value.startAudio(); } catch (_) {}
      document.querySelectorAll("audio").forEach(function (a) { try { a.play(); } catch (_) {} });
      needsAudioTap.value = false;
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
      likeBurst.value.push({ id: id, x: 10 + Math.random() * 30 });
      setTimeout(function () { likeBurst.value = likeBurst.value.filter(function (b) { return b.id !== id; }); }, 1200);
      try { var res = await api("/api/events/" + props.eventId + "/like", { method: "POST" }); likeCount.value = res.like_count; } catch (_) {}
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
      if (waitTimer) { clearInterval(waitTimer); waitTimer = null; }
      if (room.value) { room.value.disconnect(); room.value = null; }
    });

    return {
      eventInfo: eventInfo, loading: loading, error: error, eventId: props.eventId,
      connected: connected, likeCount: likeCount, spectatorCount: spectatorCount,
      likeBurst: likeBurst, sendLike: sendLike, leave: leave,
      tiles: tiles, needsAudioTap: needsAudioTap, enableAudio: enableAudio,
    };
  },
  template: `
<div class="spectator-view ama-public">
  <div v-if="loading" class="ama-loading"><div class="ama-spinner"></div></div>
  <div v-else-if="error && !connected" class="participant-status ama-wait"><div class="ama-brand">ama<span class="brand-accent">Pod</span></div><p class="error-text">{{ error }}</p></div>
  <div v-else-if="eventInfo && eventInfo.status !== 'active' && !connected" class="participant-status ama-wait">
    <div class="ama-brand">ama<span class="brand-accent">Pod</span></div>
    <h2>{{ eventInfo.title }}</h2>
    <template v-if="eventInfo.status === 'created'">
      <div class="ama-state-icon ama-pulse">⏳</div>
      <p class="ama-lead">Empieza pronto. Deja esta página abierta: se conecta sola.</p>
      <a class="primary ama-ask" :href="'/join/' + eventId">Quiero preguntar</a>
    </template>
    <template v-else-if="eventInfo.status === 'left'"><p class="ama-lead">Saliste del evento.</p></template>
    <template v-else><div class="ama-state-icon">⏹</div><p class="ama-lead">Este evento ya terminó.</p></template>
  </div>
  <div v-else class="ama-watch-layout">
    <div class="ama-watch-top">
      <span class="ama-brand small">ama<span class="brand-accent">Pod</span></span>
      <span class="ama-live">EN VIVO</span>
      <span class="spacer"></span>
      <span class="ama-viewers">👁 {{ spectatorCount }}</span>
    </div>
    <div class="ama-watch-stage" :class="'n' + tiles.length" @dblclick="sendLike">
      <div v-for="t in tiles" :key="t.id" class="ama-watch-tile">
        <div :data-spec-id="t.id" class="ama-watch-video"></div>
        <div class="video-label">{{ t.name }}</div>
      </div>
      <div v-if="!tiles.length" class="ama-watch-empty">Conectando con el evento…</div>
      <button v-if="needsAudioTap" class="ama-sound" @click.stop="enableAudio">🔈 Toca para escuchar</button>
      <div v-for="b in likeBurst" :key="b.id" class="spec-like-float" :style="{ right: b.x + '%' }">❤</div>
    </div>
    <div class="ama-watch-info">
      <h3>{{ eventInfo.title }}</h3>
      <p v-if="eventInfo.description" class="muted">{{ eventInfo.description }}</p>
    </div>
    <audience-chat :event-id="eventId" class="ama-watch-chat" />
    <div class="ama-watch-actions">
      <button class="ama-like" @click="sendLike">❤ <span>{{ likeCount }}</span></button>
      <a class="primary ama-ask" :href="'/join/' + eventId">Quiero preguntar</a>
      <button class="ghost" @click="leave">Salir</button>
    </div>
  </div>
</div>`
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
      var base = window.POD_BASE || "";
      if (base && path.indexOf(base) === 0) path = path.slice(base.length) || "/";
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

    var touch = useTouch();
    watch([touch, function () { return state.route; }], function (v) {
      document.body.classList.toggle("m-app", !!(v[0] && (v[1] === "dashboard" || v[1] === "host")));
    }, { immediate: true });
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
_app.component("audience-chat", AudienceChat);
_app.component("PodPwaRows", PodPwaRows);
_app.mount("#app");
