var { createApp, reactive, ref, computed, onMounted, onBeforeUnmount, watch, nextTick } = Vue;

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

/* Upload with progress events via XMLHttpRequest.
   onProgress is called with a 0..100 number as the upload advances. */
function apiUpload(path, formData, onProgress) {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open("POST", path);
    xhr.withCredentials = true;
    xhr.responseType = "text";
    xhr.upload.addEventListener("progress", (ev) => {
      if (ev.lengthComputable && onProgress) {
        onProgress(Math.round((ev.loaded / ev.total) * 100));
      }
    });
    xhr.addEventListener("load", () => {
      let data = null;
      try { data = xhr.responseText ? JSON.parse(xhr.responseText) : null; }
      catch (_) { data = { error: xhr.responseText }; }
      if (xhr.status >= 200 && xhr.status < 300) {
        resolve(data);
      } else {
        const err = new Error(data?.error || xhr.statusText || "upload failed");
        err.status = xhr.status;
        err.data = data;
        reject(err);
      }
    });
    xhr.addEventListener("error", () => reject(new Error("error de red durante upload")));
    xhr.addEventListener("abort", () => reject(new Error("upload cancelado")));
    xhr.send(formData);
  });
}

function pad(n, w = 2) { return String(Math.floor(n)).padStart(w, "0"); }

function formatTimecode(seconds) {
  if (seconds == null || !isFinite(seconds)) return { hh: "00", mm: "00", ss: "00", cs: "00" };
  const s = Math.max(0, seconds);
  const hh = Math.floor(s / 3600);
  const mm = Math.floor((s % 3600) / 60);
  const ss = Math.floor(s % 60);
  const cs = Math.floor((s - Math.floor(s)) * 100);
  return { hh: pad(hh), mm: pad(mm), ss: pad(ss), cs: pad(cs) };
}

function formatShort(seconds) {
  const { mm, ss, cs } = formatTimecode(seconds);
  return `${mm}:${ss}.${cs}`;
}

function formatSize(bytes) {
  if (bytes == null) return "";
  const units = ["B", "KB", "MB", "GB"];
  let n = bytes, i = 0;
  while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
  return `${n.toFixed(n < 10 && i > 0 ? 1 : 0)} ${units[i]}`;
}

function formatDurationCompact(seconds) {
  if (seconds == null) return "";
  const { mm, ss } = formatTimecode(seconds);
  const hh = Math.floor(seconds / 3600);
  return hh > 0 ? `${hh}:${mm}:${ss}` : `${mm}:${ss}`;
}

function niceTickInterval(visibleSeconds, maxTicks = 10) {
  const candidates = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800];
  for (const c of candidates) if (visibleSeconds / c <= maxTicks) return c;
  return 3600;
}

/* Compute cumulative timeline starts for a list of clip objects. Tracks 1-4
   each stack independently starting from t=0 (multi-cam model). Each
   returned clip gets {...clip, track, start, end}. */
function withTimelineStarts(clips) {
  const cursor = { 1: 0, 2: 0, 3: 0, 4: 0 };
  return clips.map((c) => {
    const track = c.track || 1;
    const dur = c.duration || 0;
    const start = cursor[track] || 0;
    cursor[track] = start + dur;
    return { ...c, track, start, end: start + dur };
  });
}

/* Total timeline duration = max of each track's cumulative end. */
function totalDurationFromClips(clips) {
  let m = 0;
  for (const c of clips) if (c.end > m) m = c.end;
  return m;
}

/* Walk switch_track ops in moment order to determine the active track at
   time `t`. Default is track 1. */
function activeTrackAtTime(moments, t) {
  if (!moments || !moments.length) return 1;
  const sorted = [...moments].sort((a, b) => a.timeline_seconds - b.timeline_seconds);
  let active = 1;
  for (const m of sorted) {
    if (m.timeline_seconds > t + 1e-6) break;
    const op = (m.operations || []).find(o => o.type === "switch_track");
    if (!op) continue;
    const p = op.params || {};
    if (p.toggle) active = (active % 4) + 1;
    else if (p.track >= 1 && p.track <= 4) active = p.track;
  }
  return active;
}

/* Given a timeline time t and the full clips list (withTimelineStarts),
   return the clip that should be playing: the clip on the active track (as
   determined by switch_track ops) that spans t. Falls back gracefully when
   the active track has no clip at t — returns the other track's clip if
   present, else the last clip of any track. */
function clipAtTime(clips, t, moments) {
  if (!clips.length) return null;
  const active = activeTrackAtTime(moments || [], t);
  const onTrack = (trk) => {
    for (const c of clips) {
      if ((c.track || 1) !== trk) continue;
      if (t < c.end) return c;
    }
    return null;
  };
  for (let t = 0; t < 4; t++) {
    const trk = ((active - 1 + t) % 4) + 1;
    const found = onTrack(trk);
    if (found) return found;
  }
  return clips[clips.length - 1];
}

/* Module-level peaks cache, keyed by peaks_url. Each entry is a Promise. */
var _peaksCache = new Map();

function fetchPeaks(url) {
  if (!url) return Promise.resolve(null);
  if (_peaksCache.has(url)) return _peaksCache.get(url);
  const p = fetch(url, { credentials: "same-origin" })
    .then((r) => (r.ok ? r.json() : null))
    .catch(() => null);
  _peaksCache.set(url, p);
  return p;
}

function sliceAndDownsamplePeaks(peaks, sourceStart, sourceEnd, sourceDuration, maxPoints = 600) {
  if (!peaks || !peaks.length || !sourceDuration) return [];
  const n = peaks.length;
  const startIdx = Math.max(0, Math.floor((sourceStart / sourceDuration) * n));
  const endIdx = Math.min(n, Math.ceil((sourceEnd / sourceDuration) * n));
  const slice = peaks.slice(startIdx, endIdx);
  if (slice.length <= maxPoints) return slice;
  const bucket = Math.ceil(slice.length / maxPoints);
  const out = [];
  for (let i = 0; i < slice.length; i += bucket) {
    let m = 0;
    const end = Math.min(i + bucket, slice.length);
    for (let j = i; j < end; j++) if (slice[j] > m) m = slice[j];
    out.push(m);
  }
  return out;
}

var ClipWaveform = {
  props: {
    peaksUrl: String,
    sourceStart: Number,
    sourceEnd: Number,
    sourceDuration: Number,
  },
  setup(props) {
    const rawPeaks = ref(null);

    async function load() {
      if (!props.peaksUrl) { rawPeaks.value = null; return; }
      const data = await fetchPeaks(props.peaksUrl);
      rawPeaks.value = (data && Array.isArray(data.peaks)) ? data.peaks : null;
    }

    watch(() => props.peaksUrl, load, { immediate: true });

    const displayed = computed(() => {
      if (!rawPeaks.value) return [];
      return sliceAndDownsamplePeaks(
        rawPeaks.value, props.sourceStart, props.sourceEnd, props.sourceDuration, 600,
      );
    });

    const pathD = computed(() => {
      const p = displayed.value;
      if (!p.length) return "";
      const n = p.length;
      const H = 100;
      const mid = H / 2;
      const amp = (H / 2) - 4;
      let top = `M 0 ${(mid - p[0] * amp).toFixed(2)}`;
      for (let i = 1; i < n; i++) {
        top += ` L ${i} ${(mid - p[i] * amp).toFixed(2)}`;
      }
      let bot = "";
      for (let i = n - 1; i >= 0; i--) {
        bot += ` L ${i} ${(mid + p[i] * amp).toFixed(2)}`;
      }
      return `${top}${bot} Z`;
    });

    return { displayed, pathD };
  },
  template: `
    <svg v-if="displayed.length" class="tl-waveform" :viewBox="'0 0 ' + displayed.length + ' 100'" preserveAspectRatio="none" aria-hidden="true">
      <path :d="pathD"></path>
    </svg>
  `,
};

var OP_TYPES = [
  { value: "remove_silences", label: "Quitar silencios del rango",  kinds: ["relative"] },
  { value: "to_vertical",  label: "Formato vertical 9:16",       kinds: ["relative", "absolute"] },
  { value: "vertical_split", label: "Vertical 9:16 apilado (TikTok)", kinds: ["relative", "absolute"] },
  { value: "cut_before",   label: "Cortar todo lo anterior",     kinds: ["relative"] },
  { value: "cut_after",    label: "Cortar todo lo posterior",    kinds: ["relative"] },
  { value: "insert_clip",  label: "Insertar clip",               kinds: ["relative"] },
  { value: "switch_video", label: "Cambiar de cámara/video",     kinds: ["relative"] },
  { value: "zoom_in",      label: "Zoom in",                     kinds: ["relative", "absolute"] },
  { value: "zoom_out",     label: "Zoom out (volver normal)",    kinds: ["relative", "absolute"] },
  { value: "color_effect", label: "Efecto de color",             kinds: ["relative", "absolute"] },
  { value: "audio_replace",label: "Reemplazar audio",            kinds: ["relative"] },
  { value: "audio_mix",    label: "Mezclar audio extra",         kinds: ["relative"] },
  { value: "subtitle",     label: "Mostrar subtítulo",           kinds: ["relative", "absolute"] },
  { value: "jump_to_moment", label: "Saltar al siguiente momento", kinds: ["relative", "absolute"] },
  { value: "text_overlay",   label: "Texto cómic (PUM/BANG/custom)",  kinds: ["relative", "absolute"] },
];

var COMIC_FONTS = [
  { key: "bangers",          label: "Bangers (Batman TV)",  family: "Bangers" },
  { key: "titan_one",        label: "Titan One",            family: "Titan One" },
  { key: "luckiest_guy",     label: "Luckiest Guy",         family: "Luckiest Guy" },
  { key: "permanent_marker", label: "Permanent Marker",     family: "Permanent Marker" },
];

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
        <div class="eyebrow">STUDIO · ON AIR</div>
        <h2>post<em>Pod</em></h2>
        <div class="subtitle">Suite de postproducción no-destructiva para podcast y videocast.</div>
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
            {{ busy ? "Verificando…" : "Ingresar al estudio" }}
          </button>
        </form>
        <div class="footer-line">
          <span>CH · 01</span>
          <span>v0.3 · plan 3</span>
        </div>
      </div>
    </div>
  `,
};

/* ==========================================================================
   Project list
   ========================================================================== */

var ProjectListView = {
  props: { onOpen: { type: Function, required: true } },
  setup(props) {
    const projects = ref([]);
    const loading = ref(true);
    const error = ref("");
    const showCreate = ref(false);
    const newName = ref("");
    const creating = ref(false);

    async function load() {
      loading.value = true;
      error.value = "";
      try { projects.value = await api("/api/projects"); }
      catch (e) { error.value = e.message; }
      finally { loading.value = false; }
    }

    async function create() {
      if (!newName.value.trim()) return;
      creating.value = true;
      try {
        const p = await api("/api/projects", {
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
      if (!await podSwal.confirm(`¿Eliminar proyecto "${p.name}"?\nSe borrarán TODOS los archivos del proyecto.`)) return;
      try { await api(`/api/projects/${p.slug}`, { method: "DELETE" }); await load(); }
      catch (e) { error.value = e.message; }
    }

    function fmtDate(s) {
      if (!s) return "";
      try {
        return new Date(s).toLocaleString("es-AR", { day: "2-digit", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit" });
      } catch (_) { return s; }
    }

    async function importProject(ev) {
      const file = ev.target.files?.[0];
      if (!file) return;
      const form = new FormData();
      form.append("file", file);
      try {
        const r = await fetch("/api/projects/import", {
          method: "POST",
          body: form,
        });
        const data = await r.json();
        if (!r.ok) { error.value = data.error || "Error al importar"; return; }
        if (data.warning) alert(data.warning);
        await load();
      } catch (e) {
        error.value = "Error al importar: " + e.message;
      }
    }

    onMounted(load);
    return { projects, loading, error, showCreate, newName, creating, create, remove, fmtDate, importProject };
  },
  template: `
    <div class="container">
      <div class="page-head">
        <div>
          <div class="eyebrow">PROYECTOS · SESIONES ACTIVAS</div>
          <h2>Control <em style="color:var(--signal);font-style:italic;">room</em></h2>
        </div>
        <div class="spacer"></div>
        <button class="primary" @click="showCreate = true">＋ Nuevo proyecto</button>
        <button class="ghost" @click="$refs.importInput.click()" title="Importar proyecto (.zip) o archivo de medios (.mp4, .webm, .mp3, etc.)">⇧ Importar</button>
        <input ref="importInput" type="file" accept=".zip,video/*,audio/*,image/*" style="display:none" @change="importProject">
      </div>
      <div v-if="error" class="error">{{ error }}</div>
      <div v-if="loading" class="muted">Cargando sesiones…</div>
      <div v-else-if="projects.length === 0" class="empty-state">
        <div class="icon">∅</div>
        <div style="font-family:var(--font-display); font-size:18px; font-style:italic; margin-bottom:4px;">
          Todavía no hay proyectos.
        </div>
        <div>Creá el primero para arrancar a editar.</div>
      </div>
      <div v-else class="project-list">
        <div v-for="p in projects" :key="p.slug" class="project-tile" @click="$props.onOpen(p)">
          <div class="stamp">SESIÓN · {{ fmtDate(p.created_at) }}</div>
          <h3>{{ p.name }}</h3>
          <div class="slug">/ {{ p.slug }}</div>
          <div class="bottom">
            <span class="tiny">Abrir →</span>
            <button class="danger" @click="remove(p, $event)">Eliminar</button>
          </div>
        </div>
      </div>
      <div v-if="showCreate" class="modal-backdrop" @click.self="showCreate = false">
        <div class="modal">
          <div class="eyebrow">NUEVA SESIÓN</div>
          <h3>Crear proyecto</h3>
          <p class="muted" style="margin-bottom:18px;">El nombre puede tener acentos, espacios o emojis. Se genera un slug automáticamente.</p>
          <div class="form-row">
            <label>Nombre</label>
            <input type="text" v-model="newName" @keyup.enter="create" autofocus placeholder="Piloto Podcast Nº 1">
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
   Video player — multi-clip aware + CSS effects
   ========================================================================== */

