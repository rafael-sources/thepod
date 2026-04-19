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

var LoginView = {
  props: { onLoggedIn: { type: Function, required: true } },
  setup(props) {
    const username = ref("");
    const password = ref("");
    const error = ref("");
    const busy = ref(false);
    async function submit() {
      error.value = "";
      busy.value = true;
      try {
        const data = await api("/api/auth/login", {
          method: "POST",
          body: { username: username.value, password: password.value },
        });
        props.onLoggedIn(data.username);
      } catch (e) { error.value = e.message; }
      finally { busy.value = false; }
    }
    return { username, password, error, busy, submit };
  },
  template: `
    <div class="login-wrapper">
      <div class="login-card">
        <div class="eyebrow">GREEN ROOM · PRE-PRODUCCIÓN</div>
        <h2>pre<em>Pod</em></h2>
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
      if (!confirm(`¿Eliminar podcast "${p.name}"?\nSe borrarán TODOS sus archivos de branding.`)) return;
      try { await api(`/api/podcasts/${p.slug}`, { method: "DELETE" }); await load(); }
      catch (e) { error.value = e.message; }
    }

    onMounted(load);
    return { podcasts, loading, error, showCreate, newName, creating, create, remove, fmtDate };
  },
  template: `
    <div class="container">
      <div class="page-head">
        <div>
          <div class="eyebrow">PODCASTS · SHOWS ACTIVOS</div>
          <h2>Green <em style="color:var(--signal);font-style:italic;">room</em></h2>
        </div>
        <div class="spacer"></div>
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

    const save = debounce(async () => {
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
            font_heading: meta.font_heading,
            font_body: meta.font_body,
          },
        });
        Object.assign(meta, updated);
        saveState.value = "saved";
        setTimeout(() => { if (saveState.value === "saved") saveState.value = null; }, 1400);
        props.onUpdated?.(updated);
      } catch (e) {
        saveState.value = "error";
        error.value = e.message;
      }
    }, 500);

    watch(() => [
      meta.name, meta.description, meta.tagline,
      meta.color_primary, meta.color_secondary, meta.color_accent,
      meta.font_heading, meta.font_body,
    ], save);

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
        else { meta.cover_filename = r.filename; meta.cover_url = r.url; }
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
      if (!confirm(`¿Quitar ${kind === "logo" ? "logo" : "cover"}?`)) return;
      try {
        await api(`/api/podcasts/${meta.slug}/branding/${kind}`, { method: "DELETE" });
        if (kind === "logo") { meta.logo_filename = null; meta.logo_url = null; }
        else { meta.cover_filename = null; meta.cover_url = null; }
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

    onMounted(loadFonts);

    return {
      meta, error, saveState, fonts,
      previewStyle, uploadImage, clearImage, fmtDate,
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
          </div>
        </div>

        <!-- Assets visuales -->
        <div class="section">
          <div class="section-head">
            <div class="eyebrow">ASSETS</div>
            <h3>Logo y cover</h3>
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

      <transition>
        <div v-if="saveState === 'saving'" class="save-indicator saving">◉ guardando…</div>
        <div v-else-if="saveState === 'saved'" class="save-indicator">✓ guardado</div>
        <div v-else-if="saveState === 'error'" class="save-indicator" style="background: var(--signal-hot); color: #fff;">◆ error</div>
      </transition>
    </div>
  `,
};

/* ==========================================================================
   Episodes — Kanban board (Plan 2)
   ========================================================================== */

var EPISODE_COLS = [
  { key: "idea",      label: "Ideas" },
  { key: "planning",  label: "Planificando" },
  { key: "scripted",  label: "Con guion" },
  { key: "recorded",  label: "Grabado" },
  { key: "published", label: "Publicado" },
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
  props: { show: Boolean },
  emits: ["create", "cancel"],
  setup(_, { emit }) {
    const title = ref("");
    watch(() => _.show, (s) => { if (s) title.value = ""; });
    function submit() {
      const t = title.value.trim();
      if (!t) return;
      emit("create", { title: t });
    }
    return { title, submit };
  },
  template: `
    <div v-if="show" class="modal-backdrop" @click.self="$emit('cancel')">
      <div class="modal">
        <div class="eyebrow">NUEVO EPISODIO</div>
        <h3>Arrancar un episodio</h3>
        <p class="muted" style="margin-bottom: 16px;">El número se asigna automáticamente. Podrás editar todo lo demás desde adentro.</p>
        <div class="form-row">
          <label>Título</label>
          <input type="text" v-model="title" @keyup.enter="submit" autofocus placeholder="Ej: Especial de fin de año">
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
    const error = ref("");
    const showCreate = ref(false);
    const createInStatus = ref("idea");
    const dragOverCol = ref(null);

    async function load() {
      try { episodes.value = await api(`/api/podcasts/${props.slug}/episodes`); }
      catch (e) { error.value = e.message; }
    }

    const byStatus = computed(() => {
      const m = { idea: [], planning: [], scripted: [], recorded: [], published: [] };
      for (const e of episodes.value) {
        if (m[e.status]) m[e.status].push(e);
      }
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

    function askCreate(status) { createInStatus.value = status; showCreate.value = true; }
    async function doCreate(payload) {
      try {
        const created = await api(`/api/podcasts/${props.slug}/episodes`, {
          method: "POST",
          body: { title: payload.title, status: createInStatus.value },
        });
        episodes.value.push(created);
        showCreate.value = false;
        emit("open-episode", created.id);
      } catch (e) { error.value = e.message; }
    }

    onMounted(load);
    return {
      columns: EPISODE_COLS, episodes, byStatus, error, dragOverCol, showCreate, createInStatus,
      onDragStart, onDragEnd, onDragOver, onDragLeave, onDrop, askCreate, doCreate,
      fmtDate, fmtDurationMin,
    };
  },
  template: `
    <div class="kanban">
      <div
        v-for="col in columns"
        :key="col.key"
        class="kanban-col"
        :class="{ 'drag-over': dragOverCol === col.key }"
        :data-status="col.key"
        @dragover.prevent="onDragOver(col.key)"
        @dragleave="onDragLeave(col.key)"
        @drop.prevent="onDrop(col.key)"
      >
        <div class="kanban-col-head">
          <span class="dot"></span>
          <span class="name">{{ col.label }}</span>
          <span class="count">{{ (byStatus[col.key] || []).length }}</span>
        </div>
        <div class="kanban-col-body">
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
            <div class="ep-num">EP · #{{ ep.episode_number }}</div>
            <div class="ep-title">{{ ep.title }}</div>
            <div class="ep-meta">
              <span v-if="ep.scheduled_date">📅 {{ ep.scheduled_date }}</span>
              <span v-if="ep.duration_estimate">⏱ {{ fmtDurationMin(ep.duration_estimate) }}</span>
            </div>
          </div>
          <button class="add-btn" @click="askCreate(col.key)">＋ Nuevo episodio</button>
        </div>
      </div>
      <CreateEpisodeModal :show="showCreate" @create="doCreate" @cancel="showCreate = false" />
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
      if (!confirm("¿Eliminar idea?")) return;
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
      if (!confirm("¿Eliminar sección?")) return;
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

var EpisodeIntegrationBar = {
  props: { slug: String, episodeId: Number },
  setup(props) {
    const status = ref(null);
    const error = ref("");
    const busyPost = ref(false);
    const busyProd = ref(false);

    async function load() {
      try { status.value = await api(`/api/podcasts/${props.slug}/episodes/${props.episodeId}/integration-status`); }
      catch (e) { error.value = e.message; }
    }

    async function sendToPostpod() {
      busyPost.value = true; error.value = "";
      try {
        const r = await api(`/api/podcasts/${props.slug}/episodes/${props.episodeId}/send-to-postpod`, { method: "POST" });
        alert(r.created ? `Proyecto creado en postPod: ${r.postpod_slug}` : `Ya existía — slug: ${r.postpod_slug}`);
        await load();
      } catch (e) { error.value = e.message; alert(e.message); }
      finally { busyPost.value = false; }
    }

    async function sendToProdpod() {
      busyProd.value = true; error.value = "";
      try {
        const r = await api(`/api/podcasts/${props.slug}/episodes/${props.episodeId}/send-to-prodpod`, { method: "POST" });
        alert(r.created ? `Sesión creada en prodPod #${r.prodpod_session_id}` : `Ya existía — sesión #${r.prodpod_session_id}`);
        await load();
      } catch (e) { error.value = e.message; alert(e.message); }
      finally { busyProd.value = false; }
    }

    watch(() => props.episodeId, load, { immediate: true });
    return { status, error, busyPost, busyProd, sendToPostpod, sendToProdpod };
  },
  template: `
    <div>
      <div v-if="error" class="error">{{ error }}</div>
      <div class="integration-panel">
        <span class="eyebrow" style="font-family: var(--font-mono); font-size: 10px; letter-spacing: 0.22em; text-transform: uppercase; color: var(--signal); font-weight: 600;">FLUJO</span>

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
   Episode detail (Plan 2)
   ========================================================================== */

var EpisodeDetail = {
  components: { IdeasPanel, ScriptEditor, EpisodeLinks, EpisodeIntegrationBar },
  props: { slug: String, episodeId: Number },
  emits: ["back", "updated"],
  setup(props, { emit }) {
    const ep = ref(null);
    const error = ref("");
    const saveState = ref(null);

    async function load() {
      try {
        ep.value = await api(`/api/podcasts/${props.slug}/episodes/${props.episodeId}`);
      } catch (e) { error.value = e.message; }
    }

    const save = debounce(async () => {
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
              scheduled_date: ep.value.scheduled_date || null,
              duration_estimate: ep.value.duration_estimate || null,
            },
          },
        );
        Object.assign(ep.value, updated);
        saveState.value = "saved";
        setTimeout(() => { if (saveState.value === "saved") saveState.value = null; }, 1400);
        emit("updated", updated);
      } catch (e) {
        saveState.value = "error";
        error.value = e.message;
      }
    }, 500);

    watch(() => [
      ep.value?.title, ep.value?.description, ep.value?.scheduled_date, ep.value?.duration_estimate,
    ], (newVals, oldVals) => {
      if (!ep.value || !oldVals || oldVals.every(v => v === undefined)) return;
      save();
    });

    watch(() => props.episodeId, load, { immediate: true });

    return { ep, error, saveState, fmtDate };
  },
  template: `
    <div v-if="ep" class="episode-detail">
      <div class="main">
        <div v-if="error" class="error">{{ error }}</div>

        <div class="section">
          <div class="section-head">
            <div class="eyebrow">EP · #{{ ep.episode_number }} · {{ ep.status.toUpperCase() }}</div>
            <h3>
              <input type="text" v-model="ep.title" style="font-family: var(--font-display); font-size: 22px; font-weight: 500; letter-spacing: -0.01em; padding: 4px 0; border: 0; background: transparent;">
            </h3>
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
              <label>Fecha prevista</label>
              <input type="date" v-model="ep.scheduled_date">
            </div>
            <div>
              <label>Duración est. (min)</label>
              <input type="number" v-model.number="ep.duration_estimate" min="0" step="1">
            </div>
          </div>
        </div>

        <div class="section">
          <ScriptEditor :slug="slug" :episode-id="ep.id" />
        </div>

        <div class="section">
          <EpisodeLinks :slug="slug" :episode-id="ep.id" />
        </div>

        <EpisodeIntegrationBar :slug="slug" :episode-id="ep.id" />
      </div>

      <aside class="side">
        <IdeasPanel :slug="slug" :episode-id="ep.id" />
      </aside>

      <transition>
        <div v-if="saveState === 'saving'" class="save-indicator saving">◉ guardando…</div>
        <div v-else-if="saveState === 'saved'" class="save-indicator">✓ guardado</div>
        <div v-else-if="saveState === 'error'" class="save-indicator" style="background: var(--signal-hot); color: #fff;">◆ error</div>
      </transition>
    </div>
    <div v-else class="container">
      <div class="muted">Cargando episodio…</div>
    </div>
  `,
};
/* ==========================================================================
   Team editor (used inside LandingPanel)
   ========================================================================== */

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
      if (!confirm(`¿Eliminar "${m.name}" del equipo?`)) return;
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

      <div v-if="members.length === 0" class="empty-pill">Sin miembros. Agregá al host o al equipo.</div>

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

    const save = debounce(async () => {
      saveState.value = "saving";
      try {
        const r = await api(`/api/podcasts/${props.podcast.slug}/landing`, {
          method: "PUT",
          body: { ...cfg },
        });
        Object.assign(cfg, r);
        saveState.value = "saved";
        setTimeout(() => { if (saveState.value === "saved") saveState.value = null; }, 1400);
      } catch (e) {
        saveState.value = "error";
        error.value = e.message;
      }
    }, 500);

    watch(() => Object.values(cfg), () => { if (loaded.value) save(); });

    const landingUrl = computed(() => `${window.location.origin}/landing/${props.podcast.slug}`);
    const rssUrl     = computed(() => `${window.location.origin}/landing/${props.podcast.slug}/feed.xml`);

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

    onMounted(load);

    return { cfg, loaded, error, saveState, copyNotice, landingUrl, rssUrl, copy, openPreview };
  },
  template: `
    <div class="landing-wrap">
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

        <div class="landing-url" style="margin-bottom: 18px;">
          <span class="tiny">RSS</span>
          <span class="url-txt" :title="rssUrl">{{ rssUrl }}</span>
          <button class="icon ghost" @click="copy(rssUrl, 'RSS')" title="Copiar RSS">⧉</button>
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

      <transition>
        <div v-if="saveState === 'saving'" class="save-indicator saving">◉ guardando…</div>
        <div v-else-if="saveState === 'saved'" class="save-indicator">✓ guardado</div>
        <div v-else-if="saveState === 'error'" class="save-indicator" style="background: var(--signal-hot); color: #fff;">◆ error</div>
        <div v-else-if="copyNotice" class="save-indicator">{{ copyNotice }}</div>
      </transition>
    </div>
  `,
};

/* ==========================================================================
   Podcast view (router: branding · episodes · landing · episode detail)
   ========================================================================== */

var PodcastView = {
  components: { BrandingEditor, EpisodesBoard, EpisodeDetail, LandingPanel },
  props: { podcast: Object, onBack: Function, onUpdated: Function },
  setup(props) {
    const mode = ref("branding");
    const selectedEpId = ref(null);

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

    return { mode, selectedEpId, openEpisode, backToBoard };
  },
  template: `
    <div class="podcast-view-wrap">
      <div class="page-bar">
        <button v-if="mode === 'episode-detail'" class="ghost" @click="backToBoard">← Episodios</button>
        <button v-else class="ghost" @click="onBack">← Podcasts</button>
        <h3>{{ podcast.name }}</h3>
        <div v-if="mode !== 'episode-detail'" class="mode-tabs" style="margin-left: 10px;">
          <button :class="{active: mode === 'branding'}" @click="mode = 'branding'">Branding</button>
          <button :class="{active: mode === 'episodes'}" @click="mode = 'episodes'">Episodios</button>
          <button :class="{active: mode === 'landing'}" @click="mode = 'landing'">Landing</button>
        </div>
        <div class="spacer"></div>
        <span class="badge-id" :title="podcast.shared_project_id">id · {{ podcast.shared_project_id ? podcast.shared_project_id.slice(0, 8) + '…' : '—' }}</span>
      </div>

      <BrandingEditor v-if="mode === 'branding'" :podcast="podcast" :on-updated="onUpdated" />
      <EpisodesBoard v-else-if="mode === 'episodes'" :slug="podcast.slug" @open-episode="openEpisode" />
      <LandingPanel v-else-if="mode === 'landing'" :podcast="podcast" />
      <EpisodeDetail v-else-if="mode === 'episode-detail'" :slug="podcast.slug" :episode-id="selectedEpId" @back="backToBoard" />
    </div>
  `,
};

/* ==========================================================================
   Root
   ========================================================================== */

var App = {
  components: { LoginView, PodcastListView, PodcastView, IntegrationSettingsModal },
  setup() {
    const state = reactive({ username: null, currentPodcast: null, loading: true, showSettings: false });

    async function checkAuth() {
      state.loading = true;
      try { const d = await api("/api/auth/me"); state.username = d.username; }
      catch (_) { state.username = null; }
      finally { state.loading = false; }
    }
    async function logout() {
      try { await api("/api/auth/logout", { method: "POST" }); } catch (_) {}
      state.username = null;
      state.currentPodcast = null;
    }
    function onLoggedIn(u) { state.username = u; }
    function onOpen(p) { state.currentPodcast = p; }
    function onBack() { state.currentPodcast = null; }
    function onUpdated(p) {
      if (state.currentPodcast && state.currentPodcast.slug === p.slug) {
        state.currentPodcast = { ...state.currentPodcast, ...p };
      }
    }
    onMounted(checkAuth);
    return { state, onLoggedIn, onOpen, onBack, onUpdated, logout };
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
          <span class="mark">pre<em>Pod</em></span>
          <span class="tag">green room · v0.1</span>
        </div>
        <div class="stage-light">
          <span class="dot"></span>
          <span>IN PREP</span>
        </div>
        <div class="spacer"></div>
        <div v-if="state.currentPodcast" class="row">
          <button class="ghost" @click="onBack">← Podcasts</button>
        </div>
        <button class="settings-btn" @click="state.showSettings = true" title="Integraciones">⚙</button>
        <div class="user-chip">
          <span class="tiny">OP</span>
          <span class="name">{{ state.username }}</span>
          <button class="ghost" @click="logout">Salir</button>
        </div>
      </header>
      <PodcastView v-if="state.currentPodcast" :podcast="state.currentPodcast" :on-back="onBack" :on-updated="onUpdated" />
      <PodcastListView v-else :on-open="onOpen" />
      <IntegrationSettingsModal v-if="state.showSettings" @close="state.showSettings = false" />
    </template>
  `,
};

createApp(App).mount("#app");
