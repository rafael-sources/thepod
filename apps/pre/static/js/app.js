var { createApp, reactive, ref, computed, onMounted, onBeforeUnmount, watch } = Vue;

/* ==========================================================================
   Helpers
   ========================================================================== */

async function api(path, options = {}) {
  const opts = {
    credentials: "same-origin",
    headers: { Accept: "application/json" },
    ...options,
  };
  if (opts.body && !(opts.body instanceof FormData)) {
    opts.headers["Content-Type"] = "application/json";
    opts.body = JSON.stringify(opts.body);
  }
  const res = await fetch(path, opts);
  const text = await res.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch (_) { data = { error: text }; }
  if (!res.ok) {
    const err = new Error(data?.error || res.statusText);
    err.status = res.status;
    err.data = data;
    throw err;
  }
  return data;
}

function apiUpload(path, formData, onProgress) {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open("POST", path);
    xhr.withCredentials = true;
    xhr.upload.addEventListener("progress", (ev) => {
      if (ev.lengthComputable && onProgress) onProgress(Math.round((ev.loaded / ev.total) * 100));
    });
    xhr.addEventListener("load", () => {
      let data = null;
      try { data = xhr.responseText ? JSON.parse(xhr.responseText) : null; }
      catch (_) { data = { error: xhr.responseText }; }
      if (xhr.status >= 200 && xhr.status < 300) resolve(data);
      else {
        const err = new Error(data?.error || xhr.statusText || "upload failed");
        err.status = xhr.status;
        reject(err);
      }
    });
    xhr.addEventListener("error", () => reject(new Error("error de red")));
    xhr.send(formData);
  });
}

function fmtDate(s) {
  if (!s) return "";
  try {
    return new Date(s.endsWith("Z") ? s : s + "Z").toLocaleString("es-AR", {
      day: "2-digit", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit",
    });
  } catch (_) { return s; }
}

function debounce(fn, ms = 400) {
  let t = null;
  return function (...args) {
    clearTimeout(t);
    t = setTimeout(() => fn.apply(this, args), ms);
  };
}

/* ==========================================================================
   Login
   ========================================================================== */

// Celular / iPad: la misma regla que usa el CSS para el modo táctil.
function isTouchLayout() {
  try { return window.matchMedia("(max-width: 900px), (pointer: coarse)").matches; } catch (_) { return false; }
}

var LoginView = {
  props: { onLoggedIn: { type: Function, required: true } },
  setup(props) {
    const username = ref("");
    const password = ref("");
    const error = ref("");
    const success = ref("");
    const busy = ref(false);
    const mode = ref("login"); // "login" | "forgot" | "reset"
    const forgotId = ref("");
    const resetToken = ref("");
    const newPassword = ref("");
    const newPassword2 = ref("");

    // Check URL for reset token on mount
    onMounted(() => {
      var params = new URLSearchParams(window.location.search);
      var token = params.get("token");
      if (window.location.pathname === "/reset-password" && token) {
        mode.value = "reset";
        resetToken.value = token;
      }
    });

    async function submit() {
      error.value = ""; busy.value = true;
      try {
        const data = await api("/api/auth/login", {
          method: "POST",
          body: { username: username.value, password: password.value },
        });
        props.onLoggedIn(data.username);
      } catch (e) { error.value = e.message; }
      finally { busy.value = false; }
    }

    async function submitForgot() {
      error.value = ""; success.value = ""; busy.value = true;
      try {
        var r = await api("/api/auth/forgot-password", {
          method: "POST",
          body: { identifier: forgotId.value },
        });
        success.value = r.message;
      } catch (e) { error.value = e.message; }
      finally { busy.value = false; }
    }

    async function submitReset() {
      error.value = ""; success.value = "";
      if (newPassword.value.length < 6) { error.value = "La contraseña debe tener al menos 6 caracteres."; return; }
      if (newPassword.value !== newPassword2.value) { error.value = "Las contraseñas no coinciden."; return; }
      busy.value = true;
      try {
        var r = await api("/api/auth/reset-password", {
          method: "POST",
          body: { token: resetToken.value, password: newPassword.value },
        });
        success.value = r.message;
        setTimeout(function() { mode.value = "login"; window.history.replaceState({}, "", "/"); }, 2000);
      } catch (e) { error.value = e.message; }
      finally { busy.value = false; }
    }

    return { username, password, error, success, busy, mode,
             forgotId, resetToken, newPassword, newPassword2,
             submit, submitForgot, submitReset };
  },
  template: `
    <div class="login-wrapper">
      <div class="login-card">
        <div class="eyebrow">GREEN ROOM · PRE-PRODUCCIÓN</div>
        <h2>pre<em>Pod</em></h2>

        <!-- LOGIN -->
        <template v-if="mode === 'login'">
          <div class="subtitle">Branding, episodios y planificación previos a la grabación.</div>
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
              {{ busy ? "Verificando…" : "Entrar a la sala" }}
            </button>
          </form>
          <div style="text-align:center;margin-top:14px;">
            <a href="#" @click.prevent="mode = 'forgot'; error = ''; success = ''" style="font-size:12px;color:var(--paper-dim,#8a7d65);">
              Olvidé mi contraseña
            </a>
          </div>
        </template>

        <!-- FORGOT PASSWORD -->
        <template v-if="mode === 'forgot'">
          <div class="subtitle">Ingresa tu usuario o email para recibir un enlace de recuperación.</div>
          <form @submit.prevent="submitForgot">
            <div class="form-row">
              <label>Usuario o email</label>
              <input type="text" v-model="forgotId" autofocus placeholder="ej: admin o correo@ejemplo.com">
            </div>
            <div v-if="error" class="error">{{ error }}</div>
            <div v-if="success" class="success" style="color:#5a8bff;font-size:13px;margin:10px 0;">{{ success }}</div>
            <button type="submit" class="primary" :disabled="busy || !forgotId.trim()">
              {{ busy ? "Enviando…" : "Enviar enlace" }}
            </button>
          </form>
          <div style="text-align:center;margin-top:14px;">
            <a href="#" @click.prevent="mode = 'login'; error = ''; success = ''" style="font-size:12px;color:var(--paper-dim,#8a7d65);">
              Volver al login
            </a>
          </div>
        </template>

        <!-- RESET PASSWORD -->
        <template v-if="mode === 'reset'">
          <div class="subtitle">Crea tu nueva contraseña.</div>
          <form @submit.prevent="submitReset">
            <div class="form-row">
              <label>Nueva contraseña</label>
              <input type="password" v-model="newPassword" autofocus autocomplete="new-password" placeholder="Mínimo 6 caracteres">
            </div>
            <div class="form-row" style="margin-top:14px;">
              <label>Confirmar contraseña</label>
              <input type="password" v-model="newPassword2" autocomplete="new-password">
            </div>
            <div v-if="error" class="error">{{ error }}</div>
            <div v-if="success" class="success" style="color:#5a8bff;font-size:13px;margin:10px 0;">{{ success }}</div>
            <button type="submit" class="primary" :disabled="busy">
              {{ busy ? "Guardando…" : "Cambiar contraseña" }}
            </button>
          </form>
          <div style="text-align:center;margin-top:14px;">
            <a href="#" @click.prevent="mode = 'login'; error = ''; success = ''; window.history.replaceState({}, '', '/')" style="font-size:12px;color:var(--paper-dim,#8a7d65);">
              Volver al login
            </a>
          </div>
        </template>

        <div class="footer-line">
          <span>CH · 02</span>
          <span>v0.1 · plan 1</span>
        </div>
      </div>
    </div>
  `,
};

/* ==========================================================================
   Podcast list
   ========================================================================== */

var PodcastListView = {
  props: { onOpen: { type: Function, required: true } },
  setup(props) {
    const podcasts = ref([]);
    const loading = ref(true);
    const error = ref("");
    const showCreate = ref(false);
    const newName = ref("");
    const creating = ref(false);

    async function load() {
      loading.value = true;
      error.value = "";
      try { podcasts.value = await api("/api/podcasts"); }
      catch (e) { error.value = e.message; }
      finally { loading.value = false; }
    }

    async function create() {
      if (!newName.value.trim()) return;
      creating.value = true;
      try {
        const p = await api("/api/podcasts", {
          method: "POST",
          body: { name: newName.value.trim() },
        });
        showCreate.value = false;
        newName.value = "";
        await load();
        props.onOpen(p);
      } catch (e) { error.value = e.message; }
      finally { creating.value = false; }
    }

    async function remove(p, ev) {
      ev.stopPropagation();
      if (!await podSwal.confirm(`¿Eliminar podcast "${p.name}"?\nSe borrarán TODOS sus archivos de branding.`)) return;
      try { await api(`/api/podcasts/${p.slug}`, { method: "DELETE" }); await load(); }
      catch (e) { error.value = e.message; }
    }

    const importing = ref(false);
    function triggerImport() {
      const input = document.createElement("input");
      input.type = "file";
      input.accept = ".zip";
      input.onchange = async () => {
        if (!input.files || !input.files[0]) return;
        importing.value = true;
        error.value = "";
        try {
          const fd = new FormData();
          fd.append("file", input.files[0]);
          const r = await fetch("/api/podcasts/import", { method: "POST", credentials: "same-origin", body: fd });
          const data = await r.json();
          if (!r.ok) throw new Error(data.error || "error al importar");
          await load();
        } catch (e) { error.value = e.message; }
        finally { importing.value = false; }
      };
      input.click();
    }
    onMounted(load);
    return { podcasts, loading, error, showCreate, newName, creating, create, remove, fmtDate, importing, triggerImport };
  },
  template: `
    <div class="container">
      <div class="page-head">
        <div>
          <div class="eyebrow">PODCASTS · SHOWS ACTIVOS</div>
          <h2>Green <em style="color:var(--signal);font-style:italic;">room</em></h2>
        </div>
        <div class="spacer"></div>
        <button class="ghost" @click="triggerImport" :disabled="importing" style="margin-right:8px;">
          {{ importing ? "Importando…" : "↑ Importar" }}
        </button>
        <button class="primary" @click="showCreate = true">＋ Nuevo podcast</button>
      </div>
      <div v-if="error" class="error">{{ error }}</div>
      <div v-if="loading" class="muted">Cargando shows…</div>
      <div v-else-if="podcasts.length === 0" class="empty-state">
        <div class="icon">∅</div>
        <div style="font-family:var(--font-display); font-size:18px; font-style:italic; margin-bottom:4px;">
          Aún no hay podcasts.
        </div>
        <div>Crea el primero para definir su branding, episodios y script.</div>
      </div>
      <div v-else class="podcast-list">
        <div v-for="p in podcasts" :key="p.slug" class="podcast-tile" @click="$props.onOpen(p)">
          <div class="cover" :style="p.cover_url ? { backgroundImage: 'url(' + p.cover_url + ')' } : { background: 'linear-gradient(135deg,' + p.color_secondary + ',' + p.color_primary + ')' }">
            <div v-if="p.logo_url" class="logo-corner" :style="{ backgroundImage: 'url(' + p.logo_url + ')' }"></div>
          </div>
          <div class="body">
            <h3>{{ p.name }}</h3>
            <div v-if="p.tagline" class="tagline">{{ p.tagline }}</div>
            <div class="slug">/ {{ p.slug }}</div>
            <div class="bottom">
              <span class="tiny">{{ fmtDate(p.created_at) }}</span>
              <button class="danger" @click="remove(p, $event)">Eliminar</button>
            </div>
          </div>
        </div>
      </div>

      <div v-if="showCreate" class="modal-backdrop" @click.self="showCreate = false">
        <div class="modal">
          <div class="eyebrow">NUEVO PODCAST</div>
          <h3>Crear podcast</h3>
          <p class="muted" style="margin-bottom:18px;">Definirás branding, episodios y guion desde adentro. El nombre se puede cambiar después.</p>
          <div class="form-row">
            <label>Nombre</label>
            <input type="text" v-model="newName" @keyup.enter="create" autofocus placeholder="Pistas de Garage">
          </div>
          <div class="row right" style="margin-top:20px; gap:8px;">
            <button class="ghost" @click="showCreate = false">Cancelar</button>
            <button class="primary" @click="create" :disabled="creating || !newName.trim()">
              {{ creating ? "Creando…" : "Crear" }}
            </button>
          </div>
        </div>
      </div>
    </div>
  `,
};

/* ==========================================================================
   Branding editor (Plan 1 — refactored into its own component)
   ========================================================================== */

var BrandingEditor = {
  props: { podcast: Object, onUpdated: Function },
  setup(props) {
    const meta = reactive({ ...props.podcast });
    const error = ref("");
    const saveState = ref(null);  // null | "saving" | "saved" | "error"
    const fonts = ref([
      "Fraunces", "Bricolage Grotesque", "Inter", "Poppins",
      "Roboto", "Lora", "Playfair Display", "Space Grotesk",
      "DM Serif Display", "Archivo",
    ]);

    async function loadFonts() {
      try {
        const r = await api("/api/config/fonts");
        if (r?.fonts?.length) fonts.value = r.fonts;
      } catch (_) {}
    }

    // Manual save model: dirty flag + user-controlled "Guardar" button +
    // a soft autosave only after 60s of inactivity (so nothing ever gets
    // lost permanently). NEVER overwrite local reactive state with the
    // server response (that's what cleared fields while typing).
    const dirty = ref(false);

    async function _doSave() {
      saveState.value = "saving";
      try {
        const updated = await api(`/api/podcasts/${meta.slug}`, {
          method: "PUT",
          body: {
            name: meta.name,
            description: meta.description,
            tagline: meta.tagline,
            color_primary: meta.color_primary,
            color_secondary: meta.color_secondary,
            color_accent: meta.color_accent,
            color_bg: meta.color_bg,
            color_text: meta.color_text,
            color_text_align: meta.color_text_align,
            font_heading: meta.font_heading,
            font_body: meta.font_body,
            rss_override_url: meta.rss_override_url,
          },
        });
        dirty.value = false;
        saveState.value = "saved";
        setTimeout(() => { if (saveState.value === "saved") saveState.value = null; }, 2000);
        props.onUpdated?.(updated);
      } catch (e) {
        saveState.value = "error";
        error.value = e.message;
      }
    }

    const _idleSave = debounce(() => { if (dirty.value) _doSave(); }, 60_000);
    function saveNow() { _doSave(); }

    watch(() => [
      meta.name, meta.description, meta.tagline,
      meta.color_primary, meta.color_secondary, meta.color_accent,
      meta.color_bg, meta.color_text, meta.color_text_align,
      meta.font_heading, meta.font_body, meta.rss_override_url,
    ], (newVals, oldVals) => {
      if (!oldVals || oldVals.every(v => v === undefined)) return;
      dirty.value = true;
      _idleSave();
    });

    async function uploadImage(kind, ev) {
      const f = ev.target.files?.[0];
      if (!f) return;
      error.value = "";
      saveState.value = "saving";
      try {
        const form = new FormData();
        form.append("file", f);
        const r = await apiUpload(`/api/podcasts/${meta.slug}/branding/${kind}`, form);
        if (kind === "logo") { meta.logo_filename = r.filename; meta.logo_url = r.url; }
        else if (kind === "cover") { meta.cover_filename = r.filename; meta.cover_url = r.url; }
        else if (kind === "background") { meta.background_filename = r.filename; meta.background_url = r.url; }
        saveState.value = "saved";
        setTimeout(() => { if (saveState.value === "saved") saveState.value = null; }, 1400);
        ev.target.value = "";
        props.onUpdated?.({ ...meta });
      } catch (e) {
        saveState.value = "error";
        error.value = e.message;
      }
    }

    async function clearImage(kind) {
      const labels = { logo: "logo", cover: "cover", background: "fondo" };
      if (!await podSwal.confirm(`¿Quitar ${labels[kind] || kind}?`)) return;
      try {
        await api(`/api/podcasts/${meta.slug}/branding/${kind}`, { method: "DELETE" });
        if (kind === "logo") { meta.logo_filename = null; meta.logo_url = null; }
        else if (kind === "cover") { meta.cover_filename = null; meta.cover_url = null; }
        else if (kind === "background") { meta.background_filename = null; meta.background_url = null; }
        saveState.value = "saved";
        setTimeout(() => { if (saveState.value === "saved") saveState.value = null; }, 1400);
        props.onUpdated?.({ ...meta });
      } catch (e) { error.value = e.message; }
    }

    const previewStyle = computed(() => ({
      "--brand-primary": meta.color_primary,
      "--brand-secondary": meta.color_secondary,
      "--brand-accent": meta.color_accent,
      "--brand-heading": `'${meta.font_heading}', serif`,
      "--brand-body": `'${meta.font_body}', sans-serif`,
      "--brand-cover": meta.cover_url ? `url(${meta.cover_url})` : "none",
    }));

    onMounted(() => { loadFonts(); loadHosts(); });

    // ---- Hosts (owner + extra_hosts) ----
    const owner = ref("");
    const extraHosts = ref([]);
    const hostInvitations = ref({});
    const newHost = ref("");
    const hostsError = ref("");
    const hostsSuccess = ref("");
    const hostsBusy = ref(false);
    const hostSuggestions = ref([]);
    const hostSearchFocused = ref(false);
    let hostSearchTimer = null;
    const directors = ref([]);

    function _syncHostResponse(r) {
      owner.value = r.owner || "";
      extraHosts.value = r.extra_hosts || [];
      if (r.invitations) hostInvitations.value = r.invitations;
    }

    async function loadHosts() {
      try {
        const r = await api(`/api/podcasts/${meta.slug}/hosts`);
        _syncHostResponse(r);
        if (r.directors) directors.value = r.directors;
      } catch (e) { hostsError.value = e.message; }
    }
    async function saveHosts(list) {
      hostsBusy.value = true; hostsError.value = "";
      try { _syncHostResponse(await api(`/api/podcasts/${meta.slug}/hosts`, { method: "PUT", body: { extra_hosts: list } })); }
      catch (e) { hostsError.value = e.message; }
      finally { hostsBusy.value = false; }
    }
    function onHostInput() {
      clearTimeout(hostSearchTimer);
      const q = newHost.value.trim();
      if (q.length < 1) { hostSuggestions.value = []; return; }
      hostSearchTimer = setTimeout(async () => {
        try {
          const all = await api("/api/podcasts/search-users?q=" + encodeURIComponent(q));
          hostSuggestions.value = all.filter(u =>
            u.username !== owner.value && !extraHosts.value.includes(u.username)
          );
        } catch (_) { hostSuggestions.value = []; }
      }, 200);
    }
    async function inviteHost(username) {
      hostsBusy.value = true; hostsError.value = ""; hostsSuccess.value = "";
      hostSuggestions.value = [];
      newHost.value = "";
      try {
        const r = await api(`/api/podcasts/${meta.slug}/invite-host`, {
          method: "POST",
          body: { username },
        });
        _syncHostResponse(r);
        if (r.email && r.email.ok) {
          hostsSuccess.value = "Invitación enviada por correo a " + username + ".";
          setTimeout(() => { hostsSuccess.value = ""; }, 5000);
        } else if (r.email && r.email.reason === "no_email") {
          hostsError.value = "Host agregado, pero no tiene email configurado — no se envió invitación.";
        } else if (r.email && !r.email.ok) {
          hostsError.value = "Host agregado, pero falló el envío del correo.";
        } else {
          hostsSuccess.value = "Host agregado.";
          setTimeout(() => { hostsSuccess.value = ""; }, 3000);
        }
      } catch (e) { hostsError.value = e.message; }
      finally { hostsBusy.value = false; }
    }
    async function addHost() {
      const v = newHost.value.trim().toLowerCase();
      if (!v) return;
      await inviteHost(v);
    }
    async function removeHost(u) {
      if (!await podSwal.confirm('¿Quitar a "' + u + '" como host de este podcast?')) return;
      await saveHosts(extraHosts.value.filter(x => x !== u));
    }

    // ---- Directors ----
    const newDirector = ref("");
    const directorError = ref("");
    const directorBusy = ref(false);
    const directorSuggestions = ref([]);
    const directorSearchFocused = ref(false);
    let directorSearchTimer = null;

    function onDirectorInput() {
      clearTimeout(directorSearchTimer);
      const q = newDirector.value.trim();
      if (q.length < 1) { directorSuggestions.value = []; return; }
      directorSearchTimer = setTimeout(async () => {
        try {
          const all = await api("/api/podcasts/search-users?q=" + encodeURIComponent(q));
          directorSuggestions.value = all.filter(u =>
            !directors.value.includes(u.username)
          );
        } catch (_) { directorSuggestions.value = []; }
      }, 200);
    }

    async function addDirector(username) {
      const u = username || newDirector.value.trim().toLowerCase();
      if (!u) return;
      directorBusy.value = true; directorError.value = "";
      directorSuggestions.value = []; newDirector.value = "";
      try {
        const r = await api(`/api/podcasts/${meta.slug}/directors`, {
          method: "POST", body: { username: u },
        });
        _syncDirectors(r);
      } catch (e) { directorError.value = e.message; }
      finally { directorBusy.value = false; }
    }

    async function removeDirector(u) {
      if (!await podSwal.confirm('¿Quitar a "' + u + '" como director?')) return;
      directorBusy.value = true; directorError.value = "";
      try {
        const r = await api(`/api/podcasts/${meta.slug}/directors/${u}`, { method: "DELETE" });
        _syncDirectors(r);
      } catch (e) { directorError.value = e.message; }
      finally { directorBusy.value = false; }
    }

    return {
      meta, error, saveState, dirty, saveNow, fonts,
      previewStyle, uploadImage, clearImage, fmtDate,
      owner, extraHosts, hostInvitations, newHost, hostsError, hostsSuccess, hostsBusy,
      hostSuggestions, hostSearchFocused,
      loadHosts, addHost, removeHost, onHostInput, inviteHost,
      directors, newDirector, directorError, directorBusy,
      directorSuggestions, directorSearchFocused,
      addDirector, removeDirector, onDirectorInput,
    };
  },
  template: `
    <div class="editor">
      <div class="main">
        <div v-if="error" class="error">{{ error }}</div>

        <!-- Identidad -->
        <div class="section">
          <div class="section-head">
            <div class="eyebrow">IDENTIDAD</div>
            <h3>Nombre, descripción y tagline</h3>
          </div>
          <div class="form-row">
            <label>Nombre del podcast</label>
            <input type="text" v-model="meta.name">
          </div>
          <div class="form-row" style="margin-top: 12px;">
            <label>Tagline (una línea)</label>
            <input type="text" v-model="meta.tagline" placeholder="Ej: conversaciones honestas desde el garage">
          </div>
          <div class="form-row" style="margin-top: 12px;">
            <label>Descripción</label>
            <textarea v-model="meta.description" rows="3" placeholder="De qué va tu podcast, a quién le habla, qué tono tiene..."></textarea>
          </div>
        </div>

        <!-- Hosts -->
        <div class="section">
          <div class="section-head">
            <div class="eyebrow">HOSTS</div>
            <h3>Quién tiene acceso a este podcast</h3>
          </div>
          <p class="muted" style="margin-top: -6px; font-size: 12px;">
            El <strong>owner</strong> creó el podcast. Los <strong>hosts adicionales</strong> también lo ven en su lista y pueden editarlo.
          </p>
          <div v-if="hostsError" class="error">{{ hostsError }}</div>
          <div v-if="hostsSuccess" class="host-success" style="font-size:13px;color:#5a8bff;padding:6px 10px;background:rgba(90,139,255,0.08);border-radius:6px;margin-top:8px;">{{ hostsSuccess }}</div>
          <div class="hosts-row">
            <span class="host-chip owner">{{ owner }} · owner</span>
            <span v-for="u in extraHosts" :key="u" class="host-chip"
                  :class="{ 'host-pending': hostInvitations[u] && hostInvitations[u].status === 'pendiente',
                            'host-accepted': hostInvitations[u] && hostInvitations[u].status === 'aceptado' }">
              {{ u }}
              <span v-if="hostInvitations[u]" class="host-status-badge">
                <template v-if="hostInvitations[u].status === 'pendiente'">
                  pendiente
                  <span v-if="hostInvitations[u].email_sent" class="host-email-sent" title="Correo enviado">&#9993;</span>
                </template>
                <template v-else-if="hostInvitations[u].status === 'aceptado'">aceptado</template>
              </span>
              <button class="icon danger" @click="removeHost(u)" :disabled="hostsBusy" title="Quitar host">&#10005;</button>
            </span>
            <span v-if="!extraHosts.length && owner" class="muted" style="font-size: 12px;">Sin hosts adicionales.</span>
          </div>
          <div class="hosts-add" style="position:relative;">
            <input type="text" v-model="newHost" @input="onHostInput"
                   @focus="hostSearchFocused = true"
                   @blur="setTimeout(() => hostSearchFocused = false, 200)"
                   @keyup.enter="addHost"
                   placeholder="Buscar usuario..." :disabled="hostsBusy"
                   autocomplete="off">
            <button class="primary" @click="addHost" :disabled="hostsBusy || !newHost.trim()">＋ Invitar host</button>
            <div v-if="hostSuggestions.length && hostSearchFocused" class="host-autocomplete">
              <div v-for="s in hostSuggestions" :key="s.username" class="host-suggestion"
                   @mousedown.prevent="inviteHost(s.username)">
                <span class="host-sug-avatar" :style="{ background: s.avatar_color }">{{ s.display_name[0] }}</span>
                <span class="host-sug-info">
                  <strong>{{ s.display_name }}</strong> <span class="muted mono">@{{ s.username }}</span>
                  <span v-if="s.email" class="muted" style="font-size:11px;display:block;">{{ s.email }}</span>
                </span>
              </div>
            </div>
          </div>
        </div>

        <!-- Director -->
        <div class="section">
          <div class="section-head">
            <div class="eyebrow">DIRECTOR</div>
            <h3>Director de producción</h3>
          </div>
          <p class="muted" style="margin-top: -6px; font-size: 12px;">
            El director puede conectarse al Control Room en prodPod durante una grabación en vivo. Desde ahí puede inyectar overlays, enviar cues a los hosts, y controlar la producción sin estar en cámara.
          </p>
          <div v-if="directorError" class="error">{{ directorError }}</div>
          <div class="hosts-row">
            <span v-for="d in directors" :key="d" class="host-chip" style="border-color: #00bcd4;">
              {{ d }}
              <button class="icon danger" @click="removeDirector(d)" :disabled="directorBusy" title="Quitar director">&#10005;</button>
            </span>
            <span v-if="!directors.length" class="muted" style="font-size: 12px;">Sin director asignado.</span>
          </div>
          <div class="hosts-add" style="position:relative;">
            <input type="text" v-model="newDirector" @input="onDirectorInput"
                   @focus="directorSearchFocused = true"
                   @blur="setTimeout(() => directorSearchFocused = false, 200)"
                   @keyup.enter="addDirector()"
                   placeholder="Buscar usuario..." :disabled="directorBusy"
                   autocomplete="off">
            <button class="primary" @click="addDirector()" :disabled="directorBusy || !newDirector.trim()">＋ Asignar director</button>
            <div v-if="directorSuggestions.length && directorSearchFocused" class="host-autocomplete">
              <div v-for="s in directorSuggestions" :key="s.username" class="host-suggestion"
                   @mousedown.prevent="addDirector(s.username)">
                <span class="host-sug-avatar" :style="{ background: s.avatar_color }">{{ s.display_name[0] }}</span>
                <span class="host-sug-info">
                  <strong>{{ s.display_name }}</strong> <span class="muted mono">@{{ s.username }}</span>
                </span>
              </div>
            </div>
          </div>
        </div>

        <!-- Colores -->
        <div class="section">
          <div class="section-head">
            <div class="eyebrow">COLORES</div>
            <h3>Paleta del podcast</h3>
          </div>
          <div class="grid-3">
            <div>
              <label>Primario</label>
              <div class="color-field">
                <input type="color" v-model="meta.color_primary">
                <input type="text" class="hex" v-model="meta.color_primary">
              </div>
            </div>
            <div>
              <label>Secundario</label>
              <div class="color-field">
                <input type="color" v-model="meta.color_secondary">
                <input type="text" class="hex" v-model="meta.color_secondary">
              </div>
            </div>
            <div>
              <label>Acento</label>
              <div class="color-field">
                <input type="color" v-model="meta.color_accent">
                <input type="text" class="hex" v-model="meta.color_accent">
              </div>
            </div>
            <div>
              <label>Fondo (landing)</label>
              <div class="color-field">
                <input type="color" :value="meta.color_bg || '#fafaf7'" @input="meta.color_bg = $event.target.value">
                <input type="text" class="hex" v-model="meta.color_bg" placeholder="(default)">
              </div>
            </div>
            <div>
              <label>Texto (landing)</label>
              <div class="color-field">
                <input type="color" :value="meta.color_text || '#14110b'" @input="meta.color_text = $event.target.value">
                <input type="text" class="hex" v-model="meta.color_text" placeholder="(default)">
              </div>
            </div>
          </div>
        </div>

        <!-- Tipografía -->
        <div class="section">
          <div class="section-head">
            <div class="eyebrow">TIPOGRAFÍA</div>
            <h3>Fuentes para títulos y cuerpo</h3>
          </div>
          <div class="grid-2">
            <div>
              <label>Títulos</label>
              <select v-model="meta.font_heading">
                <option v-for="f in fonts" :key="f" :value="f">{{ f }}</option>
              </select>
            </div>
            <div>
              <label>Cuerpo</label>
              <select v-model="meta.font_body">
                <option v-for="f in fonts" :key="f" :value="f">{{ f }}</option>
              </select>
            </div>
            <div>
              <label>Alineación del texto</label>
              <select v-model="meta.color_text_align">
                <option :value="null">Izquierda (default)</option>
                <option value="left">Izquierda</option>
                <option value="center">Centrado</option>
                <option value="right">Derecha</option>
                <option value="justify">Justificado</option>
              </select>
            </div>
            <div>
              <label>RSS personalizado (opcional)</label>
              <input type="text" v-model="meta.rss_override_url" placeholder="https://feeds.tuhost.com/...">
              <div class="muted" style="font-size: 11px; margin-top: 4px;">Si tienes el RSS hosteado en otro lado, ponlo aquí. Si está vacío, se usa el de prePod.</div>
            </div>
          </div>
        </div>

        <!-- Assets visuales -->
        <div class="section">
          <div class="section-head">
            <div class="eyebrow">ASSETS</div>
            <h3>Logo, cover y fondo</h3>
          </div>
          <div class="grid-2">
            <div>
              <label>Logo (hasta 500 × 500)</label>
              <div class="image-slot">
                <div v-if="meta.logo_url" class="preview logo-aspect" :style="{ backgroundImage: 'url(' + meta.logo_url + ')' }"></div>
                <input type="file" accept="image/*" @change="(ev) => uploadImage('logo', ev)">
                <div v-if="meta.logo_url" class="image-actions">
                  <button class="danger" @click="clearImage('logo')">Quitar</button>
                </div>
              </div>
            </div>
            <div>
              <label>Cover (hasta 1200 × 800)</label>
              <div class="image-slot">
                <div v-if="meta.cover_url" class="preview cover-aspect" :style="{ backgroundImage: 'url(' + meta.cover_url + ')' }"></div>
                <input type="file" accept="image/*" @change="(ev) => uploadImage('cover', ev)">
                <div v-if="meta.cover_url" class="image-actions">
                  <button class="danger" @click="clearImage('cover')">Quitar</button>
                </div>
              </div>
            </div>
          </div>
          <div style="margin-top: 16px;">
            <label>Fondo de video (reemplaza barras negras en el export)</label>
            <div class="muted" style="font-size: 11px; margin-bottom: 6px;">
              Se usa detrás del video cuando el aspect ratio no coincide con el formato de salida. Ideal: degradado o patrón del branding.
            </div>
            <div class="image-slot">
              <div v-if="meta.background_url" class="preview cover-aspect" :style="{ backgroundImage: 'url(' + meta.background_url + ')' }"></div>
              <input type="file" accept="image/*" @change="(ev) => uploadImage('background', ev)">
              <div v-if="meta.background_url" class="image-actions">
                <button class="danger" @click="clearImage('background')">Quitar</button>
              </div>
            </div>
          </div>
        </div>
      </div>

      <!-- Preview column -->
      <aside class="side">
        <div class="preview-wrap">
          <div class="preview-heading">PREVIEW DEL BRANDING</div>
          <div class="brand-preview" :style="previewStyle">
            <div class="hero">
              <div class="hero-content">
                <div v-if="meta.logo_url" class="hero-logo" :style="{ backgroundImage: 'url(' + meta.logo_url + ')' }"></div>
                <div v-else class="hero-logo"></div>
                <div class="hero-name">{{ meta.name }}</div>
                <div v-if="meta.tagline" class="hero-tagline">{{ meta.tagline }}</div>
              </div>
            </div>
            <div class="body">
              <div class="desc">{{ meta.description || "Agrega una descripción para ver cómo queda aquí." }}</div>
              <div class="cta">Escuchar episodio →</div>
            </div>
          </div>

          <div class="swatch-strip">
            <div class="s" :style="{ background: meta.color_primary }">primario</div>
            <div class="s" :style="{ background: meta.color_secondary }">secundario</div>
            <div class="s" :style="{ background: meta.color_accent }">acento</div>
          </div>

          <div class="muted" style="margin-top: 18px; font-size: 11px; line-height: 1.5;">
            Los cambios se guardan solos al editar. La landing page y los episodios se configuran en los planes 2 y 3.
          </div>
        </div>
      </aside>

      <div class="save-bar">
        <span v-if="saveState === 'saving'" class="save-indicator saving">◉ guardando…</span>
        <span v-else-if="saveState === 'saved'" class="save-indicator">✓ guardado</span>
        <span v-else-if="saveState === 'error'" class="save-indicator" style="background: var(--signal-hot); color: #fff;">◆ error</span>
        <span v-else-if="dirty" class="save-indicator dirty">● sin guardar</span>
        <button class="primary save-btn" :disabled="!dirty || saveState === 'saving'" @click="saveNow">
          💾 Guardar
        </button>
      </div>
    </div>
  `,
};