var VideoPlayer = {
  props: {
    clips: Array,           // withTimelineStarts(timeline.clips), each has source URL, start_offset, end_offset, start, end, duration
    playerState: Object,
    zoom: Object,
    effects: Object,        // { filter, transform, subtitles[] }
    moments: Array,         // all moments with their operations, used for jump_to_moment
    selectedRange: Object,  // { start, end } | null — range selected by drag on the timeline
    liveSelection: Object,  // { start, end } | null — in-flight drag, updated every pointermove
    verticalSplitSources: Array, // [{url, localTime, cropX, track}] | null — feeds the stacked preview when a vertical_split op is active
    multitrackPreview: Boolean,  // true when auto-multitrack (side-by-side 16:9), false for vertical_split (9:16)
    audioLane: Array,       // parallel audio lane clips for preview playback
    textOverlaySounds: Array, // one-shot sounds bound to text_overlay ops
    editingOverlay: Object, // shared ref with OpForm for WYSIWYG text_overlay editing
    liveCaption: String,    // current SRT segment text or null
    captionsEnabled: Boolean,
    karaokeWords: { type: Array, default: null },
    karaokeStyle: { type: Object, default: null },
    karaokeMode: { type: Boolean, default: false },
  },
  emits: ["toggle-captions"],
  setup(props) {
    const videoEl = ref(null);
    const rangeMode = ref("free");
    const currentClipId = ref(null);
    const lastTimelineT = ref(0);
    let jumpCooldownUntil = 0;  // epoch ms, suppresses double-jumps after a jump

    const activeClip = computed(() => clipAtTime(props.clips, props.playerState.currentTime, props.moments));

    const karaokeWindow = computed(() => {
      if (!props.karaokeMode || !props.karaokeWords || !props.karaokeWords.length) return null;
      const t = props.playerState.currentTime;
      const words = props.karaokeWords;
      let best = -1;
      for (let i = 0; i < words.length; i++) {
        if (words[i].s <= t && words[i].e >= t) { best = i; break; }
        if (words[i].s > t) { best = Math.max(0, i - 1); break; }
      }
      if (best < 0) best = words.length - 1;
      const groupStart = Math.max(0, best - 1);
      const groupEnd = Math.min(words.length, groupStart + 4);
      return words.slice(groupStart, groupEnd).map(w => ({
        text: w.w,
        active: w.s <= t && w.e >= t,
      }));
    });

    // Preload jump_to_moment targets' media so the jump doesn't lag when it
    // crosses into a different source clip. We keep one hidden <video> per
    // distinct target URL; the browser caches the bytes and the real player's
    // swapTo reuses them instantly.
    const preloadEls = new Map();  // url -> HTMLVideoElement
    function syncJumpPreload() {
      const want = new Set();
      const ms = props.moments || [];
      for (const m of ms) {
        const ops = m.operations || [];
        const jump = ops.find(o => o.type === "jump_to_moment");
        if (!jump) continue;
        const tgt = ms.find(mm => mm.id === jump.params?.target_moment_id);
        if (!tgt) continue;
        const tgtClip = clipAtTime(props.clips, tgt.timeline_seconds, props.moments);
        if (tgtClip?.source?.url) want.add(tgtClip.source.url);
      }
      // Add missing
      for (const url of want) {
        if (preloadEls.has(url)) continue;
        const el = document.createElement("video");
        el.src = url; el.preload = "auto"; el.muted = true;
        el.style.position = "absolute"; el.style.width = "1px"; el.style.height = "1px";
        el.style.opacity = "0"; el.style.pointerEvents = "none";
        document.body.appendChild(el);
        preloadEls.set(url, el);
      }
      // Remove stale
      for (const [url, el] of preloadEls) {
        if (want.has(url)) continue;
        try { el.remove(); } catch (_) {}
        preloadEls.delete(url);
      }
    }
    watch(() => [props.moments, props.clips], syncJumpPreload, { deep: true, immediate: true });
    onBeforeUnmount(() => {
      for (const [, el] of preloadEls) { try { el.remove(); } catch (_) {} }
      preloadEls.clear();
    });

    const visibleDuration = computed(() => {
      const end = props.zoom.endSeconds ?? props.playerState.duration;
      return Math.max(0, end - props.zoom.startSeconds);
    });
    // Effective range for "Rango" / "Lento" playback: selectedRange wins over zoom.
    const effectiveRange = computed(() => {
      const sel = props.selectedRange;
      if (sel && sel.end > sel.start + 0.01) return { start: sel.start, end: sel.end };
      return { start: props.zoom.startSeconds || 0,
               end:   props.zoom.endSeconds ?? props.playerState.duration };
    });
    const rangeDuration = computed(() => Math.max(0, effectiveRange.value.end - effectiveRange.value.start));
    const canSlowPlay = computed(() => rangeDuration.value > 0 && rangeDuration.value <= 10);

    function currentSrc() {
      const c = activeClip.value;
      return c?.source?.url || null;
    }

    function localTimeForClip(clip, timelineT) {
      const start = clip.start;
      const offset = clip.start_offset || 0;
      return offset + (timelineT - start);
    }

    // seek in timeline seconds; returns a Promise that resolves when the
    // underlying <video> is at the requested position (loads src if needed).
    function seek(t, autoPlay = false) {
      const total = props.playerState.duration;
      const clamped = Math.max(0, Math.min(t, total || t));
      props.playerState.currentTime = clamped;
      // A deliberate seek is a hard discontinuity; force-realign lane audio.
      laneLastSync.clear();
      const c = clipAtTime(props.clips, clamped, props.moments);
      if (!c || !videoEl.value) return Promise.resolve();
      if (currentClipId.value !== c.id) {
        return swapTo(c, clamped, autoPlay ? "resume" : null);
      }
      const localT = Math.max(0, localTimeForClip(c, clamped));
      const max = videoEl.value.duration ? videoEl.value.duration - 0.01 : localT;
      videoEl.value.currentTime = Math.min(localT, max);
      if (autoPlay) videoEl.value.play().catch(() => {});
      return Promise.resolve();
    }

    function swapTo(clip, timelineT, afterLoad /* "resume" | null */) {
      currentClipId.value = clip.id;
      const v = videoEl.value;
      if (!v) return Promise.resolve();
      const target = clip.source?.url || "";
      // Pause during src swap so no stale timeupdate events fire with t=0 of the new clip.
      try { v.pause(); } catch (_) {}
      const localT = Math.max(0, localTimeForClip(clip, timelineT));
      const needsLoad = !v.src || !v.src.endsWith(target);

      return new Promise((resolve) => {
        const finish = () => {
          const max = v.duration ? v.duration - 0.01 : localT;
          v.currentTime = Math.min(localT, max);
          // Firefox may reset or implicitly mute on src swap — re-assert audio.
          v.muted = false;
          const volTarget = props.playerState?.volume ?? 1.0;
          if (Math.abs(v.volume - volTarget) > 0.001) v.volume = volTarget;
          if (afterLoad === "resume") v.play().catch(() => {});
          resolve();
        };
        if (needsLoad) {
          const onLoad = () => {
            v.removeEventListener("loadedmetadata", onLoad);
            finish();
          };
          v.addEventListener("loadedmetadata", onLoad);
          v.src = target;
          // Note: don't call v.load() — setting src already triggers load in
          // every browser, and Firefox sometimes double-loads which races
          // with the loadedmetadata handler and drops audio init.
        } else {
          finish();
        }
      });
    }

    function _unmute(v) {
      if (isMultitrackSplit.value) { v.muted = true; return; }
      v.muted = false;
      const clipVol = activeClip.value?.volume ?? 1.0;
      const globalVol = props.playerState?.volume ?? 1.0;
      const target = Math.max(0, Math.min(1, clipVol * globalVol));
      if (Math.abs(v.volume - target) > 0.001) v.volume = target;
    }

    // When active clip changes, volume is edited, or multitrack state changes, re-apply.
    watch(() => [activeClip.value?.volume, props.playerState.volume, activeClip.value?.id, isMultitrackSplit.value], () => {
      if (videoEl.value) _unmute(videoEl.value);
    });

    function togglePlay() {
      const v = videoEl.value;
      if (!v || !activeClip.value) return;
      rangeMode.value = "free";
      v.playbackRate = 1.0;
      _unmute(v);
      if (v.paused) v.play().catch(() => {});
      else v.pause();
    }

    async function playVisibleRange() {
      if (rangeDuration.value <= 0) return;
      rangeMode.value = "range";
      const v = videoEl.value;
      if (v) { _unmute(v); v.playbackRate = 1.0; v.play().catch(() => {}); }
      await seek(effectiveRange.value.start, false);
      if (videoEl.value) {
        videoEl.value.playbackRate = 1.0;
        _unmute(videoEl.value);
        if (videoEl.value.paused) videoEl.value.play().catch(() => {});
      }
    }
    async function playSlow10s() {
      if (!canSlowPlay.value) return;
      rangeMode.value = "slow";
      const rate = Math.max(0.01, rangeDuration.value / 10.0);
      const v = videoEl.value;
      if (v) { _unmute(v); v.play().catch(() => {}); }
      await seek(effectiveRange.value.start, false);
      if (videoEl.value) {
        videoEl.value.playbackRate = rate;
        _unmute(videoEl.value);
        if (videoEl.value.paused) videoEl.value.play().catch(() => {});
      }
    }

    function onTimeUpdate() {
      const v = videoEl.value;
      const clip = activeClip.value;
      if (!v || !clip) return;
      // Local (within source file) time
      const localT = v.currentTime;
      // Convert to timeline time
      const timelineT = clip.start + (localT - (clip.start_offset || 0));
      const prevT = lastTimelineT.value;
      props.playerState.currentTime = timelineT;
      lastTimelineT.value = timelineT;
      _syncLaneAudio();
      _syncOverlaySounds();

      // jump_to_moment: if we just crossed a moment's position and it has a
      // jump op, seek to the target moment. Cooldown prevents immediate
      // re-trigger loops when target is earlier in the timeline.
      const now = Date.now();
      if (!v.paused && now > jumpCooldownUntil && (props.moments || []).length) {
        for (const m of props.moments) {
          if (!m.operations) continue;
          const jumpOp = m.operations.find(o => o.type === "jump_to_moment");
          if (!jumpOp) continue;
          const hit = (m.timeline_seconds > prevT && m.timeline_seconds <= timelineT);
          if (!hit) continue;
          const tgt = props.moments.find(mm => mm.id === jumpOp.params?.target_moment_id);
          if (!tgt) continue;
          jumpCooldownUntil = now + 400;
          seek(tgt.timeline_seconds, true);
          break;
        }
      }

      // Did we cross clip.end? Advance to the NEXT clip on the same track
      // (tracks are parallel; a switch_track op may have changed the active
      // track so let the activeClip computed resolve via clipAtTime).
      const srcEnd = clip.end_offset ?? (clip.source?.duration ?? Infinity);
      if (localT >= srcEnd - 0.02) {
        const next = (props.clips || [])
          .filter(x => (x.track || 1) === (clip.track || 1))
          .find(x => x.start >= clip.end - 1e-6);
        if (next) {
          swapTo(next, next.start, "resume");
        } else {
          v.pause();
          rangeMode.value = "free";
        }
      }

      // Bounded playback modes stop at zoom end
      const zEnd = effectiveRange.value.end;
      if (rangeMode.value !== "free" && timelineT >= zEnd - 0.01) {
        v.pause();
        v.playbackRate = 1.0;
        rangeMode.value = "free";
      }
    }

    // ---- Audio lane playback (parallel music/SFX) ----
    const laneAudioEls = new Map();   // clip_id -> HTMLAudioElement
    function _ensureLaneEl(lc) {
      let el = laneAudioEls.get(lc.id);
      if (!el) {
        el = new Audio();
        el.preload = "auto";
        el.src = lc.source?.url || "";
        laneAudioEls.set(lc.id, el);
      }
      return el;
    }
    // Track when we last hard-synced each lane element so we only nudge on
    // meaningful drift (avoid the per-tick currentTime=… that causes audible
    // stutter every time the video element emits a timeupdate).
    const laneLastSync = new Map();  // id -> epoch ms
    function _syncLaneAudio(force) {
      const t = props.playerState.currentTime || 0;
      const v = videoEl.value;
      const videoPlaying = v && !v.paused;
      const rate = v ? (v.playbackRate || 1) : 1;
      const lane = props.audioLane || [];
      const wanted = new Set();
      const now = Date.now();
      for (const lc of lane) {
        wanted.add(lc.id);
        const el = _ensureLaneEl(lc);
        el.volume = Math.max(0, Math.min(2, lc.volume || 0));
        if (Math.abs(el.playbackRate - rate) > 0.01) el.playbackRate = rate;

        const inRange = t >= lc.tl_start - 0.02 && t < lc.tl_end - 0.02;
        if (!inRange || !videoPlaying) {
          if (!el.paused) el.pause();
          laneLastSync.delete(lc.id);
          continue;
        }

        const localT = (lc.start_offset || 0) + (t - lc.tl_start);
        const drift = Math.abs(el.currentTime - localT);
        const lastSync = laneLastSync.get(lc.id) || 0;
        const sinceSync = now - lastSync;

        // Hard-sync only when truly needed. Cooldown of 800ms prevents the
        // burst of timeupdate events that fire around a seek from re-seeking
        // the audio element multiple times in a row.
        const firstTouch = !lastSync;
        const bigDrift = drift > 1.0 && sinceSync > 800;
        if (firstTouch || bigDrift) {
          try { el.currentTime = Math.max(0, localT); } catch (_) {}
          laneLastSync.set(lc.id, now);
        }
        if (el.paused) el.play().catch(() => {});
      }
      for (const [id, el] of laneAudioEls) {
        if (!wanted.has(id)) {
          try { el.pause(); el.src = ""; } catch (_) {}
          laneAudioEls.delete(id);
          laneLastSync.delete(id);
        }
      }
    }
    watch(() => props.audioLane, _syncLaneAudio, { deep: true });

    // One-shot text_overlay sounds: keep one HTMLAudioElement per op id.
    // Keyed by `${op.id}|${url}` so url changes replace the element cleanly.
    const overlaySoundEls = new Map();     // key -> HTMLAudioElement
    const overlayLastFired = new Map();    // op.id -> last tl_start that fired
    function _soundKey(s) { return s.id + "|" + s.url; }
    const DBG = new URLSearchParams(location.search).has("dbg");
    function _syncOverlaySounds() {
      const t = props.playerState.currentTime || 0;
      const v = videoEl.value;
      const videoPlaying = v && !v.paused;
      const list = props.textOverlaySounds || [];
      if (DBG) console.log("[overlay-sync] t=", t.toFixed(3), "playing=", videoPlaying, "sounds=", list.length, list);
      const wantedKeys = new Set();
      for (const s of list) {
        const key = _soundKey(s);
        wantedKeys.add(key);
        let el = overlaySoundEls.get(key);
        if (!el) {
          el = new Audio();
          el.preload = "auto";
          el.src = s.url;
          overlaySoundEls.set(key, el);
        }
        el.volume = Math.max(0, Math.min(2, s.volume || 1));
        const inRange = t >= s.tl_start - 0.02 && t < s.tl_end - 0.02;
        if (inRange && videoPlaying) {
          if (overlayLastFired.get(s.id) !== s.tl_start) {
            overlayLastFired.set(s.id, s.tl_start);
            if (DBG) console.log("[overlay-fire]", s.id, "url=", s.url, "vol=", el.volume);
            try {
              el.currentTime = Math.max(0, t - s.tl_start);
              el.play().then(() => { if (DBG) console.log("[overlay-fire OK]", s.id); })
                       .catch(err => { if (DBG) console.warn("[overlay-fire FAIL]", s.id, err); });
            } catch (err) { if (DBG) console.warn("[overlay-fire EXC]", err); }
          }
        } else {
          if (!el.paused && t < s.tl_start - 0.02) {
            try { el.pause(); } catch (_) {}
            overlayLastFired.delete(s.id);
          }
          if (t >= s.tl_end - 0.02) overlayLastFired.delete(s.id);
        }
      }
      for (const [key, el] of overlaySoundEls) {
        if (!wantedKeys.has(key)) {
          try { el.pause(); el.src = ""; } catch (_) {}
          overlaySoundEls.delete(key);
        }
      }
    }
    watch(() => props.textOverlaySounds, _syncOverlaySounds, { deep: true, immediate: true });

    onBeforeUnmount(() => {
      for (const [, el] of laneAudioEls) { try { el.pause(); el.src = ""; } catch (_) {} }
      laneAudioEls.clear();
      for (const [, el] of overlaySoundEls) { try { el.pause(); el.src = ""; } catch (_) {} }
      overlaySoundEls.clear();
    });

    function onPlay() { props.playerState.isPlaying = true; _syncLaneAudio(); _syncOverlaySounds(); }
    function onPause() { props.playerState.isPlaying = false; _syncLaneAudio(); _syncOverlaySounds(); }
    function onVolumeChange() {
      if (videoEl.value) props.playerState.volume = videoEl.value.volume;
    }

    watch(() => props.playerState.volume, () => {
      if (videoEl.value) _unmute(videoEl.value);
    });

    // When active clip changes (e.g., timeline rebuilt), swap src to first clip at currentTime
    watch(activeClip, (clip, oldClip) => {
      if (!clip) { currentClipId.value = null; return; }
      if (clip.id !== currentClipId.value) {
        swapTo(clip, props.playerState.currentTime, null);
      }
    }, { immediate: true });

    const tc = computed(() => formatTimecode(props.playerState.currentTime));
    const tcTotal = computed(() => formatTimecode(props.playerState.duration));

    // Range readout: while the user is drag-selecting (liveSelection) OR
    // after they commit (selectedRange), the big clock at the top of the
    // player swaps from "currentTime / total" to "start → end · duration"
    // so they get instant feedback without looking at the timeline.
    const rangeReadout = computed(() => {
      const r = props.liveSelection || props.selectedRange;
      if (!r) return null;
      const dur = Math.max(0, (r.end || 0) - (r.start || 0));
      return {
        start: formatTimecode(r.start || 0),
        end: formatTimecode(r.end || 0),
        durationSec: dur,
        live: !!props.liveSelection,
      };
    });

    const frameStyle = computed(() => {
      const eff = props.effects || {};
      const out = {};
      if (eff.filter) out.filter = eff.filter;
      if (eff.transform) {
        out.transform = eff.transform;
        out.transformOrigin = "center";
        out.transition = "transform 250ms var(--ease), filter 250ms var(--ease)";
      } else {
        out.transition = "filter 250ms var(--ease)";
      }
      return out;
    });

    const verticalStyle = computed(() => {
      const v = props.effects?.vertical;
      if (!v) return null;
      // Shift object-position horizontally based on cropX (0..1 → 0%..100%)
      return { objectPosition: `${(v.cropX ?? 0.5) * 100}% 50%` };
    });
    const isVerticalSplit = computed(() => {
      const srcs = props.verticalSplitSources || [];
      return srcs.some(s => s && s.url);
    });
    const isMultitrackSplit = computed(() => isVerticalSplit.value && !!props.multitrackPreview);
    const isVertical = computed(() =>
      !!props.effects?.vertical || (isVerticalSplit.value && !isMultitrackSplit.value)
    );

    function textOverlayFontFamily(key) {
      const map = {
        bangers: "Bangers, sans-serif",
        titan_one: "'Titan One', sans-serif",
        luckiest_guy: "'Luckiest Guy', sans-serif",
        permanent_marker: "'Permanent Marker', sans-serif",
      };
      return map[key] || map.bangers;
    }
    function textOverlayShadow(ov) {
      if (!ov.shadow) return "none";
      return "4px 6px 0 rgba(0,0,0,0.6), 0 0 10px rgba(0,0,0,0.3)";
    }

    // WYSIWYG drag/resize/rotate for the overlay currently being edited.
    function _frameBox() {
      const host = videoEl.value?.closest?.(".video-frame");
      if (!host) return null;
      return host.getBoundingClientRect();
    }
    function onEditOverlayPointerDown(ev, handle) {
      const ov = props.editingOverlay;
      if (!ov) return;
      const box = _frameBox();
      if (!box) return;
      ev.preventDefault(); ev.stopPropagation();
      const startX = ev.clientX, startY = ev.clientY;
      const startParams = { x_pct: ov.x_pct, y_pct: ov.y_pct,
                            size_pct: ov.size_pct, rotation_deg: ov.rotation_deg };
      const cx = box.left + box.width * ov.x_pct;
      const cy = box.top  + box.height * ov.y_pct;

      function move(e) {
        if (handle === "move") {
          const dx = (e.clientX - startX) / box.width;
          const dy = (e.clientY - startY) / box.height;
          ov.x_pct = Math.max(0, Math.min(1, startParams.x_pct + dx));
          ov.y_pct = Math.max(0, Math.min(1, startParams.y_pct + dy));
        } else if (handle === "resize") {
          const distStart = Math.hypot(startX - cx, startY - cy);
          const distNow   = Math.hypot(e.clientX - cx, e.clientY - cy);
          const factor = distNow / Math.max(1, distStart);
          ov.size_pct = Math.max(3, Math.min(60, startParams.size_pct * factor));
        } else if (handle === "rotate") {
          const a0 = Math.atan2(startY - cy, startX - cx);
          const a1 = Math.atan2(e.clientY - cy, e.clientX - cx);
          const delta = (a1 - a0) * 180 / Math.PI;
          let next = startParams.rotation_deg + delta;
          while (next > 180) next -= 360;
          while (next < -180) next += 360;
          ov.rotation_deg = Math.round(next);
        }
      }
      function up() {
        window.removeEventListener("pointermove", move);
        window.removeEventListener("pointerup", up);
      }
      window.addEventListener("pointermove", move);
      window.addEventListener("pointerup", up);
    }

    // ---- Vertical-split preview: keep panel <video>s in sync ----
    // Each panel is a thin wrapper around an HTMLVideoElement that we drive
    // manually via the playerState. We don't try for frame-perfect sync —
    // the goal is "show the user what TikTok will look like", which a
    // two-frame drift doesn't break.
    const splitPanelEls = ref([]);  // Vue refs for the <video> elements
    function setSplitPanelEl(el, idx) {
      if (!el) return;
      splitPanelEls.value[idx] = el;
    }
    function _syncSplitPanels() {
      const sources = props.verticalSplitSources || [];
      const playing = !!props.playerState.isPlaying;
      const mt = isMultitrackSplit.value;
      const globalVol = props.playerState?.volume ?? 1.0;
      for (let i = 0; i < sources.length; i++) {
        const el = splitPanelEls.value[i];
        const src = sources[i];
        if (!el || !src || !src.url) continue;
        if (el.dataset.url !== src.url) {
          el.src = src.url;
          el.dataset.url = src.url;
        }
        const want = Math.max(0, src.localTime || 0);
        if (Math.abs((el.currentTime || 0) - want) > 0.25) {
          try { el.currentTime = want; } catch (_) {}
        }
        if (mt) {
          el.muted = false;
          el.volume = Math.max(0, Math.min(1, (src.volume ?? 1.0) * globalVol));
        } else {
          el.muted = true;
        }
        if (playing) {
          if (el.paused) { el.play().catch(() => {}); }
        } else {
          if (!el.paused) el.pause();
        }
      }
      // In multitrack mode, mute the main video to avoid doubling audio.
      if (mt && videoEl.value) videoEl.value.muted = true;
    }
    watch(
      () => [props.playerState.currentTime, props.playerState.isPlaying, props.verticalSplitSources, isVerticalSplit.value],
      _syncSplitPanels,
      { flush: "post" },
    );

    return {
      videoEl, rangeMode, canSlowPlay, seek, togglePlay, playVisibleRange, playSlow10s,
      onTimeUpdate, onPlay, onPause, onVolumeChange,
      tc, tcTotal, rangeReadout, activeClip, frameStyle, isVertical, verticalStyle,
      isVerticalSplit, isMultitrackSplit, setSplitPanelEl,
      textOverlayFontFamily, textOverlayShadow, onEditOverlayPointerDown,
      karaokeWindow,
    };
  },
  template: `
    <div class="video-stage">
      <div class="video-frame" :class="{ 'vertical-preview': isVertical }">
        <div class="video-inner" :style="frameStyle">
          <video
            v-show="activeClip && !isVerticalSplit"
            ref="videoEl"
            :style="verticalStyle"
            :class="{ vertical: isVertical }"
            @timeupdate="onTimeUpdate"
            @play="onPlay"
            @pause="onPause"
            @volumechange="onVolumeChange"
            @click="togglePlay"
            preload="metadata"
          ></video>

          <div v-if="isVerticalSplit" :class="isMultitrackSplit ? 'multitrack-frame' : 'vsplit-frame'"
               @click="togglePlay">
            <div
              v-for="(src, i) in (verticalSplitSources || [])"
              :key="'vsplit-' + i"
              class="vsplit-panel"
            >
              <video
                v-if="src && src.url"
                :ref="(el) => setSplitPanelEl(el, i)"
                :style="{ objectPosition: ((src.cropX || 0.5) * 100) + '% 50%' }"
                preload="metadata"
                :muted="!isMultitrackSplit"
                playsinline
              ></video>
              <div v-else class="vsplit-empty">sin clip en track {{ i + 1 }}</div>
              <div class="vsplit-track-tag">T{{ i + 1 }}</div>
            </div>
          </div>
        </div>
        <div v-if="isVertical" class="vertical-badge">9:16</div>
        <template v-if="effects && effects.subtitles">
          <div
            v-for="(s, i) in effects.subtitles"
            :key="i"
            class="subtitle-overlay"
            :class="'pos-' + (s.position || 'bottom')"
          >{{ s.text }}</div>
        </template>
        <div v-if="liveCaption" class="caption-overlay">{{ liveCaption }}</div>
        <div v-if="karaokeWindow" class="karaoke-overlay"
             :class="'pos-' + (karaokeStyle?.position || 'center')">
          <span v-for="(kw, ki) in karaokeWindow" :key="ki"
                class="karaoke-word" :class="{ active: kw.active }">
            {{ kw.text }}
          </span>
        </div>
        <template v-if="effects && effects.textOverlays && effects.textOverlays.length">
          <div
            v-for="(ov, i) in effects.textOverlays"
            :key="'txt-' + i"
            class="text-overlay"
            :style="{
              left: (ov.x_pct * 100) + '%',
              top:  (ov.y_pct * 100) + '%',
              fontSize: ov.size_pct + 'cqmin',
              color: ov.color,
              fontFamily: textOverlayFontFamily(ov.font),
              transform: 'translate(-50%, -50%) rotate(' + ov.rotation_deg + 'deg)',
              textShadow: textOverlayShadow(ov),
              WebkitTextStroke: ov.outline ? '2px #000' : 'none',
            }"
          >{{ ov.text }}</div>
        </template>
        <div v-if="editingOverlay" class="text-overlay-edit"
             :style="{
               left: (editingOverlay.x_pct * 100) + '%',
               top:  (editingOverlay.y_pct * 100) + '%',
               transform: 'translate(-50%, -50%) rotate(' + editingOverlay.rotation_deg + 'deg)',
             }"
             @pointerdown="onEditOverlayPointerDown($event, 'move')">
          <div class="text-overlay"
               style="position: static; left: auto; top: auto; transform: none;"
               :style="{
                 fontSize: editingOverlay.size_pct + 'cqmin',
                 color: editingOverlay.color,
                 fontFamily: textOverlayFontFamily(editingOverlay.font),
                 textShadow: textOverlayShadow(editingOverlay),
                 WebkitTextStroke: editingOverlay.outline ? '2px #000' : 'none',
               }">{{ editingOverlay.text || '…' }}</div>
          <div class="text-overlay-box"></div>
          <div class="text-overlay-handle handle-rotate"
               @pointerdown.stop="onEditOverlayPointerDown($event, 'rotate')" title="Rotar">⟳</div>
          <div class="text-overlay-handle handle-resize"
               @pointerdown.stop="onEditOverlayPointerDown($event, 'resize')" title="Redimensionar">⇲</div>
        </div>
        <div v-if="!activeClip" class="video-placeholder">
          <div class="mark">◉</div>
          <div class="msg">Timeline vacío</div>
          <div class="hint">agrega clips desde el panel derecho</div>
        </div>
        <div v-if="activeClip" class="clip-indicator">
          <span class="tiny">CLIP</span>
          <span class="mono">{{ activeClip.label || activeClip.source && activeClip.source.original_name || ('#' + activeClip.id) }}</span>
        </div>
      </div>

      <div class="transport" v-if="activeClip">
        <button class="btn-play" @click="togglePlay" :title="playerState.isPlaying ? 'Pausar (Espacio)' : 'Reproducir (Espacio)'">
          <svg v-if="!playerState.isPlaying" viewBox="0 0 16 16"><path d="M3 1.5L14 8 3 14.5z" fill="currentColor"/></svg>
          <svg v-else viewBox="0 0 16 16"><rect x="3" y="2" width="4" height="12" fill="currentColor"/><rect x="9" y="2" width="4" height="12" fill="currentColor"/></svg>
        </button>
        <button class="btn-range" @click="playVisibleRange" :class="{primary: rangeMode === 'range'}" title="Reproducir rango visible a 1×">▶ Rango</button>
        <button class="btn-range" @click="playSlow10s" :disabled="!canSlowPlay" :class="{primary: rangeMode === 'slow'}" title="Estirar rango a 10s">◐ Lento</button>

        <div class="time-readout" :class="{ 'range-mode': rangeReadout, 'live': rangeReadout && rangeReadout.live }">
          <template v-if="rangeReadout">
            <span class="rr-prefix">RANGO</span>
            <span class="rr-time">{{ rangeReadout.start.mm }}:{{ rangeReadout.start.ss }}<span class="ms">.{{ rangeReadout.start.cs }}</span></span>
            <span class="rr-sep">→</span>
            <span class="rr-time">{{ rangeReadout.end.mm }}:{{ rangeReadout.end.ss }}<span class="ms">.{{ rangeReadout.end.cs }}</span></span>
            <span class="rr-dur">· {{ rangeReadout.durationSec.toFixed(2) }}s</span>
          </template>
          <template v-else>
            <span>{{ tc.hh }}</span><span class="sep">:</span><span>{{ tc.mm }}</span><span class="sep">:</span><span>{{ tc.ss }}</span><span class="ms">.{{ tc.cs }}</span>
            <span class="total">/ {{ tcTotal.hh }}:{{ tcTotal.mm }}:{{ tcTotal.ss }}</span>
          </template>
        </div>

        <div class="spacer"></div>

        <button class="btn-range" :class="{primary: captionsEnabled}"
                @click="$emit('toggle-captions')"
                :title="captionsEnabled ? (liveCaption ? 'Captions ON — segmento actual visible' : 'Captions ON, pero este clip no tiene SRT generado. Generalo con 🎙 desde el panel de archivos.') : 'Mostrar captions'">
          CC
          <span v-if="captionsEnabled && !liveCaption" style="font-size: 9px; margin-left: 4px; opacity: 0.85;">(sin SRT)</span>
        </button>

        <div class="volume">
          <span>VOL</span>
          <input type="range" min="0" max="1" step="0.01" v-model.number="playerState.volume">
        </div>
      </div>
    </div>
  `,
};

/* ==========================================================================
   Timeline
   ========================================================================== */