/* ==========================================================================
   Episodes — Kanban board (Plan 2)
   ========================================================================== */

var EPISODE_COLS = [
  { key: "idea",      label: "Ideas" },
  { key: "planning",  label: "Planificando" },
  { key: "scripted",  label: "Listo para grabar" },
  { key: "recorded",  label: "Grabado" },
  { key: "published", label: "Publicado" },
  { key: "archived",  label: "Archivado" },
];

/* Module-level shared drag state (simpler than dataTransfer). */
var _dragState = reactive({ episodeId: null });

function fmtDurationMin(minutes) {
  if (!minutes || minutes <= 0) return "—";
  const m = Math.floor(minutes);
  return `${m} min`;
}

function fmtTotalSeconds(secs) {
  if (!secs || secs <= 0) return "0:00";
  const m = Math.floor(secs / 60);
  const s = Math.floor(secs % 60);
  return `${m}:${String(s).padStart(2, "0")}`;
}

var CreateEpisodeModal = {
  props: {
    show: Boolean,
    suggestedNumber: { type: Number, default: 1 },
    templates: { type: Array, default: () => [] },
  },
  emits: ["create", "cancel"],
  setup(props, { emit }) {
    const title = ref("");
    const epNumber = ref(props.suggestedNumber || 1);
    // "" = no template; otherwise the template id as string (for v-model on <select>).
    // Default to the podcast's default template, if any.
    const templateId = ref("");
    function pickDefault() {
      const def = (props.templates || []).find(t => t.is_default);
      templateId.value = def ? String(def.id) : "";
    }
    watch(() => props.show, (s) => {
      if (s) {
        title.value = "";
        epNumber.value = props.suggestedNumber || 1;
        pickDefault();
      }
    });
    watch(() => props.templates, pickDefault);
    function submit() {
      const t = title.value.trim();
      if (!t) return;
      const n = parseInt(epNumber.value, 10);
      const payload = { title: t, episode_number: isNaN(n) || n < 1 ? null : n };
      // Always send template_id explicitly so the server doesn't fall back
      // to its own default when the user picked "Ninguna".
      payload.template_id = templateId.value === "" ? null : parseInt(templateId.value, 10);
      emit("create", payload);
    }
    return { title, epNumber, templateId, submit };
  },
  template: `
    <div v-if="show" class="modal-backdrop" @click.self="$emit('cancel')">
      <div class="modal">
        <div class="eyebrow">NUEVO EPISODIO</div>
        <h3>Arrancar un episodio</h3>
        <p class="muted" style="margin-bottom: 16px;">Por defecto se sugiere el siguiente disponible. Puedes cambiarlo si quieres empezar por otro número (ej: 3).</p>
        <div class="form-row">
          <label>Número de episodio</label>
          <input type="number" v-model.number="epNumber" min="1" style="max-width: 120px;">
        </div>
        <div class="form-row" style="margin-top: 12px;">
          <label>Título</label>
          <input type="text" v-model="title" @keyup.enter="submit" autofocus placeholder="Ej: Especial de fin de año">
        </div>
        <div v-if="templates.length" class="form-row" style="margin-top: 12px;">
          <label>Plantilla</label>
          <select v-model="templateId" style="max-width: 280px;">
            <option value="">Ninguna (en blanco)</option>
            <option v-for="t in templates" :key="t.id" :value="String(t.id)">
              {{ t.name }}{{ t.is_default ? " · default" : "" }}
            </option>
          </select>
        </div>
        <div class="row right" style="margin-top: 20px; gap: 8px;">
          <button class="ghost" @click="$emit('cancel')">Cancelar</button>
          <button class="primary" @click="submit" :disabled="!title.trim()">Crear</button>
        </div>
      </div>
    </div>
  `,
};

var EpisodesBoard = {
  components: { CreateEpisodeModal },
  props: { slug: String },
  emits: ["open-episode"],
  setup(props, { emit }) {
    const episodes = ref([]);
    const templates = ref([]);
    const error = ref("");
    const showCreate = ref(false);
    const createInStatus = ref("idea");
    const dragOverCol = ref(null);

    const _hiddenKey = `prepod_hidden_cols_${props.slug}`;
    const hiddenCols = ref(JSON.parse(localStorage.getItem(_hiddenKey) || '["archived"]'));
    function toggleCol(key) {
      const idx = hiddenCols.value.indexOf(key);
      if (idx >= 0) hiddenCols.value.splice(idx, 1);
      else hiddenCols.value.push(key);
      localStorage.setItem(_hiddenKey, JSON.stringify(hiddenCols.value));
    }

    async function load() {
      try { episodes.value = await api(`/api/podcasts/${props.slug}/episodes`); }
      catch (e) { error.value = e.message; }
    }

    async function loadTemplates() {
      try { templates.value = await api(`/api/podcasts/${props.slug}/templates`); }
      catch (_) { /* templates are optional — silent if endpoint fails */ }
    }

    const byStatus = computed(() => {
      const m = { idea: [], planning: [], scripted: [], recorded: [], published: [], archived: [] };
      for (const e of episodes.value) {
        if (m[e.status]) m[e.status].push(e);
      }
      m.published.sort((a, b) => (b.scheduled_date || "").localeCompare(a.scheduled_date || "") || b.episode_number - a.episode_number);
      return m;
    });

    function onDragStart(ep) { _dragState.episodeId = ep.id; }
    function onDragEnd() { _dragState.episodeId = null; dragOverCol.value = null; }
    function onDragOver(colKey) { dragOverCol.value = colKey; }
    function onDragLeave(colKey) { if (dragOverCol.value === colKey) dragOverCol.value = null; }
    async function onDrop(colKey) {
      const epId = _dragState.episodeId;
      dragOverCol.value = null;
      if (!epId) return;
      const ep = episodes.value.find(e => e.id === epId);
      if (!ep || ep.status === colKey) return;
      ep.status = colKey;  // optimistic
      try {
        await api(`/api/podcasts/${props.slug}/episodes/${epId}`, {
          method: "PUT", body: { status: colKey },
        });
      } catch (e) { error.value = e.message; await load(); }
    }

    const suggestedNumber = computed(() => {
      const used = episodes.value.map(e => e.episode_number || 0);
      return used.length ? Math.max(...used) + 1 : 1;
    });

    // Order in which episodes appear on the public landing.
    // Episodes with explicit landing_position go first (lowest to highest);
    // those without one fall back to creation order. Each gets a 1-indexed
    // position the UI can render as "LANDING #N".
    const landingOrder = computed(() => {
      const arr = [...episodes.value].sort((a, b) => {
        const ap = a.landing_position == null ? 9999 : a.landing_position;
        const bp = b.landing_position == null ? 9999 : b.landing_position;
        if (ap !== bp) return ap - bp;
        return (a.id || 0) - (b.id || 0);
      });
      return arr;
    });
    const landingPosOf = computed(() => {
      const map = {};
      landingOrder.value.forEach((e, i) => { map[e.id] = i + 1; });
      return map;
    });

    async function removeEpisode(ep) {
      if (!await podSwal.confirm(`¿Eliminar el episodio #${ep.episode_number} "${ep.title}"? Esta acción no se puede deshacer.`)) return;
      try {
        await api(`/api/podcasts/${props.slug}/episodes/${ep.id}`, { method: "DELETE" });
        episodes.value = episodes.value.filter(e => e.id !== ep.id);
      } catch (e) { error.value = e.message; }
    }

    async function moveLanding(ep, delta) {
      // Reorder among ALL episodes by landing_position. Episodes without
      // a position get one assigned in current visual order.
      const sorted = [...episodes.value].sort((a, b) => {
        const ap = a.landing_position == null ? 9999 : a.landing_position;
        const bp = b.landing_position == null ? 9999 : b.landing_position;
        if (ap !== bp) return ap - bp;
        return (a.id || 0) - (b.id || 0);
      });
      const idx = sorted.findIndex(e => e.id === ep.id);
      if (idx < 0) return;
      const newIdx = idx + delta;
      if (newIdx < 0 || newIdx >= sorted.length) return;
      [sorted[idx], sorted[newIdx]] = [sorted[newIdx], sorted[idx]];
      // Persist new positions
      try {
        await Promise.all(sorted.map((e, i) =>
          api(`/api/podcasts/${props.slug}/episodes/${e.id}`, {
            method: "PUT", body: { landing_position: i },
          })
        ));
        // Reflect locally
        sorted.forEach((e, i) => { e.landing_position = i; });
      } catch (e) { error.value = e.message; await load(); }
    }

    function askCreate(status) {
      createInStatus.value = status;
      // Refresh templates each time the modal opens so a newly added one
      // shows up without forcing a board reload.
      loadTemplates();
      showCreate.value = true;
    }
    async function doCreate(payload) {
      try {
        const body = { title: payload.title, status: createInStatus.value };
        if (payload.episode_number) body.episode_number = payload.episode_number;
        if (payload.template_id !== undefined) body.template_id = payload.template_id;
        const created = await api(`/api/podcasts/${props.slug}/episodes`, {
          method: "POST", body,
        });
        episodes.value.push(created);
        showCreate.value = false;
        emit("open-episode", created.id);
      } catch (e) { error.value = e.message; }
    }

    onMounted(() => { load(); loadTemplates(); });
    return {
      columns: EPISODE_COLS, episodes, templates, byStatus, error, dragOverCol,
      showCreate, createInStatus, suggestedNumber,
      landingPosOf, hiddenCols, toggleCol,
      onDragStart, onDragEnd, onDragOver, onDragLeave, onDrop, askCreate, doCreate,
      removeEpisode, moveLanding,
      fmtDate, fmtDurationMin,
    };
  },
  template: `
    <div class="kanban">
      <div
        v-for="col in columns"
        :key="col.key"
        class="kanban-col"
        :class="{ 'drag-over': dragOverCol === col.key, collapsed: hiddenCols.includes(col.key) }"
        :data-status="col.key"
        @click="hiddenCols.includes(col.key) && toggleCol(col.key)"
        @dragover.prevent="onDragOver(col.key)"
        @dragleave="onDragLeave(col.key)"
        @drop.prevent="onDrop(col.key)"
      >
        <div class="kanban-col-head">
          <span class="dot"></span>
          <span class="name">{{ col.label }}</span>
          <span class="count">{{ (byStatus[col.key] || []).length }}</span>
          <button v-if="col.key !== 'archived'" class="add-btn-head" @click="askCreate(col.key)" title="Nuevo episodio">＋</button>
          <button class="toggle-col" @click.stop="toggleCol(col.key)" :title="hiddenCols.includes(col.key) ? 'Mostrar columna' : 'Ocultar columna'">
            {{ hiddenCols.includes(col.key) ? '◉' : '◎' }}
          </button>
        </div>
        <div class="kanban-col-body" v-show="!hiddenCols.includes(col.key)">
          <div
            v-for="ep in byStatus[col.key]"
            :key="ep.id"
            class="ep-card"
            :class="{ dragging: false }"
            draggable="true"
            @dragstart="onDragStart(ep)"
            @dragend="onDragEnd"
            @click="$emit('open-episode', ep.id)"
          >
            <button class="ep-card-del" @click.stop="removeEpisode(ep)" title="Eliminar episodio">✕</button>
            <div class="ep-num">
              EP · #{{ ep.episode_number }}
              <span class="landing-pos" :title="'Posición en el landing: ' + landingPosOf[ep.id]">
                · LANDING #{{ landingPosOf[ep.id] }}
              </span>
            </div>
            <div class="ep-title">{{ ep.title }}</div>
            <div class="ep-meta">
              <span v-if="ep.scheduled_date">📅 {{ ep.scheduled_date }}</span>
              <span v-if="ep.duration_estimate">⏱ {{ fmtDurationMin(ep.duration_estimate) }}</span>
            </div>
            <div class="ep-reorder">
              <button class="icon ghost" @click.stop="moveLanding(ep, -1)"
                      :disabled="landingPosOf[ep.id] === 1"
                      title="Subir en landing">▲</button>
              <button class="icon ghost" @click.stop="moveLanding(ep,  1)"
                      :disabled="landingPosOf[ep.id] === episodes.length"
                      title="Bajar en landing">▼</button>
            </div>
          </div>
        </div>
      </div>
      <CreateEpisodeModal :show="showCreate" :suggested-number="suggestedNumber" :templates="templates" @create="doCreate" @cancel="showCreate = false" />
    </div>
  `,
};

/* ==========================================================================
   Ideas panel (inside EpisodeDetail)
   ========================================================================== */

var IdeasPanel = {
  props: { slug: String, episodeId: Number },
  setup(props) {
    const ideas = ref([]);
    const newIdea = ref("");
    const error = ref("");

    async function load() {
      try { ideas.value = await api(`/api/podcasts/${props.slug}/episodes/${props.episodeId}/ideas`); }
      catch (e) { error.value = e.message; }
    }

    async function add() {
      const text = newIdea.value.trim();
      if (!text) return;
      try {
        const created = await api(
          `/api/podcasts/${props.slug}/episodes/${props.episodeId}/ideas`,
          { method: "POST", body: { content: text } },
        );
        ideas.value.push(created);
        newIdea.value = "";
      } catch (e) { error.value = e.message; }
    }

    async function toggleVote(idea) {
      try {
        const method = idea.voted_by_me ? "DELETE" : "POST";
        const r = await api(`/api/podcasts/${props.slug}/ideas/${idea.id}/vote`, { method });
        idea.votes = r.votes;
        idea.voted_by_me = r.voted_by_me;
      } catch (e) { error.value = e.message; }
    }

    async function setStatus(idea, status) {
      try {
        const r = await api(`/api/podcasts/${props.slug}/ideas/${idea.id}`, {
          method: "PUT", body: { status },
        });
        Object.assign(idea, r);
      } catch (e) { error.value = e.message; }
    }

    async function remove(idea) {
      if (!await podSwal.confirm("¿Eliminar idea?")) return;
      try {
        await api(`/api/podcasts/${props.slug}/ideas/${idea.id}`, { method: "DELETE" });
        ideas.value = ideas.value.filter(i => i.id !== idea.id);
      } catch (e) { error.value = e.message; }
    }

    watch(() => props.episodeId, load, { immediate: true });
    return { ideas, newIdea, error, add, toggleVote, setStatus, remove };
  },
  template: `
    <div>
      <div class="ideas-head">
        <span class="label">Ideas</span>
        <span class="count">{{ ideas.length }}</span>
      </div>

      <div class="idea-form">
        <textarea v-model="newIdea" maxlength="500" placeholder="Proponer una idea para este episodio..." @keydown.ctrl.enter="add" @keydown.meta.enter="add"></textarea>
        <div class="idea-form-row">
          <span class="counter">{{ newIdea.length }}/500 · Ctrl+Enter</span>
          <button class="primary" @click="add" :disabled="!newIdea.trim()" style="padding: 6px 12px; font-size: 12px;">＋ Agregar</button>
        </div>
      </div>

      <div v-if="error" class="error">{{ error }}</div>

      <div v-if="ideas.length === 0" class="empty-pill" style="margin-top: 12px;">Sin ideas todavía</div>

      <div v-else class="idea-list">
        <div v-for="idea in ideas" :key="idea.id" class="idea-card" :class="idea.status">
          <div class="content">{{ idea.content }}</div>
          <div class="row-bottom">
            <span class="author">{{ idea.author }}</span>
            <span class="status-pill" :class="idea.status">{{ idea.status }}</span>
            <button class="vote-btn" :class="{ voted: idea.voted_by_me }" @click="toggleVote(idea)">
              ▲ {{ idea.votes }}
            </button>
            <span class="idea-actions">
              <button v-if="idea.status !== 'accepted'" class="icon ghost" title="Aceptar" @click="setStatus(idea, 'accepted')">✓</button>
              <button v-if="idea.status !== 'rejected'" class="icon ghost" title="Rechazar" @click="setStatus(idea, 'rejected')">✕</button>
              <button v-if="idea.status !== 'proposed'" class="icon ghost" title="Volver a propuesta" @click="setStatus(idea, 'proposed')">↺</button>
              <button class="icon danger" title="Eliminar" @click="remove(idea)">🗑</button>
            </span>
          </div>
        </div>
      </div>
    </div>
  `,
};

/* ==========================================================================
   Script editor (inside EpisodeDetail)
   ========================================================================== */

var ScriptEditor = {
  props: { slug: String, episodeId: Number },
  emits: ["total-seconds-changed"],
  setup(props, { emit }) {
    const sections = ref([]);
    const error = ref("");

    async function load() {
      try { sections.value = await api(`/api/podcasts/${props.slug}/episodes/${props.episodeId}/script`); }
      catch (e) { error.value = e.message; }
    }

    async function addSection() {
      try {
        const created = await api(
          `/api/podcasts/${props.slug}/episodes/${props.episodeId}/script`,
          { method: "POST", body: { speaker: "Host", content: "" } },
        );
        sections.value.push(created);
      } catch (e) { error.value = e.message; }
    }

    async function removeSection(sec) {
      if (!await podSwal.confirm("¿Eliminar sección?")) return;
      try {
        await api(`/api/podcasts/${props.slug}/script-sections/${sec.id}`, { method: "DELETE" });
        await load();
      } catch (e) { error.value = e.message; }
    }

    async function move(sec, delta) {
      const newPos = sec.position + delta;
      if (newPos < 0 || newPos >= sections.value.length) return;
      try {
        await api(`/api/podcasts/${props.slug}/script-sections/${sec.id}`, {
          method: "PUT", body: { position: newPos },
        });
        await load();
      } catch (e) { error.value = e.message; }
    }

    /* Per-section debounced save, keyed by sec.id. */
    const _savers = new Map();
    function saveSection(sec) {
      let fn = _savers.get(sec.id);
      if (!fn) {
        fn = debounce(async () => {
          try {
            await api(`/api/podcasts/${props.slug}/script-sections/${sec.id}`, {
              method: "PUT",
              body: {
                speaker: sec.speaker,
                content: sec.content,
                estimated_duration: sec.estimated_duration,
                notes: sec.notes,
              },
            });
          } catch (e) { error.value = e.message; }
        }, 500);
        _savers.set(sec.id, fn);
      }
      fn();
    }

    const totalSeconds = computed(() =>
      sections.value.reduce((acc, s) => acc + (s.estimated_duration || 0), 0)
    );
    watch(totalSeconds, (v) => emit("total-seconds-changed", v));

    watch(() => props.episodeId, load, { immediate: true });
    return { sections, error, addSection, removeSection, move, saveSection, totalSeconds, fmtTotalSeconds };
  },
  template: `
    <div>
      <div class="script-head">
        <div class="eyebrow">GUIÓN</div>
        <div class="spacer"></div>
        <span class="total mono">TOTAL {{ fmtTotalSeconds(totalSeconds) }}</span>
        <button @click="addSection">＋ Sección</button>
      </div>

      <div v-if="error" class="error">{{ error }}</div>

      <div v-if="sections.length === 0" class="empty-pill">Sin secciones. Empezá agregando la intro.</div>

      <div v-else class="script-sections">
        <div v-for="(sec, idx) in sections" :key="sec.id" class="script-sec">
          <div class="sec-head">
            <span class="pos-tag">#{{ idx + 1 }}</span>
            <input type="text" class="speaker-input" v-model="sec.speaker" placeholder="Speaker" @input="saveSection(sec)">
            <div class="spacer"></div>
            <span class="sec-actions">
              <button class="icon ghost" @click="move(sec, -1)" :disabled="idx === 0" title="Mover arriba">▲</button>
              <button class="icon ghost" @click="move(sec, 1)" :disabled="idx === sections.length - 1" title="Mover abajo">▼</button>
              <button class="icon danger" @click="removeSection(sec)" title="Eliminar">✕</button>
            </span>
          </div>
          <textarea v-model="sec.content" @input="saveSection(sec)" placeholder="Texto a leer / decir en esta sección..."></textarea>
          <div class="notes-row">
            <input type="text" v-model="sec.notes" @input="saveSection(sec)" placeholder="Notas internas (timings, direcciones)...">
            <input type="number" class="dur-input" v-model.number="sec.estimated_duration" @input="saveSection(sec)" min="0" step="1" placeholder="seg">
          </div>
        </div>
      </div>
    </div>
  `,
};

/* ==========================================================================
   Episode detail (Plan 2) — dependencies defined first
   ========================================================================== */

var IntegrationSettingsModal = {
  emits: ["close"],
  setup() {
    const cfg = reactive({ postpod_url: "", prodpod_url: "", cookie_domain: null });
    const loaded = ref(false);
    const busy = ref(false);
    const pinging = ref(false);
    const error = ref("");
    const pingResult = ref(null);

    async function load() {
      try { Object.assign(cfg, await api("/api/integrations/config")); }
      catch (e) { error.value = e.message; }
      finally { loaded.value = true; }
    }
    async function save() {
      busy.value = true; error.value = "";
      try {
        const r = await api("/api/integrations/config", {
          method: "PUT",
          body: { postpod_url: cfg.postpod_url, prodpod_url: cfg.prodpod_url },
        });
        Object.assign(cfg, r);
      } catch (e) { error.value = e.message; }
      finally { busy.value = false; }
    }
    async function ping() {
      pinging.value = true; error.value = "";
      await save();
      try { pingResult.value = await api("/api/integrations/ping"); }
      catch (e) { error.value = e.message; }
      finally { pinging.value = false; }
    }

    function statusFor(name) {
      const r = pingResult.value?.[name];
      if (!r) return { kind: "idle", label: "sin probar" };
      if (!r.configured) return { kind: "idle", label: "sin URL" };
      if (r.secret_mismatch) return { kind: "err", label: "secret no coincide" };
      if (r.reachable) return { kind: "ok", label: "alcanzable" };
      return { kind: "warn", label: "sin conexión" };
    }

    onMounted(load);
    return { cfg, loaded, busy, pinging, error, pingResult, save, ping, statusFor };
  },
  template: `
    <div class="modal-backdrop" @click.self="$emit('close')">
      <div class="modal" style="width: 560px;">
        <div class="eyebrow">INTEGRACIONES</div>
        <h3>Conexiones con las otras apps</h3>
        <p class="muted" style="margin: 4px 0 18px;">URLs donde corren postPod y prodPod. Se usan para enviar episodios a post-producción y consultar el estado.</p>

        <div v-if="error" class="error">{{ error }}</div>

        <div class="sibling-card">
          <span class="name">postPod</span>
          <input type="text" v-model="cfg.postpod_url" placeholder="http://127.0.0.1:5000">
          <span class="status-chip" :class="statusFor('postpod').kind">{{ statusFor('postpod').label }}</span>
        </div>
        <div class="sibling-card">
          <span class="name">prodPod</span>
          <input type="text" v-model="cfg.prodpod_url" placeholder="http://127.0.0.1:5002">
          <span class="status-chip" :class="statusFor('prodpod').kind">{{ statusFor('prodpod').label }}</span>
        </div>

        <div class="muted" style="margin-top: 14px; font-size: 11px; line-height: 1.5;">
          Ambas apps usan la misma cookie de sesión (SSO). Si te logueás en una, las otras te reconocen automáticamente en el mismo host.
        </div>

        <div class="row right" style="margin-top: 18px; gap: 8px;">
          <button class="ghost" @click="$emit('close')">Cerrar</button>
          <button @click="ping" :disabled="pinging">{{ pinging ? "Probando…" : "Guardar y probar" }}</button>
        </div>
      </div>
    </div>
  `,
};

var PRODUCTION_STATUS_LABEL = {
  recording: { label: "● grabando ahora", cls: "live" },
  recorded:  { label: "✓ grabación lista", cls: "done" },
  exported:  { label: "↗ enviado a postPod", cls: "exported" },
};

var EpisodeIntegrationBar = {
  props: { slug: String, episodeId: Number },
  setup(props) {
    const status = ref(null);
    const ep = ref(null);
    const error = ref("");
    const busyPost = ref(false);
    const busyProd = ref(false);
    let poller = null;

    async function loadStatus() {
      try { status.value = await api(`/api/podcasts/${props.slug}/episodes/${props.episodeId}/integration-status`); }
      catch (e) { error.value = e.message; }
    }
    async function loadEpisode() {
      try { ep.value = await api(`/api/podcasts/${props.slug}/episodes/${props.episodeId}`); }
      catch (e) { /* keep prior value */ }
    }
    async function load() { await Promise.all([loadStatus(), loadEpisode()]); }

    function startPolling() {
      if (poller) return;
      poller = setInterval(loadEpisode, 8000);
    }
    function stopPolling() {
      if (poller) { clearInterval(poller); poller = null; }
    }

    async function sendToPostpod() {
      busyPost.value = true; error.value = "";
      try {
        const r = await api(`/api/podcasts/${props.slug}/episodes/${props.episodeId}/send-to-postpod`, { method: "POST" });
        podSwal.success(r.created ? `Proyecto creado en postPod: ${r.postpod_slug}` : `Ya existía — slug: ${r.postpod_slug}`);
        await load();
      } catch (e) { error.value = e.message; podSwal.error(e.message); }
      finally { busyPost.value = false; }
    }

    async function sendToProdpod() {
      busyProd.value = true; error.value = "";
      try {
        const r = await api(`/api/podcasts/${props.slug}/episodes/${props.episodeId}/send-to-prodpod`, { method: "POST" });
        podSwal.success(r.created ? `Sesión creada en prodPod #${r.prodpod_session_id}` : `Ya existía — sesión #${r.prodpod_session_id}`);
        await load();
      } catch (e) { error.value = e.message; podSwal.error(e.message); }
      finally { busyProd.value = false; }
    }

    function productionChip() {
      const s = ep.value?.production_status;
      if (!s) return null;
      return PRODUCTION_STATUS_LABEL[s] || { label: s, cls: "done" };
    }

    function postpodLinkFromMeta() {
      const m = ep.value?.production_meta;
      return m?.postpod_url || null;
    }

    watch(() => props.episodeId, () => { stopPolling(); load(); startPolling(); }, { immediate: true });
    onBeforeUnmount(stopPolling);

    return {
      status, ep, error, busyPost, busyProd,
      sendToPostpod, sendToProdpod, productionChip, postpodLinkFromMeta,
    };
  },
  template: `
    <div>
      <div v-if="error" class="error">{{ error }}</div>
      <div class="integration-panel">
        <span class="eyebrow" style="font-family: var(--font-mono); font-size: 10px; letter-spacing: 0.22em; text-transform: uppercase; color: var(--signal); font-weight: 600;">FLUJO</span>

        <template v-if="productionChip()">
          <span class="pill prod-chip" :class="productionChip().cls">{{ productionChip().label }}</span>
          <a v-if="postpodLinkFromMeta()" class="target-link" :href="postpodLinkFromMeta()" target="_blank" rel="noopener">postPod ↗</a>
        </template>

        <template v-if="status && status.prodpod && status.prodpod.linked">
          <span class="pill linked" style="background: rgba(255,59,59,0.14); color: #ff3b3b; border-color: #7a2224;">◉ En prodPod</span>
          <a class="target-link" :href="status.prodpod.url" target="_blank" rel="noopener">abrir ↗</a>
        </template>
        <template v-else-if="status && status.prodpod && status.prodpod.unreachable">
          <span class="pill unreachable">prodPod sin conexión</span>
        </template>
        <template v-else>
          <button @click="sendToProdpod" :disabled="busyProd" style="background: rgba(255,59,59,0.1); color: #ff3b3b; border-color: #7a2224;">
            {{ busyProd ? "Enviando…" : "◉ Enviar a prodPod" }}
          </button>
        </template>

        <template v-if="status && status.postpod && status.postpod.linked">
          <span class="pill linked">↗ En postPod</span>
          <a class="target-link" :href="status.postpod.url + '/#/projects/' + status.postpod.project.slug" target="_blank" rel="noopener">abrir ↗</a>
        </template>
        <template v-else-if="status && status.postpod && status.postpod.unreachable">
          <span class="pill unreachable">postPod sin conexión</span>
        </template>
        <template v-else>
          <button class="primary" @click="sendToPostpod" :disabled="busyPost">
            {{ busyPost ? "Enviando…" : "↗ Enviar a postPod" }}
          </button>
        </template>

        <div class="spacer"></div>
      </div>
    </div>
  `,
};

/* ==========================================================================
   Episode distribution links (used inside EpisodeDetail)
   ========================================================================== */

var LINK_PLATFORMS = [
  { value: "youtube",         label: "YouTube" },
  { value: "spotify",         label: "Spotify" },
  { value: "apple_podcasts",  label: "Apple Podcasts" },
  { value: "google_podcasts", label: "Google Podcasts" },
  { value: "podbean",         label: "Podbean" },
  { value: "overcast",        label: "Overcast" },
  { value: "castbox",         label: "Castbox" },
  { value: "iheart",          label: "iHeart" },
  { value: "website",         label: "Sitio propio" },
];

var EpisodeLinks = {
  props: { slug: String, episodeId: Number },
  setup(props) {
    const links = ref([]);
    const error = ref("");
    const newPlatform = ref("youtube");
    const newUrl = ref("");

    async function load() {
      try { links.value = await api(`/api/podcasts/${props.slug}/episodes/${props.episodeId}/links`); }
      catch (e) { error.value = e.message; }
    }

    async function add() {
      const url = newUrl.value.trim();
      if (!url) return;
      try {
        await api(`/api/podcasts/${props.slug}/episodes/${props.episodeId}/links`, {
          method: "POST",
          body: { platform: newPlatform.value, url },
        });
        newUrl.value = "";
        await load();
      } catch (e) { error.value = e.message; }
    }

    async function remove(platform) {
      try {
        await api(`/api/podcasts/${props.slug}/episodes/${props.episodeId}/links/${platform}`, { method: "DELETE" });
        await load();
      } catch (e) { error.value = e.message; }
    }

    function labelFor(platform) {
      const p = LINK_PLATFORMS.find(x => x.value === platform);
      return p ? p.label : platform.replace(/_/g, " ");
    }

    watch(() => props.episodeId, load, { immediate: true });
    return { links, error, newPlatform, newUrl, platforms: LINK_PLATFORMS, add, remove, labelFor };
  },
  template: `
    <div>
      <div class="section-head">
        <div class="eyebrow">ENLACES DE DISTRIBUCIÓN</div>
        <h3>Dónde está publicado este episodio</h3>
      </div>

      <div v-if="error" class="error">{{ error }}</div>

      <div v-if="links.length === 0" class="empty-pill">Sin enlaces. Agregá el primero abajo.</div>
      <div v-else class="links-list">
        <div v-for="l in links" :key="l.platform" class="link-row">
          <span class="plat">{{ labelFor(l.platform) }}</span>
          <a class="url" :href="l.url" target="_blank" rel="noopener" :title="l.url">{{ l.url }}</a>
          <button class="icon danger" @click="remove(l.platform)" title="Quitar">✕</button>
        </div>
      </div>

      <div class="link-add">
        <select v-model="newPlatform">
          <option v-for="p in platforms" :key="p.value" :value="p.value">{{ p.label }}</option>
        </select>
        <input type="text" v-model="newUrl" placeholder="https://..." @keyup.enter="add">
        <button class="primary" @click="add" :disabled="!newUrl.trim()">＋ Agregar</button>
      </div>
    </div>
  `,
};

/* ==========================================================================
   Rundown editor (estructura del episodio: bloques planificados)
   ========================================================================== */

var BLOCK_KINDS = [
  { value: "intro",     label: "Intro" },
  { value: "segment",   label: "Segmento" },
  { value: "interview", label: "Entrevista" },
  { value: "sponsor",   label: "Sponsor" },
  { value: "break",     label: "Pausa" },
  { value: "outro",     label: "Outro" },
  { value: "custom",    label: "Otro" },
];

function fmtMin(m) {
  if (!m && m !== 0) return "—";
  const min = Math.floor(m);
  const sec = Math.round((m - min) * 60);
  return sec ? `${min}m${String(sec).padStart(2, "0")}s` : `${min}min`;
}

var RundownEditor = {
  props: { slug: String, episodeId: Number },
  setup(props) {
    const blocks = ref([]);
    const sponsors = ref([]);
    const error = ref("");
    const dragging = ref(null);

    async function load() {
      try { blocks.value = await api(`/api/podcasts/${props.slug}/episodes/${props.episodeId}/blocks`); }
      catch (e) { error.value = e.message; }
    }

    async function loadSponsors() {
      try { sponsors.value = await api(`/api/podcasts/${props.slug}/sponsors`); }
      catch (_) { /* sponsors are optional */ }
    }

    async function add(kind) {
      kind = kind || "segment";
      var title = kind === "sponsor" ? "" : "Nuevo bloque";
      try {
        const created = await api(`/api/podcasts/${props.slug}/episodes/${props.episodeId}/blocks`, {
          method: "POST",
          body: { kind: kind, title: title },
        });
        if (kind === "sponsor") {
          var cum = 0;
          blocks.value.forEach(function (b) {
            if (b.duration_estimate) cum += parseFloat(b.duration_estimate) * 60;
          });
          created.planned_offset_seconds = Math.round(cum);
          if (sponsors.value.length === 1) {
            created.sponsor_id = sponsors.value[0].id;
            created.title = sponsors.value[0].name;
          }
          save(created);
        }
        blocks.value.push(created);
      } catch (e) { error.value = e.message; }
    }

    async function remove(b) {
      if (!await podSwal.confirm(`¿Eliminar "${b.title || b.kind}"?`)) return;
      try {
        await api(`/api/podcasts/${props.slug}/blocks/${b.id}`, { method: "DELETE" });
        blocks.value = blocks.value.filter(x => x.id !== b.id);
      } catch (e) { error.value = e.message; }
    }

    const _savers = new Map();
    function save(b) {
      let fn = _savers.get(b.id);
      if (!fn) {
        fn = debounce(async () => {
          try {
            await api(`/api/podcasts/${props.slug}/blocks/${b.id}`, {
              method: "PUT",
              body: { kind: b.kind, title: b.title, duration_estimate: b.duration_estimate, notes: b.notes, planned_offset_seconds: b.planned_offset_seconds },
            });
          } catch (e) { error.value = e.message; }
        }, 500);
        _savers.set(b.id, fn);
      }
      fn();
    }

    function fmtOffset(sec) {
      if (sec == null) return "";
      var m = Math.floor(sec / 60);
      var s = sec % 60;
      return m + ":" + String(s).padStart(2, "0");
    }

    function parseOffset(str) {
      str = (str || "").trim();
      if (!str) return null;
      var parts = str.split(":");
      if (parts.length === 2) return parseInt(parts[0], 10) * 60 + parseInt(parts[1], 10);
      return parseInt(str, 10) * 60;
    }

    function sponsorCopy(b) {
      if (!b.sponsor_id) return "";
      var sp = sponsors.value.find(function (s) { return s.id === b.sponsor_id; });
      return sp ? sp.copy : "";
    }

    function sponsorLogo(b) {
      if (!b.sponsor_id) return "";
      var sp = sponsors.value.find(function (s) { return s.id === b.sponsor_id; });
      return sp ? sp.logo_url : "";
    }

    function onDragStart(b)   { dragging.value = b.id; }
    function onDragEnd()      { dragging.value = null; }
    function onDragOver(ev)   { ev.preventDefault(); }
    function moveBlock(b, dir) {
      const idx = blocks.value.findIndex(x => x.id === b.id);
      const target = blocks.value[idx + dir];
      if (!target) return;
      dragging.value = b.id;
      onDrop(target);
    }

    async function onDrop(target) {
      const fromId = dragging.value;
      dragging.value = null;
      if (!fromId || fromId === target.id) return;
      const ids = blocks.value.map(b => b.id);
      const fromIdx = ids.indexOf(fromId);
      const toIdx = ids.indexOf(target.id);
      if (fromIdx < 0 || toIdx < 0) return;
      ids.splice(toIdx, 0, ids.splice(fromIdx, 1)[0]);
      // Optimistic local reorder
      blocks.value = ids.map(id => blocks.value.find(b => b.id === id));
      try {
        const updated = await api(`/api/podcasts/${props.slug}/episodes/${props.episodeId}/blocks/reorder`, {
          method: "POST", body: { order: ids },
        });
        blocks.value = updated;
      } catch (e) { error.value = e.message; await load(); }
    }

    const totalMin = computed(() =>
      blocks.value.reduce((acc, b) => acc + (parseFloat(b.duration_estimate) || 0), 0)
    );

    function kindLabel(k) {
      return (BLOCK_KINDS.find(x => x.value === k) || { label: k }).label;
    }

    async function setSponsor(b, sponsorIdRaw) {
      const sponsorId = sponsorIdRaw === "" || sponsorIdRaw == null ? null : parseInt(sponsorIdRaw, 10);
      try {
        await api(`/api/podcasts/${props.slug}/blocks/${b.id}/sponsor`, {
          method: "PUT", body: { sponsor_id: sponsorId },
        });
        b.sponsor_id = sponsorId;
        // Helpful default: if the block has no title yet, prefill with the
        // sponsor's name when one is selected. The user can still rename.
        if (sponsorId && !(b.title || "").trim()) {
          const sp = sponsors.value.find(s => s.id === sponsorId);
          if (sp) {
            b.title = sp.name;
            save(b);
          }
        }
      } catch (e) { error.value = e.message; }
    }

    watch(() => props.episodeId, () => { load(); loadSponsors(); }, { immediate: true });
    return { moveBlock, 
      blocks, sponsors, error, dragging, kinds: BLOCK_KINDS,
      add, remove, save, onDragStart, onDragEnd, onDragOver, onDrop,
      totalMin, fmtMin, kindLabel, setSponsor, fmtOffset, parseOffset, sponsorCopy, sponsorLogo,
    };
  },
  template: `
    <div>
      <div class="section-head">
        <div class="eyebrow">RUNDOWN</div>
        <h3>Estructura del episodio</h3>
        <div class="spacer"></div>
        <span class="total mono">TOTAL {{ fmtMin(totalMin) }}</span>
        <button @click="add('sponsor')" style="background: rgba(244,199,112,0.12); border-color: rgba(244,199,112,0.3); color: #f4c770;">＋ Sponsor</button>
        <button @click="add()">＋ Bloque</button>
      </div>

      <div v-if="error" class="error">{{ error }}</div>

      <div v-if="blocks.length === 0" class="empty-pill">Sin bloques. Arma la estructura: intro → segmentos → outro.</div>

      <div v-else class="rundown-list">
        <template v-for="(b, idx) in blocks" :key="b.id">
          <div class="rundown-block" :class="['kind-' + b.kind, { dragging: dragging === b.id }]"
               draggable="true"
               @dragstart="onDragStart(b)" @dragend="onDragEnd"
               @dragover="onDragOver" @drop="onDrop(b)">
            <span class="rb-handle d-only" title="Arrastra para reordenar">⋮⋮</span>
            <span class="rb-move m-only"><button class="icon" @click="moveBlock(b, -1)" :disabled="idx === 0" aria-label="Subir">▲</button><button class="icon" @click="moveBlock(b, 1)" :disabled="idx === blocks.length - 1" aria-label="Bajar">▼</button></span>
            <span class="rb-pos">#{{ idx + 1 }}</span>
            <select v-model="b.kind" @change="save(b)" class="rb-kind">
              <option v-for="k in kinds" :key="k.value" :value="k.value">{{ k.label }}</option>
            </select>
            <input type="text" v-model="b.title" @input="save(b)" placeholder="Título del bloque" class="rb-title">
            <input type="number" v-model.number="b.duration_estimate" @input="save(b)" min="0" step="0.5" placeholder="min" class="rb-dur">
            <input type="text" v-model="b.notes" @input="save(b)" placeholder="Notas (opcional)" class="rb-notes">
            <button class="icon danger" @click="remove(b)" title="Eliminar">✕</button>
          </div>
          <div v-if="b.kind === 'sponsor'" class="rundown-sponsor-link"
               style="margin: -2px 0 6px 36px; padding: 10px 12px; display: flex; flex-direction: column; gap: 8px; font-size: 12px; background: rgba(244,199,112,0.06); border-left: 3px solid rgba(244,199,112,0.5); border-radius: 0 6px 6px 0;">
            <div style="display: flex; align-items: center; gap: 8px;">
              <img v-if="sponsorLogo(b)" :src="sponsorLogo(b)" style="width: 28px; height: 28px; object-fit: contain; border-radius: 4px; background: rgba(255,255,255,0.08);">
              <span v-else style="width: 28px; height: 28px; display: flex; align-items: center; justify-content: center; border-radius: 4px; background: rgba(244,199,112,0.12); color: #f4c770; font-size: 14px; flex-shrink: 0;">📢</span>
              <select :value="b.sponsor_id || ''" @change="setSponsor(b, $event.target.value)" style="flex: 1; max-width: 280px; font-size: 13px;">
                <option value="">— Elige un sponsor —</option>
                <option v-for="s in sponsors" :key="s.id" :value="s.id">
                  {{ s.name }}{{ s.is_active ? '' : ' (pausado)' }}
                </option>
              </select>
              <span v-if="!sponsors.length" class="muted" style="font-size: 11px;">Crea sponsors en la pestaña "Sponsors".</span>
              <label style="display: flex; align-items: center; gap: 4px; white-space: nowrap; font-size: 11px; color: #aaa;" title="En qué momento del episodio aparece en prodPod (m:ss)">
                ⏱ Aparece en
                <input type="text" :value="fmtOffset(b.planned_offset_seconds)" @change="b.planned_offset_seconds = parseOffset($event.target.value); save(b)" placeholder="m:ss" style="width: 54px; font-size: 12px; padding: 2px 6px; text-align: center;">
              </label>
            </div>
            <div v-if="!b.sponsor_id && sponsors.length" style="font-size: 11px; color: rgba(244,199,112,0.7); padding: 4px 0 0 36px;">
              ↑ Elige el sponsor que aparecerá en el teleprompter de prodPod en este momento del episodio.
            </div>
            <div v-if="b.sponsor_id && sponsorCopy(b)" style="font-size: 12px; color: #bbb; white-space: pre-wrap; padding: 8px 10px; background: rgba(255,255,255,0.04); border-radius: 4px; line-height: 1.45;">
              <span class="eyebrow" style="display: block; margin-bottom: 3px; color: rgba(244,199,112,0.7);">TELEPROMPTER — esto verás en prodPod</span>
              {{ sponsorCopy(b) }}
            </div>
          </div>
        </template>
      </div>
    </div>
  `,
};