var Timeline = {
  components: { ClipWaveform },
  props: {
    clips: Array,
    playerState: Object,
    zoom: Object,
    moments: Array,
    selectedMomentId: Number,
    selectedRange: Object,  // { start, end } | null
    audioLane: Array,       // [{id, tl_start, tl_end, duration, volume, source, ...}]
  },
  emits: ["seek", "zoom-to", "select-moment", "lane-click", "lane-remove", "clip-click", "live-select"],
  setup(props, { emit }) {
    const root = ref(null);
    const selecting = ref(false);
    const selectStartPx = ref(0);
    const selectCurPx = ref(0);
    const playheadDragging = ref(false);
    const DRAG_THRESHOLD_PX = 4;

    const visibleStart = computed(() => props.zoom.startSeconds || 0);
    const visibleEnd = computed(() => {
      const e = props.zoom.endSeconds;
      if (e == null || e <= visibleStart.value) return Math.max(visibleStart.value + 0.001, props.playerState.duration || 0.001);
      return e;
    });
    const visibleDur = computed(() => Math.max(0.001, visibleEnd.value - visibleStart.value));

    function secToPct(t) { return ((t - visibleStart.value) / visibleDur.value) * 100; }

    function clipStyle(clip) {
      const clampedStart = Math.max(clip.start, visibleStart.value);
      const clampedEnd = Math.min(clip.end, visibleEnd.value);
      const left = secToPct(clampedStart);
      const width = secToPct(clampedEnd) - left;
      const fullyVisible = clip.start >= visibleStart.value && clip.end <= visibleEnd.value;
      return {
        left: `${left}%`,
        // Subtract ~3px from each clip's right edge to create a visible gap
        // between adjacent clips without affecting their absolute positions.
        width: `calc(${Math.max(0, width)}% - 3px)`,
        opacity: width < 0.4 ? 0.3 : (fullyVisible ? 1 : 0.85),
      };
    }
    function laneClipStyle(c) {
      const clampedStart = Math.max(c.tl_start, visibleStart.value);
      const clampedEnd = Math.min(c.tl_end, visibleEnd.value);
      const left = secToPct(clampedStart);
      const width = secToPct(clampedEnd) - left;
      return {
        left: `${left}%`,
        width: `calc(${Math.max(0, width)}% - 3px)`,
      };
    }

    const ticks = computed(() => {
      const interval = niceTickInterval(visibleDur.value);
      const first = Math.ceil(visibleStart.value / interval) * interval;
      const out = [];
      for (let t = first; t <= visibleEnd.value + 0.0001; t += interval) {
        out.push({ t, label: formatShort(t) });
      }
      return out;
    });

    function onPointerDown(ev) {
      if (!props.clips.length) return;
      if (ev.button !== 0) return;
      // Click on moment marker — select + jump to it, don't drag
      if (ev.target.classList.contains("tl-moment")) {
        const mid = Number(ev.target.dataset.momentId);
        if (mid) {
          emit("select-moment", mid);
          const m = props.moments.find(mm => mm.id === mid);
          if (m && m.timeline_seconds != null) emit("seek", m.timeline_seconds);
          return;
        }
      }
      // Mousedown on the playhead → scrubbing. Continuous seek while
      // dragging gives the user a "find the exact frame" affordance that
      // a one-shot click doesn't.
      if (ev.target.classList.contains("tl-cursor")) {
        playheadDragging.value = true;
        ev.preventDefault();
        window.addEventListener("pointermove", onPlayheadMove);
        window.addEventListener("pointerup", onPlayheadUp);
        return;
      }
      // Click on a video clip or audio-lane clip — let its own @click handler
      // open the editor; don't start a drag-selection.
      if (ev.target.closest(".tl-clip, .tl-lane-clip")) return;
      const rect = root.value.getBoundingClientRect();
      selecting.value = true;
      selectStartPx.value = ev.clientX - rect.left;
      selectCurPx.value = selectStartPx.value;
      window.addEventListener("pointermove", onPointerMove);
      window.addEventListener("pointerup", onPointerUp);
    }
    function onPlayheadMove(ev) {
      if (!playheadDragging.value || !root.value) return;
      const rect = root.value.getBoundingClientRect();
      const x = Math.max(0, Math.min(rect.width, ev.clientX - rect.left));
      const t = visibleStart.value + (x / rect.width) * visibleDur.value;
      emit("seek", t);
    }
    function onPlayheadUp() {
      playheadDragging.value = false;
      window.removeEventListener("pointermove", onPlayheadMove);
      window.removeEventListener("pointerup", onPlayheadUp);
    }
    function onPointerMove(ev) {
      if (!selecting.value || !root.value) return;
      const rect = root.value.getBoundingClientRect();
      selectCurPx.value = Math.max(0, Math.min(rect.width, ev.clientX - rect.left));
      // Push the in-flight range up to ProjectView so the big time-readout
      // in the player can mirror what the user is selecting in real time.
      const a = Math.min(selectStartPx.value, selectCurPx.value);
      const b = Math.max(selectStartPx.value, selectCurPx.value);
      const t0 = visibleStart.value + (a / rect.width) * visibleDur.value;
      const t1 = visibleStart.value + (b / rect.width) * visibleDur.value;
      emit("live-select", { start: t0, end: t1 });
    }
    function onPointerUp(ev) {
      if (!selecting.value) return;
      selecting.value = false;
      window.removeEventListener("pointermove", onPointerMove);
      window.removeEventListener("pointerup", onPointerUp);
      // Drop the live-select preview now that we've committed (or
      // discarded as a click).
      emit("live-select", null);
      const delta = Math.abs(selectCurPx.value - selectStartPx.value);
      const rect = root.value.getBoundingClientRect();
      if (delta < DRAG_THRESHOLD_PX) {
        const t = visibleStart.value + (selectStartPx.value / rect.width) * visibleDur.value;
        emit("seek", t);
      } else {
        const a = Math.min(selectStartPx.value, selectCurPx.value);
        const b = Math.max(selectStartPx.value, selectCurPx.value);
        const t0 = visibleStart.value + (a / rect.width) * visibleDur.value;
        const t1 = visibleStart.value + (b / rect.width) * visibleDur.value;
        emit("zoom-to", { start: t0, end: t1 });
      }
    }
    onBeforeUnmount(() => {
      window.removeEventListener("pointermove", onPointerMove);
      window.removeEventListener("pointerup", onPointerUp);
      window.removeEventListener("pointermove", onPlayheadMove);
      window.removeEventListener("pointerup", onPlayheadUp);
    });

    const cursorPct = computed(() => secToPct(props.playerState.currentTime));

    // Compute arcs for moments with jump_to_moment operations. Each link is a
    // thin SVG path drawn above the clips connecting source moment to target.
    const momentLinks = computed(() => {
      const out = [];
      (props.moments || []).forEach((m) => {
        const ops = m.operations || [];
        const jumpOp = ops.find(o => o.type === "jump_to_moment");
        if (!jumpOp) return;
        const tgt = (props.moments || []).find(mm => mm.id === jumpOp.params?.target_moment_id);
        if (!tgt) return;
        const x1 = secToPct(m.timeline_seconds);
        const x2 = secToPct(tgt.timeline_seconds);
        // Ignore links entirely outside the visible range
        if ((x1 < -5 && x2 < -5) || (x1 > 105 && x2 > 105)) return;
        out.push({ id: m.id + "->" + tgt.id, x1, x2 });
      });
      return out;
    });

    const selectRect = computed(() => {
      if (!selecting.value || !root.value) return null;
      const rect = root.value.getBoundingClientRect();
      const a = Math.min(selectStartPx.value, selectCurPx.value);
      const b = Math.max(selectStartPx.value, selectCurPx.value);
      return { left: `${(a / rect.width) * 100}%`, width: `${((b - a) / rect.width) * 100}%` };
    });

    const persistedRangeStyle = computed(() => {
      const r = props.selectedRange;
      if (!r || r.end <= r.start + 0.01) return null;
      const a = secToPct(r.start);
      const b = secToPct(r.end);
      if (b < 0 || a > 100) return null;
      return { left: Math.max(0, a) + "%", width: Math.min(100, b) - Math.max(0, a) + "%" };
    });

    // Floating time label — visible while drag-selecting OR while
    // scrubbing the playhead. During selection it follows the cursor;
    // during scrub it sits at the current play position.
    const timeTooltip = computed(() => {
      if (playheadDragging.value) {
        const t = props.playerState.currentTime || 0;
        return { leftPct: secToPct(t), label: formatShort(t), variant: "scrub" };
      }
      if (selecting.value && root.value) {
        const rect = root.value.getBoundingClientRect();
        if (rect.width <= 0) return null;
        const a = Math.min(selectStartPx.value, selectCurPx.value);
        const b = Math.max(selectStartPx.value, selectCurPx.value);
        const t0 = visibleStart.value + (a / rect.width) * visibleDur.value;
        const t1 = visibleStart.value + (b / rect.width) * visibleDur.value;
        const dur = Math.max(0, t1 - t0);
        const leftPct = ((selectCurPx.value / rect.width) * 100);
        return {
          leftPct: Math.max(0, Math.min(100, leftPct)),
          label: `${formatShort(t1)}`,
          rangeLabel: dur > 0.05
            ? `${formatShort(t0)} → ${formatShort(t1)}  ·  ${dur.toFixed(2)}s`
            : null,
          variant: "select",
        };
      }
      return null;
    });

    const maxTrack = computed(() => {
      let m = 1;
      for (const c of props.clips) { const t = c.track || 1; if (t > m) m = t; }
      return m;
    });
    const clipsHeight = computed(() => (maxTrack.value * 20) + 'px');

    return {
      root, cursorPct, selectRect, persistedRangeStyle, ticks, clipStyle, laneClipStyle, secToPct, onPointerDown,
      visibleStart, visibleEnd, formatShort, momentLinks,
      playheadDragging, timeTooltip, clipsHeight,
    };
  },
  template: `
    <div class="timeline" :class="{empty: clips.length === 0}" ref="root" @pointerdown="onPointerDown">
      <div class="tl-ticks">
        <div v-for="tick in ticks" :key="tick.t" class="tl-tick" :style="{left: secToPct(tick.t) + '%'}">
          {{ tick.label }}
        </div>
      </div>
      <div v-if="clips.length" class="tl-edge tl-edge-start">{{ formatShort(visibleStart) }}</div>
      <div v-if="clips.length" class="tl-edge tl-edge-end">{{ formatShort(visibleEnd) }}</div>
      <div v-if="audioLane && audioLane.length" class="tl-audio-lane">
        <div class="tl-lane-label">AUDIO</div>
        <div
          v-for="lc in audioLane"
          :key="'lane-' + lc.id"
          class="tl-lane-clip"
          :style="laneClipStyle(lc)"
          :title="(lc.label || (lc.source && lc.source.original_name) || '') + ' · vol ' + lc.volume.toFixed(2) + ' · @' + lc.tl_start.toFixed(2) + 's'"
          @click.stop="$emit('lane-click', lc)"
          @contextmenu.prevent="$emit('lane-remove', lc)"
        >
          <ClipWaveform
            v-if="lc.source && lc.source.peaks_url && lc.source.duration"
            :peaks-url="lc.source.peaks_url"
            :source-start="lc.start_offset || 0"
            :source-end="lc.end_offset != null ? lc.end_offset : lc.source.duration"
            :source-duration="lc.source.duration"
          />
          <span class="tl-lane-clip-name">{{ lc.label || (lc.source && lc.source.original_name) }}</span>
        </div>
      </div>
      <div class="tl-clips" :style="{height: clipsHeight}">
        <div
          v-for="clip in clips"
          :key="clip.id"
          class="tl-clip"
          :class="[
            clip.source ? clip.source.file_type : 'video',
            'track-' + (clip.track || 1)
          ]"
          :style="clipStyle(clip)"
          :title="clip.label || (clip.source ? clip.source.original_name : '#' + clip.id)"
          @click.stop="$emit('clip-click', clip)"
        >
          <img v-if="clip.source && clip.source.thumbnail_url"
               :src="clip.source.thumbnail_url" class="tl-clip-thumb tl-clip-thumb-start" alt="">
          <img v-if="clip.source && (clip.source.thumbnail_end_url || clip.source.thumbnail_url)"
               :src="clip.source.thumbnail_end_url || clip.source.thumbnail_url"
               class="tl-clip-thumb tl-clip-thumb-end" alt="">
          <ClipWaveform
            v-if="clip.source && clip.source.peaks_url && clip.source.duration"
            :peaks-url="clip.source.peaks_url"
            :source-start="clip.start_offset || 0"
            :source-end="clip.end_offset != null ? clip.end_offset : clip.source.duration"
            :source-duration="clip.source.duration"
          />
          <span class="tl-clip-label">{{ clip.label || (clip.source ? clip.source.original_name : '#' + clip.id) }}</span>
        </div>
      </div>
      <template v-if="clips.length">
        <svg v-if="momentLinks.length" class="tl-links" preserveAspectRatio="none" viewBox="0 0 100 100">
          <path
            v-for="l in momentLinks" :key="l.id"
            :d="'M ' + l.x1 + ' 100 Q ' + ((l.x1 + l.x2) / 2) + ' 0 ' + l.x2 + ' 100'"
            vector-effect="non-scaling-stroke"
          />
          <circle v-for="l in momentLinks" :key="l.id + '-arrow'"
                  :cx="l.x2" cy="100" r="1.8" />
        </svg>
        <div v-if="playerState.duration > 0" class="tl-cursor"
             :class="{ scrubbing: playheadDragging }"
             :style="{left: cursorPct + '%'}"
             title="Arrastra para buscar (scrub)"></div>
        <div v-if="timeTooltip" class="tl-time-tip" :class="['variant-' + timeTooltip.variant]"
             :style="{left: timeTooltip.leftPct + '%'}">
          <span class="tip-time">{{ timeTooltip.label }}</span>
          <span v-if="timeTooltip.rangeLabel" class="tip-range">{{ timeTooltip.rangeLabel }}</span>
        </div>
        <div
          v-for="m in moments"
          :key="m.id"
          class="tl-moment"
          :class="[m.type, { selected: selectedMomentId === m.id,
                             linked: (m.operations || []).some(o => o.type === 'jump_to_moment') }]"
          :data-moment-id="m.id"
          :style="{left: secToPct(m.timeline_seconds) + '%'}"
          :title="(m.label || '(sin etiqueta)') + ' · ' + formatShort(m.timeline_seconds)"
        ></div>
        <div v-if="persistedRangeStyle" class="tl-range-select" :style="persistedRangeStyle"></div>
        <div v-if="selectRect" class="tl-zoom-select" :style="selectRect"></div>
      </template>
    </div>
  `,
};

/* ==========================================================================
   Zoom controls
   ========================================================================== */

var ZoomControls = {
  props: { zoom: Object, playerState: Object },
  emits: ["update-zoom"],
  setup(props, { emit }) {
    const MIN_RANGE = 0.5;
    function zoomBy(factor) {
      const total = props.playerState.duration || 0;
      if (total <= 0) return;
      const curStart = props.zoom.startSeconds || 0;
      const curEnd = props.zoom.endSeconds ?? total;
      const curDur = curEnd - curStart;
      const newDur = Math.min(total, Math.max(MIN_RANGE, curDur * factor));
      const center = Math.max(curStart, Math.min(curEnd, props.playerState.currentTime));
      let start = center - (center - curStart) * (newDur / curDur);
      let end = start + newDur;
      if (end > total) { end = total; start = Math.max(0, end - newDur); }
      if (start < 0) { start = 0; end = Math.min(total, newDur); }
      emit("update-zoom", { start, end });
    }
    function reset() {
      emit("update-zoom", { start: 0, end: props.playerState.duration || null });
    }
    return { zoomBy, reset };
  },
  template: `
    <div class="zoom-bar">
      <button @click="zoomBy(0.9)" title="Acercar 10% (+)">🔍＋</button>
      <button @click="zoomBy(1.111)" title="Alejar 10% (-)">🔍−</button>
      <button @click="reset" title="Reset zoom">↺ all</button>
    </div>
  `,
};

/* ==========================================================================
   Capture moment modal
   ========================================================================== */

var CaptureMomentModal = {
  props: { show: Boolean, currentTime: Number },
  emits: ["capture", "cancel"],
  setup(props, { emit }) {
    const type = ref("relative");
    const label = ref("");
    watch(() => props.show, (s) => { if (s) { type.value = "relative"; label.value = ""; } });
    function save() { emit("capture", { type: type.value, label: label.value.trim() }); }
    const tc = computed(() => formatTimecode(props.currentTime));
    return { type, label, save, tc };
  },
  template: `
    <div v-if="show" class="modal-backdrop" @click.self="$emit('cancel')">
      <div class="modal">
        <div class="eyebrow">CAPTURAR MOMENTO</div>
        <h3>Marca un punto en el timeline</h3>
        <div class="time-readout" style="margin: 16px 0 22px; min-width:auto;">
          <span>{{ tc.hh }}</span><span class="sep">:</span><span>{{ tc.mm }}</span><span class="sep">:</span><span>{{ tc.ss }}</span><span class="ms">.{{ tc.cs }}</span>
        </div>
        <label>Tipo de momento</label>
        <div class="radio-group">
          <div class="radio-card" :class="{selected: type === 'relative'}" @click="type = 'relative'">
            <div class="name">Relativo</div>
            <div class="desc">Se desplaza si editás los clips antes de este punto.</div>
          </div>
          <div class="radio-card hot" :class="{selected: type === 'absolute'}" @click="type = 'absolute'">
            <div class="name">Absoluto</div>
            <div class="desc">Fijo en el timeline sin importar qué cambie.</div>
          </div>
        </div>
        <label>Etiqueta <span style="text-transform:none; letter-spacing:0; color:var(--paper-faint);">(opcional)</span></label>
        <input type="text" v-model="label" @keyup.enter="save" placeholder="Ej: cue de risa, punto de corte…" autofocus>
        <div class="row right" style="margin-top:22px; gap:8px;">
          <button class="ghost" @click="$emit('cancel')">Cancelar</button>
          <button class="primary" @click="save">Guardar momento</button>
        </div>
      </div>
    </div>
  `,
};

/* ==========================================================================
   Moments list
   ========================================================================== */

var MomentsList = {
  props: { moments: Array, selectedMomentId: Number },
  emits: ["goto", "preview", "update-label", "update-type", "remove", "select",
          "jump-next", "set-track", "toggle-track", "update-time", "export-moment"],
  setup(props, { emit }) {
    const sorted = computed(() => [...props.moments].sort((a, b) => a.timeline_seconds - b.timeline_seconds));

    function toggleType(m) {
      const next = m.type === "relative" ? "absolute" : "relative";
      emit("update-type", { id: m.id, type: next });
    }

    function hasJumpOp(m) {
      return (m.operations || []).some(o => o.type === "jump_to_moment");
    }

    // Inline numeric edit of a moment's start / end. The "end" field is
    // really `timeline_seconds + duration_seconds`; we recompute the
    // duration on save.
    function endValueFor(m) {
      if (!m || !m.duration_seconds || m.duration_seconds <= 0) return "";
      return ((m.timeline_seconds || 0) + m.duration_seconds).toFixed(2);
    }
    function onChangeStart(m, ev) {
      const f = parseFloat(ev.target.value);
      if (!isFinite(f) || f < 0) { ev.target.value = m.timeline_seconds.toFixed(2); return; }
      const patch = { timeline_seconds: f };
      if (m.duration_seconds && m.duration_seconds > 0) {
        patch.duration_seconds = m.duration_seconds;
      }
      emit("update-time", { id: m.id, patch });
    }
    function onChangeEnd(m, ev) {
      const raw = ev.target.value;
      if (raw === "" || raw === null) {
        emit("update-time", { id: m.id, patch: { duration_seconds: null } });
        return;
      }
      const f = parseFloat(raw);
      if (!isFinite(f)) return;
      const dur = f - (m.timeline_seconds || 0);
      emit("update-time", {
        id: m.id,
        patch: { duration_seconds: dur > 0 ? dur : null },
      });
    }
    function durationValueFor(m) {
      if (!m || !m.duration_seconds || m.duration_seconds <= 0) return "";
      return m.duration_seconds.toFixed(2);
    }
    function onChangeDuration(m, ev) {
      const raw = ev.target.value;
      if (raw === "" || raw === null) {
        emit("update-time", { id: m.id, patch: { duration_seconds: null } });
        return;
      }
      const f = parseFloat(raw);
      if (!isFinite(f) || f < 0) return;
      emit("update-time", { id: m.id, patch: { duration_seconds: f > 0 ? f : null } });
    }

    function beginEdit(ev) {
      const el = ev.target;
      el.setAttribute("contenteditable", "true");
      if (el.classList.contains("empty")) el.textContent = "";
      el.classList.remove("empty");
      requestAnimationFrame(() => {
        const range = document.createRange();
        range.selectNodeContents(el);
        const sel = window.getSelection();
        sel.removeAllRanges();
        sel.addRange(range);
      });
    }
    function endEdit(ev, m) {
      const el = ev.target;
      const text = el.textContent.trim();
      el.removeAttribute("contenteditable");
      if (!text) el.classList.add("empty");
      if (text !== (m.label || "")) emit("update-label", { id: m.id, label: text });
    }
    function onKey(ev, m) {
      if (ev.key === "Enter") { ev.preventDefault(); ev.target.blur(); }
      if (ev.key === "Escape") { ev.target.textContent = m.label || ""; ev.target.blur(); }
    }

    return { sorted, formatTimecode, beginEdit, endEdit, onKey, toggleType, hasJumpOp,
             endValueFor, onChangeStart, onChangeEnd, durationValueFor, onChangeDuration };
  },
  template: `
    <div class="moments-section">
      <div class="moments-head">
        <span class="label">Momentos</span>
        <span class="count">{{ moments.length }}</span>
        <div class="spacer"></div>
        <span class="muted">Doble clic edita la etiqueta · chip edita el tipo · <span class="kbd">M</span> captura</span>
      </div>
      <div v-if="moments.length === 0" class="moments-empty">Aún no hay momentos marcados.</div>
      <div v-else class="moments-list">
        <div
          v-for="m in sorted"
          :key="m.id"
          class="moment-row"
          :class="{selected: m.id === selectedMomentId}"
          @click="$emit('select', m.id)"
        >
          <div class="moment-row-top">
            <span class="time mono">
              <template v-for="(part, i) in [formatTimecode(m.timeline_seconds)]" :key="i">
                {{ part.hh }}:{{ part.mm }}:{{ part.ss }}<span style="color:var(--paper-faint);">.{{ part.cs }}</span>
              </template>
            </span>
            <span class="kind" :class="m.type" @click.stop="toggleType(m)" title="Cambiar tipo (relativo/absoluto)">{{ m.type }}</span>
            <span
              class="label"
              :class="{ empty: !m.label }"
              @click.stop
              @dblclick="beginEdit"
              @blur="(ev) => endEdit(ev, m)"
              @keydown="(ev) => onKey(ev, m)"
              spellcheck="false"
            >{{ m.label }}</span>
            <span v-if="m.operations && m.operations.length" class="op-count" :title="m.operations.length + ' operación(es)'">
              {{ m.operations.length }}
            </span>
            <span class="actions" @click.stop>
              <button class="icon" @click="$emit('goto', m.timeline_seconds)" title="Saltar al momento">⇥</button>
              <button class="icon primary-subtle" @click="$emit('preview', m)" title="Reproducir desde un poco antes">▶</button>
              <button class="icon" @click="$emit('export-moment', m)" title="Exportar este momento">⇪</button>
              <button class="icon danger" @click="$emit('remove', m.id)" title="Eliminar">✕</button>
            </span>
          </div>
          <div class="moment-row-actions" @click.stop>
            <button class="qa" :class="{ on: hasJumpOp(m) }"
                    @click="$emit('jump-next', m)"
                    title="Al llegar a este momento, saltar al siguiente">⇢ salto</button>
            <button class="qa" @click="$emit('set-track', { m, track: 1 })" title="Cambiar a Track 1">T1</button>
            <button class="qa" @click="$emit('set-track', { m, track: 2 })" title="Cambiar a Track 2">T2</button>
            <button class="qa" @click="$emit('set-track', { m, track: 3 })" title="Cambiar a Track 3">T3</button>
            <button class="qa" @click="$emit('set-track', { m, track: 4 })" title="Cambiar a Track 4">T4</button>
            <button class="qa" @click="$emit('toggle-track', m)" title="Rotar al siguiente track">⇋</button>
          </div>

          <div v-if="m.id === selectedMomentId" class="moment-time-edit" @click.stop>
            <div class="mte-field">
              <label>Empieza (s)</label>
              <input type="number" step="0.01" min="0"
                     :value="m.timeline_seconds.toFixed(2)"
                     @change="onChangeStart(m, $event)"
                     @keydown.enter="$event.target.blur()">
            </div>
            <div class="mte-arrow">→</div>
            <div class="mte-field">
              <label>Termina (s)</label>
              <input type="number" step="0.01" min="0"
                     :value="endValueFor(m)" placeholder="(sin rango)"
                     @change="onChangeEnd(m, $event)"
                     @keydown.enter="$event.target.blur()">
            </div>
            <div class="mte-arrow">⇔</div>
            <div class="mte-field">
              <label>Duración (s)</label>
              <input type="number" step="0.01" min="0"
                     :value="durationValueFor(m)" placeholder="(punto)"
                     @change="onChangeDuration(m, $event)"
                     @keydown.enter="$event.target.blur()">
            </div>
          </div>
        </div>
      </div>
    </div>
  `,
};

/* ==========================================================================
   Files panel (sidebar)
   ========================================================================== */

var FilesPanel = {
  props: { project: Object },
  emits: ["add-to-timeline", "refresh", "captions-changed"],
  setup(props, { emit }) {
    const tab = ref("local");
    const localFiles = ref([]);
    const globalFiles = ref([]);
    const error = ref("");
    const uploading = ref(false);
    const uploadProgress = ref(0);
    const uploadName = ref("");
    const fileInput = ref(null);

    // Captions state
    const captionsModalFor = ref(null);   // file row or null
    const captionLanguages = ref([]);
    const captionForm = reactive({ language: "es", model: "small" });
    const captionJob = ref(null);          // current job for the open file
    const captionList = ref([]);           // existing SRT sidecars for the open file
    let captionPoll = null;

    async function openCaptionsModal(f, ev) {
      ev.stopPropagation();
      captionsModalFor.value = f;
      captionJob.value = null;
      captionList.value = [];
      if (!captionLanguages.value.length) {
        try { captionLanguages.value = await api("/api/captions/languages"); } catch (_) {}
      }
      await refreshCaptionList();
    }
    function closeCaptionsModal() {
      captionsModalFor.value = null;
      if (captionPoll) { clearInterval(captionPoll); captionPoll = null; }
    }
    async function refreshCaptionList() {
      const f = captionsModalFor.value;
      if (!f) return;
      try {
        const data = await api(`/api/projects/${props.project.slug}/files/${f.id}/captions`);
        captionList.value = data.captions || [];
        const running = (data.jobs || []).find(j => j.status === "pending" || j.status === "running");
        if (running) {
          captionJob.value = running;
          startPollingJob(running.id);
        }
      } catch (_) {}
    }
    function startPollingJob(jobId) {
      if (captionPoll) clearInterval(captionPoll);
      captionPoll = setInterval(async () => {
        try {
          const j = await api(`/api/projects/${props.project.slug}/caption-jobs/${jobId}`);
          captionJob.value = j;
          if (j.status === "done" || j.status === "error") {
            clearInterval(captionPoll); captionPoll = null;
            await refreshCaptionList();
            emit("captions-changed");
          }
        } catch (_) {}
      }, 2000);
    }
    async function generateCaptions() {
      const f = captionsModalFor.value;
      if (!f) return;
      try {
        const j = await api(`/api/projects/${props.project.slug}/files/${f.id}/captions`, {
          method: "POST", body: { language: captionForm.language, model: captionForm.model },
        });
        captionJob.value = j;
        if (j.id) startPollingJob(j.id);
      } catch (e) { error.value = e.message; }
    }
    async function deleteCaption(lang) {
      const f = captionsModalFor.value;
      if (!f) return;
      if (!await podSwal.confirm(`¿Eliminar las captions en ${lang}?`)) return;
      try {
        await api(`/api/projects/${props.project.slug}/files/${f.id}/captions/${lang}`, { method: "DELETE" });
        await refreshCaptionList();
        emit("captions-changed");
      } catch (e) { error.value = e.message; }
    }

    const captionUploadRef = ref(null);
    let captionUploadLang = null;
    function triggerCaptionUpload(lang) {
      captionUploadLang = lang;
      if (captionUploadRef.value) captionUploadRef.value.click();
    }
    async function handleCaptionUpload(ev) {
      const file = ev.target.files?.[0];
      ev.target.value = "";
      if (!file || !captionsModalFor.value || !captionUploadLang) return;
      const fd = new FormData();
      fd.append("srt", file);
      try {
        const slug = props.project.slug;
        const fid = captionsModalFor.value.id;
        await fetch(`/api/projects/${slug}/files/${fid}/captions/${captionUploadLang}/upload`, {
          method: "PUT", body: fd,
        }).then(r => { if (!r.ok) throw new Error("Error al subir SRT"); return r.json(); });
        await refreshCaptionList();
        emit("captions-changed");
        podSwal.toast("SRT actualizado");
      } catch (e) { error.value = e.message; }
    }

    onBeforeUnmount(() => { if (captionPoll) clearInterval(captionPoll); });

    async function load() {
      try {
        const [local, glob] = await Promise.all([
          api(`/api/projects/${props.project.slug}/files`),
          api(`/api/global/files`),
        ]);
        localFiles.value = local;
        globalFiles.value = glob;
        emit("refresh", { local, global: glob });
      } catch (e) { error.value = e.message; }
    }

    async function upload(ev) {
      const f = ev.target.files?.[0];
      if (!f) return;
      uploading.value = true;
      uploadProgress.value = 0;
      uploadName.value = f.name;
      error.value = "";
      try {
        const form = new FormData();
        form.append("file", f);
        await apiUpload(
          `/api/projects/${props.project.slug}/files`,
          form,
          (pct) => { uploadProgress.value = pct; }
        );
        await load();
      } catch (e) { error.value = e.message; }
      finally {
        uploading.value = false;
        uploadProgress.value = 0;
        uploadName.value = "";
        if (fileInput.value) fileInput.value.value = "";
      }
    }

    async function removeFile(f, ev) {
      ev.stopPropagation();
      if (!await podSwal.confirm(`¿Eliminar "${f.original_name}"?\nSi está en el timeline, se quitará automáticamente.`)) return;
      try {
        await api(`/api/projects/${props.project.slug}/files/${f.id}`, { method: "DELETE" });
        await load();
        emit("refresh", { fileDeleted: f.id });
      } catch (e) { error.value = e.message; }
    }

    async function makeGlobal(f, ev) {
      ev.stopPropagation();
      if (!await podSwal.confirm(`Mover "${f.original_name}" a archivos globales?\nSi está en el timeline, se quitará. Esta acción no se puede deshacer.`)) return;
      try {
        await api(`/api/projects/${props.project.slug}/files/${f.id}/make-global`, { method: "POST" });
        await load();
        emit("refresh", { fileDeleted: f.id });
      } catch (e) { error.value = e.message; }
    }

    const nextTrack = ref(1);
    function cycleTrack(ev) {
      ev.stopPropagation();
      nextTrack.value = (nextTrack.value % 4) + 1;
    }
    function addToTimeline(f) {
      if (f.file_type === "image") {
        podSwal.toast("Las imágenes no se pueden usar como clip del timeline. Usa un archivo de video o de audio.");
        return;
      }
      emit("add-to-timeline", { ...f, _track: f.file_type === "video" ? nextTrack.value : 1 });
    }

    onMounted(load);

    return {
      tab, localFiles, globalFiles, error, uploading, uploadProgress, uploadName, fileInput,
      upload, removeFile, makeGlobal, addToTimeline, nextTrack, cycleTrack, formatSize, formatDurationCompact, load,
      captionsModalFor, captionLanguages, captionForm, captionJob, captionList,
      openCaptionsModal, closeCaptionsModal, generateCaptions, deleteCaption,
      captionUploadRef, triggerCaptionUpload, handleCaptionUpload,
    };
  },
  template: `
    <aside class="side">
      <div class="project-info">
        <h3>{{ project.name }}</h3>
        <div class="slug">/ {{ project.slug }}</div>
      </div>
      <div class="tabs">
        <button :class="{active: tab === 'local'}" @click="tab = 'local'">Proyecto</button>
        <button :class="{active: tab === 'global'}" @click="tab = 'global'">Globales</button>
      </div>
      <div v-if="tab === 'local'" class="upload-box">
        <input type="file" ref="fileInput" @change="upload" :disabled="uploading" accept="video/*,audio/*,image/*">
        <div v-if="uploading" class="upload-progress">
          <div class="upload-progress-name" :title="uploadName">{{ uploadName }}</div>
          <div class="progress-bar">
            <div class="progress-fill" :style="{ width: uploadProgress + '%' }"></div>
            <div class="progress-text mono">{{ uploadProgress }}%</div>
          </div>
        </div>
      </div>
      <div v-if="error" class="error">{{ error }}</div>
      <div v-if="tab === 'local'">
        <div v-if="localFiles.length === 0" class="muted" style="padding: 8px 4px;">Sin archivos todavía.</div>
        <div class="file-list">
          <div v-for="f in localFiles" :key="f.id" class="file-row">
            <div v-if="f.thumbnail_url" class="thumb-mini" :style="{ backgroundImage: 'url(' + f.thumbnail_url + ')' }"></div>
            <span v-else :class="['type-pill', f.file_type]">{{ f.file_type }}</span>
            <div class="name">
              <div class="title" :title="f.original_name">{{ f.original_name }}</div>
              <div class="meta">
                {{ formatSize(f.size_bytes) }}<span v-if="f.duration"> · {{ formatDurationCompact(f.duration) }}</span>
              </div>
            </div>
            <div class="actions">
              <button v-if="f.file_type !== 'image'" class="icon ghost" @click.stop="addToTimeline(f)" title="Agregar al timeline">+</button>
              <button v-if="f.file_type === 'video'" class="track-btn" :class="'track-' + nextTrack"
                      @click.stop="cycleTrack" :title="'Pista destino: T' + nextTrack + ' (click para cambiar)'">T{{ nextTrack }}</button>
              <button v-if="f.file_type !== 'image'" class="icon ghost" @click.stop="openCaptionsModal(f, $event)" title="Generar captions con Whisper">🎙</button>
              <button class="icon ghost" @click.stop="makeGlobal(f, $event)" title="Mover a globales">⇪</button>
              <button class="icon danger" @click.stop="removeFile(f, $event)" title="Eliminar">✕</button>
            </div>
          </div>
        </div>
      </div>
      <div v-else>
        <div v-if="globalFiles.length === 0" class="muted" style="padding:8px 4px;">Sin archivos globales.</div>
        <div class="file-list">
          <div v-for="f in globalFiles" :key="f.url" class="file-row">
            <div v-if="f.thumbnail_url" class="thumb-mini" :style="{ backgroundImage: 'url(' + f.thumbnail_url + ')' }"></div>
            <span v-else :class="['type-pill', f.file_type]">{{ f.file_type }}</span>
            <div class="name">
              <div class="title" :title="f.original_name">{{ f.original_name }}</div>
              <div class="meta">
                {{ formatSize(f.size_bytes) }}<span v-if="f.duration"> · {{ formatDurationCompact(f.duration) }}</span>
              </div>
            </div>
          </div>
        </div>
      </div>

      <div v-if="captionsModalFor" class="modal-backdrop" @click.self="closeCaptionsModal">
        <div class="modal" style="width: 460px;">
          <div class="eyebrow">CAPTIONS · WHISPER</div>
          <h3 style="margin: 4px 0 12px;">Generar subtítulos</h3>
          <p class="muted" style="margin-bottom: 14px; font-size: 12px;">
            Para <span class="mono">{{ captionsModalFor.original_name }}</span>.
            Whisper corre en CPU — espera ~0.5-1× la duración del clip.
          </p>

          <div v-if="captionList.length" style="margin-bottom: 14px;">
            <div class="tiny" style="margin-bottom: 6px;">EXISTENTES</div>
            <div v-for="c in captionList" :key="c.language" class="invite-row" style="padding: 4px 0;">
              <span class="who mono">{{ c.language }} · {{ c.filename }}</span>
              <a :href="c.url" target="_blank" class="join-pill">↓ srt</a>
              <button class="join-pill" @click="triggerCaptionUpload(c.language)">↑ subir</button>
              <button class="icon danger" @click="deleteCaption(c.language)">✕</button>
            </div>
            <input type="file" ref="captionUploadRef" accept=".srt" @change="handleCaptionUpload" style="display:none;">
          </div>

          <div class="form-row" style="margin-bottom: 12px;">
            <label>Idioma</label>
            <select v-model="captionForm.language">
              <option v-for="l in captionLanguages" :key="l.code" :value="l.code">{{ l.label }}</option>
            </select>
          </div>
          <div class="form-row" style="margin-bottom: 14px;">
            <label>Modelo (más grande = mejor calidad, más lento)</label>
            <select v-model="captionForm.model">
              <option value="tiny">tiny (más rápido)</option>
              <option value="base">base</option>
              <option value="small">small (recomendado)</option>
              <option value="medium">medium</option>
              <option value="large-v3">large-v3 (mejor)</option>
            </select>
          </div>

          <div v-if="captionJob" class="tiny muted" style="margin-bottom: 10px;">
            <span v-if="captionJob.status === 'pending'">⏳ Encolado…</span>
            <span v-else-if="captionJob.status === 'running'">🔄 Procesando ({{ captionJob.progress || 0 }}%)…</span>
            <span v-else-if="captionJob.status === 'done'" style="color: var(--signal-cool);">✓ Listo</span>
            <span v-else-if="captionJob.status === 'error'" style="color: var(--signal-hot);">❌ {{ captionJob.error_msg }}</span>
          </div>

          <div class="row right" style="gap: 8px;">
            <button class="ghost" @click="closeCaptionsModal">Cerrar</button>
            <button class="primary" @click="generateCaptions"
                    :disabled="captionJob && (captionJob.status === 'pending' || captionJob.status === 'running')">
              Generar
            </button>
          </div>
        </div>
      </div>
    </aside>
  `,
};