/* ==========================================================================
   Guests panel (roster + invites returned by prodPod)
   ========================================================================== */

var GUEST_ROLES = [
  { value: "host", label: "Host" },
  { value: "co-host", label: "Co-host" },
  { value: "guest", label: "Invitado" },
];

var RSVP_STATUSES = [
  { value: "pending", label: "Pendiente" },
  { value: "yes", label: "Confirma" },
  { value: "no", label: "No puede" },
  { value: "maybe", label: "Tal vez" },
];

var RSVP_LABELS = { pending: "Pendiente", yes: "Confirmado", no: "No puede", maybe: "Tal vez" };
var RSVP_COLORS = { pending: "#888", yes: "#2a7", no: "#c44", maybe: "#c90" };

var GuestsPanel = {
  props: { slug: String, episodeId: Number },
  setup(props) {
    const guests = ref([]);
    const error = ref("");
    const newName = ref("");
    const newEmail = ref("");
    const newRole = ref("guest");

    async function load() {
      try { guests.value = await api(`/api/podcasts/${props.slug}/episodes/${props.episodeId}/guests`); }
      catch (e) { error.value = e.message; }
    }

    async function add() {
      const name = newName.value.trim();
      if (!name) return;
      try {
        const created = await api(`/api/podcasts/${props.slug}/episodes/${props.episodeId}/guests`, {
          method: "POST",
          body: { name, email: newEmail.value.trim(), role: newRole.value },
        });
        guests.value.push(created);
        newName.value = "";
        newEmail.value = "";
        newRole.value = "guest";
      } catch (e) { error.value = e.message; }
    }

    async function remove(g) {
      if (!await podSwal.confirm(`¿Eliminar a "${g.name}" del roster?`)) return;
      try {
        await api(`/api/podcasts/${props.slug}/guests/${g.id}`, { method: "DELETE" });
        guests.value = guests.value.filter(x => x.id !== g.id);
      } catch (e) { error.value = e.message; }
    }

    const _savers = new Map();
    function saveGuest(g) {
      let fn = _savers.get(g.id);
      if (!fn) {
        fn = debounce(async () => {
          try {
            const r = await api(`/api/podcasts/${props.slug}/guests/${g.id}`, {
              method: "PUT",
              body: {
                name: g.name, email: g.email, role: g.role,
                bio: g.bio, rsvp_status: g.rsvp_status,
                social_instagram: g.social_instagram,
                social_twitter: g.social_twitter,
                social_youtube: g.social_youtube,
                social_tiktok: g.social_tiktok,
              },
            });
            Object.assign(g, r);
          } catch (e) { error.value = e.message; }
        }, 500);
        _savers.set(g.id, fn);
      }
      fn();
    }

    async function copyInvite(g) {
      if (!g.invite_url) return;
      try {
        await navigator.clipboard.writeText(g.invite_url);
        g._copied = true;
        setTimeout(() => { g._copied = false; }, 1400);
      } catch (e) { error.value = "no pude copiar al portapapeles"; }
    }

    const canShare = typeof navigator !== "undefined" && !!navigator.share;
    function shareRsvp(g) {
      const url = g._rsvp_full_url || (window.location.origin + (g.rsvp_url || ""));
      navigator.share({ title: "Invitación", text: `Hola ${g.name}, te invitamos al podcast. Confirma aquí:`, url }).catch(() => {});
    }

    async function copyRsvp(g) {
      const url = g._rsvp_full_url || (window.location.origin + (g.rsvp_url || ""));
      if (!url) return;
      try {
        await navigator.clipboard.writeText(url);
        g._rsvp_copied = true;
        setTimeout(() => { g._rsvp_copied = false; }, 1400);
      } catch (e) { error.value = "no pude copiar al portapapeles"; }
    }

    async function sendRsvp(g) {
      if (!g.email || !g.email.trim()) {
        error.value = "Agrega un email para invitar";
        return;
      }
      g._rsvp_sending = true;
      g._rsvp_msg = "";
      try {
        const r = await api(`/api/podcasts/${props.slug}/guests/${g.id}/send-rsvp`, { method: "POST" });
        // Server may return an absolute prepod URL; fall back to origin-relative
        // when SMTP isn't configured (legacy / dev setups).
        if (r.rsvp_url) g._rsvp_full_url = r.rsvp_url.startsWith("http")
          ? r.rsvp_url
          : (window.location.origin + r.rsvp_url);
        if (r.ok) {
          g._rsvp_msg = `✓ Email enviado a ${r.sent_to}`;
        } else if (r.reason === "no_smtp") {
          g._rsvp_msg = "SMTP no configurado — copia el link y mándalo a mano:";
          g._rsvp_show_link = true;
        } else {
          g._rsvp_msg = "✕ No se pudo enviar — copia el link y mándalo a mano:";
          g._rsvp_show_link = true;
        }
      } catch (e) {
        error.value = e.message;
      } finally {
        g._rsvp_sending = false;
      }
    }

    async function sendPreRecording(g) {
      if (!g.email || !g.email.trim()) {
        error.value = "Agrega un email para enviar preparación";
        return;
      }
      g._prep_sending = true;
      g._prep_msg = "";
      try {
        var r = await api("/api/podcasts/" + props.slug + "/episodes/" + props.episodeId + "/send-pre-recording", {
          method: "POST", body: { guest_id: g.id },
        });
        if (r.results && r.results.length) {
          var res = r.results[0];
          g._prep_msg = res.ok ? ("✓ Preparación enviada a " + res.sent_to) : ("✕ " + (res.reason || res.error || "Error"));
        }
      } catch (e) { error.value = e.message; }
      finally { g._prep_sending = false; }
    }

    var bulkSending = ref(false);
    var bulkMsg = ref("");

    async function sendAllPreRecording() {
      var withEmail = guests.value.filter(function (g) { return g.email && g.email.trim(); });
      if (!withEmail.length) { error.value = "Ningún invitado tiene email"; return; }
      bulkSending.value = true;
      bulkMsg.value = "";
      try {
        var r = await api("/api/podcasts/" + props.slug + "/episodes/" + props.episodeId + "/send-pre-recording", {
          method: "POST", body: {},
        });
        bulkMsg.value = "✓ Enviados " + r.sent + "/" + r.total;
      } catch (e) { error.value = e.message; }
      finally { bulkSending.value = false; }
    }

    watch(() => props.episodeId, load, { immediate: true });
    return { canShare, shareRsvp, 
      guests, error, newName, newEmail, newRole,
      roles: GUEST_ROLES, rsvpLabels: RSVP_LABELS, rsvpColors: RSVP_COLORS,
      add, remove, saveGuest, copyInvite, copyRsvp, sendRsvp,
      sendPreRecording, sendAllPreRecording, bulkSending, bulkMsg,
    };
  },
  template: `
    <div>
      <div class="section-head" style="display: flex; align-items: center; justify-content: space-between;">
        <div>
          <div class="eyebrow">ROSTER</div>
          <h3>Quiénes participan en este episodio</h3>
        </div>
        <button v-if="guests.length > 0" class="ghost" :disabled="bulkSending" @click="sendAllPreRecording" style="font-size: 12px; padding: 5px 12px; white-space: nowrap;">
          {{ bulkSending ? "Enviando…" : "📋 Enviar preparación a todos" }}
        </button>
      </div>
      <div v-if="bulkMsg" class="muted" style="font-size: 12px; margin-bottom: 8px;">{{ bulkMsg }}</div>

      <div v-if="error" class="error">{{ error }}</div>

      <div v-if="guests.length === 0" class="empty-pill">Sin invitados todavía. Agrega al primero abajo.</div>
      <div v-else class="guest-list">
        <div v-for="g in guests" :key="g.id" class="guest-card">
          <div class="guest-row">
            <input type="text" class="guest-name" v-model="g.name" @input="saveGuest(g)" placeholder="Nombre">
            <select v-model="g.role" @change="saveGuest(g)">
              <option v-for="r in roles" :key="r.value" :value="r.value">{{ r.label }}</option>
            </select>
            <span class="rsvp-badge" :style="{ background: rsvpColors[g.rsvp_status] || '#888' }">{{ rsvpLabels[g.rsvp_status] || g.rsvp_status }}</span>
            <button class="icon danger" @click="remove(g)" title="Eliminar">✕</button>
          </div>
          <div class="guest-row">
            <input type="email" v-model="g.email" @input="saveGuest(g)" placeholder="email@dominio">
            <input type="text" v-model="g.bio" @input="saveGuest(g)" placeholder="Bio breve (opcional)">
          </div>
          <div class="guest-row" style="gap: 6px;">
            <input type="text" v-model="g.social_instagram" @input="saveGuest(g)" placeholder="Instagram" style="flex:1; min-width: 100px; font-size: 12px;">
            <input type="text" v-model="g.social_twitter" @input="saveGuest(g)" placeholder="X / Twitter" style="flex:1; min-width: 100px; font-size: 12px;">
            <input type="text" v-model="g.social_youtube" @input="saveGuest(g)" placeholder="YouTube" style="flex:1; min-width: 100px; font-size: 12px;">
            <input type="text" v-model="g.social_tiktok" @input="saveGuest(g)" placeholder="TikTok" style="flex:1; min-width: 100px; font-size: 12px;">
          </div>
          <div v-if="g.invite_url" class="guest-invite">
            <span class="eyebrow">INVITE prodPod</span>
            <a :href="g.invite_url" target="_blank" rel="noopener" :title="g.invite_url">{{ g.invite_url }}</a>
            <button class="icon" @click="copyInvite(g)" :title="g._copied ? 'copiado' : 'copiar'">{{ g._copied ? '✓' : '⧉' }}</button>
          </div>

          <div v-if="g.rsvp_token" class="guest-invite" style="display: flex; flex-wrap: wrap; gap: 6px; align-items: center;">
            <span class="eyebrow">RSVP</span>
            <button class="ghost" :disabled="g._rsvp_sending || !g.email" @click="sendRsvp(g)" style="font-size: 12px; padding: 4px 10px;">
              {{ g._rsvp_sending ? "Enviando…" : "📧 Invitar" }}
            </button>
            <button v-if="canShare" class="ghost rsvp-share" @click="shareRsvp(g)" style="font-size: 12px; padding: 4px 10px;">📤 Compartir</button>
            <a :href="g.rsvp_url" target="_blank" rel="noopener" class="ghost" style="font-size: 12px; padding: 4px 10px; text-decoration: none;">↗ Abrir</a>
            <button class="icon" @click="copyRsvp(g)" :title="g._rsvp_copied ? 'copiado' : 'copiar link RSVP'">{{ g._rsvp_copied ? '✓' : '⧉' }}</button>
            <button class="ghost" :disabled="g._prep_sending || !g.email" @click="sendPreRecording(g)" style="font-size: 12px; padding: 4px 10px;">
              {{ g._prep_sending ? "Enviando…" : "📋 Preparación" }}
            </button>
            <span v-if="g._rsvp_msg" class="muted" style="font-size: 12px; flex-basis: 100%;">{{ g._rsvp_msg }}</span>
            <a v-if="g._rsvp_show_link && (g._rsvp_full_url || g.rsvp_url)"
               :href="g._rsvp_full_url || g.rsvp_url" target="_blank" rel="noopener"
               style="font-size: 12px; flex-basis: 100%; word-break: break-all;">
              {{ g._rsvp_full_url || g.rsvp_url }}
            </a>
            <span v-if="g._prep_msg" class="muted" style="font-size: 12px; flex-basis: 100%;">{{ g._prep_msg }}</span>
          </div>
        </div>
      </div>

      <div class="guest-add">
        <input type="text" v-model="newName" placeholder="Nombre" @keyup.enter="add">
        <input type="email" v-model="newEmail" placeholder="email (opcional)" @keyup.enter="add">
        <select v-model="newRole">
          <option v-for="r in roles" :key="r.value" :value="r.value">{{ r.label }}</option>
        </select>
        <button class="primary" @click="add" :disabled="!newName.trim()">＋ Agregar</button>
      </div>
    </div>
  `,
};

/* ==========================================================================
   Show notes modal — opens on demand or auto when status hits 'published'.
   The server returns ready-to-paste text plus structured chapters; we offer
   a "Solo capítulos" copy in addition to the full text so users can paste
   chapters into YouTube's chapter field separately.
   ========================================================================== */

var ShowNotesModal = {
  props: { show: Boolean, slug: String, episodeId: Number },
  emits: ["close"],
  setup(props, { emit }) {
    const data = ref(null);
    const loading = ref(false);
    const error = ref("");
    const copied = ref("");

    async function load() {
      if (!props.episodeId) return;
      loading.value = true;
      error.value = "";
      try {
        data.value = await api(`/api/podcasts/${props.slug}/episodes/${props.episodeId}/show-notes`);
      } catch (e) {
        error.value = e.message;
      } finally {
        loading.value = false;
      }
    }

    watch(() => [props.show, props.episodeId], ([s]) => { if (s) load(); }, { immediate: true });

    const chaptersOnly = computed(() => {
      if (!data.value || !data.value.chapters || !data.value.chapters.length) return "";
      return data.value.chapters.map(c => `${c.offset_label} ${c.title}`).join("\n");
    });

    async function copyText(label, text) {
      if (!text) return;
      try {
        await navigator.clipboard.writeText(text);
        copied.value = label;
        setTimeout(() => { if (copied.value === label) copied.value = ""; }, 1500);
      } catch (_) {
        error.value = "No pude copiar al portapapeles";
      }
    }

    return { data, loading, error, copied, chaptersOnly, copyText };
  },
  template: `
    <div v-if="show" class="modal-backdrop" @click.self="$emit('close')">
      <div class="modal" style="max-width: 720px;">
        <div class="eyebrow">SHOW NOTES</div>
        <h3>Texto listo para publicar</h3>
        <p class="muted" style="margin-bottom: 14px;">Pegá esto en la descripción del episodio en Spotify, Apple, YouTube. Los capítulos están en formato YouTube (válido también en Spotify y Apple).</p>

        <div v-if="error" class="error">{{ error }}</div>
        <div v-if="loading" class="muted">Generando…</div>

        <template v-else-if="data">
          <div class="form-row">
            <label style="display: flex; align-items: center; gap: 10px;">
              <span>Texto completo</span>
              <button class="ghost" style="font-size: 12px; padding: 4px 10px;"
                      @click="copyText('full', data.text)">
                {{ copied === 'full' ? '✓ copiado' : '⧉ copiar' }}
              </button>
            </label>
            <textarea readonly :value="data.text" rows="14" style="font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12.5px;"></textarea>
          </div>

          <div v-if="chaptersOnly" class="form-row" style="margin-top: 14px;">
            <label style="display: flex; align-items: center; gap: 10px;">
              <span>Solo capítulos (YouTube)</span>
              <button class="ghost" style="font-size: 12px; padding: 4px 10px;"
                      @click="copyText('chapters', chaptersOnly)">
                {{ copied === 'chapters' ? '✓ copiado' : '⧉ copiar' }}
              </button>
            </label>
            <textarea readonly :value="chaptersOnly" rows="6" style="font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12.5px;"></textarea>
          </div>

          <div v-if="!data.chapters.length" class="muted" style="font-size: 12px; margin-top: 10px;">
            Tip: completa duraciones en el rundown para que se generen capítulos automáticos.
          </div>
        </template>

        <div class="row right" style="margin-top: 18px; gap: 8px;">
          <button class="primary" @click="$emit('close')">Cerrar</button>
        </div>
      </div>
    </div>
  `,
};

/* ==========================================================================
   Episode detail (Plan 2)
   ========================================================================== */

var EpisodeDetail = {
  components: { IdeasPanel, ScriptEditor, EpisodeLinks, EpisodeIntegrationBar, GuestsPanel, RundownEditor, ShowNotesModal },
  props: { slug: String, episodeId: Number },
  emits: ["back", "updated"],
  setup(props, { emit }) {
    const ep = ref(null);
    const error = ref("");
    const saveState = ref(null);
    const showNotesOpen = ref(false);
    // Track previous status so we only auto-open the modal on the
    // idea/planning/recorded → published *transition* (not on every reload
    // of an already-published episode).
    let prevStatus = null;

    async function load() {
      try {
        const data = await api(`/api/podcasts/${props.slug}/episodes/${props.episodeId}`);
        // Backfill scheduled_at from a legacy date-only scheduled_date.
        if (!data.scheduled_at && data.scheduled_date) {
          data.scheduled_at = `${data.scheduled_date}T09:00`;
        }
        ep.value = data;
      } catch (e) { error.value = e.message; }
    }

    // Manual save + 60s idle, no Object.assign retrigger.
    const dirty = ref(false);
    async function _doSave() {
      if (!ep.value) return;
      saveState.value = "saving";
      try {
        const updated = await api(
          `/api/podcasts/${props.slug}/episodes/${ep.value.id}`,
          {
            method: "PUT",
            body: {
              title: ep.value.title,
              description: ep.value.description,
              episode_number: ep.value.episode_number,
              scheduled_date: (ep.value.scheduled_at || "").slice(0, 10) || null,
              scheduled_at: ep.value.scheduled_at || null,
              duration_estimate: ep.value.duration_estimate || null,
            },
          },
        );
        dirty.value = false;
        saveState.value = "saved";
        setTimeout(() => { if (saveState.value === "saved") saveState.value = null; }, 2000);
        emit("updated", updated);
      } catch (e) {
        saveState.value = "error";
        error.value = e.message;
      }
    }
    const _idleSave = debounce(() => { if (dirty.value) _doSave(); }, 60_000);
    function saveNow() { _doSave(); }

    watch(() => [
      ep.value?.title, ep.value?.description, ep.value?.episode_number,
      ep.value?.scheduled_date, ep.value?.scheduled_at, ep.value?.duration_estimate,
    ], (newVals, oldVals) => {
      if (!ep.value || !oldVals || oldVals.every(v => v === undefined)) return;
      dirty.value = true;
      _idleSave();
    });

    watch(() => ep.value?.status, (newStatus) => {
      // Auto-open show notes the moment the episode is marked "published".
      // Suppress on initial load (prevStatus null) and on no-op writes.
      if (newStatus === "published" && prevStatus && prevStatus !== "published") {
        showNotesOpen.value = true;
      }
      prevStatus = newStatus || null;
    });

    watch(() => props.episodeId, () => { prevStatus = null; load(); }, { immediate: true });

    function openShowNotes() { showNotesOpen.value = true; }
    function closeShowNotes() { showNotesOpen.value = false; }

    // --- Show Notes (AI) ---
    async function forceSyncNotes(slug, epId) {
      const data = await api(`/api/podcasts/${slug}/episodes/${epId}/sync-notes`, { method: 'POST' });
      return data;
    }

    async function syncNotes() {
      const data = await forceSyncNotes(props.slug, ep.value.id);
      if (data.ok) {
        ep.value.ai_summary = data.ai_summary;
        ep.value.ai_highlights = data.ai_highlights;
        ep.value.ai_notes_synced_at = data.synced_at;
      }
    }

    // --- Publish ---
    const publishPath = ref('');
    const publishing = ref(false);

    async function publishEpisode(slug, epId, mediaFile) {
      const data = await api(`/api/podcasts/${slug}/episodes/${epId}/publish`, {
        method: 'POST',
        body: { media_file: mediaFile },
      });
      return data;
    }

    async function doPublish() {
      if (!publishPath.value) return;
      publishing.value = true;
      try {
        const data = await publishEpisode(props.slug, ep.value.id, publishPath.value);
        if (data.ok) {
          ep.value.media_url = data.media_url;
          ep.value.status = 'published';
        } else {
          alert(data.error || 'Error al publicar');
        }
      } catch (e) { alert(e.message); }
      finally { publishing.value = false; }
    }

    return { ep, error, saveState, dirty, saveNow, fmtDate,
             showNotesOpen, openShowNotes, closeShowNotes,
             publishPath, publishing, syncNotes, doPublish };
  },
  template: `
    <div v-if="ep" class="episode-detail">
      <div class="main">
        <div v-if="error" class="error">{{ error }}</div>

        <div class="section">
          <div class="section-head">
            <div class="eyebrow">{{ ep.status.toUpperCase() }}</div>
            <div style="display: flex; align-items: center; gap: 12px; width: 100%;">
              <label class="ep-number-label">
                <span class="tiny">EP #</span>
                <input type="number" v-model.number="ep.episode_number" min="1" class="ep-number-input">
              </label>
              <h3 style="margin: 0; flex: 1;">
                <input type="text" v-model="ep.title" style="font-family: var(--font-display); font-size: 22px; font-weight: 500; letter-spacing: -0.01em; padding: 4px 0; border: 0; background: transparent; width: 100%;">
              </h3>
            </div>
          </div>

          <div class="form-row" style="margin-bottom: 14px;">
            <label>Descripción</label>
            <textarea v-model="ep.description" rows="3" placeholder="De qué va este episodio..."></textarea>
          </div>

          <div class="ep-meta-grid">
            <div>
              <label>Estado</label>
              <select v-model="ep.status" @change="$emit('updated', ep)">
                <option value="idea">Idea</option>
                <option value="planning">Planificando</option>
                <option value="scripted">Con guion</option>
                <option value="recorded">Grabado</option>
                <option value="published">Publicado</option>
              </select>
            </div>
            <div>
              <label>Fecha y hora</label>
              <input type="datetime-local" v-model="ep.scheduled_at">
            </div>
            <div>
              <label>Duración est. (min)</label>
              <input type="number" v-model.number="ep.duration_estimate" min="0" step="1">
            </div>
          </div>
          <div class="row" style="margin-top: 8px; gap: 8px; align-items: center;">
            <a v-if="ep.scheduled_at || ep.scheduled_date"
               class="ghost btn-link"
               :href="'/api/podcasts/' + slug + '/episodes/' + ep.id + '.ics'"
               download>📅 Descargar .ics</a>
            <span v-else class="muted" style="font-size: 12px;">Programa fecha y hora para exportar al calendario.</span>
            <div class="spacer"></div>
            <button class="ghost" @click="openShowNotes" title="Generar texto listo para publicar">📋 Show notes</button>
          </div>
        </div>

        <div class="show-notes-panel" v-if="ep.ai_summary">
          <h4>
            Show Notes (AI)
            <span class="show-notes-meta" v-if="ep.ai_notes_synced_at">
              Sincronizado: {{ ep.ai_notes_synced_at }}
            </span>
          </h4>
          <div class="show-notes-summary">{{ ep.ai_summary }}</div>
          <ul class="show-notes-highlights" v-if="ep.ai_highlights && ep.ai_highlights.length">
            <li v-for="h in ep.ai_highlights" :key="h">{{ h }}</li>
          </ul>
          <div class="show-notes-actions">
            <button @click="syncNotes">Sincronizar notas</button>
          </div>
        </div>

        <div class="publish-section" v-if="ep.status !== 'published' && ep.media_url === null">
          <h4>Publicar episodio</h4>
          <p style="font-size:0.8rem;color:var(--text-3);">
            Sube el audio/video final a VPS y actualiza el feed RSS.
          </p>
          <input v-model="publishPath" placeholder="Ruta al archivo exportado" style="width:100%;margin-bottom:0.5rem;padding:6px;border-radius:4px;border:1px solid var(--border,#dee2e6);font-size:0.8rem;" />
          <button class="publish-btn" @click="doPublish" :disabled="publishing || !publishPath">
            {{ publishing ? 'Publicando...' : 'Publicar' }}
          </button>
          <div class="publish-status" v-if="ep.media_url">
            Publicado: <a :href="ep.media_url" target="_blank">{{ ep.media_url }}</a>
          </div>
        </div>
        <div class="publish-section" v-else-if="ep.media_url">
          <h4>Publicado</h4>
          <div class="publish-status">
            <a :href="ep.media_url" target="_blank">{{ ep.media_url }}</a>
          </div>
        </div>

        <EpisodeIntegrationBar :slug="slug" :episode-id="ep.id" />

        <div class="section">
          <RundownEditor :slug="slug" :episode-id="ep.id" />
        </div>

        <div class="section">
          <ScriptEditor :slug="slug" :episode-id="ep.id" />
        </div>

        <div class="section">
          <GuestsPanel :slug="slug" :episode-id="ep.id" />
        </div>

        <div class="section">
          <EpisodeLinks :slug="slug" :episode-id="ep.id" />
        </div>
      </div>

      <aside class="side">
        <IdeasPanel :slug="slug" :episode-id="ep.id" />
      </aside>

      <div class="save-bar">
        <span v-if="saveState === 'saving'" class="save-indicator saving">◉ guardando…</span>
        <span v-else-if="saveState === 'saved'" class="save-indicator">✓ guardado</span>
        <span v-else-if="saveState === 'error'" class="save-indicator" style="background: var(--signal-hot); color: #fff;">◆ error</span>
        <span v-else-if="dirty" class="save-indicator dirty">● sin guardar</span>
        <button class="primary save-btn" :disabled="!dirty || saveState === 'saving'" @click="saveNow">
          💾 Guardar
        </button>
      </div>

      <ShowNotesModal :show="showNotesOpen" :slug="slug" :episode-id="ep.id" @close="closeShowNotes" />
    </div>
    <div v-else class="container">
      <div class="muted">Cargando episodio…</div>
    </div>
  `,
};
/* ==========================================================================
   Team editor (used inside LandingPanel)
   ========================================================================== */

var BodyBlocksEditor = {
  props: { slug: String, initialJson: String },
  emits: ["saved"],
  setup(props, { emit }) {
    const elRef = ref(null);
    const saveState = ref(null);
    const error = ref("");
    let editor = null;

    function _initialData() {
      const raw = (props.initialJson || "").trim();
      if (!raw) return { blocks: [] };
      try { return JSON.parse(raw); } catch (_) { return { blocks: [] }; }
    }

    onMounted(() => {
      if (!window.EditorJS) {
        error.value = "Editor.js no cargó (revisa la consola).";
        return;
      }
      const tools = {
        header: { class: window.Header, inlineToolbar: true, tunes: ["alignment"] },
        paragraph: {
          class: window.Paragraph || EditorJS.Paragraph,
          inlineToolbar: true,
          tunes: ["alignment"],
        },
        list: { class: window.List, inlineToolbar: true, tunes: ["alignment"] },
        quote: { class: window.Quote, inlineToolbar: true, tunes: ["alignment"] },
        delimiter: { class: window.Delimiter },
        image: {
          class: window.ImageTool,
          config: {
            endpoints: {
              byFile: `/api/podcasts/${props.slug}/landing-image`,
            },
            field: "image",
            additionalRequestHeaders: {},
            captionPlaceholder: "Pie de foto (opcional)",
          },
        },
        embed: { class: window.Embed, inlineToolbar: true },
        marker: { class: window.Marker },
        inlineCode: { class: window.InlineCode },
      };
      // The alignment plugin is registered as a tune.
      if (window.AlignmentBlockTune || window.TextAlignmentBlockTune) {
        tools.alignment = {
          class: window.AlignmentBlockTune || window.TextAlignmentBlockTune,
          config: { default: "left", blocks: { header: "left", paragraph: "left", quote: "left", list: "left" } },
        };
      } else {
        // alignment plugin not loaded — strip the tune refs to avoid runtime errors.
        Object.values(tools).forEach(t => { delete t.tunes; });
      }
      editor = new window.EditorJS({
        holder: elRef.value,
        placeholder: "Empieza a escribir, o presiona / para insertar bloques (imagen, cita, lista, etc.)",
        data: _initialData(),
        tools,
        i18n: { messages: {} },
        onChange: () => { saveState.value = "dirty"; },
      });
    });

    onBeforeUnmount(() => { try { editor && editor.destroy && editor.destroy(); } catch (_) {} });

    async function save() {
      if (!editor) return;
      saveState.value = "saving"; error.value = "";
      try {
        const data = await editor.save();
        const json = JSON.stringify(data);
        await api(`/api/podcasts/${props.slug}`, {
          method: "PUT", body: { landing_blocks: json },
        });
        saveState.value = "saved";
        setTimeout(() => { if (saveState.value === "saved") saveState.value = null; }, 2000);
        emit("saved");
      } catch (e) {
        saveState.value = "error";
        error.value = e.message || String(e);
      }
    }

    return { elRef, save, saveState, error };
  },
  template: `
    <div class="body-blocks">
      <div class="bb-toolbar">
        <span class="eyebrow">CUERPO DE LA PÁGINA</span>
        <span class="muted" style="font-size: 11px; flex: 1;">
          Imágenes, párrafos, citas, listas, encabezados, embeds. Arrastra para reordenar. Cada bloque tiene alineación.
        </span>
        <span v-if="saveState === 'saving'" class="tiny" style="color: var(--signal);">guardando…</span>
        <span v-else-if="saveState === 'saved'" class="tiny" style="color: var(--signal-cool);">✓ guardado</span>
        <span v-else-if="saveState === 'dirty'" class="tiny" style="color: var(--signal-amber, #f4c770);">● sin guardar</span>
        <button class="primary" @click="save" :disabled="saveState === 'saving'">💾 Guardar bloques</button>
      </div>
      <div v-if="error" class="error">{{ error }}</div>
      <div ref="elRef" class="bb-holder"></div>
    </div>
  `,
};

var TeamEditor = {
  props: { slug: String },
  setup(props) {
    const members = ref([]);
    const error = ref("");

    async function load() {
      try { members.value = await api(`/api/podcasts/${props.slug}/team`); }
      catch (e) { error.value = e.message; }
    }

    async function addMember() {
      try {
        const created = await api(`/api/podcasts/${props.slug}/team`, {
          method: "POST",
          body: { name: "Nuevo miembro" },
        });
        members.value.push(created);
      } catch (e) { error.value = e.message; }
    }

    async function removeMember(m) {
      if (!await podSwal.confirm(`¿Eliminar "${m.name}" del equipo?`)) return;
      try {
        await api(`/api/podcasts/${props.slug}/team/${m.id}`, { method: "DELETE" });
        members.value = members.value.filter(x => x.id !== m.id);
      } catch (e) { error.value = e.message; }
    }

    const _savers = new Map();
    function saveMember(m) {
      let fn = _savers.get(m.id);
      if (!fn) {
        fn = debounce(async () => {
          try {
            const r = await api(`/api/podcasts/${props.slug}/team/${m.id}`, {
              method: "PUT",
              body: {
                name: m.name, role: m.role, bio: m.bio,
                social_twitter: m.social_twitter,
                social_instagram: m.social_instagram,
                social_youtube: m.social_youtube,
                social_tiktok: m.social_tiktok,
                social_website: m.social_website,
              },
            });
            Object.assign(m, r);
          } catch (e) { error.value = e.message; }
        }, 500);
        _savers.set(m.id, fn);
      }
      fn();
    }

    async function uploadAvatar(m, ev) {
      const f = ev.target.files?.[0];
      if (!f) return;
      try {
        const form = new FormData();
        form.append("file", f);
        const r = await apiUpload(`/api/podcasts/${props.slug}/team/${m.id}/image`, form);
        m.image_filename = r.filename;
        m.image_url = r.url;
      } catch (e) { error.value = e.message; }
      finally { ev.target.value = ""; }
    }

    onMounted(load);
    return { members, error, addMember, removeMember, saveMember, uploadAvatar };
  },
  template: `
    <div>
      <div v-if="error" class="error">{{ error }}</div>

      <div v-if="members.length === 0" class="empty-pill">Sin miembros. Agrega al host o al equipo.</div>

      <div class="team-list">
        <div v-for="m in members" :key="m.id" class="member-card">
          <div class="avatar" :style="m.image_url ? { backgroundImage: 'url(' + m.image_url + ')' } : {}" :title="'Subir foto de ' + m.name">
            <div class="upload-hint">cambiar</div>
            <input type="file" accept="image/*" @change="(ev) => uploadAvatar(m, ev)">
          </div>
          <div class="fields">
            <input type="text" class="name-input" v-model="m.name" placeholder="Nombre" @input="saveMember(m)">
            <input type="text" v-model="m.role" placeholder="Rol (Host, Guest, Producer…)" @input="saveMember(m)">
            <input type="text" v-model="m.bio" placeholder="Bio breve (una línea)" @input="saveMember(m)">
            <div class="social-row">
              <input type="text" v-model="m.social_instagram" placeholder="Instagram" @input="saveMember(m)">
              <input type="text" v-model="m.social_twitter" placeholder="X / Twitter" @input="saveMember(m)">
              <input type="text" v-model="m.social_youtube" placeholder="YouTube" @input="saveMember(m)">
              <input type="text" v-model="m.social_tiktok" placeholder="TikTok" @input="saveMember(m)">
            </div>
          </div>
          <div class="actions">
            <button class="icon danger" @click="removeMember(m)" title="Eliminar">✕</button>
          </div>
        </div>
      </div>

      <div class="row right" style="margin-top: 12px;">
        <button @click="addMember">＋ Agregar miembro</button>
      </div>
    </div>
  `,
};

/* ==========================================================================
   Landing panel (Plan 3)
   ========================================================================== */

var LandingPanel = {
  components: { TeamEditor },
  props: { podcast: Object },
  setup(props) {
    const cfg = reactive({
      template: "minimal",
      custom_css: "",
      show_episodes: true,
      show_team: false,
      owner_name: "",
      owner_email: "",
      language: "es",
      social_youtube: "",
      social_spotify: "",
      social_apple_podcasts: "",
      social_instagram: "",
      social_tiktok: "",
      social_twitter: "",
      analytics_code: "",
      og_image_url: "",
    });
    const loaded = ref(false);
    const error = ref("");
    const saveState = ref(null);
    const copyNotice = ref("");

    async function load() {
      try {
        const r = await api(`/api/podcasts/${props.podcast.slug}/landing`);
        Object.assign(cfg, r);
      } catch (e) { error.value = e.message; }
      finally { loaded.value = true; }
    }

    // Manual save model: dirty flag + button + 60s idle autosave net.
    // No Object.assign after the save (was causing the indicator to flash
    // every second because the response retriggered the watcher).
    const dirty = ref(false);

    async function _doSave() {
      saveState.value = "saving";
      try {
        await api(`/api/podcasts/${props.podcast.slug}/landing`, {
          method: "PUT",
          body: { ...cfg },
        });
        dirty.value = false;
        saveState.value = "saved";
        setTimeout(() => { if (saveState.value === "saved") saveState.value = null; }, 2000);
      } catch (e) {
        saveState.value = "error";
        error.value = e.message;
      }
    }
    const _idleSave = debounce(() => { if (dirty.value) _doSave(); }, 60_000);
    function saveNow() { _doSave(); }

    watch(() => Object.values(cfg), () => {
      if (!loaded.value) return;
      dirty.value = true;
      _idleSave();
    });

    const landingUrl   = computed(() => `${window.location.origin}/landing/${props.podcast.slug}`);
    const defaultRssUrl = computed(() => `${window.location.origin}/landing/${props.podcast.slug}/feed.xml`);
    const rssOverride  = ref(props.podcast.rss_override_url || "");
    const effectiveRss = computed(() => (rssOverride.value || "").trim() || defaultRssUrl.value);
    const rssSaveState = ref(null);

    async function saveRss() {
      rssSaveState.value = "saving";
      try {
        await api(`/api/podcasts/${props.podcast.slug}`, {
          method: "PUT",
          body: { rss_override_url: (rssOverride.value || "").trim() },
        });
        rssSaveState.value = "saved";
        setTimeout(() => { if (rssSaveState.value === "saved") rssSaveState.value = null; }, 1500);
      } catch (e) {
        rssSaveState.value = "error";
        error.value = e.message;
      }
    }
    function clearRssOverride() {
      rssOverride.value = "";
      saveRss();
    }

    async function copy(value, label) {
      try {
        await navigator.clipboard.writeText(value);
        copyNotice.value = `${label} copiado`;
        setTimeout(() => { copyNotice.value = ""; }, 1500);
      } catch (_) {
        copyNotice.value = "no se pudo copiar";
        setTimeout(() => { copyNotice.value = ""; }, 1500);
      }
    }

    function openPreview() { window.open(landingUrl.value, "_blank"); }

    // Live preview: iframe pointing at the landing in EDIT MODE. Each
    // contenteditable element auto-saves on blur via /static/landing-edit.js.
    // Cache-bust on every reload so style changes show immediately.
    const previewSrc = ref(landingUrl.value + "?edit_mode=1");
    function reloadPreview() {
      previewSrc.value = landingUrl.value + "?edit_mode=1&t=" + Date.now();
    }
    // Reload preview whenever a save completes successfully OR when the user
    // toggles a control that doesn't go through the debounced save.
    watch(saveState, (s) => { if (s === "saved") reloadPreview(); });
    watch(rssSaveState, (s) => { if (s === "saved") reloadPreview(); });
    // Discrete switches (template, toggles) save immediately + reload preview
    // — they don't have the typing-in-progress problem so don't need to wait.
    watch(() => cfg.template, async (v, prev) => {
      if (!loaded.value || !prev) return;
      await _doSave();
      reloadPreview();
    });
    watch(() => cfg.show_episodes, async (v, prev) => {
      if (!loaded.value || prev === undefined) return;
      await _doSave();
      reloadPreview();
    });
    watch(() => cfg.show_team, async (v, prev) => {
      if (!loaded.value || prev === undefined) return;
      await _doSave();
      reloadPreview();
    });

    onMounted(load);

    return { cfg, loaded, error, saveState, dirty, saveNow, copyNotice, landingUrl, defaultRssUrl,
             rssOverride, effectiveRss, rssSaveState, saveRss, clearRssOverride,
             copy, openPreview, previewSrc, reloadPreview };
  },
  template: `
    <div class="landing-wrap landing-wysiwyg">
      <div class="inner" v-if="loaded">
        <div v-if="error" class="error">{{ error }}</div>

        <div class="landing-top">
          <div class="tpl-chips">
            <button :class="{active: cfg.template === 'minimal'}" @click="cfg.template = 'minimal'">Minimal</button>
            <button :class="{active: cfg.template === 'bold'}" @click="cfg.template = 'bold'">Bold</button>
            <button :class="{active: cfg.template === 'classic'}" @click="cfg.template = 'classic'">Classic</button>
          </div>
          <div class="landing-url">
            <span class="tiny">LANDING</span>
            <span class="url-txt" :title="landingUrl">{{ landingUrl }}</span>
            <button class="icon ghost" @click="copy(landingUrl, 'URL')" title="Copiar URL">⧉</button>
          </div>
          <button class="primary" @click="openPreview">Ver landing ↗</button>
        </div>

        <div class="landing-rss-row">
          <span class="tiny">RSS</span>
          <input type="text"
                 v-model="rssOverride"
                 :placeholder="defaultRssUrl"
                 @blur="saveRss"
                 @keyup.enter="$event.target.blur()"
                 class="rss-input">
          <button class="icon ghost" @click="copy(effectiveRss, 'RSS')" title="Copiar el RSS que se está usando">⧉</button>
          <button v-if="rssOverride" class="ghost" @click="clearRssOverride" title="Volver al RSS por defecto">↺ default</button>
          <span v-if="rssSaveState === 'saving'" class="tiny" style="color: var(--signal);">guardando…</span>
          <span v-else-if="rssSaveState === 'saved'" class="tiny" style="color: var(--signal-cool);">✓ guardado</span>
          <span v-else-if="rssSaveState === 'error'" class="tiny" style="color: var(--signal-hot);">error</span>
        </div>
        <div class="muted" style="font-size: 11px; margin: -4px 0 18px;">
          Default: <span class="mono">{{ defaultRssUrl }}</span>. Edita arriba si tienes el RSS hosteado en otro lado (Megafono, Spreaker, etc.).
        </div>

        <div class="section">
          <div class="section-head">
            <div class="eyebrow">IDENTIDAD DEL FEED</div>
            <h3>Para Apple Podcasts / Spotify</h3>
          </div>
          <div class="grid-2">
            <div>
              <label>Owner name</label>
              <input type="text" v-model="cfg.owner_name" placeholder="Tu nombre">
            </div>
            <div>
              <label>Owner email</label>
              <input type="text" v-model="cfg.owner_email" placeholder="mail@example.com">
            </div>
          </div>
          <div style="margin-top: 12px; max-width: 200px;">
            <label>Idioma</label>
            <select v-model="cfg.language">
              <option value="es">Español</option>
              <option value="es-AR">Español (AR)</option>
              <option value="es-ES">Español (ES)</option>
              <option value="en">English</option>
              <option value="pt">Português</option>
              <option value="fr">Français</option>
              <option value="it">Italiano</option>
            </select>
          </div>
        </div>

        <div class="section">
          <div class="section-head">
            <div class="eyebrow">PLATAFORMAS</div>
            <h3>Enlaces de suscripción</h3>
          </div>
          <div class="socials-grid">
            <div class="social-row"><span class="plat">YouTube</span><input type="text" v-model="cfg.social_youtube" placeholder="https://youtube.com/@..."></div>
            <div class="social-row"><span class="plat">Spotify</span><input type="text" v-model="cfg.social_spotify" placeholder="https://open.spotify.com/show/..."></div>
            <div class="social-row"><span class="plat">Apple</span><input type="text" v-model="cfg.social_apple_podcasts" placeholder="https://podcasts.apple.com/..."></div>
            <div class="social-row"><span class="plat">Instagram</span><input type="text" v-model="cfg.social_instagram" placeholder="https://instagram.com/..."></div>
            <div class="social-row"><span class="plat">TikTok</span><input type="text" v-model="cfg.social_tiktok" placeholder="https://tiktok.com/@..."></div>
            <div class="social-row"><span class="plat">Twitter/X</span><input type="text" v-model="cfg.social_twitter" placeholder="https://x.com/..."></div>
          </div>
        </div>

        <div class="section">
          <div class="section-head">
            <div class="eyebrow">VISIBILIDAD</div>
            <h3>Qué mostrar en la landing</h3>
          </div>
          <div class="toggle-row">
            <div class="label">
              Mostrar lista de episodios
              <div class="hint">Los últimos 50 episodios aparecen en la página pública.</div>
            </div>
            <input type="checkbox" v-model="cfg.show_episodes">
          </div>
          <div class="toggle-row">
            <div class="label">
              Mostrar equipo
              <div class="hint">Sección con los miembros cargados abajo.</div>
            </div>
            <input type="checkbox" v-model="cfg.show_team">
          </div>
        </div>

        <div class="section">
          <div class="section-head">
            <div class="eyebrow">EQUIPO</div>
            <h3>Miembros del podcast</h3>
          </div>
          <TeamEditor :slug="podcast.slug" />
        </div>

        <div class="section">
          <div class="section-head">
            <div class="eyebrow">PERSONALIZACIÓN</div>
            <h3>CSS custom y analytics</h3>
          </div>
          <div class="form-row" style="margin-bottom: 12px;">
            <label>CSS personalizado (se inyecta al final de la landing)</label>
            <textarea v-model="cfg.custom_css" rows="6" style="font-family: var(--font-mono); font-size: 12px;" placeholder=".hero { ... }"></textarea>
          </div>
          <div class="form-row">
            <label>Analytics (HTML/script, ej: Google Analytics, Plausible)</label>
            <textarea v-model="cfg.analytics_code" rows="4" style="font-family: var(--font-mono); font-size: 12px;" placeholder="<script>...</script>"></textarea>
          </div>
          <div class="muted" style="margin-top: 10px; font-size: 11px;">
            El código de analytics se inserta tal cual en el &lt;head&gt; de la landing. Revisá que sea HTML válido.
          </div>
        </div>
      </div>

      <aside class="landing-preview" v-if="loaded">
        <div class="preview-head">
          <span class="tiny">PREVIEW EN VIVO</span>
          <button class="icon ghost" @click="reloadPreview" title="Recargar preview">↻</button>
          <button class="icon ghost" @click="openPreview" title="Abrir en pestaña nueva">↗</button>
        </div>
        <iframe :src="previewSrc" class="preview-frame"></iframe>
      </aside>

      <div class="save-bar">
        <span v-if="saveState === 'saving'" class="save-indicator saving">◉ guardando…</span>
        <span v-else-if="saveState === 'saved'" class="save-indicator">✓ guardado</span>
        <span v-else-if="saveState === 'error'" class="save-indicator" style="background: var(--signal-hot); color: #fff;">◆ error</span>
        <span v-else-if="dirty" class="save-indicator dirty">● sin guardar</span>
        <span v-else-if="copyNotice" class="save-indicator">{{ copyNotice }}</span>
        <button class="primary save-btn" :disabled="!dirty || saveState === 'saving'" @click="saveNow">
          💾 Guardar
        </button>
      </div>
    </div>
  `,
};

/* ==========================================================================
   Podcast view (router: branding · episodes · landing · episode detail)
   ========================================================================== */