/* ==========================================================================
   Clips panel (right sidebar)
   ========================================================================== */

var ClipsPanel = {
  props: { clips: Array, totalDuration: Number },
  emits: ["reorder", "remove", "trim", "seek-to", "remove-silences", "set-track"],
  setup(props, { emit }) {
    const editing = ref(null);  // clip id being trimmed
    const trimStart = ref(0);
    const trimEnd = ref(0);

    function openTrim(clip) {
      editing.value = clip.id;
      trimStart.value = clip.start_offset || 0;
      trimEnd.value = clip.end_offset ?? clip.source?.duration ?? 0;
    }
    function applyTrim(clip) {
      emit("trim", {
        id: clip.id,
        start_offset: Math.max(0, trimStart.value),
        end_offset: trimEnd.value,
      });
      editing.value = null;
    }

    function move(clip, delta) {
      const newPos = clip.position + delta;
      if (newPos < 0 || newPos >= props.clips.length) return;
      emit("reorder", { id: clip.id, position: newPos });
    }

    // ---- Drag-to-reorder ----
    const draggingId = ref(null);
    const dragOverId = ref(null);
    function onDragStart(ev, clip) {
      draggingId.value = clip.id;
      ev.dataTransfer.effectAllowed = "move";
      // Some browsers require setData to make the drag actually start.
      try { ev.dataTransfer.setData("text/plain", String(clip.id)); } catch (_) {}
    }
    function onDragOver(ev, clip) {
      if (draggingId.value == null || draggingId.value === clip.id) return;
      ev.preventDefault();
      ev.dataTransfer.dropEffect = "move";
      dragOverId.value = clip.id;
    }
    function onDragLeave(clip) {
      if (dragOverId.value === clip.id) dragOverId.value = null;
    }
    function onDrop(ev, targetClip) {
      ev.preventDefault();
      const sourceId = draggingId.value;
      draggingId.value = null;
      dragOverId.value = null;
      if (sourceId == null || sourceId === targetClip.id) return;
      const targetPos = targetClip.position;
      emit("reorder", { id: sourceId, position: targetPos });
    }
    function onDragEnd() {
      draggingId.value = null;
      dragOverId.value = null;
    }

    return { editing, trimStart, trimEnd, openTrim, applyTrim, move, formatDurationCompact, formatShort,
             draggingId, dragOverId, onDragStart, onDragOver, onDragLeave, onDrop, onDragEnd };
  },
  template: `
    <aside class="clips-panel">
      <div class="panel-head">
        <span class="label">Timeline · clips</span>
        <span class="count">{{ clips.length }}</span>
        <div class="spacer"></div>
        <span class="muted mono">TOT {{ formatShort(totalDuration) }}</span>
      </div>

      <div v-if="clips.length === 0" class="panel-empty">
        Haz clic en un archivo de video o de audio del panel izquierdo para agregarlo al timeline.
      </div>

      <div v-else class="clip-stack">
        <div v-for="(clip, idx) in clips" :key="clip.id" class="clip-card"
             :class="{ dragging: draggingId === clip.id, 'drag-over': dragOverId === clip.id }"
             draggable="true"
             @dragstart="onDragStart($event, clip)"
             @dragover="onDragOver($event, clip)"
             @dragleave="onDragLeave(clip)"
             @drop="onDrop($event, clip)"
             @dragend="onDragEnd">
          <div class="clip-card-head">
            <span class="pos drag-handle" title="Arrastrar para reordenar">⋮⋮ #{{ idx + 1 }}</span>
            <div v-if="clip.source && clip.source.thumbnail_url" class="thumb-small" :style="{ backgroundImage: 'url(' + clip.source.thumbnail_url + ')' }"></div>
            <div class="clip-name" :title="clip.source ? clip.source.original_name : ''">
              {{ clip.source ? clip.source.original_name : '(archivo borrado)' }}
            </div>
            <div class="clip-actions">
              <button class="icon ghost clip-track-toggle" :class="'track-' + (clip.track || 1)"
                      @click="$emit('set-track', { id: clip.id, track: ((clip.track || 1) % 4) + 1 })"
                      :title="'Track ' + (clip.track || 1) + ' — click para cambiar'">
                T{{ clip.track || 1 }}
              </button>
              <button class="icon ghost" @click="move(clip, -1)" :disabled="idx === 0" title="Mover arriba">▲</button>
              <button class="icon ghost" @click="move(clip, 1)" :disabled="idx === clips.length - 1" title="Mover abajo">▼</button>
              <button class="icon ghost" @click="$emit('seek-to', clip.id)" title="Ir al inicio del clip">⇥</button>
              <button class="icon ghost" @click="openTrim(clip)" title="Recortar (IN/OUT)">✂</button>
              <button class="icon primary-subtle" @click="$emit('remove-silences', clip)" title="Quitar silencios (auto-corte)">⎙</button>
              <button class="icon danger" @click="$emit('remove', clip.id)" title="Quitar del timeline">✕</button>
            </div>
          </div>
          <div class="clip-card-meta">
            <span class="mono">{{ formatShort(clip.start_offset || 0) }} → {{ formatShort(clip.end_offset ?? (clip.source ? clip.source.duration : 0)) }}</span>
            <span class="spacer"></span>
            <span class="mono" style="color: var(--signal);">{{ formatShort(clip.duration) }}</span>
          </div>

          <div v-if="editing === clip.id" class="clip-trim">
            <div class="row" style="gap:6px;">
              <label style="margin-bottom:0; min-width:40px;">IN</label>
              <input type="number" v-model.number="trimStart" step="0.1" min="0">
            </div>
            <div class="row" style="gap:6px; margin-top:4px;">
              <label style="margin-bottom:0; min-width:40px;">OUT</label>
              <input type="number" v-model.number="trimEnd" step="0.1" min="0">
            </div>
            <div class="row right" style="margin-top:6px; gap:4px;">
              <button class="ghost" @click="editing = null">Cancelar</button>
              <button class="primary" @click="applyTrim(clip)">Aplicar</button>
            </div>
          </div>
        </div>
      </div>
    </aside>
  `,
};

/* ==========================================================================
   Operations panel (below clips)
   ========================================================================== */

var OpForm = {
  props: { type: String, clips: Array, localFiles: Array, globalFiles: Array, moments: Array, currentMomentId: Number,
           initialParams: { type: Object, default: null } },
  emits: ["submit", "cancel", "editing-overlay"],
  setup(props, { emit }) {
    const params = reactive({});

    watch(() => props.type, (t) => {
      for (const k of Object.keys(params)) delete params[k];
      if (t === "zoom_in") Object.assign(params, { scale: 1.5, duration_seconds: 0.5, origin_x: 0.5, origin_y: 0.5 });
      else if (t === "zoom_out") Object.assign(params, { duration_seconds: 0.5 });
      else if (t === "color_effect") Object.assign(params, { effect: "grayscale", duration_seconds: 1.0 });
      else if (t === "subtitle") Object.assign(params, { text: "", duration_seconds: 3.0, position: "bottom" });
      else if (t === "audio_mix") Object.assign(params, { media_file_id: null, volume: 0.8, duration_seconds: 2.0 });
      else if (t === "audio_replace") Object.assign(params, { media_file_id: null, duration_seconds: 2.0 });
      else if (t === "insert_clip") Object.assign(params, { timeline_clip_id: null });
      else if (t === "switch_video") Object.assign(params, { media_file_id: null });
      else if (t === "to_vertical") Object.assign(params, { crop_x: 0.5, duration_seconds: null });
      else if (t === "vertical_split") Object.assign(params, { n: 2, crop_xs: [0.5, 0.5], duration_seconds: null });
      else if (t === "remove_silences") Object.assign(params, { threshold_db: -40, min_silence_seconds: 0.5, duration_seconds: 30 });
      else if (t === "jump_to_moment") Object.assign(params, { target_moment_id: null });
      else if (t === "text_overlay") Object.assign(params, {
        text: "POW!",
        font: "bangers",
        color: "#ffde59",
        size_pct: 18,
        x_pct: 0.5,
        y_pct: 0.5,
        rotation_deg: -8,
        duration_seconds: 0.8,
        outline: true,
        shadow: true,
        sound_file_id: null,
        sound_volume: 1.0,
        _sound_selector: "",
      });
      // If editing an existing op, overlay initialParams onto the defaults.
      if (props.initialParams) Object.assign(params, props.initialParams);
      // Seed the sound dropdown from existing sound_file_id
      if (t === "text_overlay") {
        if (params.sound_file_id) params._sound_selector = "local:" + params.sound_file_id;
        else params._sound_selector = "";
      }
    }, { immediate: true });

    // Keep the video-frame WYSIWYG overlay in sync with the form params.
    watch(() => [props.type, params.text, params.font, params.color, params.size_pct,
                 params.x_pct, params.y_pct, params.rotation_deg, params.outline, params.shadow], () => {
      if (props.type === "text_overlay") emit("editing-overlay", params);
      else emit("editing-overlay", null);
    }, { immediate: true, deep: true });
    onBeforeUnmount(() => emit("editing-overlay", null));

    const audioFiles = computed(() => (props.localFiles || []).filter(f => f.file_type === "audio"));
    // Global audio (shared library) exposed so the user can pick one without
    // importing first. When a global is chosen, the caller silently imports
    // it into the project before saving the op.
    const globalAudio = computed(() => (props.globalFiles || []).filter(f => f.file_type === "audio"));
    const videoFiles = computed(() => (props.localFiles || []).filter(f => f.file_type === "video"));
    const otherMoments = computed(() =>
      [...(props.moments || [])]
        .filter(m => m.id !== props.currentMomentId)
        .sort((a, b) => a.timeline_seconds - b.timeline_seconds)
    );

    function onSoundPick() {
      const v = params._sound_selector || "";
      if (!v) { params.sound_file_id = null; params._sound_global = null; return; }
      if (v.startsWith("local:")) {
        params.sound_file_id = parseInt(v.slice(6), 10);
        params._sound_global = null;
      } else if (v.startsWith("global:")) {
        params.sound_file_id = null;
        params._sound_global = v.slice(7);  // filename; parent resolves to local id on submit
      }
    }

    function submit() {
      const out = { ...params };
      delete out._sound_selector;
      // Keep _sound_global so parent can import before saving.
      emit("submit", out);
    }

    // Mirror of params.crop_xs as a plain reactive array so v-model on each
    // slider works without index-out-of-range issues.
    const vsCropXs = reactive([0.5, 0.5, 0.5, 0.5]);
    watch(() => props.type, (t) => {
      if (t === "vertical_split") {
        const init = (props.initialParams && props.initialParams.crop_xs) || [];
        for (let i = 0; i < 4; i++) vsCropXs[i] = init[i] != null ? init[i] : 0.5;
      }
    }, { immediate: true });
    watch(() => [vsCropXs[0], vsCropXs[1], vsCropXs[2], vsCropXs[3], params.n],
      () => {
        if (props.type === "vertical_split") {
          const n = params.n || 2;
          params.crop_xs = vsCropXs.slice(0, n).map(v => Number(v) || 0.5);
        }
      }, { immediate: true });

    return { params, audioFiles, videoFiles, globalAudio, otherMoments, COMIC_FONTS, submit, onSoundPick, vsCropXs };
  },
  template: `
    <div class="op-form">
      <template v-if="type === 'zoom_in'">
        <div class="op-field"><label>Escala</label><input type="number" step="0.1" min="1.1" max="4" v-model.number="params.scale"></div>
        <div class="op-field"><label>Duración (s)</label><input type="number" step="0.1" min="0.1" v-model.number="params.duration_seconds"></div>
        <div class="op-field"><label>Origen X (0-1)</label><input type="number" step="0.05" min="0" max="1" v-model.number="params.origin_x"></div>
        <div class="op-field"><label>Origen Y (0-1)</label><input type="number" step="0.05" min="0" max="1" v-model.number="params.origin_y"></div>
      </template>
      <template v-else-if="type === 'zoom_out'">
        <div class="op-field"><label>Duración (s)</label><input type="number" step="0.1" min="0.1" v-model.number="params.duration_seconds"></div>
      </template>
      <template v-else-if="type === 'color_effect'">
        <div class="op-field">
          <label>Efecto</label>
          <select v-model="params.effect">
            <option value="grayscale">Grayscale</option>
            <option value="sepia">Sepia</option>
            <option value="invert">Invert</option>
          </select>
        </div>
        <div class="op-field"><label>Duración (s, vacío = hasta el próximo momento)</label>
          <input type="number" step="0.1" min="0.1" v-model.number="params.duration_seconds">
        </div>
      </template>
      <template v-else-if="type === 'subtitle'">
        <div class="op-field"><label>Texto</label><input type="text" v-model="params.text" placeholder="Texto a mostrar"></div>
        <div class="op-field"><label>Duración (s)</label><input type="number" step="0.1" min="0.1" v-model.number="params.duration_seconds"></div>
        <div class="op-field"><label>Posición</label>
          <select v-model="params.position">
            <option value="top">Arriba</option>
            <option value="bottom">Abajo</option>
          </select>
        </div>
      </template>
      <template v-else-if="type === 'audio_mix' || type === 'audio_replace'">
        <div class="op-field"><label>Archivo de audio</label>
          <select v-model.number="params.media_file_id">
            <option :value="null">— elegir —</option>
            <option v-for="f in audioFiles" :key="f.id" :value="f.id">{{ f.original_name }}</option>
          </select>
        </div>
        <div v-if="type === 'audio_mix'" class="op-field"><label>Volumen (0-1)</label>
          <input type="number" step="0.05" min="0" max="1" v-model.number="params.volume">
        </div>
        <div class="op-field"><label>Duración (s)</label><input type="number" step="0.1" min="0.1" v-model.number="params.duration_seconds"></div>
      </template>
      <template v-else-if="type === 'switch_video'">
        <div class="op-field"><label>Video</label>
          <select v-model.number="params.media_file_id">
            <option :value="null">— elegir —</option>
            <option v-for="f in videoFiles" :key="f.id" :value="f.id">{{ f.original_name }}</option>
          </select>
        </div>
      </template>
      <template v-else-if="type === 'insert_clip'">
        <div class="op-field"><label>Clip del timeline</label>
          <select v-model.number="params.timeline_clip_id">
            <option :value="null">— elegir —</option>
            <option v-for="(c, idx) in clips" :key="c.id" :value="c.id">
              #{{ idx + 1 }} · {{ c.source ? c.source.original_name : '(borrado)' }}
            </option>
          </select>
        </div>
      </template>
      <template v-else-if="type === 'to_vertical'">
        <div class="op-field">
          <label>Centro horizontal (0 izquierda · 1 derecha)</label>
          <input type="number" step="0.05" min="0" max="1" v-model.number="params.crop_x">
        </div>
        <div class="op-field">
          <label>Duración (s, vacío = hasta el próximo momento o fin)</label>
          <input type="number" step="0.1" min="0" v-model.number="params.duration_seconds">
        </div>
        <div class="muted" style="font-size:11px; margin-top:6px; line-height:1.5;">
          Preview: recorta un slice 9:16 del frame 16:9. En el export se re-encodea a 1080×1920.
        </div>
      </template>
      <template v-else-if="type === 'vertical_split'">
        <div class="op-field">
          <label>Cantidad de cámaras apiladas</label>
          <select v-model.number="params.n">
            <option :value="2">2 (host + invitado)</option>
            <option :value="3">3 cámaras</option>
            <option :value="4">4 cámaras</option>
          </select>
        </div>
        <div class="op-field" v-for="i in [1,2,3,4]" :key="'vsx' + i" v-show="i <= (params.n || 2)">
          <label>Centro horizontal panel {{ i }}</label>
          <input type="range" step="0.01" min="0" max="1"
                 v-model.number="vsCropXs[i-1]" style="width: 100%;">
          <div class="mono" style="font-size: 10px; color: var(--paper-dim);">{{ (vsCropXs[i-1] || 0).toFixed(2) }}</div>
        </div>
        <div class="op-field">
          <label>Duración (s, vacío = hasta el próximo momento o fin)</label>
          <input type="number" step="0.1" min="0" v-model.number="params.duration_seconds">
        </div>
        <div class="muted" style="font-size:11px; margin-top:6px; line-height:1.5;">
          Toma el composite (cámaras lado a lado) y las apila vertical para 9:16. Exportá con preset <strong>TikTok / Reels vertical</strong>.
        </div>
      </template>
      <template v-else-if="type === 'remove_silences'">
        <div class="op-field">
          <label>Duración del rango (s)</label>
          <input type="number" step="0.5" min="0.5" v-model.number="params.duration_seconds">
        </div>
        <div class="op-field">
          <label>Umbral (dB, más negativo = silencio más profundo)</label>
          <input type="number" step="1" v-model.number="params.threshold_db">
        </div>
        <div class="op-field">
          <label>Duración mínima del silencio (s)</label>
          <input type="number" step="0.1" min="0.1" v-model.number="params.min_silence_seconds">
        </div>
        <div class="muted" style="font-size:11px; margin-top:6px; line-height:1.5;">
          Analiza el audio entre este momento y momento + duración, y parte los clips
          para eliminar los silencios en ese rango. El resto del timeline no se toca.
        </div>
      </template>
      <template v-else-if="type === 'text_overlay'">
        <div class="op-field"><label>Texto</label>
          <input type="text" v-model="params.text" placeholder="POW! BANG! WHAM!">
        </div>
        <div class="op-field"><label>Fuente</label>
          <select v-model="params.font">
            <option v-for="f in COMIC_FONTS" :key="f.key" :value="f.key">{{ f.label }}</option>
          </select>
        </div>
        <div class="op-field"><label>Color</label>
          <input type="color" v-model="params.color" style="width: 60px; height: 32px; padding: 0; border: 1px solid var(--ink-line);">
        </div>
        <div class="op-field"><label>Tamaño (% del frame) = {{ params.size_pct }}%</label>
          <input type="range" min="5" max="50" step="1" v-model.number="params.size_pct">
        </div>
        <div class="op-field"><label>Posición X = {{ Math.round(params.x_pct * 100) }}%</label>
          <input type="range" min="0" max="1" step="0.01" v-model.number="params.x_pct">
        </div>
        <div class="op-field"><label>Posición Y = {{ Math.round(params.y_pct * 100) }}%</label>
          <input type="range" min="0" max="1" step="0.01" v-model.number="params.y_pct">
        </div>
        <div class="op-field"><label>Rotación = {{ params.rotation_deg }}°</label>
          <input type="range" min="-90" max="90" step="1" v-model.number="params.rotation_deg">
        </div>
        <div class="op-field"><label>Duración (s)</label>
          <input type="number" step="0.1" min="0.1" v-model.number="params.duration_seconds">
        </div>
        <div class="op-field" style="display: flex; gap: 14px;">
          <label style="display: inline-flex; align-items: center; gap: 6px; text-transform: none;">
            <input type="checkbox" v-model="params.outline"> Borde negro
          </label>
          <label style="display: inline-flex; align-items: center; gap: 6px; text-transform: none;">
            <input type="checkbox" v-model="params.shadow"> Sombra
          </label>
        </div>
        <div class="op-field"><label>Sonido (opcional)</label>
          <select v-model="params._sound_selector" @change="onSoundPick">
            <option value="">— sin sonido —</option>
            <optgroup label="Locales del proyecto">
              <option v-for="f in audioFiles" :key="'l-' + f.id" :value="'local:' + f.id">{{ f.original_name }}</option>
            </optgroup>
            <optgroup label="Librería global">
              <option v-for="f in globalAudio" :key="'g-' + f.filename" :value="'global:' + f.filename">
                {{ f.original_name || f.filename }}
              </option>
            </optgroup>
          </select>
        </div>
        <div v-if="params.sound_file_id" class="op-field"><label>Volumen sonido</label>
          <input type="range" min="0" max="2" step="0.05" v-model.number="params.sound_volume">
          <span class="mono tiny">{{ (params.sound_volume || 0).toFixed(2) }}</span>
        </div>
        <div class="muted" style="font-size:11px; margin-top:6px; line-height:1.5;">
          Preview: overlay en vivo sobre el video. En export: drawtext + rotate + overlay.
        </div>
      </template>
      <template v-else-if="type === 'jump_to_moment'">
        <div class="op-field">
          <label>Momento destino</label>
          <select v-model.number="params.target_moment_id">
            <option :value="null">— elegir —</option>
            <option v-for="m in otherMoments" :key="m.id" :value="m.id">
              {{ m.label || '(sin etiqueta)' }} · {{ m.timeline_seconds.toFixed(2) }}s
            </option>
          </select>
        </div>
        <div class="muted" style="font-size:11px; margin-top:6px; line-height:1.5;">
          Al llegar a este momento, el reproductor salta al inicio del momento destino.
          Útil para armar una secuencia no lineal o saltear secciones.
        </div>
      </template>
      <template v-else>
        <div class="muted" style="padding:8px 0;">Esta operación no tiene parámetros.</div>
      </template>

      <div class="row right" style="margin-top:10px; gap:6px;">
        <button class="ghost" @click="$emit('cancel')">Cancelar</button>
        <button class="primary" @click="submit">Aplicar</button>
      </div>
    </div>
  `,
};

var ParticipantsPanel = {
  props: { slug: String },
  emits: ["close"],
  setup(props) {
    const participants = ref([]);
    const editing = ref(null);
    const busy = ref(false);

    async function load() {
      try { participants.value = await api(`/api/projects/${props.slug}/participants`); }
      catch (_) {}
    }

    async function save(p) {
      busy.value = true;
      try {
        const updated = await api(`/api/projects/${props.slug}/participants/${p.id}`, {
          method: "PUT",
          body: {
            name: p.name, role: p.role, track: p.track,
            social_instagram: p.social_instagram, social_twitter: p.social_twitter,
            social_youtube: p.social_youtube, social_tiktok: p.social_tiktok,
          },
        });
        const idx = participants.value.findIndex(x => x.id === p.id);
        if (idx >= 0) participants.value[idx] = updated;
        editing.value = null;
      } catch (e) { alert(e.message); }
      finally { busy.value = false; }
    }

    async function add() {
      busy.value = true;
      try {
        const p = await api(`/api/projects/${props.slug}/participants`, {
          method: "POST", body: { name: "Nuevo participante" },
        });
        participants.value.push(p);
        editing.value = p.id;
      } catch (e) { alert(e.message); }
      finally { busy.value = false; }
    }

    async function remove(id) {
      try {
        await api(`/api/projects/${props.slug}/participants/${id}`, { method: "DELETE" });
        participants.value = participants.value.filter(p => p.id !== id);
      } catch (_) {}
    }

    function startEdit(p) {
      editing.value = p.id;
    }

    onMounted(load);
    return { participants, editing, busy, save, add, remove, startEdit };
  },
  template: `
    <div class="participants-panel">
      <div class="eyebrow" style="display: flex; align-items: center; gap: 8px;">
        PARTICIPANTES
        <div class="spacer"></div>
        <button class="ghost" style="font-size: 11px;" @click="add" :disabled="busy">+ Agregar</button>
        <button class="ghost" style="font-size: 11px;" @click="$emit('close')">✕</button>
      </div>
      <div class="muted" style="font-size: 11px; margin: 6px 0;">
        Asigna cada participante a una pista (track) para que sus banners aparezcan en el export con spotlight.
      </div>
      <div v-if="participants.length === 0" class="muted" style="padding: 20px; text-align: center;">
        Sin participantes. Importa desde prePod o agrega manualmente.
      </div>
      <div v-for="p in participants" :key="p.id" class="participant-card">
        <template v-if="editing !== p.id">
          <div style="display: flex; align-items: center; gap: 8px;">
            <span class="participant-track" :class="'t' + (p.track || 0)">T{{ p.track || '?' }}</span>
            <strong>{{ p.name }}</strong>
            <span class="muted" style="font-size: 10px;">{{ p.role }}</span>
            <div class="spacer"></div>
            <button class="ghost" style="font-size: 10px; padding: 2px 6px;" @click="startEdit(p)">✎</button>
            <button class="ghost" style="font-size: 10px; padding: 2px 6px; color: var(--danger, #e55);" @click="remove(p.id)">✕</button>
          </div>
          <div v-if="p.social_instagram || p.social_twitter || p.social_tiktok" class="muted" style="font-size: 10px; margin-top: 2px;">
            <span v-if="p.social_instagram">IG: @{{ p.social_instagram }}</span>
            <span v-if="p.social_twitter" style="margin-left: 8px;">X: @{{ p.social_twitter }}</span>
            <span v-if="p.social_tiktok" style="margin-left: 8px;">TK: @{{ p.social_tiktok }}</span>
          </div>
        </template>
        <template v-else>
          <div class="participant-edit">
            <div class="row" style="gap: 6px; flex-wrap: wrap;">
              <input v-model="p.name" placeholder="Nombre" style="flex: 1; min-width: 120px;">
              <select v-model="p.role" style="width: 90px;">
                <option value="host">Host</option>
                <option value="co-host">Co-host</option>
                <option value="guest">Invitado</option>
              </select>
              <select v-model.number="p.track" style="width: 70px;">
                <option :value="null">—</option>
                <option :value="1">T1</option>
                <option :value="2">T2</option>
                <option :value="3">T3</option>
                <option :value="4">T4</option>
              </select>
            </div>
            <div class="row" style="gap: 6px; margin-top: 6px; flex-wrap: wrap;">
              <input v-model="p.social_instagram" placeholder="Instagram" style="flex: 1; min-width: 100px; font-size: 11px;">
              <input v-model="p.social_twitter" placeholder="X / Twitter" style="flex: 1; min-width: 100px; font-size: 11px;">
            </div>
            <div class="row" style="gap: 6px; margin-top: 4px; flex-wrap: wrap;">
              <input v-model="p.social_youtube" placeholder="YouTube" style="flex: 1; min-width: 100px; font-size: 11px;">
              <input v-model="p.social_tiktok" placeholder="TikTok" style="flex: 1; min-width: 100px; font-size: 11px;">
            </div>
            <div class="row right" style="margin-top: 6px; gap: 6px;">
              <button class="ghost" style="font-size: 11px;" @click="editing = null">Cancelar</button>
              <button class="primary" style="font-size: 11px; padding: 4px 12px;" @click="save(p)" :disabled="busy">Guardar</button>
            </div>
          </div>
        </template>
      </div>
    </div>
  `,
};

var OperationsPanel = {
  components: { OpForm },
  props: { moment: Object, clips: Array, localFiles: Array, globalFiles: Array, moments: Array },
  emits: ["add", "update", "remove", "editing-overlay", "update-moment"],
  setup(props, { emit }) {
    const adding = ref(false);
    const newType = ref("color_effect");
    const editingOp = ref(null);   // { id, type, params } when editing existing op

    const availableTypes = computed(() => {
      const kind = props.moment?.type;
      if (!kind) return [];
      return OP_TYPES.filter(t => t.kinds.includes(kind));
    });

    watch(() => props.moment?.id, () => {
      adding.value = false;
      editingOp.value = null;
      emit("editing-overlay", null);
    });

    function startAdd() {
      adding.value = true;
      editingOp.value = null;
      const first = availableTypes.value[0];
      if (first) newType.value = first.value;
    }
    function startEdit(op) {
      editingOp.value = { id: op.id, type: op.type, params: { ...(op.params || {}) } };
      adding.value = false;
      newType.value = op.type;
    }
    function cancelForm() {
      adding.value = false;
      editingOp.value = null;
      emit("editing-overlay", null);
    }
    function submitOp(params) {
      if (editingOp.value) {
        emit("update", { id: editingOp.value.id, type: editingOp.value.type, params });
        editingOp.value = null;
      } else {
        emit("add", { type: newType.value, params });
        adding.value = false;
      }
      emit("editing-overlay", null);
    }

    function opSummary(op) {
      const p = op.params || {};
      if (op.type === "color_effect") return `${p.effect || "?"} × ${p.duration_seconds ?? "∞"}s`;
      if (op.type === "zoom_in") return `scale ${p.scale ?? "?"} × ${p.duration_seconds ?? "?"}s`;
      if (op.type === "zoom_out") return `× ${p.duration_seconds ?? "?"}s`;
      if (op.type === "subtitle") return `"${(p.text || "").slice(0, 24)}" × ${p.duration_seconds ?? "?"}s`;
      if (op.type === "audio_mix") return `mix · vol ${p.volume ?? "?"} × ${p.duration_seconds ?? "?"}s`;
      if (op.type === "audio_replace") return `replace × ${p.duration_seconds ?? "?"}s`;
      if (op.type === "cut_before" || op.type === "cut_after") return "—";
      if (op.type === "insert_clip") return `clip #${p.timeline_clip_id ?? "?"}`;
      if (op.type === "switch_video") return `media #${p.media_file_id ?? "?"}`;
      if (op.type === "to_vertical") return `9:16 · crop x=${p.crop_x ?? 0.5} × ${p.duration_seconds ?? "∞"}s`;
      if (op.type === "vertical_split") return `9:16 apilado · ${p.n || 2} cámaras × ${p.duration_seconds ?? "∞"}s`;
      if (op.type === "remove_silences") return `${p.duration_seconds ?? "?"}s @ ${p.threshold_db ?? -40}dB`;
      if (op.type === "jump_to_moment") {
        const tgt = (props.moments || []).find(m => m.id === p.target_moment_id);
        if (tgt) return `→ "${tgt.label || '(sin etiqueta)'}" @ ${tgt.timeline_seconds.toFixed(2)}s`;
        return `→ momento #${p.target_moment_id ?? "?"}`;
      }
      if (op.type === "text_overlay") {
        return `"${(p.text || "").slice(0, 16)}" · ${p.font || "?"} · ${p.size_pct ?? "?"}% × ${p.duration_seconds ?? "?"}s`;
      }
      return JSON.stringify(p);
    }

    // Per-moment debounced save for inline numeric edits (start + end).
    // Holds one timer per moment.id so switching moments doesn't carry the
    // previous timer over.
    const _momentSaveTimers = new Map();
    function saveMomentField(field, value) {
      const m = props.moment;
      if (!m) return;
      const id = m.id;
      const prev = _momentSaveTimers.get(id);
      if (prev) clearTimeout(prev);
      const t = setTimeout(() => {
        _momentSaveTimers.delete(id);
        emit("update-moment", { id, patch: { [field]: value } });
      }, 350);
      _momentSaveTimers.set(id, t);
    }
    function setStart(v) {
      const f = parseFloat(v);
      if (!isFinite(f) || f < 0) return;
      saveMomentField("timeline_seconds", f);
    }
    function setEnd(v) {
      const m = props.moment;
      if (!m) return;
      // "End" is stored as duration relative to start; null/empty clears it.
      if (v === "" || v === null || v === undefined) {
        saveMomentField("duration_seconds", null);
        return;
      }
      const f = parseFloat(v);
      if (!isFinite(f)) return;
      const start = parseFloat(m.timeline_seconds) || 0;
      const dur = f - start;
      if (dur <= 0) {
        saveMomentField("duration_seconds", null);
        return;
      }
      saveMomentField("duration_seconds", dur);
    }
    function setLabel(v) {
      saveMomentField("label", v || "");
    }

    // The "end" input shows start + duration; if duration is null, leave blank.
    const endValue = computed(() => {
      const m = props.moment;
      if (!m) return "";
      const d = m.duration_seconds;
      if (d == null || d <= 0) return "";
      return ((m.timeline_seconds || 0) + d).toFixed(2);
    });

    return {
      adding, editingOp, newType, availableTypes, startAdd, startEdit, cancelForm, submitOp, opSummary,
      setStart, setEnd, setLabel, endValue,
    };
  },
  template: `
    <div class="ops-panel">
      <div class="panel-head">
        <span class="label">Operaciones</span>
        <span v-if="moment" class="count">{{ moment.operations.length }}</span>
        <div class="spacer"></div>
      </div>
      <div v-if="!moment" class="panel-empty">Selecciona un momento para ver o añadir operaciones.</div>
      <div v-else>
        <div class="moment-summary">
          <span class="kind" :class="moment.type">{{ moment.type }}</span>
          <span class="label">{{ moment.label || '—' }}</span>
        </div>

        <div class="moment-edit">
          <div class="me-row">
            <label>Etiqueta</label>
            <input type="text" :value="moment.label" @input="setLabel($event.target.value)"
                   placeholder="Sin etiqueta">
          </div>
          <div class="me-row two">
            <div>
              <label>Empieza en (s)</label>
              <input type="number" step="0.01" min="0"
                     :value="moment.timeline_seconds.toFixed(2)"
                     @change="setStart($event.target.value)">
            </div>
            <div>
              <label>Termina en (s)</label>
              <input type="number" step="0.01" min="0"
                     :value="endValue" :placeholder="moment.timeline_seconds.toFixed(2)"
                     @change="setEnd($event.target.value)">
            </div>
          </div>
          <div class="me-hint mono">
            <span>{{ formatShort(moment.timeline_seconds) }}</span>
            <span v-if="moment.duration_seconds && moment.duration_seconds > 0">
              → {{ formatShort(moment.timeline_seconds + moment.duration_seconds) }}
              · <strong>{{ moment.duration_seconds.toFixed(2) }}s</strong>
            </span>
            <span v-else class="muted">(punto sin rango)</span>
          </div>
        </div>

        <div v-if="moment.operations.length === 0" class="panel-empty" style="margin-top:10px;">
          Sin operaciones todavía.
        </div>
        <div v-else class="op-list">
          <div v-for="op in moment.operations" :key="op.id" class="op-row"
               :class="{ editing: editingOp && editingOp.id === op.id }">
            <span class="op-type">{{ op.type }}</span>
            <span class="op-summary mono">{{ opSummary(op) }}</span>
            <button class="icon ghost" @click="startEdit(op)" title="Editar">✎</button>
            <button class="icon danger" @click="$emit('remove', op.id)" title="Eliminar">✕</button>
          </div>
        </div>

        <div v-if="adding || editingOp" class="op-add">
          <label v-if="!editingOp">Tipo de operación</label>
          <select v-if="!editingOp" v-model="newType">
            <option v-for="opt in availableTypes" :key="opt.value" :value="opt.value">{{ opt.label }}</option>
          </select>
          <OpForm :type="editingOp ? editingOp.type : newType"
                  :clips="clips" :local-files="localFiles" :global-files="globalFiles"
                  :moments="moments" :current-moment-id="moment ? moment.id : null"
                  :initial-params="editingOp ? editingOp.params : null"
                  @submit="submitOp" @cancel="cancelForm"
                  @editing-overlay="(p) => $emit('editing-overlay', p)" />
        </div>
        <div v-else class="row right" style="margin-top:10px;">
          <button class="primary" @click="startAdd">＋ Agregar operación</button>
        </div>
      </div>
    </div>
  `,
  methods: { formatShort },
};

/* ==========================================================================
   Project view (editor) — backend-synced
   ========================================================================== */

/* ==========================================================================
   Transcript editor — Phase A:
   - Single-file at a time (drop-down to switch)
   - Loads the .words.json sidecar produced by Whisper word-level
   - Click word → seek the project player
   - Drag-select word range → press Delete (or click "Eliminar selección")
     creates a transcript_cut on the server. Deleted words render
     struck-through but stay visible so the user can restore them.
   - "Filler words" filter: highlights muletillas + batch-delete
   ========================================================================== */

var FILLER_WORDS = new Set([
  "eh", "ehh", "ehm", "uhm", "uhmm", "umm", "uh", "ah",
  "este", "estee", "esteee",
  "osea", "o-sea",
  "como", "tipo",
  "bueno",
  "digamos",
  "verdad", "viste", "viste?",
]);