var CalendarView = {
  props: { slug: String },
  emits: ["open-episode"],
  setup(props, { emit }) {
    const eps = ref([]);
    const error = ref("");
    const cursor = ref(new Date()); // first of month being shown
    const todayStr = (() => {
      const t = new Date();
      return `${t.getFullYear()}-${String(t.getMonth() + 1).padStart(2, "0")}-${String(t.getDate()).padStart(2, "0")}`;
    })();

    async function load() {
      try { eps.value = await api(`/api/podcasts/${props.slug}/episodes`); }
      catch (e) { error.value = e.message; }
    }

    const monthLabel = computed(() =>
      cursor.value.toLocaleDateString("es", { month: "long", year: "numeric" })
    );

    const grid = computed(() => {
      const c = new Date(cursor.value.getFullYear(), cursor.value.getMonth(), 1);
      const firstWeekday = (c.getDay() + 6) % 7; // Mon=0
      const daysInMonth = new Date(c.getFullYear(), c.getMonth() + 1, 0).getDate();
      const cells = [];
      for (let i = 0; i < firstWeekday; i++) cells.push({ blank: true, key: `b${i}` });
      for (let d = 1; d <= daysInMonth; d++) {
        const dateStr = `${c.getFullYear()}-${String(c.getMonth() + 1).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
        const dayEps = eps.value
          .filter(e => {
            const s = e.scheduled_at || e.scheduled_date || "";
            return s.startsWith(dateStr);
          })
          .sort((a, b) => (a.scheduled_at || "").localeCompare(b.scheduled_at || ""));
        cells.push({ d, dateStr, eps: dayEps, key: dateStr, isToday: dateStr === todayStr });
      }
      return cells;
    });

    function prev() { cursor.value = new Date(cursor.value.getFullYear(), cursor.value.getMonth() - 1, 1); }
    function next() { cursor.value = new Date(cursor.value.getFullYear(), cursor.value.getMonth() + 1, 1); }
    function today() { cursor.value = new Date(); }

    function openEp(ep) { emit("open-episode", ep.id); }

    function timeOf(ep) {
      const s = ep.scheduled_at || "";
      return s.length >= 16 ? s.slice(11, 16) : "";
    }

    async function createOnDay(dateStr) {
      const title = (await podSwal.prompt(`Nuevo episodio para ${dateStr}\n\nTítulo:`, "")  || "").trim();
      if (!title) return;
      try {
        const created = await api(`/api/podcasts/${props.slug}/episodes`, {
          method: "POST",
          body: { title, status: "planning", scheduled_at: `${dateStr}T09:00` },
        });
        eps.value.push(created);
        emit("open-episode", created.id);
      } catch (e) { error.value = e.message; }
    }

    // Drag-drop: arrastrar un episodio de un día a otro cambia su fecha
    // sin perder la hora. Usamos el dataTransfer en vez de un ref porque en
    // Safari el ref puede limpiarse entre dragstart y drop.
    const dragging = ref(null);
    let _dragId = null;
    function onDragEpStart(ep, ev) {
      _dragId = ep.id;
      dragging.value = ep.id;
      try {
        ev.dataTransfer.effectAllowed = "move";
        ev.dataTransfer.setData("text/plain", String(ep.id));
      } catch (_) {}
    }
    function onDragEnd() { dragging.value = null; }
    function onCellDragOver(ev, cell) {
      if (cell.blank) return;
      // Always preventDefault on dragover so the drop event fires; some
      // browsers swallow the drop silently otherwise.
      ev.preventDefault();
      try { ev.dataTransfer.dropEffect = "move"; } catch (_) {}
    }
    function onCellDrop(ev, cell) {
      if (cell.blank) return;
      let id = _dragId || dragging.value;
      if (!id) {
        try { id = parseInt(ev.dataTransfer.getData("text/plain"), 10); } catch (_) {}
      }
      _dragId = null;
      dragging.value = null;
      if (!id) return;
      const ep = eps.value.find(e => e.id === id);
      if (!ep) { error.value = "no encontré el episodio (id " + id + ")"; return; }
      const wasDate = (ep.scheduled_at || ep.scheduled_date || "").slice(0, 10);
      if (wasDate === cell.dateStr) return;
      const oldTime = (ep.scheduled_at || "").slice(11, 16) || "09:00";
      const newAt = `${cell.dateStr}T${oldTime}`;
      const prevAt = ep.scheduled_at;
      const prevDate = ep.scheduled_date;
      // Optimistic update for snappy UI.
      ep.scheduled_at = newAt;
      ep.scheduled_date = cell.dateStr;
      // Defer the fetch out of the drop event handler. Safari (and some other
      // engines) intermittently fail fetches issued *inside* a drop handler
      // with "Load failed" — the network stack is still bound to the drag
      // operation. setTimeout(0) breaks us out of that context cleanly.
      setTimeout(() => { _persistMove(id, ep, newAt, cell.dateStr, prevAt, prevDate); }, 0);
    }

    const undoToast = ref(null);
    let _undoTimer = null;

    function dismissUndo() {
      if (_undoTimer) { clearTimeout(_undoTimer); _undoTimer = null; }
      undoToast.value = null;
    }

    async function doUndo() {
      const u = undoToast.value;
      if (!u) return;
      dismissUndo();
      const ep = eps.value.find(e => e.id === u.episodeId);
      if (!ep) return;
      ep.scheduled_at = u.prevAt;
      ep.scheduled_date = u.prevDate;
      try {
        await api(`/api/podcasts/${props.slug}/episodes/${u.episodeId}`, {
          method: "PUT",
          body: { scheduled_at: u.prevAt, scheduled_date: u.prevDate },
        });
      } catch (e) {
        error.value = "No se pudo deshacer: " + (e?.message || String(e));
      }
    }

    async function _persistMove(id, ep, newAt, newDate, prevAt, prevDate) {
      dismissUndo();
      undoToast.value = { episodeId: id, title: ep.title, newDate, prevAt, prevDate };
      _undoTimer = setTimeout(dismissUndo, 14000);
      try {
        await api(`/api/podcasts/${props.slug}/episodes/${id}`, {
          method: "PUT",
          body: { scheduled_at: newAt, scheduled_date: newDate },
        });
      } catch (e) {
        dismissUndo();
        ep.scheduled_at = prevAt;
        ep.scheduled_date = prevDate;
        const detail = e?.message || String(e);
        error.value = `No pude mover el episodio: ${detail} · ` +
          `URL=/api/podcasts/${props.slug}/episodes/${id} · nueva fecha=${newAt}`;
      }
    }

    onMounted(load);
    return { eps, error, cursor, monthLabel, grid, prev, next, today, openEp, timeOf, createOnDay,
             dragging, onDragEpStart, onDragEnd, onCellDragOver, onCellDrop,
             undoToast, doUndo, dismissUndo };
  },
  template: `
    <div class="container calendar-wide">
      <div class="section">
        <div class="section-head">
          <div class="eyebrow">CALENDARIO</div>
          <h3>Programación de episodios</h3>
          <div class="spacer"></div>
          <button class="ghost" @click="prev" title="Mes anterior">‹</button>
          <button class="ghost" @click="today">hoy</button>
          <button class="ghost" @click="next" title="Mes siguiente">›</button>
          <span class="mono cal-month-label">{{ monthLabel }}</span>
          <a class="btn primary" :href="'/api/podcasts/' + slug + '/calendar.ics'" download>📥 .ics</a>
        </div>
        <p class="muted d-only" style="margin-top: -6px; font-size: 12px;">Click en un día para crear un episodio · Click en un episodio para abrirlo.</p>

        <div v-if="error" class="error">{{ error }}</div>

        <div class="cal-weekdays">
          <div v-for="d in ['Lun','Mar','Mié','Jue','Vie','Sáb','Dom']" :key="d">{{ d }}</div>
        </div>
        <div class="cal-grid">
          <div v-for="cell in grid" :key="cell.key"
               class="cal-cell"
               :class="{ blank: cell.blank, today: cell.isToday, 'drag-target': !cell.blank && dragging }"
               @click="!cell.blank && !dragging && createOnDay(cell.dateStr)"
               @dragover="onCellDragOver($event, cell)"
               @drop.prevent.stop="onCellDrop($event, cell)">
            <template v-if="!cell.blank">
              <div class="cal-day-head">
                <span class="cal-day">{{ cell.d }}</span>
                <span class="cal-add" title="Crear episodio en este día">＋</span>
              </div>
              <div v-for="ep in cell.eps" :key="ep.id"
                   class="cal-ep"
                   :class="{ dragging: dragging === ep.id }"
                   draggable="true"
                   @click.stop="openEp(ep)"
                   @dragstart="onDragEpStart(ep, $event)"
                   @dragend="onDragEnd"
                   :title="ep.title + ' (arrastra para mover de día)'">
                <span class="cal-ep-time">{{ timeOf(ep) }}</span>
                <span class="cal-ep-title">{{ ep.title }}</span>
              </div>
            </template>
          </div>
        </div>

        <div class="cal-agenda m-only">
          <div class="eyebrow">EN ESTE MES</div>
          <template v-for="cell in grid" :key="'ag' + cell.key">
            <button v-for="ep in (cell.blank ? [] : cell.eps)" :key="'a' + ep.id" class="cal-agenda-item" @click="openEp(ep)">
              <span class="ca-date"><b>{{ cell.d }}</b><small>{{ ['Dom','Lun','Mar','Mié','Jue','Vie','Sáb'][new Date(cell.dateStr + 'T12:00').getDay()] }}</small></span>
              <span class="ca-body"><span class="ca-title">{{ ep.title }}</span><span class="ca-time mono">{{ timeOf(ep) || 'sin hora' }}</span></span>
              <span class="ca-go">›</span>
            </button>
          </template>
          <div v-if="!grid.some(c => !c.blank && c.eps && c.eps.length)" class="muted ca-empty">No hay episodios programados este mes.</div>
          <p class="muted ca-hint">Toca un día del calendario para crear un episodio en esa fecha.</p>
        </div>

        <transition name="toast-fade">
          <div v-if="undoToast" class="undo-toast">
            <span>Episodio <strong>{{ undoToast.title }}</strong> movido a {{ undoToast.newDate }}</span>
            <a class="undo-link" @click.prevent="doUndo">Deshacer</a>
            <button class="undo-close" @click="dismissUndo">&times;</button>
          </div>
        </transition>
      </div>
    </div>
  `,
};

var SoundboardLibrary = {
  props: { slug: String },
  setup(props) {
    const sounds = ref([]);
    const error = ref("");
    const uploading = ref(false);
    const showLibrary = ref(false);
    const library = ref([]);
    const libraryAvailable = ref(true);
    const libraryLoading = ref(false);
    const librarySearch = ref("");
    const librarySelected = reactive({});
    const importing = ref(false);

    async function load() {
      try { sounds.value = await api(`/api/podcasts/${props.slug}/sounds`); }
      catch (e) { error.value = e.message; }
    }

    async function loadLibrary() {
      libraryLoading.value = true;
      try {
        const r = await api(`/api/sound-library`);
        library.value = r.sounds || [];
        libraryAvailable.value = !!r.available;
      } catch (e) { error.value = e.message; }
      finally { libraryLoading.value = false; }
    }

    function openLibrary() {
      showLibrary.value = true;
      Object.keys(librarySelected).forEach(k => delete librarySelected[k]);
      if (library.value.length === 0) loadLibrary();
    }

    const filteredLibrary = computed(() => {
      const q = librarySearch.value.trim().toLowerCase();
      const owned = new Set(sounds.value.map(s => s.name.toLowerCase()));
      return library.value
        .filter(s => !q || s.name.toLowerCase().includes(q) || s.filename.toLowerCase().includes(q))
        .map(s => ({ ...s, alreadyOwned: owned.has(s.name.toLowerCase()) }));
    });

    const selectedCount = computed(() => Object.values(librarySelected).filter(Boolean).length);

    async function importSelected() {
      const filenames = Object.keys(librarySelected).filter(k => librarySelected[k]);
      if (filenames.length === 0) return;
      importing.value = true; error.value = "";
      try {
        await api(`/api/podcasts/${props.slug}/sounds/import`, {
          method: "POST", body: { filenames },
        });
        await load();
        showLibrary.value = false;
      } catch (e) { error.value = e.message; }
      finally { importing.value = false; }
    }

    async function upload(ev) {
      const f = ev.target.files?.[0];
      if (!f) return;
      uploading.value = true; error.value = "";
      try {
        const form = new FormData();
        form.append("file", f);
        form.append("name", f.name.replace(/\.[^.]+$/, ""));
        await apiUpload(`/api/podcasts/${props.slug}/sounds`, form);
        await load();
      } catch (e) { error.value = e.message; }
      finally { uploading.value = false; ev.target.value = ""; }
    }

    async function remove(s) {
      if (!await podSwal.confirm(`¿Eliminar "${s.name}"?`)) return;
      try {
        await api(`/api/podcasts/${props.slug}/sounds/${s.id}`, { method: "DELETE" });
        sounds.value = sounds.value.filter(x => x.id !== s.id);
      } catch (e) { error.value = e.message; }
    }

    const _savers = new Map();
    function save(s) {
      let fn = _savers.get(s.id);
      if (!fn) {
        fn = debounce(async () => {
          try {
            await api(`/api/podcasts/${props.slug}/sounds/${s.id}`, {
              method: "PUT",
              body: { name: s.name, shortcut_key: s.shortcut_key, color: s.color },
            });
          } catch (e) { error.value = e.message; }
        }, 500);
        _savers.set(s.id, fn);
      }
      fn();
    }

    function preview(url) {
      const a = new Audio(url);
      a.volume = 0.7;
      a.play().catch(() => {});
    }

    onMounted(load);
    return {
      sounds, error, uploading, upload, remove, save, preview,
      showLibrary, library, libraryAvailable, libraryLoading, librarySearch,
      librarySelected, filteredLibrary, selectedCount, importing,
      openLibrary, importSelected,
    };
  },
  template: `
    <div class="container">
      <div class="section">
        <div class="section-head">
          <div class="eyebrow">SOUNDBOARD</div>
          <h3>Biblioteca de sonidos del podcast</h3>
          <div class="spacer"></div>
          <button class="ghost" @click="openLibrary" title="Elegir desde la biblioteca compartida">📚 Biblioteca</button>
          <label class="btn primary" :class="{ disabled: uploading }">
            {{ uploading ? "Subiendo…" : "＋ Subir sonido" }}
            <input type="file" accept="audio/*" @change="upload" style="display: none;">
          </label>
        </div>
        <p class="muted" style="margin-top: -6px;">Estos sonidos se cargarán automáticamente en prodPod cuando envíes un episodio para grabar.</p>
        <div v-if="error" class="error">{{ error }}</div>

        <div v-if="sounds.length === 0" class="empty-pill" style="margin-top: 12px;">Sin sonidos. Importa de la biblioteca o sube uno propio.</div>
        <div v-else class="sound-grid" style="margin-top: 12px;">
          <div v-for="s in sounds" :key="s.id" class="sound-card" :style="s.color ? { borderLeftColor: s.color } : {}">
            <button class="icon ghost" @click="preview(s.url)" title="Reproducir">▶</button>
            <input type="text" class="sound-name" v-model="s.name" @input="save(s)" placeholder="Nombre">
            <input type="text" class="sound-key" v-model="s.shortcut_key" @input="save(s)" maxlength="1" placeholder="tecla">
            <input type="color" v-model="s.color" @input="save(s)" title="Color">
            <button class="icon danger" @click="remove(s)" title="Eliminar">✕</button>
          </div>
        </div>
      </div>

      <div v-if="showLibrary" class="modal-backdrop" @click.self="showLibrary = false">
        <div class="modal sound-library-modal">
          <div class="modal-head">
            <h3>📚 Biblioteca compartida</h3>
            <button class="icon ghost" @click="showLibrary = false" title="Cerrar">✕</button>
          </div>
          <div class="modal-body">
            <div v-if="!libraryAvailable && !libraryLoading" class="empty-pill">
              No hay biblioteca compartida disponible en este servidor.
            </div>
            <template v-else>
              <input type="text" v-model="librarySearch" placeholder="Buscar por nombre…" class="library-search">
              <div v-if="libraryLoading" class="muted">Cargando biblioteca…</div>
              <div v-else class="library-grid">
                <label v-for="s in filteredLibrary" :key="s.filename" class="library-item" :class="{ owned: s.alreadyOwned }">
                  <input type="checkbox" v-model="librarySelected[s.filename]" :disabled="s.alreadyOwned">
                  <button class="icon ghost" @click.prevent="preview(s.url)" title="Escuchar">▶</button>
                  <span class="lib-name">{{ s.name }}</span>
                  <span v-if="s.alreadyOwned" class="lib-tag">ya en tu lista</span>
                  <span v-else class="lib-size">{{ Math.round(s.size_bytes / 1024) }} KB</span>
                </label>
              </div>
            </template>
          </div>
          <div class="modal-footer">
            <span class="muted">{{ selectedCount }} seleccionado(s)</span>
            <div class="spacer"></div>
            <button class="ghost" @click="showLibrary = false">Cancelar</button>
            <button class="primary" :disabled="selectedCount === 0 || importing" @click="importSelected">
              {{ importing ? "Importando…" : "＋ Agregar a mi podcast" }}
            </button>
          </div>
        </div>
      </div>
    </div>
  `,
};

/* ==========================================================================
   Show templates: define a recurring format once (rundown blocks + base
   script sections), and reuse it on every new episode. Multiple templates
   per podcast; one is marked default.
   ========================================================================== */

var TemplatesPanel = {
  props: { slug: String },
  setup(props) {
    const templates = ref([]);
    const error = ref("");
    const editingId = ref(null);  // null = list view; number = editing that template
    const blocks = ref([]);
    const sections = ref([]);
    const dragging = ref(null);

    const editing = computed(() =>
      templates.value.find(t => t.id === editingId.value) || null
    );

    async function loadList() {
      try { templates.value = await api(`/api/podcasts/${props.slug}/templates`); }
      catch (e) { error.value = e.message; }
    }

    async function loadDetail(tid) {
      try {
        const detail = await api(`/api/podcasts/${props.slug}/templates/${tid}`);
        blocks.value = detail.blocks || [];
        sections.value = detail.sections || [];
        // Refresh card data so name/desc/default reflect server state.
        const idx = templates.value.findIndex(t => t.id === tid);
        if (idx >= 0) {
          templates.value[idx] = {
            ...templates.value[idx],
            name: detail.name,
            description: detail.description,
            is_default: detail.is_default,
          };
        }
      } catch (e) { error.value = e.message; }
    }

    async function createTemplate() {
      const name = await podSwal.prompt("Nombre de la plantilla (ej: Semanal)", "");
      if (!name || !name.trim()) return;
      try {
        const created = await api(`/api/podcasts/${props.slug}/templates`, {
          method: "POST", body: { name: name.trim() },
        });
        // If this is the first one, server forced default=1 — surface that
        // by reloading the full list (cheaper than reasoning locally).
        await loadList();
        editingId.value = created.id;
        await loadDetail(created.id);
      } catch (e) { error.value = e.message; }
    }

    async function renameTemplate(t) {
      const name = await podSwal.prompt("Nuevo nombre", t.name);
      if (!name || !name.trim()) return;
      try {
        await api(`/api/podcasts/${props.slug}/templates/${t.id}`, {
          method: "PATCH", body: { name: name.trim() },
        });
        t.name = name.trim();
      } catch (e) { error.value = e.message; }
    }

    async function setDefault(t) {
      if (t.is_default) return;
      try {
        await api(`/api/podcasts/${props.slug}/templates/${t.id}`, {
          method: "PATCH", body: { is_default: true },
        });
        templates.value.forEach(x => { x.is_default = x.id === t.id; });
      } catch (e) { error.value = e.message; }
    }

    async function deleteTemplate(t) {
      if (!await podSwal.confirm(`¿Eliminar "${t.name}"? Los episodios ya creados a partir de ella no se afectan.`)) return;
      try {
        await api(`/api/podcasts/${props.slug}/templates/${t.id}`, { method: "DELETE" });
        // Server may auto-promote another template to default; just reload.
        await loadList();
        if (editingId.value === t.id) editingId.value = null;
      } catch (e) { error.value = e.message; }
    }

    /* ---- description (simple debounced save) ---- */
    const _descSavers = new Map();
    function saveDescription(t) {
      let fn = _descSavers.get(t.id);
      if (!fn) {
        fn = debounce(async () => {
          try {
            await api(`/api/podcasts/${props.slug}/templates/${t.id}`, {
              method: "PATCH", body: { description: t.description || "" },
            });
          } catch (e) { error.value = e.message; }
        }, 500);
        _descSavers.set(t.id, fn);
      }
      fn();
    }

    /* ---- block CRUD ---- */
    async function addBlock() {
      try {
        const created = await api(
          `/api/podcasts/${props.slug}/templates/${editingId.value}/blocks`,
          { method: "POST", body: { kind: "segment", title: "Nuevo bloque" } },
        );
        blocks.value.push(created);
      } catch (e) { error.value = e.message; }
    }
    async function removeBlock(b) {
      if (!await podSwal.confirm(`¿Eliminar "${b.title || b.kind}"?`)) return;
      try {
        await api(`/api/podcasts/${props.slug}/template-blocks/${b.id}`, { method: "DELETE" });
        blocks.value = blocks.value.filter(x => x.id !== b.id);
      } catch (e) { error.value = e.message; }
    }
    const _blockSavers = new Map();
    function saveBlock(b) {
      let fn = _blockSavers.get(b.id);
      if (!fn) {
        fn = debounce(async () => {
          try {
            await api(`/api/podcasts/${props.slug}/template-blocks/${b.id}`, {
              method: "PUT",
              body: { kind: b.kind, title: b.title, duration_estimate: b.duration_estimate, notes: b.notes },
            });
          } catch (e) { error.value = e.message; }
        }, 500);
        _blockSavers.set(b.id, fn);
      }
      fn();
    }
    function onBlockDragStart(b) { dragging.value = b.id; }
    function onBlockDragEnd()    { dragging.value = null; }
    function onBlockDragOver(ev) { ev.preventDefault(); }
    async function onBlockDrop(target) {
      const fromId = dragging.value;
      dragging.value = null;
      if (!fromId || fromId === target.id) return;
      const ids = blocks.value.map(b => b.id);
      const fromIdx = ids.indexOf(fromId);
      const toIdx = ids.indexOf(target.id);
      if (fromIdx < 0 || toIdx < 0) return;
      ids.splice(toIdx, 0, ids.splice(fromIdx, 1)[0]);
      blocks.value = ids.map(id => blocks.value.find(b => b.id === id));
      try {
        const updated = await api(
          `/api/podcasts/${props.slug}/templates/${editingId.value}/blocks/reorder`,
          { method: "POST", body: { order: ids } },
        );
        blocks.value = updated;
      } catch (e) { error.value = e.message; await loadDetail(editingId.value); }
    }

    /* ---- section CRUD ---- */
    async function addSection() {
      try {
        const created = await api(
          `/api/podcasts/${props.slug}/templates/${editingId.value}/sections`,
          { method: "POST", body: { speaker: "Host", content: "" } },
        );
        sections.value.push(created);
      } catch (e) { error.value = e.message; }
    }
    async function removeSection(sec) {
      if (!await podSwal.confirm("¿Eliminar sección?")) return;
      try {
        await api(`/api/podcasts/${props.slug}/template-sections/${sec.id}`, { method: "DELETE" });
        await loadDetail(editingId.value);
      } catch (e) { error.value = e.message; }
    }
    async function moveSection(sec, delta) {
      const newPos = sec.position + delta;
      if (newPos < 0 || newPos >= sections.value.length) return;
      try {
        await api(`/api/podcasts/${props.slug}/template-sections/${sec.id}`, {
          method: "PUT", body: { position: newPos },
        });
        await loadDetail(editingId.value);
      } catch (e) { error.value = e.message; }
    }
    const _secSavers = new Map();
    function saveSection(sec) {
      let fn = _secSavers.get(sec.id);
      if (!fn) {
        fn = debounce(async () => {
          try {
            await api(`/api/podcasts/${props.slug}/template-sections/${sec.id}`, {
              method: "PUT",
              body: {
                speaker: sec.speaker, content: sec.content,
                estimated_duration: sec.estimated_duration, notes: sec.notes,
              },
            });
          } catch (e) { error.value = e.message; }
        }, 500);
        _secSavers.set(sec.id, fn);
      }
      fn();
    }

    function openEdit(t)  { editingId.value = t.id; loadDetail(t.id); }
    function closeEdit()  { editingId.value = null; blocks.value = []; sections.value = []; }

    function kindLabel(k) {
      return (BLOCK_KINDS.find(x => x.value === k) || { label: k }).label;
    }
    const totalMin = computed(() =>
      blocks.value.reduce((acc, b) => acc + (parseFloat(b.duration_estimate) || 0), 0)
    );

    onMounted(loadList);
    return {
      templates, error, editing, editingId, blocks, sections, dragging,
      kinds: BLOCK_KINDS, kindLabel, totalMin, fmtMin,
      createTemplate, renameTemplate, setDefault, deleteTemplate, saveDescription,
      addBlock, removeBlock, saveBlock,
      onBlockDragStart, onBlockDragEnd, onBlockDragOver, onBlockDrop,
      addSection, removeSection, moveSection, saveSection,
      openEdit, closeEdit,
    };
  },
  template: `
    <div>
      <div v-if="error" class="error">{{ error }}</div>

      <!-- LIST VIEW -->
      <div v-if="!editing">
        <div class="section-head">
          <div class="eyebrow">PLANTILLAS</div>
          <h3>Formatos recurrentes</h3>
          <div class="spacer"></div>
          <button class="primary" @click="createTemplate">＋ Nueva plantilla</button>
        </div>

        <p class="muted" style="margin: 6px 0 16px;">
          Define el formato de tu show una vez (rundown + guion base). Los episodios nuevos heredan automáticamente la plantilla marcada como predeterminada.
        </p>

        <div v-if="templates.length === 0" class="empty-pill">
          Aún no hay plantillas. Crea una para arrancar.
        </div>

        <div v-else class="cards-grid" style="display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 14px;">
          <div v-for="t in templates" :key="t.id"
               class="tpl-card"
               style="background: var(--ink-sunken, #1a1a1a); border: 1px solid var(--ink-line, #333); border-radius: 12px; padding: 14px; display: flex; flex-direction: column; gap: 8px;">
            <div style="display: flex; align-items: center; gap: 8px;">
              <strong style="font-size: 15px; flex: 1;">{{ t.name }}</strong>
              <span v-if="t.is_default"
                    style="font-size: 10px; padding: 2px 8px; border-radius: 999px; background: var(--accent, #f4c770); color: #000; font-weight: 600;">DEFAULT</span>
            </div>
            <div class="muted" style="font-size: 12px; line-height: 1.4;">
              {{ t.description || "(sin descripción)" }}
            </div>
            <div class="muted mono" style="font-size: 11px;">
              {{ t.block_count || 0 }} bloque(s) · {{ t.section_count || 0 }} sección(es)
            </div>
            <div style="display: flex; gap: 6px; margin-top: 4px; flex-wrap: wrap;">
              <button class="ghost" style="font-size: 12px; padding: 4px 10px;" @click="openEdit(t)">Editar</button>
              <button v-if="!t.is_default" class="ghost" style="font-size: 12px; padding: 4px 10px;" @click="setDefault(t)">Hacer default</button>
              <button class="ghost" style="font-size: 12px; padding: 4px 10px;" @click="renameTemplate(t)">Renombrar</button>
              <button class="icon danger" @click="deleteTemplate(t)" title="Eliminar">✕</button>
            </div>
          </div>
        </div>
      </div>

      <!-- EDIT VIEW -->
      <div v-else>
        <div class="section-head">
          <button class="ghost" @click="closeEdit">← Plantillas</button>
          <h3 style="margin-left: 8px;">{{ editing.name }}</h3>
          <span v-if="editing.is_default"
                style="font-size: 10px; padding: 2px 8px; border-radius: 999px; background: var(--accent, #f4c770); color: #000; font-weight: 600; margin-left: 6px;">DEFAULT</span>
          <div class="spacer"></div>
        </div>

        <div class="form-row" style="margin-bottom: 18px;">
          <label>Descripción</label>
          <textarea rows="2" v-model="editing.description" @input="saveDescription(editing)" placeholder="Para qué sirve esta plantilla..."></textarea>
        </div>

        <!-- Rundown -->
        <div class="section-head">
          <div class="eyebrow">RUNDOWN BASE</div>
          <div class="spacer"></div>
          <span class="total mono">TOTAL {{ fmtMin(totalMin) }}</span>
          <button @click="addBlock">＋ Bloque</button>
        </div>
        <div v-if="blocks.length === 0" class="empty-pill" style="margin-bottom: 24px;">Sin bloques. Arma la estructura: intro → segmentos → outro.</div>
        <div v-else class="rundown-list" style="margin-bottom: 24px;">
          <div v-for="(b, idx) in blocks" :key="b.id"
               class="rundown-block" :class="['kind-' + b.kind, { dragging: dragging === b.id }]"
               draggable="true"
               @dragstart="onBlockDragStart(b)" @dragend="onBlockDragEnd"
               @dragover="onBlockDragOver" @drop="onBlockDrop(b)">
            <span class="rb-handle" title="Arrastra para reordenar">⋮⋮</span>
            <span class="rb-pos">#{{ idx + 1 }}</span>
            <select v-model="b.kind" @change="saveBlock(b)" class="rb-kind">
              <option v-for="k in kinds" :key="k.value" :value="k.value">{{ k.label }}</option>
            </select>
            <input type="text" v-model="b.title" @input="saveBlock(b)" placeholder="Título del bloque" class="rb-title">
            <input type="number" v-model.number="b.duration_estimate" @input="saveBlock(b)" min="0" step="0.5" placeholder="min" class="rb-dur">
            <input type="text" v-model="b.notes" @input="saveBlock(b)" placeholder="Notas (opcional)" class="rb-notes">
            <button class="icon danger" @click="removeBlock(b)" title="Eliminar">✕</button>
          </div>
        </div>

        <!-- Script base -->
        <div class="script-head">
          <div class="eyebrow">GUIÓN BASE</div>
          <div class="spacer"></div>
          <button @click="addSection">＋ Sección</button>
        </div>
        <div v-if="sections.length === 0" class="empty-pill">Sin secciones de guion base.</div>
        <div v-else class="script-sections">
          <div v-for="(sec, idx) in sections" :key="sec.id" class="script-sec">
            <div class="sec-head">
              <span class="pos-tag">#{{ idx + 1 }}</span>
              <input type="text" class="speaker-input" v-model="sec.speaker" placeholder="Speaker" @input="saveSection(sec)">
              <div class="spacer"></div>
              <span class="sec-actions">
                <button class="icon ghost" @click="moveSection(sec, -1)" :disabled="idx === 0" title="Mover arriba">▲</button>
                <button class="icon ghost" @click="moveSection(sec, 1)" :disabled="idx === sections.length - 1" title="Mover abajo">▼</button>
                <button class="icon danger" @click="removeSection(sec)" title="Eliminar">✕</button>
              </span>
            </div>
            <textarea v-model="sec.content" @input="saveSection(sec)" placeholder="Texto base..."></textarea>
            <div class="notes-row">
              <input type="text" v-model="sec.notes" @input="saveSection(sec)" placeholder="Notas (timings, direcciones)...">
              <input type="number" class="dur-input" v-model.number="sec.estimated_duration" @input="saveSection(sec)" min="0" step="1" placeholder="seg">
            </div>
          </div>
        </div>
      </div>
    </div>
  `,
};

/* ==========================================================================
   Sponsors panel: podcast-level sponsor records used to populate
   ad-read blocks in the rundown. Each sponsor surfaces a small report
   with the episodes that referenced it.
   ========================================================================== */

var SponsorReportModal = {
  props: { show: Boolean, slug: String, sponsor: Object },
  emits: ["close"],
  setup(props) {
    const data = ref(null);
    const loading = ref(false);
    const error = ref("");

    async function load() {
      if (!props.sponsor) return;
      loading.value = true;
      error.value = "";
      try {
        data.value = await api(`/api/podcasts/${props.slug}/sponsors/${props.sponsor.id}/report`);
      } catch (e) {
        error.value = e.message;
      } finally {
        loading.value = false;
      }
    }

    watch(() => [props.show, props.sponsor && props.sponsor.id],
          ([s]) => { if (s) load(); }, { immediate: true });

    const csvUrl = computed(() => props.sponsor
      ? `/api/podcasts/${props.slug}/sponsors/${props.sponsor.id}/report.csv`
      : null
    );

    return { data, loading, error, csvUrl };
  },
  template: `
    <div v-if="show" class="modal-backdrop" @click.self="$emit('close')">
      <div class="modal" style="max-width: 760px;">
        <div class="eyebrow">REPORTE</div>
        <h3>{{ sponsor ? sponsor.name : "" }}</h3>

        <div v-if="error" class="error">{{ error }}</div>
        <div v-if="loading" class="muted">Cargando…</div>

        <template v-else-if="data">
          <div class="row" style="gap: 16px; margin: 8px 0 16px; flex-wrap: wrap;">
            <div><span class="eyebrow">Episodios</span><br><strong style="font-size: 22px;">{{ data.totals.episodes }}</strong></div>
            <div><span class="eyebrow">Bloques</span><br><strong style="font-size: 22px;">{{ data.totals.blocks }}</strong></div>
            <div><span class="eyebrow">Min. estimados</span><br><strong style="font-size: 22px;">{{ data.totals.duration_minutes_estimated }}</strong></div>
            <div class="spacer"></div>
            <a v-if="csvUrl" :href="csvUrl" class="ghost" style="align-self: center; padding: 8px 14px; text-decoration: none;">↓ CSV para anunciante</a>
          </div>

          <div v-if="data.episodes.length === 0" class="empty-pill">
            Aún no hay bloques de rundown que referencien a este sponsor.
          </div>
          <div v-else style="max-height: 360px; overflow-y: auto;">
            <table style="width: 100%; border-collapse: collapse; font-size: 13px;">
              <thead>
                <tr style="text-align: left; opacity: 0.75;">
                  <th style="padding: 6px 8px;">#</th>
                  <th style="padding: 6px 8px;">Episodio</th>
                  <th style="padding: 6px 8px;">Estado</th>
                  <th style="padding: 6px 8px;">Fecha</th>
                  <th style="padding: 6px 8px;">Bloque</th>
                  <th style="padding: 6px 8px; text-align: right;">Min</th>
                </tr>
              </thead>
              <tbody>
                <tr v-for="ep in data.episodes" :key="ep.block_id" style="border-top: 1px solid var(--ink-line);">
                  <td style="padding: 6px 8px;" class="mono">{{ ep.episode_number || "—" }}</td>
                  <td style="padding: 6px 8px;">{{ ep.title }}</td>
                  <td style="padding: 6px 8px;">{{ ep.status }}</td>
                  <td style="padding: 6px 8px;" class="mono">{{ (ep.scheduled_at || ep.scheduled_date || "").replace("T", " ") }}</td>
                  <td style="padding: 6px 8px;">{{ ep.block_title || "(sin título)" }}</td>
                  <td style="padding: 6px 8px; text-align: right;" class="mono">{{ ep.duration_estimate_min || "—" }}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </template>

        <div class="row right" style="margin-top: 18px; gap: 8px;">
          <button class="primary" @click="$emit('close')">Cerrar</button>
        </div>
      </div>
    </div>
  `,
};

var SponsorsPanel = {
  components: { SponsorReportModal },
  props: { slug: String },
  setup(props) {
    const sponsors = ref([]);
    const error = ref("");
    const reportFor = ref(null);
    const showReport = ref(false);

    async function load() {
      try { sponsors.value = await api(`/api/podcasts/${props.slug}/sponsors`); }
      catch (e) { error.value = e.message; }
    }

    async function createSponsor() {
      const name = await podSwal.prompt("Nombre del sponsor", "");
      if (!name || !name.trim()) return;
      try {
        const created = await api(`/api/podcasts/${props.slug}/sponsors`, {
          method: "POST", body: { name: name.trim() },
        });
        sponsors.value.push(created);
      } catch (e) { error.value = e.message; }
    }

    async function deleteSponsor(s) {
      if (!await podSwal.confirm(`¿Eliminar "${s.name}"? Los bloques que lo referencian quedarán sin sponsor (no se borran).`)) return;
      try {
        await api(`/api/podcasts/${props.slug}/sponsors/${s.id}`, { method: "DELETE" });
        sponsors.value = sponsors.value.filter(x => x.id !== s.id);
      } catch (e) { error.value = e.message; }
    }

    const _savers = new Map();
    function saveSponsor(s) {
      let fn = _savers.get(s.id);
      if (!fn) {
        fn = debounce(async () => {
          try {
            await api(`/api/podcasts/${props.slug}/sponsors/${s.id}`, {
              method: "PATCH",
              body: { name: s.name, copy: s.copy, url: s.url, notes: s.notes, is_active: s.is_active },
            });
          } catch (e) { error.value = e.message; }
        }, 500);
        _savers.set(s.id, fn);
      }
      fn();
    }

    async function uploadLogo(s, ev) {
      var file = ev.target.files && ev.target.files[0];
      if (!file) return;
      var fd = new FormData();
      fd.append("logo", file);
      try {
        var updated = await fetch("/api/podcasts/" + props.slug + "/sponsors/" + s.id + "/logo", {
          method: "POST", body: fd, credentials: "same-origin",
        }).then(function (r) { return r.json(); });
        if (updated.error) { error.value = updated.error; return; }
        s.logo_filename = updated.logo_filename;
        s.logo_url = updated.logo_url;
      } catch (e) { error.value = e.message; }
      ev.target.value = "";
    }

    async function removeLogo(s) {
      try {
        await api("/api/podcasts/" + props.slug + "/sponsors/" + s.id + "/logo", { method: "DELETE" });
        s.logo_filename = "";
        s.logo_url = "";
      } catch (e) { error.value = e.message; }
    }

    function openReport(s) { reportFor.value = s; showReport.value = true; }
    function closeReport() { showReport.value = false; }

    onMounted(load);
    return {
      sponsors, error, reportFor, showReport,
      createSponsor, deleteSponsor, saveSponsor, uploadLogo, removeLogo, openReport, closeReport,
    };
  },
  template: `
    <div>
      <div v-if="error" class="error">{{ error }}</div>

      <div class="section-head">
        <div class="eyebrow">SPONSORS</div>
        <h3>Anunciantes y ad-reads</h3>
        <div class="spacer"></div>
        <button class="primary" @click="createSponsor">＋ Nuevo sponsor</button>
      </div>

      <p class="muted" style="margin: 6px 0 16px;">
        Define un sponsor una vez (copy + URL). Después, en el rundown, los bloques con tipo "Sponsor" pueden enlazarse a este registro. El reporte cuenta cuántos episodios lo incluyeron.
      </p>

      <div v-if="sponsors.length === 0" class="empty-pill">Aún no hay sponsors.</div>

      <div v-else class="cards-grid" style="display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 14px;">
        <div v-for="s in sponsors" :key="s.id" class="tpl-card"
             :style="{
               background: 'var(--ink-sunken, #1a1a1a)',
               border: '1px solid var(--ink-line, #333)',
               borderRadius: '12px', padding: '14px',
               display: 'flex', flexDirection: 'column', gap: '8px',
               opacity: s.is_active ? 1 : 0.55,
             }">
          <div style="display: flex; align-items: center; gap: 10px;">
            <div v-if="s.logo_url" style="position: relative; flex-shrink: 0;">
              <img :src="s.logo_url" style="width: 48px; height: 48px; object-fit: contain; border-radius: 6px; background: rgba(255,255,255,0.08);">
              <button class="icon danger" @click="removeLogo(s)" title="Quitar logo" style="position: absolute; top: -6px; right: -6px; font-size: 10px; width: 18px; height: 18px; padding: 0; line-height: 18px;">✕</button>
            </div>
            <label v-else class="ghost" style="font-size: 11px; padding: 4px 8px; cursor: pointer; flex-shrink: 0;">
              🖼 Logo
              <input type="file" accept="image/*" @change="uploadLogo(s, $event)" style="display: none;">
            </label>
            <input type="text" v-model="s.name" @input="saveSponsor(s)" style="flex: 1; font-size: 15px; font-weight: 600; background: transparent; border: 0; padding: 0; color: inherit;">
            <span v-if="!s.is_active" class="pill" style="font-size: 10px; padding: 2px 8px; border-radius: 999px; background: rgba(255,255,255,0.12); color: rgba(255,255,255,0.75);">PAUSADO</span>
          </div>
          <input type="text" v-model="s.url" @input="saveSponsor(s)" placeholder="https://…" style="font-size: 12px; background: transparent; border: 0; padding: 0; color: var(--signal); border-bottom: 1px dashed var(--ink-line);">
          <textarea v-model="s.copy" @input="saveSponsor(s)" rows="3" placeholder="Copy del ad-read (teleprompter)..." style="font-size: 13px; padding: 8px; border-radius: 6px;"></textarea>
          <input type="text" v-model="s.notes" @input="saveSponsor(s)" placeholder="Notas internas (opcional)" style="font-size: 12px;">
          <div class="muted mono" style="font-size: 11px;">{{ s.episode_count || 0 }} episodio(s)</div>
          <div style="display: flex; gap: 6px; flex-wrap: wrap;">
            <button class="ghost" style="font-size: 12px; padding: 4px 10px;" @click="openReport(s)">📊 Reporte</button>
            <label v-if="s.logo_url" class="ghost" style="font-size: 12px; padding: 4px 10px; cursor: pointer;">
              🖼 Cambiar logo
              <input type="file" accept="image/*" @change="uploadLogo(s, $event)" style="display: none;">
            </label>
            <label style="display: flex; align-items: center; gap: 4px; font-size: 12px;">
              <input type="checkbox" :checked="s.is_active" @change="s.is_active = $event.target.checked; saveSponsor(s)">
              Activo
            </label>
            <div class="spacer"></div>
            <button class="icon danger" @click="deleteSponsor(s)" title="Eliminar">✕</button>
          </div>
        </div>
      </div>

      <SponsorReportModal :show="showReport" :slug="slug" :sponsor="reportFor" @close="closeReport" />
    </div>
  `,
};


/* ==========================================================================
   Exports panel — browse/download/delete files generated in postPod
   ========================================================================== */

var ExportsPanel = {
  props: { slug: String },
  setup(props) {
    const exports_ = ref([]);
    const loading = ref(false);
    const error = ref("");

    async function load() {
      loading.value = true;
      error.value = "";
      try {
        exports_.value = await api(`/api/podcasts/${props.slug}/exports`);
      } catch (e) { error.value = e.message; }
      finally { loading.value = false; }
    }

    async function deleteExport(job) {
      if (!confirm(`¿Eliminar export #${job.id} (${job.preset_id})? El archivo se borrará del servidor.`)) return;
      try {
        await api(`/api/podcasts/${props.slug}/exports/${job.id}`, { method: "DELETE" });
        exports_.value = exports_.value.filter(e => e.id !== job.id);
      } catch (e) { error.value = e.message; }
    }

    function fmtSize(bytes) {
      if (!bytes) return "—";
      if (bytes < 1024) return bytes + " B";
      if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + " KB";
      return (bytes / (1024 * 1024)).toFixed(1) + " MB";
    }

    function fmtDate(d) {
      if (!d) return "—";
      return d.replace("T", " ").slice(0, 16);
    }

    onMounted(load);

    return { exports: exports_, loading, error, load, deleteExport, fmtSize, fmtDate };
  },
  template: `
    <div style="padding: 20px;">
      <div class="row" style="align-items: center; margin-bottom: 12px;">
        <h3 style="margin: 0;">Archivos generados</h3>
        <div class="spacer"></div>
        <button class="ghost" @click="load" :disabled="loading">{{ loading ? 'Cargando…' : 'Actualizar' }}</button>
      </div>

      <div v-if="error" class="error" style="margin-bottom: 10px;">{{ error }}</div>

      <div v-if="!loading && exports.length === 0" class="empty-pill">
        No hay archivos generados. Los renders se crean desde postPod al exportar un episodio.
      </div>

      <table v-else class="exports-table" style="width: 100%; border-collapse: collapse; font-size: 13px;">
        <thead>
          <tr>
            <th style="text-align: left; padding: 6px 8px; border-bottom: 1px solid var(--ink-line); font-size: 11px; text-transform: uppercase; letter-spacing: 0.06em; color: var(--paper-dim);">#</th>
            <th style="text-align: left; padding: 6px 8px; border-bottom: 1px solid var(--ink-line); font-size: 11px; text-transform: uppercase; letter-spacing: 0.06em; color: var(--paper-dim);">Preset</th>
            <th style="text-align: left; padding: 6px 8px; border-bottom: 1px solid var(--ink-line); font-size: 11px; text-transform: uppercase; letter-spacing: 0.06em; color: var(--paper-dim);">Estado</th>
            <th style="text-align: right; padding: 6px 8px; border-bottom: 1px solid var(--ink-line); font-size: 11px; text-transform: uppercase; letter-spacing: 0.06em; color: var(--paper-dim);">Peso</th>
            <th style="text-align: left; padding: 6px 8px; border-bottom: 1px solid var(--ink-line); font-size: 11px; text-transform: uppercase; letter-spacing: 0.06em; color: var(--paper-dim);">Fecha</th>
            <th style="text-align: right; padding: 6px 8px; border-bottom: 1px solid var(--ink-line);"></th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="ex in exports" :key="ex.id" style="border-bottom: 1px solid var(--ink-line-2);">
            <td style="padding: 5px 8px; font-family: var(--font-mono); font-size: 11px; color: var(--paper-dim);">{{ ex.id }}</td>
            <td style="padding: 5px 8px; font-family: var(--font-mono); font-size: 11px;">{{ ex.preset_id }}</td>
            <td style="padding: 5px 8px;">
              <span :style="{
                color: ex.status === 'done' ? 'var(--signal-cool)' :
                       ex.status === 'error' ? 'var(--signal-hot)' :
                       ex.status === 'running' ? 'var(--signal)' : 'var(--paper-dim)',
                fontSize: '11px', fontFamily: 'var(--font-mono)'
              }">{{ ex.status }}</span>
            </td>
            <td style="padding: 5px 8px; text-align: right; font-family: var(--font-mono); font-size: 11px;">{{ fmtSize(ex.size_bytes) }}</td>
            <td style="padding: 5px 8px; font-size: 11px; color: var(--paper-dim);">{{ fmtDate(ex.created_at) }}</td>
            <td style="padding: 5px 8px; text-align: right; white-space: nowrap;">
              <a v-if="ex.status === 'done' && ex.output_file"
                 :href="'/api/podcasts/' + slug + '/exports/' + ex.id + '/download'"
                 class="kbd" style="text-decoration: none; font-size: 10px; padding: 3px 8px; margin-right: 4px;">
                Descargar
              </a>
              <button v-if="ex.status !== 'running' && ex.status !== 'pending'"
                      class="ghost danger" style="font-size: 10px; padding: 2px 8px;"
                      @click="deleteExport(ex)">
                Eliminar
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  `,
};


/* ==========================================================================
   Distribution Panel
   ========================================================================== */

var DistributionPanel = {
  props: { slug: String },
  setup(props) {
    const data = ref(null);
    const loading = ref(true);
    const error = ref("");
    const checking = ref("");
    const youtube = ref(null);
    const ytConnecting = ref(false);

    async function load() {
      loading.value = true;
      error.value = "";
      try {
        data.value = await api(`/api/podcasts/${props.slug}/distribution`);
        const ytStatus = await api(`/api/youtube/status?slug=${props.slug}`);
        youtube.value = ytStatus;
      } catch (e) { error.value = e.message; }
      finally { loading.value = false; }
    }

    async function markSubmitted(platform) {
      try {
        await api(`/api/podcasts/${props.slug}/distribution`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ platform, status: "pending" }),
        });
        await load();
      } catch (e) { error.value = e.message; }
    }

    async function markConnected(platform, url) {
      try {
        await api(`/api/podcasts/${props.slug}/distribution`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ platform, status: "connected", external_url: url || "" }),
        });
        await load();
      } catch (e) { error.value = e.message; }
    }

    async function checkLive(platform) {
      checking.value = platform;
      try {
        const res = await api(`/api/podcasts/${props.slug}/distribution/check`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ platform }),
        });
        if (res.found) {
          await load();
        } else {
          error.value = `No se encontró el podcast en ${platform === "apple" ? "Apple Podcasts" : "Spotify"} todavía. Puede tardar entre 24-72 horas.`;
        }
      } catch (e) { error.value = e.message; }
      finally { checking.value = ""; }
    }

    async function resetPlatform(platform) {
      if (!confirm("¿Resetear la conexión de esta plataforma?")) return;
      try {
        await api(`/api/podcasts/${props.slug}/distribution/${platform}`, { method: "DELETE" });
        await load();
      } catch (e) { error.value = e.message; }
    }

    async function connectYoutube() {
      ytConnecting.value = true;
      try {
        const res = await api(`/api/youtube/auth-url?slug=${props.slug}`);
        if (res.auth_url) {
          const popup = window.open(res.auth_url, "youtube-auth", "width=600,height=700");
          const handler = (ev) => {
            if (ev.data === "youtube-connected") {
              window.removeEventListener("message", handler);
              load();
            }
          };
          window.addEventListener("message", handler);
          const interval = setInterval(() => {
            if (popup && popup.closed) {
              clearInterval(interval);
              window.removeEventListener("message", handler);
              ytConnecting.value = false;
              load();
            }
          }, 1000);
        }
      } catch (e) { error.value = e.message; ytConnecting.value = false; }
    }

    async function disconnectYoutube() {
      if (!confirm("¿Desconectar YouTube de este podcast?")) return;
      try {
        await api("/api/youtube/disconnect", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ slug: props.slug }),
        });
        youtube.value = { connected: false };
      } catch (e) { error.value = e.message; }
    }

    function copyFeed() {
      if (data.value && data.value.feed_url) {
        navigator.clipboard.writeText(data.value.feed_url);
      }
    }

    onMounted(load);

    return { data, loading, error, checking, youtube, ytConnecting, load, markSubmitted, markConnected, checkLive, resetPlatform, connectYoutube, disconnectYoutube, copyFeed };
  },
  template: `
    <div style="padding: 20px; max-width: 700px;">
      <h3 style="margin: 0 0 6px 0;">Distribución</h3>
      <p style="color: var(--paper-dim); font-size: 13px; margin: 0 0 16px 0;">
        Conecta tu podcast a las plataformas. Solo necesitas hacerlo una vez por plataforma.
      </p>

      <div v-if="error" class="error" style="margin-bottom: 12px; font-size: 13px;">{{ error }}</div>

      <div v-if="loading" style="color: var(--paper-dim); padding: 20px;">Cargando…</div>

      <template v-if="data && !loading">
        <!-- Feed URL -->
        <div class="dist-feed-box">
          <label style="font-size: 11px; text-transform: uppercase; letter-spacing: 0.06em; color: var(--paper-dim); margin-bottom: 4px; display: block;">URL del Feed RSS</label>
          <div style="display: flex; gap: 8px; align-items: center;">
            <code style="flex: 1; background: var(--ink-bg); padding: 8px 12px; border-radius: 6px; font-size: 12px; word-break: break-all;">{{ data.feed_url }}</code>
            <button class="ghost" @click="copyFeed" style="font-size: 11px; white-space: nowrap;">Copiar</button>
          </div>
        </div>

        <!-- Validation -->
        <div v-if="data.validation" class="dist-validation" style="margin: 16px 0;">
          <div v-if="data.validation.valid" style="color: var(--signal-cool); font-size: 13px; font-weight: 500;">
            ✓ Feed listo para enviar a plataformas
          </div>
          <div v-else>
            <div style="color: var(--signal-hot); font-size: 13px; font-weight: 500; margin-bottom: 6px;">
              El feed tiene problemas que debes resolver:
            </div>
            <ul style="margin: 0; padding-left: 18px; font-size: 13px;">
              <li v-for="issue in data.validation.issues" :key="issue" style="color: var(--signal-hot); margin-bottom: 3px;">{{ issue }}</li>
            </ul>
          </div>
          <ul v-if="data.validation.warnings && data.validation.warnings.length" style="margin: 6px 0 0; padding-left: 18px; font-size: 12px;">
            <li v-for="w in data.validation.warnings" :key="w" style="color: var(--signal); margin-bottom: 2px;">{{ w }}</li>
          </ul>
        </div>

        <!-- Platform cards -->
        <div class="dist-platforms">

          <!-- Spotify & Apple cards -->
          <template v-for="key in ['spotify', 'apple']" :key="key">
            <div class="dist-card">
              <div class="dist-card-header">
                <span class="dist-platform-icon">{{ key === 'spotify' ? '🎧' : '🎙' }}</span>
                <strong>{{ data.platforms[key].name }}</strong>
                <span class="dist-badge" :class="'dist-badge--' + (data.platforms[key].status || 'not_configured')">
                  {{ data.platforms[key].status === 'connected' ? 'Conectado' : data.platforms[key].status === 'pending' ? 'Pendiente' : 'No configurado' }}
                </span>
              </div>

              <div v-if="!data.platforms[key].status || data.platforms[key].status === 'not_configured'" class="dist-card-body">
                <p style="font-size: 13px; color: var(--paper-dim); margin: 8px 0;">{{ data.platforms[key].help }}</p>
                <div v-if="data.validation && data.validation.valid" class="dist-steps">
                  <div class="dist-step">
                    <span class="dist-step-num">1</span>
                    <span>Copia la URL del feed RSS (arriba)</span>
                  </div>
                  <div class="dist-step">
                    <span class="dist-step-num">2</span>
                    <span>
                      <a :href="data.platforms[key].submit_url" target="_blank" rel="noopener" style="color: var(--accent);">
                        Abre {{ data.platforms[key].name }}
                      </a>
                      e inicia sesión con tu cuenta personal
                    </span>
                  </div>
                  <div class="dist-step">
                    <span class="dist-step-num">3</span>
                    <span>Pega la URL del feed cuando te la pidan</span>
                  </div>
                </div>
                <div style="margin-top: 10px;">
                  <button class="ghost" @click="markSubmitted(key)" :disabled="!data.validation || !data.validation.valid">
                    Ya lo envié ✓
                  </button>
                </div>
              </div>

              <div v-else-if="data.platforms[key].status === 'pending'" class="dist-card-body">
                <p style="font-size: 13px; color: var(--paper-dim); margin: 8px 0;">
                  Enviado{{ data.platforms[key].submitted_at ? ' el ' + data.platforms[key].submitted_at.slice(0, 10) : '' }}. Las plataformas suelen tardar entre 24 y 72 horas en aprobar.
                </p>
                <div style="display: flex; gap: 8px; margin-top: 8px;">
                  <button class="ghost" @click="checkLive(key)" :disabled="checking === key">
                    {{ checking === key ? 'Verificando…' : 'Verificar si está live' }}
                  </button>
                  <button class="ghost" @click="markConnected(key, '')">Marcar como conectado</button>
                  <button class="ghost danger" @click="resetPlatform(key)" style="font-size: 11px;">Resetear</button>
                </div>
              </div>

              <div v-else-if="data.platforms[key].status === 'connected'" class="dist-card-body">
                <p style="font-size: 13px; color: var(--signal-cool); margin: 8px 0;">
                  ✓ Tu podcast está en {{ data.platforms[key].name }}
                </p>
                <a v-if="data.platforms[key].external_url" :href="data.platforms[key].external_url" target="_blank" rel="noopener"
                   style="font-size: 12px; color: var(--accent);">
                  Ver en {{ data.platforms[key].name }} →
                </a>
                <div style="margin-top: 8px;">
                  <button class="ghost danger" @click="resetPlatform(key)" style="font-size: 11px;">Desconectar</button>
                </div>
              </div>
            </div>
          </template>

          <!-- YouTube card (OAuth flow) -->
          <div class="dist-card">
            <div class="dist-card-header">
              <span class="dist-platform-icon">▶</span>
              <strong>YouTube</strong>
              <span class="dist-badge" :class="youtube && youtube.connected ? 'dist-badge--connected' : 'dist-badge--not_configured'">
                {{ youtube && youtube.connected ? 'Conectado' : 'No conectado' }}
              </span>
            </div>

            <div v-if="!youtube || !youtube.connected" class="dist-card-body">
              <p style="font-size: 13px; color: var(--paper-dim); margin: 8px 0;">
                Conecta tu canal de YouTube para subir videos directamente desde prePod. Usa tu cuenta personal de Google — la misma con la que accedes a YouTube.
              </p>
              <button class="ghost" @click="connectYoutube" :disabled="ytConnecting" style="margin-top: 6px;">
                {{ ytConnecting ? 'Conectando…' : 'Conectar canal de YouTube' }}
              </button>
            </div>

            <div v-else class="dist-card-body">
              <p style="font-size: 13px; color: var(--signal-cool); margin: 8px 0;">
                ✓ Canal conectado: <strong>{{ youtube.channel_name || 'YouTube' }}</strong>
              </p>
              <a v-if="youtube.channel_id" :href="'https://www.youtube.com/channel/' + youtube.channel_id" target="_blank" rel="noopener"
                 style="font-size: 12px; color: var(--accent);">
                Ver canal →
              </a>
              <div style="margin-top: 8px;">
                <button class="ghost danger" @click="disconnectYoutube" style="font-size: 11px;">Desconectar</button>
              </div>
            </div>
          </div>

        </div>
      </template>
    </div>
  `,
};


var PodcastView = {
  components: { BrandingEditor, EpisodesBoard, EpisodeDetail, LandingPanel, SoundboardLibrary, CalendarView, TemplatesPanel, SponsorsPanel, ExportsPanel, DistributionPanel },
  props: { podcast: Object, onBack: Function, onUpdated: Function },
  setup(props) {
    // En celular/iPad se entra directo a los episodios: es lo que se usa en una emergencia.
    const mode = ref(isTouchLayout() ? "episodes" : "branding");
    const selectedEpId = ref(null);
    const moreOpen = ref(false);
    const MORE_MODES = [
      { key: "branding", label: "Branding", ico: "🎨" },
      { key: "sounds", label: "Sonidos", ico: "🔊" },
      { key: "templates", label: "Plantillas", ico: "🧩" },
      { key: "sponsors", label: "Sponsors", ico: "📢" },
      { key: "exports", label: "Archivos", ico: "📁" },
      { key: "distribution", label: "Distribución", ico: "📡" },
    ];
    function goMode(m) { mode.value = m; moreOpen.value = false; selectedEpId.value = null; }
    const inMore = computed(() => MORE_MODES.some(m => m.key === mode.value));

    function openEpisode(id) { selectedEpId.value = id; mode.value = "episode-detail"; }
    function backToBoard() { selectedEpId.value = null; mode.value = "episodes"; }

    function onEpisodeKey(ev) {
      const t = ev.target;
      const isTyping = t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable);
      if (isTyping) return;
      if ((ev.ctrlKey || ev.metaKey) && ev.key.toLowerCase() === "n") {
        ev.preventDefault();
        mode.value = "episodes";
      }
    }
    onMounted(() => window.addEventListener("keydown", onEpisodeKey));
    onBeforeUnmount(() => window.removeEventListener("keydown", onEpisodeKey));

    return { mode, selectedEpId, openEpisode, backToBoard, moreOpen, MORE_MODES, goMode, inMore };
  },
  template: `
    <div class="podcast-view-wrap">
      <div class="page-bar">
        <button v-if="mode === 'episode-detail'" class="ghost" @click="backToBoard">← Episodios</button>
        <button v-else class="ghost" @click="onBack">← Podcasts</button>
        <h3>{{ podcast.name }}</h3>
        <div v-if="mode !== 'episode-detail'" class="mode-tabs d-only" style="margin-left: 10px;">
          <button :class="{active: mode === 'branding'}" @click="mode = 'branding'">Branding</button>
          <button :class="{active: mode === 'episodes'}" @click="mode = 'episodes'">Episodios</button>
          <button :class="{active: mode === 'calendar'}" @click="mode = 'calendar'">Calendario</button>
          <button :class="{active: mode === 'sounds'}" @click="mode = 'sounds'">Sonidos</button>
          <button :class="{active: mode === 'templates'}" @click="mode = 'templates'">Plantillas</button>
          <button :class="{active: mode === 'sponsors'}" @click="mode = 'sponsors'">Sponsors</button>
          <button :class="{active: mode === 'landing'}" @click="mode = 'landing'">Landing</button>
          <button :class="{active: mode === 'exports'}" @click="mode = 'exports'">Archivos</button>
          <button :class="{active: mode === 'distribution'}" @click="mode = 'distribution'">Distribución</button>
        </div>
        <div class="spacer"></div>
        <a :href="'/api/podcasts/' + podcast.slug + '/export-bundle'" download
           class="ghost d-only" style="font-size:11px;padding:4px 10px;text-decoration:none;margin-right:8px;">↓ Exportar</a>
        <span class="badge-id d-only" :title="podcast.shared_project_id">id · {{ podcast.shared_project_id ? podcast.shared_project_id.slice(0, 8) + '…' : '—' }}</span>
      </div>

      <BrandingEditor v-if="mode === 'branding'" :podcast="podcast" :on-updated="onUpdated" />
      <EpisodesBoard v-else-if="mode === 'episodes'" :slug="podcast.slug" @open-episode="openEpisode" />
      <CalendarView v-else-if="mode === 'calendar'" :slug="podcast.slug" @open-episode="openEpisode" />
      <SoundboardLibrary v-else-if="mode === 'sounds'" :slug="podcast.slug" />
      <TemplatesPanel v-else-if="mode === 'templates'" :slug="podcast.slug" />
      <SponsorsPanel v-else-if="mode === 'sponsors'" :slug="podcast.slug" />
      <LandingPanel v-else-if="mode === 'landing'" :podcast="podcast" />
      <ExportsPanel v-else-if="mode === 'exports'" :slug="podcast.slug" />
      <DistributionPanel v-else-if="mode === 'distribution'" :slug="podcast.slug" />
      <EpisodeDetail v-else-if="mode === 'episode-detail'" :slug="podcast.slug" :episode-id="selectedEpId" @back="backToBoard" />

      <nav v-if="mode !== 'episode-detail'" class="pod-tabs m-only">
        <button :class="{ on: mode === 'episodes' }" @click="goMode('episodes')"><span class="pt-ico">🎙</span>Episodios</button>
        <button :class="{ on: mode === 'calendar' }" @click="goMode('calendar')"><span class="pt-ico">📅</span>Calendario</button>
        <button :class="{ on: mode === 'landing' }" @click="goMode('landing')"><span class="pt-ico">🌐</span>Landing</button>
        <button :class="{ on: inMore || moreOpen }" @click="moreOpen = !moreOpen"><span class="pt-ico">⋯</span>Más</button>
      </nav>
      <div v-if="moreOpen" class="pod-sheet-backdrop m-only" @click.self="moreOpen = false">
        <div class="pod-sheet">
          <div class="pod-sheet-grab"></div>
          <button v-for="m in MORE_MODES" :key="m.key" :class="{ on: mode === m.key }" @click="goMode(m.key)"><span>{{ m.ico }}</span>{{ m.label }}</button>
          <a class="pod-sheet-link" :href="'/api/podcasts/' + podcast.slug + '/export-bundle'" download><span>↓</span>Exportar podcast</a>
        </div>
      </div>
    </div>
  `,
};