function _normalizeFillerWord(w) {
  return (w || "")
    .toLowerCase()
    .replace(/[¿?¡!.,;:()"…]/g, "")
    .trim();
}

var TranscriptEditor = {
  props: { show: Boolean, slug: String },
  emits: ["close", "seek", "cuts-changed"],
  setup(props, { emit }) {
    const files = ref([]);                    // [{id, original_name, file_type, languages: ["es"]}]
    const selectedFileId = ref(null);
    const selectedLanguage = ref("");
    const transcript = ref(null);             // {language, duration, words}
    const cuts = ref([]);                     // server-truth transcript_cuts
    const loading = ref(false);
    const error = ref("");

    // Selection (range of word indices, [start, end] inclusive).
    const selStart = ref(null);
    const selEnd = ref(null);
    const dragging = ref(false);

    // Undo stack — stores IDs of recently created cuts.
    const cutHistory = ref([]);

    // Filter state
    const showFillersOnly = ref(false);

    /* ---------- loading ---------- */

    async function loadFiles() {
      try {
        const all = await api(`/api/projects/${props.slug}/files`);
        const usable = all.filter(f => f.file_type === "video" || f.file_type === "audio");
        // For each file, ask captions endpoint to know which langs are available.
        const out = [];
        for (const f of usable) {
          try {
            const r = await api(`/api/projects/${props.slug}/files/${f.id}/captions`);
            const langs = (r.captions || []).map(c => c.language);
            if (langs.length) out.push({ ...f, languages: langs });
          } catch (_) {}
        }
        files.value = out;
        if (!selectedFileId.value && out.length) {
          selectedFileId.value = out[0].id;
          selectedLanguage.value = out[0].languages[0];
        }
      } catch (e) { error.value = e.message; }
    }

    async function loadTranscript() {
      if (!selectedFileId.value || !selectedLanguage.value) return;
      loading.value = true;
      transcript.value = null;
      try {
        transcript.value = await api(
          `/api/projects/${props.slug}/files/${selectedFileId.value}/transcript?language=${encodeURIComponent(selectedLanguage.value)}`
        );
      } catch (e) {
        error.value = e.message + " — regenera los captions con la versión actual para tener timestamps por palabra.";
      } finally {
        loading.value = false;
      }
    }

    async function loadCuts() {
      try { cuts.value = await api(`/api/projects/${props.slug}/transcript-cuts`); }
      catch (_) {}
    }

    watch(() => [props.show, selectedFileId.value, selectedLanguage.value],
          ([s]) => { if (s) { loadTranscript(); loadCuts(); } });
    watch(() => props.show, (s) => { if (s) { loadFiles(); loadSubtitleStyle(); } });

    /* ---------- helpers ---------- */

    // A word is "deleted" if any cut covers its [s, e]. Cheap O(N*C) — fine
    // for transcripts up to ~10k words and a few hundred cuts.
    function isWordDeleted(word) {
      for (const c of cuts.value) {
        if (word.s >= c.start_seconds - 0.01 && word.e <= c.end_seconds + 0.01) return true;
      }
      return false;
    }

    function isFiller(word) {
      return FILLER_WORDS.has(_normalizeFillerWord(word.w));
    }

    const visibleWords = computed(() => transcript.value ? transcript.value.words : []);

    const fillerWords = computed(() =>
      visibleWords.value.map((w, i) => ({ w, i })).filter(x => isFiller(x.w) && !isWordDeleted(x.w))
    );

    const cutsCount = computed(() => cuts.value.length);
    const totalCutSeconds = computed(() =>
      cuts.value.reduce((sum, c) => sum + (c.end_seconds - c.start_seconds), 0)
    );
    const hasSelection = computed(() => selStart.value != null && selEnd.value != null);
    const selectionLabel = computed(() => {
      if (!hasSelection.value) return "";
      const a = Math.min(selStart.value, selEnd.value);
      const b = Math.max(selStart.value, selEnd.value);
      return `${b - a + 1} palabra(s)`;
    });

    /* ---------- selection ---------- */

    function onWordMouseDown(idx, ev) {
      // Plain click → seek + start selection at this idx
      ev.preventDefault();
      dragging.value = true;
      selStart.value = idx;
      selEnd.value = idx;
      const w = visibleWords.value[idx];
      if (w) emit("seek", w.s);
    }
    function onWordMouseEnter(idx) {
      if (dragging.value && selStart.value != null) selEnd.value = idx;
    }
    function onMouseUp() { dragging.value = false; }
    function clearSelection() { selStart.value = null; selEnd.value = null; }

    /* ---------- delete / restore ---------- */

    async function deleteSelection() {
      if (!hasSelection.value) return;
      const a = Math.min(selStart.value, selEnd.value);
      const b = Math.max(selStart.value, selEnd.value);
      const first = visibleWords.value[a];
      const last  = visibleWords.value[b];
      if (!first || !last) return;
      try {
        const created = await api(`/api/projects/${props.slug}/transcript-cuts`, {
          method: "POST",
          body: { start_seconds: first.s, end_seconds: last.e, label: `${b - a + 1} palabra(s)` },
        });
        cuts.value.push(created);
        if (created && created.id) cutHistory.value.push(created.id);
        clearSelection();
        emit("cuts-changed");
      } catch (e) { error.value = e.message; }
    }

    async function deleteAllFillers() {
      const words = fillerWords.value;
      if (!words.length) return;
      if (!confirm(`Eliminar ${words.length} muletilla(s)?`)) return;
      // Build cuts in batch — server accepts {cuts: [...]}
      const payload = words.map(x => ({
        start_seconds: x.w.s, end_seconds: x.w.e, label: `muletilla "${x.w.w.trim()}"`,
      }));
      try {
        const created = await api(`/api/projects/${props.slug}/transcript-cuts`, {
          method: "POST", body: { cuts: payload },
        });
        cuts.value = cuts.value.concat(Array.isArray(created) ? created : [created]);
        emit("cuts-changed");
      } catch (e) { error.value = e.message; }
    }

    async function restoreCut(cutId) {
      try {
        await api(`/api/projects/${props.slug}/transcript-cuts/${cutId}`, { method: "DELETE" });
        cuts.value = cuts.value.filter(c => c.id !== cutId);
        emit("cuts-changed");
      } catch (e) { error.value = e.message; }
    }

    async function restoreAll() {
      if (!cuts.value.length) return;
      if (!confirm(`Restaurar ${cuts.value.length} corte(s)?`)) return;
      try {
        await api(`/api/projects/${props.slug}/transcript-cuts`, { method: "DELETE" });
        cuts.value = [];
        emit("cuts-changed");
      } catch (e) { error.value = e.message; }
    }

    function getCutIdForWord(word) {
      const cut = cuts.value.find(
        c => word.s >= c.start_seconds - 0.01 && word.e <= c.end_seconds + 0.01
      );
      return cut ? cut.id : null;
    }

    async function undoLastCut() {
      const lastId = cutHistory.value.pop();
      if (lastId) await restoreCut(lastId);
    }

    /* ---------- subtitle style panel ---------- */

    const showStylePanel = ref(false);
    const subtitleStyle = ref({
      font_family: "sans-serif", font_size: "medium",
      text_color: "#FFFFFF", outline_color: "#000000",
      background_color: null, highlight_color: "#FFD700",
      position: "bottom",
    });

    async function loadSubtitleStyle() {
      try {
        subtitleStyle.value = await api(`/api/projects/${props.slug}/subtitle-style`);
      } catch (_) {}
    }

    async function updateStyleField(field, value) {
      subtitleStyle.value[field] = value;
      try {
        await api(`/api/projects/${props.slug}/subtitle-style`, {
          method: "PUT",
          body: { [field]: value },
        });
      } catch (e) { console.error("Error updating style:", e); }
    }

    /* ---------- inline word editing ---------- */

    const editingWordIdx = ref(null);
    const editingWordText = ref("");

    function startEditWord(idx) {
      editingWordIdx.value = idx;
      editingWordText.value = transcript.value.words[idx].w;
      nextTick(() => {
        const inp = document.querySelector(".word-edit-input");
        if (inp) inp.focus();
      });
    }

    async function saveEditWord() {
      const idx = editingWordIdx.value;
      if (idx == null) return;
      const newText = editingWordText.value.trim();
      if (!newText || newText === transcript.value.words[idx].w) {
        editingWordIdx.value = null;
        return;
      }
      try {
        await api(`/api/projects/${props.slug}/files/${selectedFileId.value}/captions/${encodeURIComponent(selectedLanguage.value)}/words`, {
          method: "PATCH",
          body: { edits: [{ index: idx, w: newText }] },
        });
        transcript.value.words[idx].w = newText;
        transcript.value.words[idx]._edited = true;
      } catch (e) {
        console.error("Error saving word edit:", e);
      }
      editingWordIdx.value = null;
    }

    function cancelEditWord() {
      editingWordIdx.value = null;
    }

    /* ---------- keyboard ---------- */

    function onKey(ev) {
      if (!props.show) return;
      if (editingWordIdx.value != null) return;
      // Delete or Backspace removes selection
      if ((ev.key === "Delete" || ev.key === "Backspace") && hasSelection.value) {
        ev.preventDefault();
        deleteSelection();
      } else if ((ev.ctrlKey || ev.metaKey) && ev.key === "z") {
        ev.preventDefault();
        undoLastCut();
      } else if (ev.key === "Escape") {
        clearSelection();
      }
    }
    onMounted(() => {
      window.addEventListener("keydown", onKey);
      window.addEventListener("mouseup", onMouseUp);
    });
    onBeforeUnmount(() => {
      window.removeEventListener("keydown", onKey);
      window.removeEventListener("mouseup", onMouseUp);
    });

    /* ---------- UI helpers ---------- */

    function fmtTs(s) {
      if (!isFinite(s)) return "—";
      const m = Math.floor(s / 60), sec = Math.floor(s % 60);
      return `${m}:${String(sec).padStart(2, "0")}`;
    }

    function fileChanged(ev) {
      const id = parseInt(ev.target.value, 10);
      selectedFileId.value = id;
      const f = files.value.find(x => x.id === id);
      if (f && f.languages.length) selectedLanguage.value = f.languages[0];
    }

    return {
      files, selectedFileId, selectedLanguage,
      transcript, cuts, loading, error,
      selStart, selEnd, hasSelection, selectionLabel,
      visibleWords, fillerWords, cutsCount, totalCutSeconds, showFillersOnly,
      cutHistory, isWordDeleted, isFiller, fmtTs, fileChanged,
      onWordMouseDown, onWordMouseEnter, clearSelection,
      deleteSelection, deleteAllFillers, restoreCut, restoreAll, loadTranscript,
      getCutIdForWord, undoLastCut,
      editingWordIdx, editingWordText, startEditWord, saveEditWord, cancelEditWord,
      showStylePanel, subtitleStyle, updateStyleField,
    };
  },
  template: `
    <div v-if="show" class="modal-backdrop" @click.self="$emit('close')">
      <div class="modal" style="width: min(960px, 96vw); max-height: 92vh; display: flex; flex-direction: column;">
        <div class="eyebrow">TRANSCRIPT</div>
        <h3>Editar por palabras</h3>
        <p class="muted" style="margin: 0 0 12px; font-size: 12px;">
          Selecciona palabras y bórralas — los rangos se cortan en el render final. No es destructivo: puedes restaurar.
        </p>

        <div v-if="error" class="error">{{ error }}</div>

        <div style="display: flex; gap: 10px; align-items: center; flex-wrap: wrap; margin-bottom: 10px;">
          <select :value="selectedFileId || ''" @change="fileChanged" :disabled="!files.length">
            <option v-if="!files.length" value="">— sin transcripts —</option>
            <option v-for="f in files" :key="f.id" :value="f.id">{{ f.original_name }}</option>
          </select>
          <select v-model="selectedLanguage" :disabled="!selectedFileId">
            <option v-for="l in (files.find(f => f.id === selectedFileId) || {languages:[]}).languages" :key="l" :value="l">{{ l }}</option>
          </select>
          <button class="ghost" @click="loadTranscript" title="Recargar">⟲</button>
          <div class="spacer"></div>
          <span class="mono muted" style="font-size: 12px;">{{ cutsCount }} corte(s)</span>
          <button v-if="cutsCount" class="ghost" style="font-size: 12px;" @click="restoreAll">↶ Restaurar todo</button>
        </div>

        <div v-if="loading" class="muted">Cargando transcript…</div>

        <template v-else-if="transcript">
          <div class="transcript-toolbar" style="display: flex; gap: 8px; align-items: center; margin-bottom: 8px; flex-wrap: wrap;">
            <span v-if="hasSelection" class="role-chip" style="background: var(--signal); color: #fff;">{{ selectionLabel }}</span>
            <button v-if="hasSelection" class="primary" style="font-size: 12px; padding: 4px 10px;" @click="deleteSelection">✕ Eliminar selección (Del)</button>
            <button v-if="hasSelection" class="ghost" style="font-size: 12px; padding: 4px 10px;" @click="clearSelection">Cancelar</button>
            <button v-if="cutHistory.length" class="ghost" style="font-size: 12px; padding: 4px 10px;" @click="undoLastCut" title="Ctrl+Z">↶ Deshacer</button>

            <div class="spacer"></div>

            <span v-if="totalCutSeconds > 0" class="transcript-cut-counter">{{ totalCutSeconds.toFixed(1) }}s eliminados</span>
            <span class="transcript-hint">Selecciona y Delete · Doble-click edita · Ctrl+Z deshace</span>

            <label style="display: flex; align-items: center; gap: 4px; font-size: 12px;">
              <input type="checkbox" v-model="showFillersOnly">
              Resaltar muletillas
            </label>
            <button v-if="fillerWords.length" class="ghost" style="font-size: 12px; padding: 4px 10px;" @click="deleteAllFillers">
              ✂ Eliminar {{ fillerWords.length }} muletilla(s)
            </button>
          </div>

          <div style="margin-bottom: 8px;">
            <button class="kbd" @click="showStylePanel = !showStylePanel" style="font-size:11px;">
              {{ showStylePanel ? '▾' : '▸' }} Estilo de subtítulos
            </button>
          </div>
          <div v-if="showStylePanel" class="subtitle-style-panel">
            <div class="style-row">
              <span class="style-label">Fuente</span>
              <div class="style-options">
                <button v-for="f in ['sans-serif','serif','mono','display']" :key="f"
                        class="kbd" :class="{ active: subtitleStyle.font_family === f }"
                        @click="updateStyleField('font_family', f)">
                  {{ {'sans-serif':'Sans','serif':'Serif','mono':'Mono','display':'Display'}[f] }}
                </button>
              </div>
            </div>
            <div class="style-row">
              <span class="style-label">Tamaño</span>
              <div class="style-options">
                <button v-for="s in ['small','medium','large']" :key="s"
                        class="kbd" :class="{ active: subtitleStyle.font_size === s }"
                        @click="updateStyleField('font_size', s)">
                  {{ {small:'S', medium:'M', large:'L'}[s] }}
                </button>
              </div>
            </div>
            <div class="style-row">
              <span class="style-label">Color texto</span>
              <input type="color" :value="subtitleStyle.text_color"
                     @change="updateStyleField('text_color', $event.target.value)">
            </div>
            <div class="style-row">
              <span class="style-label">Color contorno</span>
              <input type="color" :value="subtitleStyle.outline_color"
                     @change="updateStyleField('outline_color', $event.target.value)">
            </div>
            <div class="style-row">
              <span class="style-label">Fondo</span>
              <label style="display:flex;align-items:center;gap:6px;">
                <input type="checkbox" :checked="!!subtitleStyle.background_color"
                       @change="updateStyleField('background_color', $event.target.checked ? '#000000' : null)">
                <input v-if="subtitleStyle.background_color" type="color"
                       :value="subtitleStyle.background_color"
                       @change="updateStyleField('background_color', $event.target.value)">
              </label>
            </div>
            <div class="style-row">
              <span class="style-label">Highlight (karaoke)</span>
              <input type="color" :value="subtitleStyle.highlight_color"
                     @change="updateStyleField('highlight_color', $event.target.value)">
            </div>
            <div class="style-row">
              <span class="style-label">Posición</span>
              <div class="style-options">
                <button v-for="p in ['top','center','bottom']" :key="p"
                        class="kbd" :class="{ active: subtitleStyle.position === p }"
                        @click="updateStyleField('position', p)">
                  {{ {top:'Arriba', center:'Centro', bottom:'Abajo'}[p] }}
                </button>
              </div>
            </div>
          </div>

          <div class="transcript-words"
               style="flex: 1; overflow-y: auto; line-height: 1.9; font-size: 15px; user-select: none; padding: 8px; border: 1px solid var(--ink-line); border-radius: 6px; background: var(--ink-sunken);">
            <template v-for="(w, i) in visibleWords" :key="i">
              <input v-if="editingWordIdx === i"
                     type="text"
                     v-model="editingWordText"
                     @keydown.enter="saveEditWord"
                     @keydown.escape="cancelEditWord"
                     @blur="saveEditWord"
                     class="word-edit-input"
                     :style="{ width: Math.max(40, editingWordText.length * 9) + 'px' }">
              <span v-else
                    class="t-word"
                    :class="{
                      'is-deleted': isWordDeleted(w),
                      'is-filler': showFillersOnly && isFiller(w) && !isWordDeleted(w),
                      'is-selected':
                        selStart != null && selEnd != null &&
                        i >= Math.min(selStart, selEnd) && i <= Math.max(selStart, selEnd),
                      'is-edited': w._edited,
                    }"
                    :title="fmtTs(w.s)"
                    @mousedown="onWordMouseDown(i, $event)"
                    @mouseenter="onWordMouseEnter(i)"
                    @dblclick.stop="startEditWord(i)"
                    style="cursor: pointer; padding: 1px 2px; border-radius: 3px;">
                {{ w.w }}<span> </span>
              </span>
            </template>
          </div>

          <div v-if="cuts.length" class="muted" style="margin-top: 10px; max-height: 120px; overflow-y: auto; font-size: 12px;">
            <div style="margin-bottom: 4px;"><span class="eyebrow">CORTES ACTIVOS</span></div>
            <div v-for="c in cuts" :key="c.id" style="display: flex; align-items: center; gap: 8px; padding: 2px 0;">
              <span class="mono">{{ fmtTs(c.start_seconds) }} → {{ fmtTs(c.end_seconds) }}</span>
              <span style="opacity: 0.7;">{{ c.label || "—" }}</span>
              <div class="spacer"></div>
              <button class="ghost" style="font-size: 11px; padding: 2px 8px;" @click="restoreCut(c.id)">↶ Restaurar</button>
            </div>
          </div>
        </template>

        <div v-else-if="!files.length" class="empty-pill" style="margin-top: 10px;">
          Genera captions de algún archivo primero (con la versión actual de la app, que ya guarda timestamps por palabra).
        </div>

        <div class="row right" style="margin-top: 14px; gap: 8px;">
          <button class="primary" @click="$emit('close')">Cerrar</button>
        </div>
      </div>
    </div>
  `,
};

var ExportModal = {
  props: {
    slug: String,
    // selectedRange comes from ProjectView's drag-select. When present, the
    // user can opt into "exportar sólo este rango" (range_start/range_end).
    selectedRange: { type: Object, default: null },
    hasMultitrack: { type: Boolean, default: false },
  },
  emits: ["close"],
  setup(props, { emit }) {
    const presets = ref([]);
    const selectedId = ref(null);
    const job = ref(null);
    const history = ref([]);
    const busy = ref(false);
    const error = ref("");
    let pollHandle = null;

    // Burn-in captions: language + which clip's source the SRT comes from.
    const burnCaptions = ref(false);
    const burnCaptionLang = ref(localStorage.getItem("postpod.captionsLanguage") || "es");
    const availableCaptions = ref([]); // [{media_file_id, original_name, languages:[]}]

    // Optional sidecar .txt with title + chapters + credits.
    const generateNotes = ref(localStorage.getItem("postpod.generateNotes") === "1");
    watch(generateNotes, (v) => localStorage.setItem("postpod.generateNotes", v ? "1" : "0"));

    // One-click "studio" audio enhancement (denoise + EQ + compression +
    // loudnorm). Off by default — irreversible operations make some users
    // nervous; let them opt in per export.
    const enhanceSpeech = ref(localStorage.getItem("postpod.enhanceSpeech") === "1");
    watch(enhanceSpeech, (v) => localStorage.setItem("postpod.enhanceSpeech", v ? "1" : "0"));

    const layoutTemplate = ref(localStorage.getItem("postpod.layoutTemplate") || "side_by_side");
    watch(layoutTemplate, (v) => localStorage.setItem("postpod.layoutTemplate", v));
    const pipCorner = ref(localStorage.getItem("postpod.pipCorner") || "bottom_right");
    watch(pipCorner, (v) => localStorage.setItem("postpod.pipCorner", v));
    const pipMainTrack = ref(parseInt(localStorage.getItem("postpod.pipMainTrack") || "1", 10));
    watch(pipMainTrack, (v) => localStorage.setItem("postpod.pipMainTrack", String(v)));

    const useBackground = ref(localStorage.getItem("postpod.useBackground") === "1");
    watch(useBackground, (v) => localStorage.setItem("postpod.useBackground", v ? "1" : "0"));

    const momentBanner = ref(localStorage.getItem("postpod.momentBanner") === "1");
    watch(momentBanner, (v) => localStorage.setItem("postpod.momentBanner", v ? "1" : "0"));

    const bannerPosition = ref(localStorage.getItem("postpod.bannerPosition") || "bottom");
    watch(bannerPosition, (v) => localStorage.setItem("postpod.bannerPosition", v));

    const isVerticalPreset = computed(() => {
      if (!selectedId.value) return false;
      const p = presets.value.find(x => x.id === selectedId.value);
      return p && p.height > p.width;
    });

    // "Exportar sólo el rango seleccionado": defaults to ON whenever the
    // user opens the modal with a drag-selection active. They can untick it
    // to fall back to a full-timeline export.
    const useSelectedRange = ref(false);
    watch(() => props.selectedRange, (v) => {
      // Auto-tick when a range becomes available; auto-untick when it's gone.
      useSelectedRange.value = !!v;
    }, { immediate: true });

    async function loadAvailableCaptions() {
      try {
        const files = await api(`/api/projects/${props.slug}/files`);
        const videos = files.filter(f => f.file_type === "video" || f.file_type === "audio");
        const out = [];
        for (const f of videos) {
          try {
            const data = await api(`/api/projects/${props.slug}/files/${f.id}/captions`);
            const langs = (data.captions || []).map(c => c.language);
            if (langs.length) out.push({ media_file_id: f.id, original_name: f.original_name, languages: langs });
          } catch (_) {}
        }
        availableCaptions.value = out;
      } catch (_) {}
    }

    async function loadPresets() {
      try { presets.value = await api("/api/export/presets"); }
      catch (e) { error.value = e.message; }
    }
    async function loadHistory() {
      try { history.value = await api(`/api/projects/${props.slug}/exports`); }
      catch (e) { /* ignore */ }
    }

    async function start() {
      if (!selectedId.value) return;
      busy.value = true;
      error.value = "";
      job.value = null;
      try {
        const body = { preset_id: selectedId.value };
        if (burnCaptions.value && burnCaptionLang.value && availableCaptions.value.length) {
          // Use the first clip's source as the captions origin (matches the
          // composite layout). Server resolves the SRT path.
          body.burn_captions = {
            media_file_id: availableCaptions.value[0].media_file_id,
            language: burnCaptionLang.value,
          };
        }
        if (generateNotes.value) body.generate_notes = true;
        if (enhanceSpeech.value) body.enhance_speech = true;
        if (props.hasMultitrack) {
          body.layout_template = layoutTemplate.value;
          if (layoutTemplate.value === "pip") {
            body.pip_corner = pipCorner.value;
            body.pip_main_track = pipMainTrack.value;
          }
        }
        if (useBackground.value) body.use_background = true;
        if (momentBanner.value) {
          body.moment_banner = true;
          body.banner_position = bannerPosition.value;
        }
        if (useSelectedRange.value && props.selectedRange) {
          body.range_start = props.selectedRange.start;
          body.range_end   = props.selectedRange.end;
        }
        const r = await api(`/api/projects/${props.slug}/export`, {
          method: "POST", body,
        });
        job.value = { id: r.job_id, status: r.status, progress: 0 };
        poll();
      } catch (e) {
        error.value = e.message;
        busy.value = false;
      }
    }

    async function cancel() {
      if (!job.value) return;
      try {
        await api(`/api/projects/${props.slug}/export/${job.value.id}/cancel`, { method: "POST" });
      } catch (e) {
        error.value = e.message;
      }
    }

    function poll() {
      if (pollHandle) clearTimeout(pollHandle);
      pollHandle = setTimeout(async () => {
        if (!job.value) return;
        try {
          const r = await api(`/api/projects/${props.slug}/export/${job.value.id}`);
          job.value = r;
          if (r.status === "running" || r.status === "pending") {
            poll();
          } else {
            busy.value = false;
            loadHistory();
          }
        } catch (e) {
          error.value = e.message;
          busy.value = false;
        }
      }, 1500);
    }

    function reset() {
      job.value = null;
      error.value = "";
      if (pollHandle) { clearTimeout(pollHandle); pollHandle = null; }
    }

    const grouped = computed(() => {
      const out = {};
      for (const p of presets.value) {
        const plat = p.platform || "General";
        if (!out[plat]) out[plat] = [];
        out[plat].push(p);
      }
      return out;
    });

    const downloadUrl = computed(() =>
      job.value && job.value.status === "done"
        ? `/api/projects/${props.slug}/export/${job.value.id}/download`
        : null
    );
    const streamUrl = computed(() =>
      job.value && job.value.status === "done"
        ? `/api/projects/${props.slug}/export/${job.value.id}/download?attachment=0`
        : null
    );
    const notesUrl = computed(() =>
      job.value && job.value.status === "done" && job.value.notes_file
        ? `/api/projects/${props.slug}/export/${job.value.id}/notes`
        : null
    );

    onMounted(() => { loadPresets(); loadHistory(); loadAvailableCaptions(); });
    onBeforeUnmount(() => { if (pollHandle) clearTimeout(pollHandle); });

    function fmtRangeSec(s) {
      if (!isFinite(s)) return "—";
      const m = Math.floor(s / 60);
      const sec = (s - m * 60).toFixed(1);
      return `${m}:${sec.padStart(4, "0")}`;
    }

    const showAllHistory = ref(false);

    return { presets, selectedId, job, history, busy, error, grouped, downloadUrl, streamUrl, notesUrl,
             start, cancel, reset, loadHistory, showAllHistory,
             burnCaptions, burnCaptionLang, availableCaptions, loadAvailableCaptions,
             generateNotes, enhanceSpeech, layoutTemplate, pipCorner, pipMainTrack, useBackground, momentBanner, bannerPosition, isVerticalPreset, useSelectedRange, fmtRangeSec };
  },
  template: `
    <div class="modal-backdrop" @click.self="$emit('close')">
      <div class="modal" style="width: 520px; max-height: calc(100vh - 40px); display: flex; flex-direction: column;">
        <div class="eyebrow">EXPORTAR</div>

        <div v-if="!job" style="margin-top: 10px; overflow-y:auto; flex: 1;">
          <div v-for="(items, plat) in grouped" :key="plat" style="margin-bottom:6px;">
            <div class="tiny" style="margin: 4px 0 2px; color: var(--signal);">{{ plat }}</div>
            <div class="preset-list">
              <div
                v-for="p in items"
                :key="p.id"
                class="preset-card"
                :class="{ selected: selectedId === p.id }"
                @click="selectedId = p.id"
              >
                <div class="preset-name">{{ p.name }}</div>
                <div class="preset-meta mono">
                  <template v-if="p.width">{{ p.width }}×{{ p.height }} · {{ p.fps }}fps · {{ p.format }}</template>
                  <template v-else>{{ p.format }} · audio</template>
                </div>
              </div>
            </div>
          </div>

          <!-- Options -->
          <div style="margin-top: 8px; padding-top: 8px; border-top: 1px solid var(--ink-line); display: flex; flex-direction: column; gap: 4px;">
            <label v-if="availableCaptions.length" style="display: flex; align-items: center; gap: 6px; cursor: pointer; text-transform: none; letter-spacing: 0; font-size: 12px;">
              <input type="checkbox" v-model="burnCaptions">
              Quemar captions
              <select v-if="burnCaptions" v-model="burnCaptionLang" style="margin-left: 4px; font-size: 11px; padding: 1px 4px;" @click.stop>
                <option v-for="lang in availableCaptions[0].languages" :key="lang" :value="lang">{{ lang }}</option>
              </select>
            </label>
            <label style="display: flex; align-items: center; gap: 6px; cursor: pointer; text-transform: none; letter-spacing: 0; font-size: 12px;">
              <input type="checkbox" v-model="generateNotes">
              Generar notas y capítulos (.txt)
            </label>
            <label style="display: flex; align-items: center; gap: 6px; cursor: pointer; text-transform: none; letter-spacing: 0; font-size: 12px;">
              <input type="checkbox" v-model="enhanceSpeech">
              Audio profesional (denoise + EQ + normalize)
            </label>
            <div v-if="hasMultitrack" style="margin-top:6px;">
              <div class="style-label" style="margin-bottom:6px;">Composición</div>
              <div class="layout-selector">
                <button v-for="lt in [
                  { id: 'side_by_side', label: 'Lado a lado', icon: '[▪▪]' },
                  { id: 'grid', label: 'Grid', icon: '[⊞]' },
                  { id: 'spotlight', label: 'Spotlight', icon: '[▪▫]' },
                  { id: 'pip', label: 'PiP', icon: '[▪°]' },
                  { id: 'solo', label: 'Solo speaker', icon: '[▪]' },
                ]" :key="lt.id"
                        class="layout-btn" :class="{ active: layoutTemplate === lt.id }"
                        @click="layoutTemplate = lt.id"
                        :title="lt.label">
                  <span class="layout-icon mono">{{ lt.icon }}</span>
                  <span class="layout-label">{{ lt.label }}</span>
                </button>
              </div>
              <div v-if="layoutTemplate === 'pip'" style="margin-top:6px;display:flex;gap:12px;align-items:center;">
                <div>
                  <span class="style-label">Esquina</span>
                  <div style="display:flex;gap:3px;margin-top:3px;">
                    <button v-for="c in [
                      { id: 'top_left', label: '↖' },
                      { id: 'top_right', label: '↗' },
                      { id: 'bottom_left', label: '↙' },
                      { id: 'bottom_right', label: '↘' },
                    ]" :key="c.id"
                            class="kbd" :class="{ active: pipCorner === c.id }"
                            @click="pipCorner = c.id"
                            style="width:28px;height:28px;display:flex;align-items:center;justify-content:center;">
                      {{ c.label }}
                    </button>
                  </div>
                </div>
                <div>
                  <span class="style-label">Track principal</span>
                  <div style="display:flex;gap:3px;margin-top:3px;">
                    <button class="kbd" :class="{ active: pipMainTrack === 1 }"
                            @click="pipMainTrack = 1">1</button>
                    <button class="kbd" :class="{ active: pipMainTrack === 2 }"
                            @click="pipMainTrack = 2">2</button>
                  </div>
                </div>
              </div>
            </div>
            <label style="display: flex; align-items: center; gap: 6px; cursor: pointer; text-transform: none; letter-spacing: 0; font-size: 12px;">
              <input type="checkbox" v-model="useBackground">
              Fondo de marca (sin barras negras)
            </label>
            <label v-if="useSelectedRange && selectedRange" style="display: flex; align-items: center; gap: 6px; cursor: pointer; text-transform: none; letter-spacing: 0; font-size: 12px;">
              <input type="checkbox" v-model="momentBanner">
              Banner de momento (estilo CNN)
              <select v-if="momentBanner && isVerticalPreset" v-model="bannerPosition" style="margin-left: 4px; font-size: 11px; padding: 1px 4px;" @click.stop>
                <option value="top">Arriba</option>
                <option value="middle">Medio</option>
                <option value="bottom">Abajo</option>
              </select>
            </label>
          </div>

          <!-- Range selection -->
          <div v-if="selectedRange" style="margin-top: 6px; padding: 6px 10px; background: rgba(244,199,112,0.08); border: 1px solid rgba(244,199,112,0.3); border-radius: 6px;">
            <label style="display: flex; align-items: center; gap: 6px; cursor: pointer; text-transform: none; letter-spacing: 0; font-size: 12px;">
              <input type="checkbox" v-model="useSelectedRange">
              Exportar sólo el rango seleccionado
            </label>
            <div class="muted mono" style="font-size: 10px; margin-top: 2px;">
              {{ fmtRangeSec(selectedRange.start) }} → {{ fmtRangeSec(selectedRange.end) }}
              · {{ (selectedRange.end - selectedRange.start).toFixed(2) }}s
            </div>
          </div>

          <!-- History (collapsed) -->
          <div v-if="history.length > 0" style="margin-top: 8px; padding-top: 8px; border-top: 1px solid var(--ink-line);">
            <div class="tiny" style="margin-bottom: 4px; display: flex; align-items: center; gap: 6px;">
              Recientes
              <span v-if="history.length > 3" style="cursor: pointer; color: var(--signal-dim); font-size: 10px;" @click="showAllHistory = !showAllHistory">
                {{ showAllHistory ? '(menos)' : '(ver ' + history.length + ')' }}
              </span>
            </div>
            <div class="history-list">
              <div v-for="h in (showAllHistory ? history : history.slice(0, 3))" :key="h.id" class="history-row">
                <span class="mono" style="color: var(--signal-dim);">#{{ h.id }}</span>
                <span class="mono">{{ h.preset_id }}</span>
                <span class="kind mono" :class="h.status">{{ h.status }}</span>
                <div class="spacer"></div>
                <a v-if="h.status === 'done' && h.output_file" :href="'/api/projects/' + slug + '/export/' + h.id + '/download'" class="kbd" style="text-decoration: none; font-size: 10px; padding: 2px 6px;" title="Descargar">↓</a>
                <a v-if="h.status === 'done' && h.notes_file" :href="'/api/projects/' + slug + '/export/' + h.id + '/notes'" class="kbd" style="text-decoration: none; font-size: 10px; padding: 2px 6px;" title="Notas">N</a>
              </div>
            </div>
          </div>
        </div>

        <!-- Job progress view -->
        <div v-else style="margin-top: 14px;">
          <div class="muted" style="font-family: var(--font-mono); font-size: 11px; letter-spacing: 0.14em; text-transform: uppercase;">
            Job #{{ job.id }} · {{ job.preset_id }}
          </div>
          <div class="progress-bar" style="margin-top: 10px;">
            <div class="progress-fill" :style="{ width: (job.progress || 0) + '%' }"></div>
            <div class="progress-text mono">
              <template v-if="job.status === 'running' || job.status === 'pending'">{{ job.progress || 0 }}%</template>
              <template v-else-if="job.status === 'done'">listo</template>
              <template v-else-if="job.status === 'cancelled'">cancelado</template>
              <template v-else-if="job.status === 'error'">error</template>
            </div>
          </div>
          <div v-if="job.status === 'running' || job.status === 'pending'" class="row right" style="margin-top: 10px;">
            <button class="danger" @click="cancel">Cancelar</button>
          </div>
          <div v-if="job.status === 'cancelled'" class="muted" style="margin-top: 10px; padding: 8px; border: 1px dashed var(--ink-line); border-radius: var(--r-md); text-align: center;">
            Export cancelado.
            <div style="margin-top: 6px;"><button class="ghost" @click="reset">Intentar otra vez</button></div>
          </div>

          <div v-if="job.status === 'done'" class="card" style="margin-top: 12px; padding: 10px;">
            <div class="row" style="gap: 8px; flex-wrap: wrap;">
              <a :href="downloadUrl" class="kbd" style="text-decoration: none; padding: 6px 12px; font-size: 12px; background: var(--signal); color: var(--ink-deep); border: 0; font-weight: 600;">Descargar</a>
              <a :href="streamUrl" target="_blank" class="kbd" style="text-decoration: none; padding: 6px 12px; font-size: 12px;">Reproducir</a>
              <a v-if="notesUrl" :href="notesUrl" class="kbd" style="text-decoration: none; padding: 6px 12px; font-size: 12px;">Notas</a>
              <div class="spacer"></div>
              <button class="ghost" @click="reset">Otra exportación</button>
            </div>
          </div>

          <div v-if="job.status === 'error'" class="error" style="margin-top: 12px; white-space: pre-wrap; max-height: 180px; overflow-y: auto; font-size: 11px;">
            {{ job.error_msg || 'error sin detalles' }}
            <div style="margin-top: 6px;"><button class="ghost" @click="reset">Intentar de nuevo</button></div>
          </div>
        </div>

        <div v-if="error" class="error" style="margin-top: 6px;">{{ error }}</div>

        <div class="row right" style="margin-top: 12px; gap: 8px;">
          <button class="ghost" @click="$emit('close')">Cerrar</button>
          <button v-if="!job" class="primary" :disabled="!selectedId || busy" @click="start">
            {{ busy ? 'Lanzando…' : 'Exportar' }}
          </button>
        </div>
      </div>
    </div>
  `,
};

var SilenceModal = {
  props: { slug: String },
  emits: ["close", "applied", "seek"],
  setup(props, { emit }) {
    const minGap = ref(parseFloat(localStorage.getItem("postpod.silenceGap") || "1.0"));
    const loading = ref(false);
    const silences = ref([]);
    const sourceUsed = ref("");
    const checked = ref({});
    const applying = ref(false);
    const error = ref("");

    watch(minGap, (v) => {
      localStorage.setItem("postpod.silenceGap", String(v));
    });

    let debounceTimer = null;
    async function detect() {
      loading.value = true;
      error.value = "";
      try {
        const r = await api(`/api/projects/${props.slug}/silence/detect`, {
          method: "POST",
          body: { min_gap: minGap.value, source: "auto" },
        });
        silences.value = r.silences || [];
        sourceUsed.value = r.source_used || "";
        const c = {};
        silences.value.forEach((_, i) => { c[i] = true; });
        checked.value = c;
      } catch (e) { error.value = e.message; }
      loading.value = false;
    }

    function onSliderInput() {
      clearTimeout(debounceTimer);
      debounceTimer = setTimeout(detect, 300);
    }

    const checkedCount = computed(() => Object.values(checked.value).filter(Boolean).length);
    const checkedDuration = computed(() => {
      let t = 0;
      silences.value.forEach((s, i) => { if (checked.value[i]) t += s.duration; });
      return t.toFixed(1);
    });

    async function apply() {
      applying.value = true;
      error.value = "";
      const cuts = silences.value.filter((_, i) => checked.value[i]).map(s => ({
        start: s.start, end: s.end, label: s.label,
      }));
      try {
        await api(`/api/projects/${props.slug}/silence/apply`, {
          method: "POST", body: { cuts },
        });
        emit("applied");
        emit("close");
      } catch (e) { error.value = e.message; }
      applying.value = false;
    }

    onMounted(detect);

    return { minGap, loading, silences, sourceUsed, checked, applying,
             error, onSliderInput, detect, checkedCount, checkedDuration, apply };
  },
  template: `
    <div class="modal-backdrop" @click.self="$emit('close')">
      <div class="modal" style="max-width:560px; max-height:80vh; display:flex; flex-direction:column;">
        <div class="eyebrow">ELIMINAR SILENCIOS</div>
        <h3>Detectar y cortar pausas</h3>
        <div style="padding:12px 0;">
          <label class="style-label" style="display:block;margin-bottom:4px;">
            Tolerancia de pausa: {{ minGap.toFixed(1) }}s
          </label>
          <input type="range" min="0.3" max="3.0" step="0.1"
                 v-model.number="minGap" @input="onSliderInput"
                 style="width:100%;">
          <div class="muted" style="font-size:10px;margin-top:2px;">
            Detectado desde: {{ sourceUsed || '...' }}
          </div>
        </div>
        <div v-if="loading" class="muted" style="padding:16px;text-align:center;">
          Analizando...
        </div>
        <div v-else-if="silences.length === 0" class="muted" style="padding:16px;text-align:center;">
          No se encontraron pausas mayores a {{ minGap.toFixed(1) }}s
        </div>
        <div v-else style="flex:1;overflow-y:auto;padding:0;">
          <div v-for="(s, i) in silences" :key="i" class="silence-row"
               @click="$emit('seek', s.start)">
            <input type="checkbox" v-model="checked[i]" @click.stop>
            <span class="silence-label">{{ s.label }}</span>
            <span class="badge mono">{{ s.duration.toFixed(1) }}s</span>
          </div>
        </div>
        <div v-if="silences.length > 0" class="silence-summary">
          <span>Se eliminarán {{ checkedCount }} de {{ silences.length }} pausas
                ({{ checkedDuration }}s)</span>
          <button class="primary" @click="apply" :disabled="applying || checkedCount === 0">
            {{ applying ? 'Aplicando...' : 'Aplicar' }}
          </button>
        </div>
        <div v-if="error" class="error" style="padding:8px 0;">{{ error }}</div>
        <div class="row right" style="margin-top:10px;">
          <button class="ghost" @click="$emit('close')">Cerrar</button>
        </div>
      </div>
    </div>
  `,
};

var AiPanel = {
  props: { slug: String, moments: Array },
  emits: ['moment-created'],
  setup(props, { emit }) {
    const notes = ref(null);       // { summary, highlights, generated_at }
    const clips = ref([]);
    const activeJob = ref(null);
    const loading = ref(false);
    let pollTimer = null;

    async function loadResults() {
      try {
        const data = await api(`/api/projects/${props.slug}/ai/results`);
        if (data.notes) {
          notes.value = {
            summary: data.notes.summary,
            highlights: data.notes.highlights || [],
            generated_at: data.notes.created_at,
          };
        }
        if (data.clips) {
          const clipsData = data.clips.clips || [];
          clips.value = clipsData.map(c => ({ ...c, _created: false }));
        }
        activeJob.value = data.active_job;
        if (data.active_job && ['pending', 'running'].includes(data.active_job.status)) {
          startPoll();
        }
      } catch (e) { /* silent */ }
    }

    function startPoll() {
      if (pollTimer) return;
      pollTimer = setInterval(async () => {
        await loadResults();
        if (!activeJob.value || !['pending', 'running'].includes(activeJob.value.status)) {
          clearInterval(pollTimer);
          pollTimer = null;
        }
      }, 3000);
    }

    async function startAnalysis() {
      loading.value = true;
      try {
        const job = await api(`/api/projects/${props.slug}/ai/analyze`, { method: 'POST' });
        activeJob.value = job;
        startPoll();
      } catch (e) { activeJob.value = { status: 'error', error_msg: e.message }; }
      finally { loading.value = false; }
    }

    async function regenNotes() {
      const job = await api(`/api/projects/${props.slug}/ai/regenerate-notes`, { method: 'POST' });
      activeJob.value = job;
      startPoll();
    }

    async function regenClips() {
      const job = await api(`/api/projects/${props.slug}/ai/regenerate-clips`, { method: 'POST' });
      activeJob.value = job;
      startPoll();
    }

    function parseTimestamp(ts) {
      const parts = ts.split(':').map(Number);
      if (parts.length === 2) return parts[0] * 60 + parts[1];
      return parts[0] * 3600 + parts[1] * 60 + parts[2];
    }

    async function createMoment(clip) {
      const startSec = parseTimestamp(clip.start);
      const endSec = parseTimestamp(clip.end);
      const body = {
        type: 'absolute',
        timeline_seconds: startSec,
        duration_seconds: endSec - startSec,
        label: `[AI] ${clip.title}`,
      };
      await api(`/api/projects/${props.slug}/moments`, { method: 'POST', body });
      clip._created = true;
      emit('moment-created');
    }

    async function createAll() {
      for (const clip of clips.value) {
        if (!clip._created) await createMoment(clip);
      }
    }

    onMounted(loadResults);
    onBeforeUnmount(() => { if (pollTimer) clearInterval(pollTimer); });

    return { notes, clips, activeJob, loading, startAnalysis, regenNotes, regenClips, createMoment, createAll };
  },
  template: `
    <div class="ai-panel">
      <h3>
        AI Show Notes
        <button v-if="!notes && !activeJob" class="ai-btn ai-btn-primary" @click="startAnalysis" :disabled="loading">
          {{ loading ? 'Iniciando...' : 'Analizar episodio' }}
        </button>
        <button v-if="notes" class="ai-btn" @click="regenNotes">Regenerar notas</button>
      </h3>

      <div v-if="activeJob && ['pending','running'].includes(activeJob.status)" class="ai-status">
        Analizando episodio...
      </div>
      <div v-if="activeJob && activeJob.status === 'error'" class="ai-error">
        Error: {{ activeJob.error_msg }}
      </div>

      <template v-if="notes">
        <div class="ai-summary">{{ notes.summary }}</div>
        <ul class="ai-highlights">
          <li v-for="h in notes.highlights" :key="h">{{ h }}</li>
        </ul>
      </template>

      <template v-if="clips.length">
        <h3 style="margin-top:1rem;">
          Clips sugeridos
          <button class="ai-btn" @click="createAll">Crear todos</button>
          <button class="ai-btn" @click="regenClips">Regenerar</button>
        </h3>
        <div class="ai-clips-grid">
          <div class="ai-clip-card" v-for="clip in clips" :key="clip.start+clip.end">
            <h4>{{ clip.title }}</h4>
            <div class="clip-meta">
              {{ clip.start }} - {{ clip.end }}
              <span class="ai-clip-type">{{ clip.type }}</span>
            </div>
            <div style="font-size:0.75rem;color:var(--text-3,#6c7086);">{{ clip.reason }}</div>
            <div class="ai-clip-actions">
              <button @click="createMoment(clip)" :disabled="clip._created">
                {{ clip._created ? 'Creado' : 'Crear momento' }}
              </button>
            </div>
          </div>
        </div>
      </template>
    </div>
  `,
};

var ProjectView = {
  props: { project: Object, onBack: Function },
  components: { FilesPanel, VideoPlayer, Timeline, ZoomControls, MomentsList, CaptureMomentModal, ClipsPanel, OperationsPanel, SilenceModal, ExportModal, TranscriptEditor, ParticipantsPanel, AiPanel },
  setup(props) {
    const timeline = reactive({ clips: [], moments: [], duration: 0, audioLane: [] });
    const silenceClip = ref(null);
    const showExport = ref(false);
    const showTranscript = ref(false);
    const showParticipants = ref(false);
    const localFiles = ref([]);
    const globalFiles = ref([]);
    const playerState = reactive({
      currentTime: 0,
      duration: 0,
      isPlaying: false,
      volume: 1.0,
    });
    const zoom = reactive({ startSeconds: 0, endSeconds: null });
    const selectedRange = ref(null);  // { start, end } | null — persistent yellow band from drag-select
    const liveSelection = ref(null);  // { start, end } | null — in-flight drag, updates every pointermove

    // Sidebar visibility toggles (persisted). Operations panel auto-shows
    // when a moment is selected; no explicit toggle.
    const showFiles = ref((localStorage.getItem("postpod.showFiles") ?? "1") === "1");
    const showClips = ref((localStorage.getItem("postpod.showClips") ?? "1") === "1");
    watch(showFiles, (v) => localStorage.setItem("postpod.showFiles", v ? "1" : "0"));
    watch(showClips, (v) => localStorage.setItem("postpod.showClips", v ? "1" : "0"));
    const focusMode = computed(() => !showFiles.value && !showClips.value);
    const selectedMomentId = ref(null);
    const capture = reactive({ show: false });
    const videoPlayerRef = ref(null);
    const error = ref("");

    // Derived: timeline clips with cumulative start positions
    const clipsWithStarts = computed(() => withTimelineStarts(timeline.clips));

    const selectedMoment = computed(() =>
      timeline.moments.find(m => m.id === selectedMomentId.value) || null
    );

    // Effects at current time
    const activeEffects = computed(() => {
      const t = playerState.currentTime;
      const out = { filter: null, transform: null, subtitles: [], vertical: null, verticalSplit: null, textOverlays: [] };
      const sortedMoments = [...timeline.moments].sort((a, b) => a.timeline_seconds - b.timeline_seconds);
      for (const m of sortedMoments) {
        for (const op of (m.operations || [])) {
          const p = op.params || {};
          let opEnd;
          if (p.duration_seconds == null) {
            const next = sortedMoments.find(x => x.timeline_seconds > m.timeline_seconds);
            opEnd = next ? next.timeline_seconds : timeline.duration;
          } else {
            opEnd = m.timeline_seconds + p.duration_seconds;
          }
          if (t >= m.timeline_seconds && t < opEnd) {
            if (op.type === "color_effect") {
              const e = p.effect;
              if (e === "grayscale") out.filter = "grayscale(1)";
              else if (e === "sepia") out.filter = "sepia(1)";
              else if (e === "invert") out.filter = "invert(1)";
            } else if (op.type === "zoom_in") {
              const s = p.scale || 1.5;
              const ox = p.origin_x ?? 0.5;
              const oy = p.origin_y ?? 0.5;
              const tx = (0.5 - ox) * 100 / s;
              const ty = (0.5 - oy) * 100 / s;
              out.transform = `scale(${s}) translate(${tx}%, ${ty}%)`;
            } else if (op.type === "zoom_out") {
              out.transform = "scale(1)";
            } else if (op.type === "subtitle") {
              out.subtitles.push({ text: p.text || "", position: p.position || "bottom" });
            } else if (op.type === "to_vertical") {
              out.vertical = { cropX: p.crop_x ?? 0.5 };
            } else if (op.type === "vertical_split") {
              // Live preview of the "two cámaras apiladas" layout. The
              // exporter assumes a side-by-side composite as input; here
              // we don't have one, so we synthesize the stack by picking
              // the active clip on each track at the playhead. cropXs are
              // forwarded so the user sees their face-centering choices.
              const n = Math.max(2, Math.min(4, parseInt(p.n, 10) || 2));
              const cropXs = [];
              for (let i = 0; i < n; i++) {
                const v = (p.crop_xs && p.crop_xs[i] != null) ? Number(p.crop_xs[i]) : 0.5;
                cropXs.push(Math.max(0, Math.min(1, isFinite(v) ? v : 0.5)));
              }
              out.verticalSplit = { n, cropXs };
            } else if (op.type === "text_overlay") {
              out.textOverlays.push({
                text: p.text || "",
                font: p.font || "bangers",
                color: p.color || "#ffde59",
                size_pct: p.size_pct ?? 18,
                x_pct: p.x_pct ?? 0.5,
                y_pct: p.y_pct ?? 0.5,
                rotation_deg: p.rotation_deg ?? 0,
                outline: p.outline !== false,
                shadow: p.shadow !== false,
              });
            }
          }
        }
      }
      return out;
    });

    const usedTracks = computed(() => {
      const set = new Set();
      for (const c of (timeline.clips || [])) set.add(c.track || 1);
      return set;
    });
    const autoMultitrack = computed(() => usedTracks.value.size > 1);

    const verticalSplitSources = computed(() => {
      const eff = activeEffects.value;
      const hasVsplit = eff && eff.verticalSplit;
      const isAuto = autoMultitrack.value && !hasVsplit;
      if (!hasVsplit && !isAuto) return null;
      const n = hasVsplit ? eff.verticalSplit.n : Math.max(...usedTracks.value);
      const cropXs = hasVsplit ? eff.verticalSplit.cropXs : [];
      const t = playerState.currentTime;
      const clips = clipsWithStarts.value || [];
      const out = [];
      for (let track = 1; track <= n; track++) {
        const c = clips.find(cl =>
          (Number(cl.track) || 1) === track &&
          cl.start <= t + 0.001 &&
          cl.end > t - 0.001
        );
        if (!c) { out.push(null); continue; }
        const localT = (c.start_offset || 0) + Math.max(0, t - c.start);
        out.push({
          clipId: c.id,
          url: c.source && c.source.url,
          localTime: localT,
          track,
          cropX: cropXs[track - 1] ?? 0.5,
          volume: c.volume ?? 1.0,
        });
      }
      return out;
    });

    // Flat list of text_overlay sound cues: VideoPlayer plays each when the
    // playhead enters the op's [tl_start, tl_end] window.
    const textOverlaySounds = computed(() => {
      const out = [];
      for (const m of (timeline.moments || [])) {
        for (const op of (m.operations || [])) {
          if (op.type !== "text_overlay") continue;
          const p = op.params || {};
          if (!p.sound_file_id) continue;
          const mf = (localFiles.value || []).find(f => f.id === p.sound_file_id);
          if (!mf) continue;
          const dur = Number(p.duration_seconds) || 0.8;
          out.push({
            id: op.id,
            url: mf.url,
            tl_start: Number(m.timeline_seconds),
            tl_end: Number(m.timeline_seconds) + dur,
            volume: Number(p.sound_volume ?? 1.0),
          });
        }
      }
      return out;
    });

    async function refreshTimeline() {
      error.value = "";
      try {
        const data = await api(`/api/projects/${props.project.slug}/timeline`);
        timeline.clips = data.clips || [];
        timeline.moments = data.moments || [];
        timeline.audioLane = data.audio_lane || [];
        // Duration: max of video-track cumulative durations AND any audio
        // lane clip's end (so music that extends past video is visible).
        const stacked = withTimelineStarts(timeline.clips);
        const videoMax = totalDurationFromClips(stacked);
        const laneMax = timeline.audioLane.reduce((m, c) => Math.max(m, c.tl_end || 0), 0);
        timeline.duration = Math.max(videoMax, laneMax);
        playerState.duration = timeline.duration;
        // Keep zoom consistent
        if (zoom.endSeconds == null || zoom.endSeconds > timeline.duration) {
          zoom.endSeconds = timeline.duration || null;
        }
        // If selected moment no longer exists
        if (selectedMomentId.value && !timeline.moments.find(m => m.id === selectedMomentId.value)) {
          selectedMomentId.value = null;
        }
      } catch (e) { error.value = e.message; }
    }

    async function addClipToTimeline(f) {
      try {
        if (f.file_type === "audio") {
          await api(`/api/projects/${props.project.slug}/audio-lane`, {
            method: "POST",
            body: {
              media_file_id: f.id,
              label: f.original_name,
              tl_start: playerState.currentTime || 0,
              volume: 0.7,
            },
          });
        } else {
          await api(`/api/projects/${props.project.slug}/timeline/clips`, {
            method: "POST",
            body: { media_file_id: f.id, label: f.original_name, track: f._track || 1 },
          });
        }
        await refreshTimeline();
      } catch (e) { error.value = e.message; }
    }

    async function updateLaneClip({ id, fields }) {
      try {
        await api(`/api/projects/${props.project.slug}/audio-lane/${id}`, {
          method: "PUT", body: fields,
        });
        await refreshTimeline();
      } catch (e) { error.value = e.message; }
    }

    const laneEditing = ref(null);  // currently-selected lane clip for edit form
    function onLaneClipClick(lc) {
      laneEditing.value = { ...lc };
      clipEditing.value = null;
      onSeek(lc.tl_start);
    }
    async function saveLaneEdit() {
      if (!laneEditing.value) return;
      const e = laneEditing.value;
      await updateLaneClip({
        id: e.id,
        fields: {
          tl_start: parseFloat(e.tl_start) || 0,
          volume: parseFloat(e.volume) || 0,
          label: e.label || "",
        },
      });
      laneEditing.value = null;
    }

    const clipEditing = ref(null);  // currently-selected video clip for edit form
    function onClipClick(clip) {
      clipEditing.value = { ...clip };
      laneEditing.value = null;
      onSeek(clip.start);
    }
    // Live-preview volume while the slider moves (before saving).
    watch(() => clipEditing.value?.volume, (vol) => {
      if (vol == null || !clipEditing.value) return;
      const c = timeline.clips.find(x => x.id === clipEditing.value.id);
      if (c) c.volume = vol;
    });
    async function saveClipEdit() {
      if (!clipEditing.value) return;
      const e = clipEditing.value;
      try {
        await api(`/api/projects/${props.project.slug}/timeline/clips/${e.id}`, {
          method: "PUT",
          body: {
            label: e.label || "",
            volume: parseFloat(e.volume) || 0,
          },
        });
        await refreshTimeline();
      } catch (err) { error.value = err.message; }
      clipEditing.value = null;
    }

    async function removeLaneClip(id) {
      if (!await podSwal.confirm("¿Quitar este audio de la pista?")) return;
      try {
        await api(`/api/projects/${props.project.slug}/audio-lane/${id}`, { method: "DELETE" });
        await refreshTimeline();
      } catch (e) { error.value = e.message; }
    }

    async function removeClip(clipId) {
      if (!await podSwal.confirm("¿Quitar este clip del timeline?")) return;
      try {
        await api(`/api/projects/${props.project.slug}/timeline/clips/${clipId}`, { method: "DELETE" });
        await refreshTimeline();
      } catch (e) { error.value = e.message; }
    }
    async function reorderClip({ id, position }) {
      try {
        await api(`/api/projects/${props.project.slug}/timeline/clips/${id}`, {
          method: "PUT",
          body: { position },
        });
        await refreshTimeline();
      } catch (e) { error.value = e.message; }
    }
    async function trimClip({ id, start_offset, end_offset }) {
      try {
        await api(`/api/projects/${props.project.slug}/timeline/clips/${id}`, {
          method: "PUT",
          body: { start_offset, end_offset },
        });
        await refreshTimeline();
      } catch (e) { error.value = e.message; }
    }

    async function setClipTrack({ id, track }) {
      try {
        await api(`/api/projects/${props.project.slug}/timeline/clips/${id}`, {
          method: "PUT", body: { track },
        });
        await refreshTimeline();
      } catch (e) { error.value = e.message; }
    }

    function seekToClip(clipId) {
      const c = clipsWithStarts.value.find(x => x.id === clipId);
      if (c) onSeek(c.start);
    }

    function openSilenceModal() { silenceClip.value = true; }
    async function onSilenceApplied() {
      await refreshTimeline();
    }

    async function createMoment(payload) {
      payload = payload || {};
      try {
        const m = await api(`/api/projects/${props.project.slug}/moments`, {
          method: "POST",
          body: {
            type: payload.type || "relative",
            timeline_seconds: playerState.currentTime,
            label: payload.label || "",
          },
        });
        capture.show = false;
        await refreshTimeline();
        // Auto-select so the user can immediately edit the label / add ops.
        if (m && m.id) selectedMomentId.value = m.id;
      } catch (e) { error.value = e.message; }
    }

    async function updateMomentType({ id, type }) {
      try {
        await api(`/api/projects/${props.project.slug}/moments/${id}`, {
          method: "PUT", body: { type },
        });
        await refreshTimeline();
      } catch (e) { error.value = e.message; }
    }

    async function addJumpToNext(m) {
      const sorted = [...timeline.moments].sort((a, b) => a.timeline_seconds - b.timeline_seconds);
      const idx = sorted.findIndex(x => x.id === m.id);
      const next = sorted[idx + 1];
      if (!next) { podSwal.toast("No hay momento posterior para saltar."); return; }
      try {
        await api(`/api/projects/${props.project.slug}/moments/${m.id}/operations`, {
          method: "POST",
          body: { type: "jump_to_moment", params: { target_moment_id: next.id } },
        });
        await refreshTimeline();
      } catch (e) { error.value = e.message; }
    }

    async function setTrackAtMoment({ m, track }) {
      try {
        await api(`/api/projects/${props.project.slug}/moments/${m.id}/operations`, {
          method: "POST",
          body: { type: "switch_track", params: { track } },
        });
        await refreshTimeline();
      } catch (e) { error.value = e.message; }
    }
    async function toggleTrackAtMoment(m) {
      try {
        await api(`/api/projects/${props.project.slug}/moments/${m.id}/operations`, {
          method: "POST",
          body: { type: "switch_track", params: { toggle: true } },
        });
        await refreshTimeline();
      } catch (e) { error.value = e.message; }
    }

    async function updateMomentLabel({ id, label }) {
      try {
        await api(`/api/projects/${props.project.slug}/moments/${id}`, {
          method: "PUT",
          body: { label },
        });
        const m = timeline.moments.find(x => x.id === id);
        if (m) m.label = label;
      } catch (e) { error.value = e.message; }
    }

    // Used by OperationsPanel for inline numeric edits (start, end, label).
    // patch is a {field: value} dict — sent as-is to PUT /moments/<id>.
    async function patchMoment({ id, patch }) {
      try {
        const updated = await api(`/api/projects/${props.project.slug}/moments/${id}`, {
          method: "PUT", body: patch,
        });
        const m = timeline.moments.find(x => x.id === id);
        if (m) {
          if (updated.timeline_seconds != null) m.timeline_seconds = updated.timeline_seconds;
          if ("duration_seconds" in updated) m.duration_seconds = updated.duration_seconds;
          if (updated.label != null) m.label = updated.label;
        }
      } catch (e) { error.value = e.message; }
    }

    async function removeMoment(id) {
      if (!await podSwal.confirm("¿Eliminar momento?")) return;
      try {
        await api(`/api/projects/${props.project.slug}/moments/${id}`, { method: "DELETE" });
        if (selectedMomentId.value === id) selectedMomentId.value = null;
        await refreshTimeline();
      } catch (e) { error.value = e.message; }
    }

    async function _resolveGlobalSound(params) {
      if (!params || !params._sound_global) {
        if (params) { delete params._sound_selector; delete params._sound_global; }
        return params;
      }
      try {
        const imported = await api(`/api/projects/${props.project.slug}/files/import-global`, {
          method: "POST",
          body: { filename: params._sound_global, file_type: "audio" },
        });
        params.sound_file_id = imported.id;
        // Keep local file list in sync so textOverlaySounds can find the URL
        // for preview playback right away (no full reload needed).
        if (!localFiles.value.some(f => f.id === imported.id)) {
          localFiles.value = [...localFiles.value, imported];
        }
      } catch (e) {
        error.value = "No se pudo importar el sonido global: " + e.message;
      }
      delete params._sound_global;
      delete params._sound_selector;
      return params;
    }

    async function addOperation(op) {
      if (!selectedMoment.value) return;
      try {
        const params = await _resolveGlobalSound({ ...(op.params || {}) });
        const r = await api(`/api/projects/${props.project.slug}/moments/${selectedMoment.value.id}/operations`, {
          method: "POST",
          body: { type: op.type, params },
        });
        await refreshTimeline();
        if (r && r.silence_result) {
          const s = r.silence_result;
          if (s.silences_detected === 0) {
            podSwal.info("No se detectaron silencios en ese rango.");
          } else {
            podSwal.success(
              `${s.silences_detected} silencio(s) detectado(s) · ` +
              `${s.removed_seconds}s eliminados · ` +
              `${s.splits} segmento(s) generado(s)` +
              (s.skipped_no_audio ? ` · ${s.skipped_no_audio} clip(s) sin audio saltados` : ""),
              "Silencios removidos"
            );
          }
        }
      } catch (e) { error.value = e.message; podSwal.error(e.message); }
    }

    async function removeOperation(opId) {
      try {
        await api(`/api/projects/${props.project.slug}/operations/${opId}`, { method: "DELETE" });
        await refreshTimeline();
      } catch (e) { error.value = e.message; }
    }

    async function updateOperation({ id, type, params }) {
      try {
        const resolved = await _resolveGlobalSound({ ...(params || {}) });
        await api(`/api/projects/${props.project.slug}/operations/${id}`, {
          method: "PUT", body: { params: resolved },
        });
        await refreshTimeline();
      } catch (e) { error.value = e.message; }
    }

    const editingOverlay = ref(null);
    function setEditingOverlay(p) { editingOverlay.value = p; }

    // ---- Captions display in preview ----
    const captionsEnabled = ref(localStorage.getItem("postpod.captionsEnabled") === "1");
    const captionsLanguage = ref(localStorage.getItem("postpod.captionsLanguage") || "");
    const captionsByMedia = reactive({});  // mediaId -> { lang -> { segments, languages: [] } }
    watch(captionsEnabled, (v) => {
      localStorage.setItem("postpod.captionsEnabled", v ? "1" : "0");
      if (v) ensureCaptionsForActiveClip();
    });
    watch(captionsLanguage, (v) => {
      if (v) localStorage.setItem("postpod.captionsLanguage", v);
    });

    function _parseSrt(text) {
      // Minimal SRT parser → [{start, end, text}] in seconds.
      const out = [];
      const blocks = text.split(/\r?\n\r?\n/);
      for (const block of blocks) {
        const lines = block.split(/\r?\n/).filter(Boolean);
        if (lines.length < 2) continue;
        // First line may be a numeric index
        const tlLineIdx = /-->/.test(lines[0]) ? 0 : 1;
        const tl = lines[tlLineIdx];
        const m = tl.match(/(\d{2}):(\d{2}):(\d{2})[,.](\d{3})\s*-->\s*(\d{2}):(\d{2}):(\d{2})[,.](\d{3})/);
        if (!m) continue;
        const s = (+m[1])*3600 + (+m[2])*60 + (+m[3]) + (+m[4])/1000;
        const e = (+m[5])*3600 + (+m[6])*60 + (+m[7]) + (+m[8])/1000;
        const txt = lines.slice(tlLineIdx + 1).join("\n").trim();
        if (txt) out.push({ start: s, end: e, text: txt });
      }
      return out;
    }

    async function ensureCaptionsForActiveClip() {
      if (!captionsEnabled.value) return;
      const clip = clipsWithStarts.value.find(c =>
        playerState.currentTime >= c.start - 0.01 &&
        playerState.currentTime <  c.end   + 0.01);
      if (!clip || !clip.source) return;
      const mid = clip.source.id;
      if (captionsByMedia[mid] && captionsByMedia[mid][captionsLanguage.value]) return;
      try {
        const data = await api(`/api/projects/${props.project.slug}/files/${mid}/captions`);
        const langs = (data.captions || []).map(c => c.language);
        if (!captionsByMedia[mid]) captionsByMedia[mid] = { _languages: langs };
        else captionsByMedia[mid]._languages = langs;
        if (!captionsLanguage.value && langs.length) {
          captionsLanguage.value = langs.find(l => l !== "auto") || langs[0];
        }
        const wantLang = captionsLanguage.value;
        const found = (data.captions || []).find(c => c.language === wantLang);
        if (found) {
          const r = await fetch(found.url, { credentials: "same-origin" });
          if (r.ok) {
            const text = await r.text();
            captionsByMedia[mid][wantLang] = _parseSrt(text);
          }
        }
      } catch (_) {}
    }

    // Live caption text for the current playhead position.
    const liveCaption = computed(() => {
      if (!captionsEnabled.value) return null;
      const clip = clipsWithStarts.value.find(c =>
        playerState.currentTime >= c.start - 0.01 &&
        playerState.currentTime <  c.end   + 0.01);
      if (!clip || !clip.source) return null;
      const track = captionsByMedia[clip.source.id];
      if (!track) return null;
      const segs = track[captionsLanguage.value];
      if (!segs) return null;
      const localT = (clip.start_offset || 0) + (playerState.currentTime - clip.start);
      const seg = segs.find(s => s.start <= localT && localT < s.end);
      return seg ? seg.text : null;
    });

    // Refresh caption track when clip changes (lazy fetch on demand).
    watch(() => playerState.currentTime, () => {
      if (captionsEnabled.value) ensureCaptionsForActiveClip();
    });
    function onCaptionsChanged() {
      // Drop cache so next play re-fetches the (possibly new) SRT.
      for (const k of Object.keys(captionsByMedia)) delete captionsByMedia[k];
      if (captionsEnabled.value) ensureCaptionsForActiveClip();
    }

    function onSeek(t) {
      videoPlayerRef.value?.seek(t);
      // Click outside the selected range clears it; click inside preserves it.
      const r = selectedRange.value;
      if (r && (t < r.start - 0.01 || t > r.end + 0.01)) {
        selectedRange.value = null;
      }
    }

    function previewMoment(m) {
      const lead = 0.4;
      const start = Math.max(0, m.timeline_seconds - lead);
      videoPlayerRef.value?.seek(start, true);
    }

    function exportMoment(m) {
      const total = playerState.duration || 0;
      const start = m.timeline_seconds || 0;
      let end;
      if (m.duration_seconds && m.duration_seconds > 0) {
        end = start + m.duration_seconds;
      } else {
        const sortedMs = [...timeline.moments].sort((a, b) => a.timeline_seconds - b.timeline_seconds);
        const next = sortedMs.find(x => x.timeline_seconds > start + 0.01);
        end = next ? next.timeline_seconds : total;
      }
      end = Math.min(end, total);
      if (end <= start + 0.01) return;
      selectedRange.value = { start, end };
      showExport.value = true;
    }
    function onZoomTo({ start, end }) {
      const total = playerState.duration || 0;
      if (total <= 0) return;
      const a = Math.max(0, Math.min(start, end));
      const b = Math.max(0, Math.max(start, end));
      if (b - a < 0.05) return;
      // Drag-select always persists as a yellow range selection. Zoom is a
      // separate, explicit action (button or "Z" shortcut).
      selectedRange.value = { start: a, end: Math.min(total, b) };
      videoPlayerRef.value?.seek(a, false);
    }

    function applyRangeAsZoom() {
      const r = selectedRange.value;
      if (!r || r.end <= r.start + 0.01) return;
      zoom.startSeconds = Math.max(0, r.start);
      zoom.endSeconds = Math.min(playerState.duration || r.end, r.end);
      selectedRange.value = null;
    }

    // Range-loop preview. While `rangeLoopActive` is on, the player loops
    // between selectedRange.start and selectedRange.end so you can audition
    // the clip with all live effects (color, zoom, text overlays — those
    // already follow `playerState.currentTime` via `activeEffects`) before
    // committing to an export. Cuts/transcript_cuts are NOT skipped during
    // preview — they're a render-time concern.
    const rangeLoopActive = ref(false);
    function playRange() {
      const r = selectedRange.value;
      if (!r || r.end <= r.start + 0.05) return;
      rangeLoopActive.value = true;
      videoPlayerRef.value?.seek(r.start, true);
    }
    function stopRangeLoop() {
      rangeLoopActive.value = false;
    }
    // Watch for the loop boundary. Triggers on every playerState.currentTime
    // tick (which fires on the video element's `timeupdate`) — cheap.
    watch(() => playerState.currentTime, (t) => {
      if (!rangeLoopActive.value) return;
      const r = selectedRange.value;
      if (!r) { rangeLoopActive.value = false; return; }
      // If the user seeked manually outside the loop window, give up.
      if (t < r.start - 0.5) { rangeLoopActive.value = false; return; }
      // Loop back when we cross the end.
      if (t >= r.end - 0.02) {
        videoPlayerRef.value?.seek(r.start, true);
      }
    });
    // If the selection is cleared (Esc, click outside, etc.), kill the loop.
    watch(selectedRange, (v) => { if (!v) rangeLoopActive.value = false; });
    function onUpdateZoom({ start, end }) {
      zoom.startSeconds = start;
      zoom.endSeconds = end;
    }

    function onFilesRefresh(payload) {
      if (payload?.local) localFiles.value = payload.local;
      if (payload?.global) globalFiles.value = payload.global;
      if (payload?.fileDeleted !== undefined) {
        // A file was deleted or made global — cascade may have removed clips
        refreshTimeline();
      }
    }

    function onKey(ev) {
      const tgt = ev.target;
      const isTyping = tgt && (tgt.tagName === "INPUT" || tgt.tagName === "TEXTAREA" || tgt.isContentEditable);
      if (isTyping) return;
      if (timeline.clips.length === 0) return;

      if (ev.code === "Space") { ev.preventDefault(); videoPlayerRef.value?.togglePlay(); }
      else if (ev.key === "m" || ev.key === "M") { ev.preventDefault(); createMoment({}); }
      else if (ev.key === "+" || ev.key === "=") { ev.preventDefault(); zoomByShortcut(0.9); }
      else if (ev.key === "-" || ev.key === "_") { ev.preventDefault(); zoomByShortcut(1.111); }
      else if (ev.key === "ArrowLeft") { ev.preventDefault(); onSeek(Math.max(0, playerState.currentTime - (ev.shiftKey ? 1/30 : 5))); }
      else if (ev.key === "ArrowRight") { ev.preventDefault(); onSeek(Math.min(playerState.duration, playerState.currentTime + (ev.shiftKey ? 1/30 : 5))); }
      else if (ev.key === "Escape") { if (selectedRange.value) { ev.preventDefault(); selectedRange.value = null; } }
      else if (ev.key === "z" || ev.key === "Z") { if (selectedRange.value) { ev.preventDefault(); applyRangeAsZoom(); } }
    }
    function zoomByShortcut(factor) {
      const total = playerState.duration || 0;
      if (total <= 0) return;
      const curStart = zoom.startSeconds || 0;
      const curEnd = zoom.endSeconds ?? total;
      const curDur = curEnd - curStart;
      const newDur = Math.min(total, Math.max(0.5, curDur * factor));
      const center = Math.max(curStart, Math.min(curEnd, playerState.currentTime));
      let start = center - (center - curStart) * (newDur / curDur);
      let end = start + newDur;
      if (end > total) { end = total; start = Math.max(0, end - newDur); }
      if (start < 0) { start = 0; end = Math.min(total, newDur); }
      zoom.startSeconds = start;
      zoom.endSeconds = end;
    }

    async function loadAllFiles() {
      try {
        const [local, glob] = await Promise.all([
          api(`/api/projects/${props.project.slug}/files`),
          api(`/api/global/files`),
        ]);
        localFiles.value = local;
        globalFiles.value = glob;
      } catch (_) { /* silent */ }
    }

    const prodpodPrompt = ref(null);

    async function checkMultiTrack(force) {
      try {
        const data = await api(`/api/projects/${props.project.slug}/timeline/prodpod-tracks`);
        if (data.individual.length < 2) {
          if (force) podSwal.toast("Se necesitan al menos 2 archivos de video para organizar pistas.");
          return;
        }
        if (force || data.timeline_empty) {
          prodpodPrompt.value = data;
        }
      } catch (_) {}
    }

    async function placeProdpod(mode) {
      if (mode === "composite" && !prodpodPrompt.value?.composite) {
        try {
          const r = await api(`/api/projects/${props.project.slug}/timeline/rebuild-composite`, { method: "POST" });
          if (r.ok) await checkMultiTrack();
          else { error.value = r.error || "No se pudo regenerar el composite"; return; }
        } catch (e) { error.value = e.message; return; }
      }
      try {
        await api(`/api/projects/${props.project.slug}/timeline/place-prodpod`, {
          method: "POST", body: { mode },
        });
        await refreshTimeline();
        await loadAllFiles();
      } catch (e) { error.value = e.message; }
      prodpodPrompt.value = null;
    }

    onMounted(() => {
      refreshTimeline();
      loadAllFiles();
      checkMultiTrack();
      window.addEventListener("keydown", onKey);
    });
    onBeforeUnmount(() => window.removeEventListener("keydown", onKey));

    return {
      timeline, localFiles, playerState, zoom, selectedMomentId, selectedMoment,
      capture, clipsWithStarts, activeEffects, videoPlayerRef, error,
      refreshTimeline, addClipToTimeline, removeClip, reorderClip, trimClip, seekToClip,
      createMoment, updateMomentLabel, updateMomentType, removeMoment, patchMoment,
      addJumpToNext, setTrackAtMoment, toggleTrackAtMoment, applyRangeAsZoom,
      rangeLoopActive, playRange, stopRangeLoop,
      setClipTrack, updateLaneClip, removeLaneClip,
      laneEditing, onLaneClipClick, saveLaneEdit,
      clipEditing, onClipClick, saveClipEdit,
      updateOperation, editingOverlay, setEditingOverlay, globalFiles,
      captionsEnabled, captionsLanguage, liveCaption, onCaptionsChanged,
      captionsByMedia,
      addOperation, removeOperation,
      onSeek, onZoomTo, onUpdateZoom, onFilesRefresh, previewMoment, exportMoment,
      showFiles, showClips, focusMode, selectedRange,
      silenceClip, openSilenceModal, onSilenceApplied,
      showExport, showParticipants,
      showTranscript,
      formatShort,
      prodpodPrompt, placeProdpod, checkMultiTrack,
      verticalSplitSources, autoMultitrack, textOverlaySounds, liveSelection,
    };
  },
  template: `
    <div class="editor-wide"
         :class="{
           'no-left':   !showFiles && !focusMode,
           'no-right':  !showClips && !selectedMoment && !showParticipants,
           'focus-mode': focusMode,
           'has-ops':    focusMode && selectedMoment != null
         }">
      <FilesPanel
        v-if="showFiles"
        :project="project"
        @add-to-timeline="addClipToTimeline"
        @refresh="onFilesRefresh"
        @captions-changed="onCaptionsChanged"
      />
      <aside v-else-if="focusMode" class="moments-sidebar">
        <MomentsList
          :moments="timeline.moments"
          :selected-moment-id="selectedMomentId"
          @goto="onSeek"
          @preview="previewMoment"
          @remove="removeMoment"
          @update-label="updateMomentLabel"
          @update-type="updateMomentType"
          @update-time="patchMoment"
          @jump-next="addJumpToNext"
          @set-track="setTrackAtMoment"
          @toggle-track="toggleTrackAtMoment"
          @select="(id) => selectedMomentId = id"
          @export-moment="exportMoment"
        />
      </aside>

      <div class="main">
        <div v-if="error" class="error" style="margin: 8px 22px 0;">{{ error }}</div>

        <VideoPlayer
          ref="videoPlayerRef"
          :clips="clipsWithStarts"
          :player-state="playerState"
          :zoom="zoom"
          :effects="activeEffects"
          :moments="timeline.moments"
          :selected-range="selectedRange"
          :live-selection="liveSelection"
          :vertical-split-sources="verticalSplitSources"
          :multitrack-preview="autoMultitrack"
          :audio-lane="timeline.audioLane"
          :text-overlay-sounds="textOverlaySounds"
          :editing-overlay="editingOverlay"
          :live-caption="liveCaption"
          :captions-enabled="captionsEnabled"
          @toggle-captions="captionsEnabled = !captionsEnabled"
        />

        <div class="timeline-section">
          <div class="timeline-head">
            <span class="label">Timeline</span>
            <span class="zoom-info">zoom: <b>{{ formatShort(zoom.startSeconds) }} → {{ formatShort(zoom.endSeconds ?? playerState.duration) }}</b></span>
            <div class="spacer"></div>
            <div class="panel-toggles" title="Mostrar/ocultar paneles laterales">
              <button :class="{on: showFiles}" @click="showFiles = !showFiles" title="Files">📁</button>
              <button :class="{on: showClips}" @click="showClips = !showClips" title="Clips">📋</button>
            </div>
            <ZoomControls :zoom="zoom" :player-state="playerState" @update-zoom="onUpdateZoom" />
            <button class="primary" :disabled="timeline.clips.length === 0" @click="createMoment({})" style="margin-left:8px;">
              ◉ Capturar momento <span class="kbd" style="margin-left:6px;">M</span>
            </button>
            <button v-if="selectedRange && !rangeLoopActive" :disabled="timeline.clips.length === 0" @click="playRange"
                    class="ghost" style="margin-left:8px;" title="Reproducir el rango seleccionado en loop">
              ▶ Reproducir rango
            </button>
            <button v-if="selectedRange && rangeLoopActive" :disabled="timeline.clips.length === 0" @click="stopRangeLoop"
                    class="ghost" style="margin-left:8px; background: var(--signal-soft, rgba(244,199,112,0.18)); border-color: var(--signal, #f4c770); color: var(--signal, #f4c770);"
                    title="Detener loop">
              ⏹ Stop loop
            </button>
            <button v-if="selectedRange" :disabled="timeline.clips.length === 0" @click="applyRangeAsZoom"
                    class="ghost" style="margin-left:8px;" title="Zoom al rango seleccionado (Z)">
              🔍 Zoom selección <span class="kbd" style="margin-left:6px;">Z</span>
            </button>
            <button :disabled="timeline.clips.length === 0" @click="showTranscript = true" class="ghost" style="margin-left:8px;" title="Editar por transcripción">
              ✍ Transcript
            </button>
            <button :disabled="timeline.clips.length === 0" @click="openSilenceModal" class="ghost" style="margin-left:8px;" title="Detectar y eliminar silencios del proyecto">
              🔇 Silencios
            </button>
            <button @click="showParticipants = !showParticipants" :class="{on: showParticipants}" class="ghost" style="margin-left:8px;" title="Participantes y banners">
              👤 Participantes
            </button>
            <button :disabled="timeline.clips.length === 0" @click="showExport = true" style="margin-left:8px;">
              ⇪ Exportar
            </button>
            <a :href="'/api/projects/' + slug + '/export-bundle'" class="ghost" style="margin-left:8px; text-decoration:none; display:inline-flex; align-items:center; padding:4px 10px; font-size:12px;" title="Descargar proyecto como .zip">
              📦 Proyecto
            </a>
            <button @click="checkMultiTrack(true)" class="ghost" style="margin-left:8px;"
                    title="Colocar cada archivo de video en su propia pista">
              ⊞ Pistas
            </button>
          </div>

          <Timeline
            :clips="clipsWithStarts"
            :player-state="playerState"
            :zoom="zoom"
            :moments="timeline.moments"
            :selected-moment-id="selectedMomentId"
            :selected-range="selectedRange"
            :audio-lane="timeline.audioLane"
            @seek="onSeek"
            @zoom-to="onZoomTo"
            @live-select="(r) => liveSelection = r"
            @select-moment="(id) => selectedMomentId = id"
            @lane-click="onLaneClipClick"
            @lane-remove="(lc) => removeLaneClip(lc.id)"
            @clip-click="onClipClick"
          />
        </div>

        <div v-if="clipEditing" class="lane-editor">
          <div class="eyebrow">
            Video · T{{ clipEditing.track || 1 }} · {{ clipEditing.label || (clipEditing.source && clipEditing.source.original_name) }}
          </div>
          <div class="row" style="gap: 10px; align-items: center; flex-wrap: wrap; margin-top: 6px;">
            <label style="margin: 0;">Volumen
              <input type="range" min="0" max="2" step="0.05" v-model.number="clipEditing.volume" style="width: 160px;">
              <span class="mono tiny">{{ (clipEditing.volume ?? 1).toFixed(2) }}</span>
            </label>
            <label style="margin: 0; flex: 1; min-width: 200px;">Label
              <input type="text" v-model="clipEditing.label" style="width: 100%;">
            </label>
            <button class="primary" @click="saveClipEdit">Guardar</button>
            <button class="ghost" @click="clipEditing = null">Cancelar</button>
          </div>
        </div>

        <div v-if="laneEditing" class="lane-editor">
          <div class="eyebrow">Audio · {{ laneEditing.label || (laneEditing.source && laneEditing.source.original_name) }}</div>
          <div class="row" style="gap: 10px; align-items: center; flex-wrap: wrap; margin-top: 6px;">
            <label style="margin: 0;">Start (s)
              <input type="number" step="0.1" min="0" v-model.number="laneEditing.tl_start" style="width: 90px;">
            </label>
            <label style="margin: 0;">Volume
              <input type="range" min="0" max="2" step="0.05" v-model.number="laneEditing.volume" style="width: 140px;">
              <span class="mono tiny">{{ (laneEditing.volume || 0).toFixed(2) }}</span>
            </label>
            <label style="margin: 0; flex: 1; min-width: 200px;">Label
              <input type="text" v-model="laneEditing.label" style="width: 100%;">
            </label>
            <button class="primary" @click="saveLaneEdit">Guardar</button>
            <button class="ghost" @click="laneEditing = null">Cancelar</button>
            <button class="danger" @click="removeLaneClip(laneEditing.id); laneEditing = null;">✕ Eliminar</button>
          </div>
        </div>

        <MomentsList
          v-if="!focusMode"
          :moments="timeline.moments"
          :selected-moment-id="selectedMomentId"
          @goto="onSeek"
          @preview="previewMoment"
          @remove="removeMoment"
          @update-label="updateMomentLabel"
          @update-type="updateMomentType"
          @update-time="patchMoment"
          @jump-next="addJumpToNext"
          @set-track="setTrackAtMoment"
          @toggle-track="toggleTrackAtMoment"
          @select="(id) => selectedMomentId = id"
          @export-moment="exportMoment"
        />

        <CaptureMomentModal
          :show="capture.show"
          :current-time="playerState.currentTime"
          @capture="createMoment"
          @cancel="capture.show = false"
        />
      </div>

      <aside v-if="showClips || selectedMoment || showParticipants" class="right-col">
        <ClipsPanel
          v-if="showClips"
          :clips="clipsWithStarts"
          :total-duration="timeline.duration"
          @reorder="reorderClip"
          @remove="removeClip"
          @trim="trimClip"
          @seek-to="seekToClip"
          @set-track="setClipTrack"
          @remove-silences="openSilenceModal"
        />
        <SilenceModal
          v-if="silenceClip"
          :slug="project.slug"
          @close="silenceClip = null"
          @applied="onSilenceApplied"
          @seek="onSeek"
        />
        <OperationsPanel
          v-if="selectedMoment"
          :moment="selectedMoment"
          :clips="clipsWithStarts"
          :local-files="localFiles"
          :global-files="globalFiles"
          :moments="timeline.moments"
          @add="addOperation"
          @update="updateOperation"
          @remove="removeOperation"
          @editing-overlay="setEditingOverlay"
          @update-moment="patchMoment"
        />
        <ParticipantsPanel
          v-if="showParticipants"
          :slug="project.slug"
          @close="showParticipants = false"
        />
      </aside>

      <ExportModal v-if="showExport" :slug="project.slug" :selected-range="selectedRange" :has-multitrack="autoMultitrack" @close="showExport = false" />
      <TranscriptEditor :show="showTranscript" :slug="project.slug"
                        @close="showTranscript = false"
                        @seek="onSeek"
                        @cuts-changed="() => {}" />

      <AiPanel :slug="project.slug" :moments="timeline.moments" @moment-created="loadTimeline" />

      <div v-if="prodpodPrompt" class="modal-backdrop" @click.self="prodpodPrompt = null">
        <div class="modal" style="width: 460px;">
          <div class="eyebrow">ORGANIZAR PISTAS</div>
          <h3 style="margin: 4px 0 12px;">¿Cómo quieres armar la timeline?</h3>
          <p class="muted" style="margin-bottom: 14px; font-size: 12px;">
            Tienes {{ prodpodPrompt.individual.length }} archivo(s) de video disponible(s)
            <span v-if="prodpodPrompt.composite">y un video compuesto lado a lado</span>.
            <br><strong>Esto reemplaza todos los clips actuales del timeline.</strong>
          </p>
          <div style="display: flex; flex-direction: column; gap: 10px;">
            <button v-if="prodpodPrompt.individual.length" class="primary" style="padding: 12px;"
                    @click="placeProdpod('individual')">
              Pistas separadas — cada archivo en su propio track ({{ prodpodPrompt.individual.length }} tracks simultáneos)
            </button>
            <button v-if="prodpodPrompt.individual.length >= 2" class="primary" style="padding: 12px; background: var(--signal-cyan);"
                    @click="placeProdpod('composite')">
              Video compuesto — todos lado a lado en un solo track
              <span v-if="!prodpodPrompt.composite" style="display:block; font-size:10px; opacity:0.8; margin-top:2px;">(se generará automáticamente)</span>
            </button>
            <button class="ghost" style="padding: 10px;" @click="prodpodPrompt = null">
              Cancelar
            </button>
          </div>
        </div>
      </div>
    </div>
  `,
};

/* ==========================================================================
   Root app
   ========================================================================== */

var App = {
  components: { LoginView, ProjectListView, ProjectView },
  setup() {
    const state = reactive({ username: null, currentProject: null, loading: true });
    const isPlaying = ref(false);
    const siblingApps = ref(null);
    const thepodUrl = ref("");

    async function checkAuth() {
      state.loading = true;
      try { const d = await api("/api/auth/me"); state.username = d.username; }
      catch (_) { state.username = null; }
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
      state.currentProject = null;
    }
    function onLoggedIn(u) { state.username = u; }
    function onOpen(p) { state.currentProject = p; }
    function onBack() { state.currentProject = null; }

    function syncTally() {
      const v = document.querySelector(".video-frame video");
      isPlaying.value = !!(v && !v.paused && !v.ended);
    }
    onMounted(() => { checkAuth(); loadApps(); setInterval(syncTally, 250); });

    return { state, isPlaying, siblingApps, thepodUrl, onLoggedIn, onOpen, onBack, logout };
  },
  template: `
    <template v-if="state.loading">
      <div class="login-wrapper"><div class="muted">Cargando estudio…</div></div>
    </template>
    <template v-else-if="!state.username">
      <LoginView :on-logged-in="onLoggedIn" />
    </template>
    <template v-else>
      <header class="app-header">
        <div class="brand">
          <a :href="thepodUrl || '#'" class="mark" title="Ir a thePod">post<em>Pod</em></a>
          <span class="tag">studio · v0.3</span>
        </div>
        <div class="sibling-apps" v-if="siblingApps">
          <a v-for="a in siblingApps" :key="a.key" :href="a.url" class="sibling-link" :title="'Ir a ' + a.name">
            <span class="ico">{{ a.icon }}</span>
            <span>{{ a.name }}</span>
          </a>
        </div>
        <div class="tally-light" :class="{on: isPlaying}">
          <span class="dot"></span>
          <span>{{ isPlaying ? 'ON AIR' : 'IDLE' }}</span>
        </div>
        <div class="spacer"></div>
        <div v-if="state.currentProject" class="row">
          <button class="ghost" @click="onBack">← Proyectos</button>
        </div>
        <div class="user-chip">
          <span class="tiny">OP</span>
          <span class="name">{{ state.username }}</span>
          <button class="ghost" @click="logout">Salir</button>
        </div>
      </header>
      <ProjectView v-if="state.currentProject" :project="state.currentProject" :on-back="onBack" />
      <ProjectListView v-else :on-open="onOpen" />
    </template>
  `,
};

createApp(App).mount("#app");