/* ==========================================================================
   Root
   ========================================================================== */

var UsersAdminModal = {
  emits: ["close"],
  setup(props, { emit }) {
    const users = ref([]);
    const error = ref("");
    const busy = ref(false);
    const lastGenerated = reactive({});
    const editing = ref(null);
    const editForm = reactive({ display_name: "", email: "", avatar_color: "" });
    const newUser = reactive({ username: "", password: "", display_name: "", email: "", is_admin: false, max_podcasts: 1 });

    async function load() {
      try { users.value = await api("/api/users"); }
      catch (e) { error.value = e.message; }
    }

    function startEdit(u) {
      editing.value = u.username;
      editForm.display_name = u.display_name || "";
      editForm.email = u.email || "";
      editForm.avatar_color = u.avatar_color || "";
    }

    function cancelEdit() { editing.value = null; }

    async function saveEdit(u) {
      busy.value = true; error.value = "";
      try {
        await api("/api/users/" + u.username, {
          method: "PUT",
          body: {
            display_name: editForm.display_name.trim() || u.username,
            email: editForm.email.trim() || null,
            avatar_color: editForm.avatar_color.trim() || null,
          },
        });
        editing.value = null;
        await load();
      } catch (e) { error.value = e.message; }
      finally { busy.value = false; }
    }

    async function createNew() {
      if (!newUser.username.trim()) { error.value = "username requerido"; return; }
      busy.value = true; error.value = "";
      try {
        const r = await api("/api/users", {
          method: "POST",
          body: {
            username: newUser.username.trim(),
            password: newUser.password.trim() || null,
            display_name: newUser.display_name.trim() || newUser.username.trim(),
            email: newUser.email.trim() || null,
            is_admin: newUser.is_admin,
            max_podcasts: newUser.is_admin ? null : (parseInt(newUser.max_podcasts) || 0),
          },
        });
        if (r.generated_password) lastGenerated[r.username] = r.generated_password;
        Object.assign(newUser, { username: "", password: "", display_name: "", email: "", is_admin: false, max_podcasts: 1 });
        await load();
      } catch (e) { error.value = e.message; }
      finally { busy.value = false; }
    }

    async function resetPassword(u) {
      if (!await podSwal.confirm("¿Generar una contraseña nueva para " + u.username + "? La actual va a dejar de funcionar.")) return;
      try {
        const r = await api("/api/users/" + u.username, { method: "PUT", body: { password: "" } });
        if (r.generated_password) lastGenerated[u.username] = r.generated_password;
      } catch (e) { error.value = e.message; }
    }

    async function setAdmin(u, is_admin) {
      try {
        await api("/api/users/" + u.username, { method: "PUT", body: { is_admin } });
        await load();
      } catch (e) { error.value = e.message; await load(); }
    }

    async function setMaxPodcasts(u, v) {
      try {
        await api("/api/users/" + u.username, { method: "PUT", body: { max_podcasts: v === "" ? null : parseInt(v) } });
        await load();
      } catch (e) { error.value = e.message; await load(); }
    }

    async function removeUser(u) {
      if (!await podSwal.confirm('¿Eliminar al usuario "' + u.username + '"? Sus podcasts NO se eliminan, solo el acceso.')) return;
      try {
        await api("/api/users/" + u.username, { method: "DELETE" });
        await load();
      } catch (e) { error.value = e.message; }
    }

    onMounted(load);
    return { users, error, busy, newUser, lastGenerated, editing, editForm,
             createNew, resetPassword, setAdmin, setMaxPodcasts, removeUser,
             startEdit, cancelEdit, saveEdit };
  },
  template: `
    <div class="modal-backdrop" @click.self="$emit('close')">
      <div class="modal users-admin-modal">
        <div class="modal-head">
          <h3>Usuarios</h3>
          <button class="icon ghost" @click="$emit('close')">✕</button>
        </div>
        <div class="modal-body">
          <div v-if="error" class="error">{{ error }}</div>

          <div class="user-list">
            <div v-for="u in users" :key="u.username" class="user-row">
              <div class="user-avatar" :style="{ background: u.avatar_color }">{{ u.display_name[0] }}</div>
              <div class="user-info" style="flex:1;min-width:0;">
                <div class="user-name">{{ u.display_name }} <span class="muted mono">@{{ u.username }}</span></div>
                <div v-if="u.email" class="muted" style="font-size:12px;">{{ u.email }}</div>
                <div v-if="lastGenerated[u.username]" class="user-pw-flash mono">
                  nueva clave: <strong>{{ lastGenerated[u.username] }}</strong> (copia ahora, no se guarda en pantalla)
                </div>

                <div v-if="editing === u.username" class="user-edit-form" style="margin-top:8px;padding:12px;background:#f7f7f9;border-radius:8px;">
                  <div class="form-row" style="margin-bottom:6px;">
                    <label style="font-size:11px;color:#888;">Nombre</label>
                    <input type="text" v-model="editForm.display_name" style="width:100%;">
                  </div>
                  <div class="form-row" style="margin-bottom:6px;">
                    <label style="font-size:11px;color:#888;">Email</label>
                    <input type="email" v-model="editForm.email" placeholder="correo@ejemplo.com" style="width:100%;">
                  </div>
                  <div class="form-row" style="margin-bottom:8px;">
                    <label style="font-size:11px;color:#888;">Color avatar</label>
                    <input type="color" v-model="editForm.avatar_color" style="width:48px;height:28px;padding:0;border:1px solid #ddd;border-radius:4px;cursor:pointer;">
                  </div>
                  <div style="display:flex;gap:8px;">
                    <button class="primary" :disabled="busy" @click="saveEdit(u)" style="font-size:13px;padding:4px 14px;">Guardar</button>
                    <button class="ghost" @click="cancelEdit" style="font-size:13px;padding:4px 14px;">Cancelar</button>
                  </div>
                </div>
              </div>
              <button v-if="editing !== u.username" class="ghost" @click="startEdit(u)" title="Editar usuario" style="font-size:14px;">&#9998;</button>
              <label class="user-toggle">
                <input type="checkbox" :checked="u.is_admin" @change="setAdmin(u, $event.target.checked)">
                admin
              </label>
              <input type="number" min="0" class="user-max" placeholder="∞"
                     :value="u.max_podcasts === null ? '' : u.max_podcasts"
                     :disabled="u.is_admin"
                     @change="setMaxPodcasts(u, $event.target.value)" title="Podcasts max">
              <button class="ghost" @click="resetPassword(u)" title="Generar nueva clave" style="font-size:14px;">&#128273;</button>
              <button class="icon danger" @click="removeUser(u)" title="Eliminar">✕</button>
            </div>
          </div>

          <div class="user-add">
            <h4 style="margin: 16px 0 8px;">Crear usuario</h4>
            <div class="form-row" style="margin-bottom: 8px;">
              <label>Username (sin espacios)</label>
              <input type="text" v-model="newUser.username" placeholder="ej: maria">
            </div>
            <div class="form-row" style="margin-bottom: 8px;">
              <label>Nombre para mostrar (opcional)</label>
              <input type="text" v-model="newUser.display_name" placeholder="ej: María García">
            </div>
            <div class="form-row" style="margin-bottom: 8px;">
              <label>Email (opcional)</label>
              <input type="email" v-model="newUser.email" placeholder="correo@ejemplo.com">
            </div>
            <div class="form-row" style="margin-bottom: 8px;">
              <label>Contraseña (vacío = generar aleatoria)</label>
              <input type="text" v-model="newUser.password" placeholder="dejar vacío para generar">
            </div>
            <div class="row" style="gap: 16px;">
              <label class="user-toggle">
                <input type="checkbox" v-model="newUser.is_admin">
                admin (ve y maneja todo)
              </label>
              <label v-if="!newUser.is_admin" class="user-toggle">
                max podcasts:
                <input type="number" min="0" v-model.number="newUser.max_podcasts" style="width: 60px; margin-left: 6px;">
              </label>
            </div>
            <button class="primary" :disabled="busy || !newUser.username.trim()" @click="createNew" style="margin-top: 12px;">
              {{ busy ? "Creando…" : "＋ Crear usuario" }}
            </button>
          </div>
        </div>
      </div>
    </div>
  `,
};

/* AppSwitcher dropdown removed — replaced by inline sibling-apps links in header */

var App = {
  components: { LoginView, PodcastListView, PodcastView, IntegrationSettingsModal, UsersAdminModal },
  setup() {
    const state = reactive({ username: null, isAdmin: false, currentPodcast: null, loading: true, showSettings: false, showUsers: false });
    const siblingApps = ref(null);
    const thepodUrl = ref("");

    async function checkAuth() {
      state.loading = true;
      try {
        const d = await api("/api/auth/me");
        state.username = d.username;
        state.isAdmin = !!d.is_admin;
      }
      catch (_) { state.username = null; state.isAdmin = false; }
      finally { state.loading = false; }
    }
    async function loadApps() {
      try {
        const d = await api("/api/config/apps");
        siblingApps.value = d.apps.filter(function (a) { return a.key !== d.current; });
        thepodUrl.value = d.thepod_url || "";
      } catch (_) {}
    }
    async function logout() {
      try { await api("/api/auth/logout", { method: "POST" }); } catch (_) {}
      state.username = null;
      state.isAdmin = false;
      state.currentPodcast = null;
    }
    function onLoggedIn(u) { checkAuth(); }
    function onOpen(p) { state.currentPodcast = p; }
    function onBack() { state.currentPodcast = null; }
    function onUpdated(p) {
      if (state.currentPodcast && state.currentPodcast.slug === p.slug) {
        state.currentPodcast = { ...state.currentPodcast, ...p };
      }
    }
    onMounted(function () { checkAuth(); loadApps(); });
    return { state, siblingApps, thepodUrl, onLoggedIn, onOpen, onBack, onUpdated, logout };
  },
  template: `
    <template v-if="state.loading">
      <div class="login-wrapper"><div class="muted">Cargando sala…</div></div>
    </template>
    <template v-else-if="!state.username">
      <LoginView :on-logged-in="onLoggedIn" />
    </template>
    <template v-else>
      <header class="app-header">
        <div class="brand">
          <a :href="thepodUrl || '#'" class="mark" title="Ir a thePod">pre<em>Pod</em></a>
          <span class="tag d-only">green room · v0.1</span>
        </div>
        <div class="sibling-apps d-only" v-if="siblingApps">
          <a v-for="a in siblingApps" :key="a.key" :href="a.url" class="sibling-link" :title="'Ir a ' + a.name">
            <span class="ico" :data-app="a.key"></span>
            <span>{{ a.name }}</span>
          </a>
        </div>
        <div class="stage-light d-only">
          <span class="dot"></span>
          <span>IN PREP</span>
        </div>
        <div class="spacer"></div>
        <div v-if="state.currentPodcast" class="row d-only">
          <button class="ghost" @click="onBack">← Podcasts</button>
        </div>
        <button v-if="state.isAdmin" class="settings-btn" @click="state.showUsers = true" title="Administrar usuarios">👥</button>
        <button class="settings-btn" @click="state.showSettings = true" title="Integraciones">⚙</button>
        <div class="user-chip">
          <span class="tiny">{{ state.isAdmin ? 'ADMIN' : 'USR' }}</span>
          <span class="name">{{ state.username }}</span>
          <button class="ghost" @click="logout">Salir</button>
        </div>
      </header>
      <PodcastView v-if="state.currentPodcast" :podcast="state.currentPodcast" :on-back="onBack" :on-updated="onUpdated" />
      <PodcastListView v-else :on-open="onOpen" />
      <IntegrationSettingsModal v-if="state.showSettings" @close="state.showSettings = false" />
      <UsersAdminModal v-if="state.showUsers" @close="state.showUsers = false" />
    </template>
  `,
};

createApp(App).mount("#app");
