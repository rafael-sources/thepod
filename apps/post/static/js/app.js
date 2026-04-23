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

/* Compute cumulative timeline starts for a list of clip objects. Tracks 1
   and 2 each stack independently starting from t=0 (multi-cam model). Each
   returned clip gets {...clip, track, start, end}. */
function withTimelineStarts(clips) {
  const cursor = { 1: 0, 2: 0 };
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
    if (p.toggle) active = active === 1 ? 2 : 1;
    else if (p.track === 1 || p.track === 2) active = p.track;
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
  return onTrack(active) || onTrack(active === 1 ? 2 : 1) || clips[clips.length - 1];
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
      if (!confirm(`¿Eliminar proyecto "${p.name}"?\nSe borrarán TODOS los archivos del proyecto.`)) return;
      try { await api(`/api/projects/${p.slug}`, { method: "DELETE" }); await load(); }
      catch (e) { error.value = e.message; }
    }

    function fmtDate(s) {
      if (!s) return "";
      try {
        return new Date(s).toLocaleString("es-AR", { day: "2-digit", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit" });
      } catch (_) { return s; }
    }

    onMounted(load);
    return { projects, loading, error, showCreate, newName, creating, create, remove, fmtDate };
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
    audioLane: Array,       // parallel audio lane clips for preview playback
    editingOverlay: Object, // shared ref with OpForm for WYSIWYG text_overlay editing
  },
  setup(props) {
    const videoEl = ref(null);
    const rangeMode = ref("free");
    const currentClipId = ref(null);
    const lastTimelineT = ref(0);
    let jumpCooldownUntil = 0;  // epoch ms, suppresses double-jumps after a jump

    const activeClip = computed(() => clipAtTime(props.clips, props.playerState.currentTime, props.moments));

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
      v.muted = false;
      const clipVol = activeClip.value?.volume ?? 1.0;
      const globalVol = props.playerState?.volume ?? 1.0;
      const target = Math.max(0, Math.min(1, clipVol * globalVol));
      if (Math.abs(v.volume - target) > 0.001) v.volume = target;
    }

    // When active clip changes or its volume is edited, re-apply volume.
    watch(() => [activeClip.value?.volume, props.playerState.volume, activeClip.value?.id], () => {
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
    onBeforeUnmount(() => {
      for (const [, el] of laneAudioEls) { try { el.pause(); el.src = ""; } catch (_) {} }
      laneAudioEls.clear();
    });

    function onPlay() { props.playerState.isPlaying = true; _syncLaneAudio(); }
    function onPause() { props.playerState.isPlaying = false; _syncLaneAudio(); }
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
    const isVertical = computed(() => !!props.effects?.vertical);

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

    return {
      videoEl, rangeMode, canSlowPlay, seek, togglePlay, playVisibleRange, playSlow10s,
      onTimeUpdate, onPlay, onPause, onVolumeChange,
      tc, tcTotal, activeClip, frameStyle, isVertical, verticalStyle,
      textOverlayFontFamily, textOverlayShadow, onEditOverlayPointerDown,
    };
  },
  template: `
    <div class="video-stage">
      <div class="video-frame" :class="{ 'vertical-preview': isVertical }">
        <div class="video-inner" :style="frameStyle">
          <video
            v-show="activeClip"
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

        <div class="time-readout">
          <span>{{ tc.hh }}</span><span class="sep">:</span><span>{{ tc.mm }}</span><span class="sep">:</span><span>{{ tc.ss }}</span><span class="ms">.{{ tc.cs }}</span>
          <span class="total">/ {{ tcTotal.hh }}:{{ tcTotal.mm }}:{{ tcTotal.ss }}</span>
        </div>

        <div class="spacer"></div>

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
  emits: ["seek", "zoom-to", "select-moment", "lane-click", "lane-remove", "clip-click"],
  setup(props, { emit }) {
    const root = ref(null);
    const selecting = ref(false);
    const selectStartPx = ref(0);
    const selectCurPx = ref(0);
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
    function onPointerMove(ev) {
      if (!selecting.value || !root.value) return;
      const rect = root.value.getBoundingClientRect();
      selectCurPx.value = Math.max(0, Math.min(rect.width, ev.clientX - rect.left));
    }
    function onPointerUp(ev) {
      if (!selecting.value) return;
      selecting.value = false;
      window.removeEventListener("pointermove", onPointerMove);
      window.removeEventListener("pointerup", onPointerUp);
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

    return {
      root, cursorPct, selectRect, persistedRangeStyle, ticks, clipStyle, laneClipStyle, secToPct, onPointerDown,
      visibleStart, visibleEnd, formatShort, momentLinks,
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
      <div class="tl-clips">
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
        <div v-if="playerState.duration > 0" class="tl-cursor" :style="{left: cursorPct + '%'}"></div>
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
          "jump-next", "set-track", "toggle-track"],
  setup(props, { emit }) {
    const sorted = computed(() => [...props.moments].sort((a, b) => a.timeline_seconds - b.timeline_seconds));

    function toggleType(m) {
      const next = m.type === "relative" ? "absolute" : "relative";
      emit("update-type", { id: m.id, type: next });
    }

    function hasJumpOp(m) {
      return (m.operations || []).some(o => o.type === "jump_to_moment");
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

    return { sorted, formatTimecode, beginEdit, endEdit, onKey, toggleType, hasJumpOp };
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
              <button class="icon danger" @click="$emit('remove', m.id)" title="Eliminar">✕</button>
            </span>
          </div>
          <div class="moment-row-actions" @click.stop>
            <button class="qa" :class="{ on: hasJumpOp(m) }"
                    @click="$emit('jump-next', m)"
                    title="Al llegar a este momento, saltar al siguiente">⇢ salto</button>
            <button class="qa" @click="$emit('set-track', { m, track: 1 })" title="Cambiar a Track 1 en este momento">T1</button>
            <button class="qa" @click="$emit('set-track', { m, track: 2 })" title="Cambiar a Track 2 en este momento">T2</button>
            <button class="qa" @click="$emit('toggle-track', m)" title="Alternar al otro track">⇋</button>
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
  emits: ["add-to-timeline", "refresh"],
  setup(props, { emit }) {
    const tab = ref("local");
    const localFiles = ref([]);
    const globalFiles = ref([]);
    const error = ref("");
    const uploading = ref(false);
    const uploadProgress = ref(0);
    const uploadName = ref("");
    const fileInput = ref(null);

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
      if (!confirm(`¿Eliminar "${f.original_name}"?\nSi está en el timeline, se quitará automáticamente.`)) return;
      try {
        await api(`/api/projects/${props.project.slug}/files/${f.id}`, { method: "DELETE" });
        await load();
        emit("refresh", { fileDeleted: f.id });
      } catch (e) { error.value = e.message; }
    }

    async function makeGlobal(f, ev) {
      ev.stopPropagation();
      if (!confirm(`Mover "${f.original_name}" a archivos globales?\nSi está en el timeline, se quitará. Esta acción no se puede deshacer.`)) return;
      try {
        await api(`/api/projects/${props.project.slug}/files/${f.id}/make-global`, { method: "POST" });
        await load();
        emit("refresh", { fileDeleted: f.id });
      } catch (e) { error.value = e.message; }
    }

    function addToTimeline(f) {
      if (f.file_type === "image") {
        alert("Las imágenes no se pueden usar como clip del timeline. Usa un archivo de video o de audio.");
        return;
      }
      emit("add-to-timeline", f);
    }

    onMounted(load);

    return {
      tab, localFiles, globalFiles, error, uploading, uploadProgress, uploadName, fileInput,
      upload, removeFile, makeGlobal, addToTimeline, formatSize, formatDurationCompact, load,
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
          <div v-for="f in localFiles" :key="f.id" class="file-row" @click="addToTimeline(f)">
            <div v-if="f.thumbnail_url" class="thumb-mini" :style="{ backgroundImage: 'url(' + f.thumbnail_url + ')' }"></div>
            <span v-else :class="['type-pill', f.file_type]">{{ f.file_type }}</span>
            <div class="name">
              <div class="title" :title="f.original_name">{{ f.original_name }}</div>
              <div class="meta">
                {{ formatSize(f.size_bytes) }}<span v-if="f.duration"> · {{ formatDurationCompact(f.duration) }}</span>
              </div>
            </div>
            <div class="actions">
              <button class="icon ghost" @click="makeGlobal(f, $event)" title="Mover a globales">⇪</button>
              <button class="icon danger" @click="removeFile(f, $event)" title="Eliminar">✕</button>
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

    return { editing, trimStart, trimEnd, openTrim, applyTrim, move, formatDurationCompact, formatShort };
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
        <div v-for="(clip, idx) in clips" :key="clip.id" class="clip-card">
          <div class="clip-card-head">
            <span class="pos">#{{ idx + 1 }}</span>
            <div v-if="clip.source && clip.source.thumbnail_url" class="thumb-small" :style="{ backgroundImage: 'url(' + clip.source.thumbnail_url + ')' }"></div>
            <div class="clip-name" :title="clip.source ? clip.source.original_name : ''">
              {{ clip.source ? clip.source.original_name : '(archivo borrado)' }}
            </div>
            <div class="clip-actions">
              <button class="icon ghost clip-track-toggle" :class="'track-' + (clip.track || 1)"
                      @click="$emit('set-track', { id: clip.id, track: (clip.track || 1) === 1 ? 2 : 1 })"
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
  props: { type: String, clips: Array, localFiles: Array, moments: Array, currentMomentId: Number,
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
      });
      // If editing an existing op, overlay initialParams onto the defaults.
      if (props.initialParams) Object.assign(params, props.initialParams);
    }, { immediate: true });

    // Keep the video-frame WYSIWYG overlay in sync with the form params.
    watch(() => [props.type, params.text, params.font, params.color, params.size_pct,
                 params.x_pct, params.y_pct, params.rotation_deg, params.outline, params.shadow], () => {
      if (props.type === "text_overlay") emit("editing-overlay", params);
      else emit("editing-overlay", null);
    }, { immediate: true, deep: true });
    onBeforeUnmount(() => emit("editing-overlay", null));

    const audioFiles = computed(() => (props.localFiles || []).filter(f => f.file_type === "audio"));
    const videoFiles = computed(() => (props.localFiles || []).filter(f => f.file_type === "video"));
    const otherMoments = computed(() =>
      [...(props.moments || [])]
        .filter(m => m.id !== props.currentMomentId)
        .sort((a, b) => a.timeline_seconds - b.timeline_seconds)
    );

    function submit() { emit("submit", { ...params }); }

    return { params, audioFiles, videoFiles, otherMoments, COMIC_FONTS, submit };
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
        <div class="op-field"><label>Sonido (opcional — archivo de audio del proyecto)</label>
          <select v-model.number="params.sound_file_id">
            <option :value="null">— sin sonido —</option>
            <option v-for="f in audioFiles" :key="f.id" :value="f.id">{{ f.original_name }}</option>
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

var OperationsPanel = {
  components: { OpForm },
  props: { moment: Object, clips: Array, localFiles: Array, moments: Array },
  emits: ["add", "update", "remove", "editing-overlay"],
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

    return { adding, editingOp, newType, availableTypes, startAdd, startEdit, cancelForm, submitOp, opSummary };
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
          <span class="mono">{{ formatShort(moment.timeline_seconds) }}</span>
          <span class="label">{{ moment.label || '—' }}</span>
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
                  :clips="clips" :local-files="localFiles"
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

var ExportModal = {
  props: { slug: String },
  emits: ["close"],
  setup(props, { emit }) {
    const presets = ref([]);
    const selectedId = ref(null);
    const job = ref(null);       // current running/done job
    const history = ref([]);
    const busy = ref(false);
    const error = ref("");
    let pollHandle = null;

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
        const r = await api(`/api/projects/${props.slug}/export`, {
          method: "POST",
          body: { preset_id: selectedId.value },
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

    onMounted(() => { loadPresets(); loadHistory(); });
    onBeforeUnmount(() => { if (pollHandle) clearTimeout(pollHandle); });

    return { presets, selectedId, job, history, busy, error, grouped, downloadUrl, streamUrl, start, cancel, reset, loadHistory };
  },
  template: `
    <div class="modal-backdrop" @click.self="$emit('close')">
      <div class="modal" style="width: 560px; max-height: calc(100vh - 40px); display: flex; flex-direction: column;">
        <div class="eyebrow">EXPORTAR · RENDER FFmpeg</div>
        <h3>Generar archivo final</h3>

        <div v-if="!job" style="margin-top: 14px; overflow-y:auto; flex: 1;">
          <label style="margin-bottom:6px;">Elige un preset</label>
          <div v-for="(items, plat) in grouped" :key="plat" style="margin-bottom:10px;">
            <div class="tiny" style="margin: 8px 0 4px; color: var(--signal);">{{ plat }}</div>
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
                  <template v-else>{{ p.format }} · audio sólo</template>
                </div>
              </div>
            </div>
          </div>
        </div>

        <div v-else style="margin-top: 18px;">
          <div class="muted" style="font-family: var(--font-mono); font-size: 11px; letter-spacing: 0.14em; text-transform: uppercase;">
            Job #{{ job.id }} · {{ job.preset_id }}
          </div>
          <div class="progress-bar" style="margin-top: 10px;">
            <div class="progress-fill" :style="{ width: (job.progress || 0) + '%' }"></div>
            <div class="progress-text mono">
              <template v-if="job.status === 'running' || job.status === 'pending'">{{ job.progress || 0 }}%</template>
              <template v-else-if="job.status === 'done'">✓ listo</template>
              <template v-else-if="job.status === 'cancelled'">⊘ cancelado</template>
              <template v-else-if="job.status === 'error'">◆ error</template>
            </div>
          </div>
          <div v-if="job.status === 'running' || job.status === 'pending'" class="row right" style="margin-top: 10px;">
            <button class="danger" @click="cancel">⊘ Cancelar</button>
          </div>
          <div v-if="job.status === 'cancelled'" class="muted" style="margin-top: 12px; padding: 10px; border: 1px dashed var(--ink-line); border-radius: var(--r-md); text-align: center;">
            Export cancelado.
            <div style="margin-top: 8px;"><button class="ghost" @click="reset">Intentar otra vez</button></div>
          </div>

          <div v-if="job.status === 'done'" class="card" style="margin-top: 14px; padding: 12px;">
            <div class="row" style="gap: 8px;">
              <a :href="downloadUrl" class="kbd" style="text-decoration: none; padding: 8px 14px; font-size: 12px; background: var(--signal); color: var(--ink-deep); border: 0; font-weight: 600;">↓ Descargar</a>
              <a :href="streamUrl" target="_blank" class="kbd" style="text-decoration: none; padding: 8px 14px; font-size: 12px;">▶ Reproducir en pestaña</a>
              <div class="spacer"></div>
              <button class="ghost" @click="reset">Otra exportación</button>
            </div>
          </div>

          <div v-if="job.status === 'error'" class="error" style="margin-top: 14px; white-space: pre-wrap; max-height: 200px; overflow-y: auto; font-size: 11px;">
            {{ job.error_msg || 'error sin detalles' }}
            <div style="margin-top: 8px;"><button class="ghost" @click="reset">Intentar de nuevo</button></div>
          </div>
        </div>

        <div v-if="history.length > 0 && !job" style="margin-top: 14px; border-top: 1px solid var(--ink-line); padding-top: 12px;">
          <div class="tiny" style="margin-bottom: 6px;">Historial reciente</div>
          <div class="history-list">
            <div v-for="h in history.slice(0, 5)" :key="h.id" class="history-row">
              <span class="mono" style="color: var(--signal-dim);">#{{ h.id }}</span>
              <span class="mono" style="font-size: 11px;">{{ h.preset_id }}</span>
              <span class="kind mono" :class="h.status">{{ h.status }}</span>
              <span v-if="h.status === 'done'" class="progress-tail mono">{{ h.progress }}%</span>
              <div class="spacer"></div>
              <a v-if="h.status === 'done' && h.output_file" :href="'/api/projects/' + slug + '/export/' + h.id + '/download'" class="kbd" style="text-decoration: none; font-size: 10px; padding: 3px 8px;">↓</a>
            </div>
          </div>
        </div>

        <div v-if="error" class="error">{{ error }}</div>

        <div class="row right" style="margin-top: 18px; gap: 8px;">
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
  props: { clip: Object },
  emits: ["apply", "cancel"],
  setup(props, { emit }) {
    const thresholdDb = ref(-40);
    const minSilence = ref(0.5);
    const running = ref(false);
    const result = ref(null);
    const error = ref("");

    async function run() {
      running.value = true;
      error.value = "";
      result.value = null;
      try {
        // We go through the parent; the parent will POST and then call us back with result.
        emit("apply", {
          clip: props.clip,
          threshold_db: thresholdDb.value,
          min_silence_seconds: minSilence.value,
          setResult: (r) => { result.value = r; running.value = false; },
          setError: (msg) => { error.value = msg; running.value = false; },
        });
      } catch (e) {
        error.value = e.message;
        running.value = false;
      }
    }

    return { thresholdDb, minSilence, running, result, error, run };
  },
  template: `
    <div class="modal-backdrop" @click.self="$emit('cancel')">
      <div class="modal" style="width:480px;">
        <div class="eyebrow">ANALIZAR Y CORTAR SILENCIOS</div>
        <h3>{{ clip.source ? clip.source.original_name : 'Clip' }}</h3>
        <p class="muted" style="margin: 6px 0 18px;">
          Analiza el audio del clip y reemplaza este clip por varios (uno por tramo con sonido).
          Ajustable con umbral de volumen y duración mínima del silencio.
        </p>

        <div class="op-field">
          <label>Umbral (dB, más negativo = silencio más profundo)</label>
          <input type="number" step="1" v-model.number="thresholdDb" :disabled="running">
        </div>
        <div class="op-field">
          <label>Duración mínima del silencio (s)</label>
          <input type="number" step="0.1" min="0.1" v-model.number="minSilence" :disabled="running">
        </div>

        <div v-if="running" class="muted" style="margin-top:14px; text-align:center; font-family:var(--font-mono); color:var(--signal); font-size:11px; letter-spacing:0.15em; text-transform:uppercase;">
          ◉ analizando con ffmpeg…
        </div>

        <div v-if="error" class="error" style="margin-top:12px;">{{ error }}</div>

        <div v-if="result && !running" class="card" style="margin-top:14px; padding:12px; background: var(--ink-sunken);">
          <div v-if="result.splits === 0">{{ result.message || 'No se aplicaron cambios.' }}</div>
          <div v-else>
            <div class="mono" style="font-size:13px;">
              <b style="color:var(--signal);">{{ result.splits }}</b> segmentos generados ·
              <b style="color:var(--signal-hot);">{{ result.removed_seconds }}s</b> removidos ·
              <b style="color:var(--signal-cool);">{{ result.kept_seconds }}s</b> retenidos
            </div>
            <div class="muted" style="margin-top:6px; font-size:11px;">
              {{ result.silences_detected }} silencio(s) detectado(s).
            </div>
          </div>
        </div>

        <div class="row right" style="margin-top:20px; gap:8px;">
          <button class="ghost" @click="$emit('cancel')" :disabled="running">Cerrar</button>
          <button class="primary" @click="run" :disabled="running">
            {{ running ? 'Procesando…' : (result ? 'Re-procesar' : 'Analizar y aplicar') }}
          </button>
        </div>
      </div>
    </div>
  `,
};

var ProjectView = {
  props: { project: Object, onBack: Function },
  components: { FilesPanel, VideoPlayer, Timeline, ZoomControls, MomentsList, CaptureMomentModal, ClipsPanel, OperationsPanel, SilenceModal, ExportModal },
  setup(props) {
    const timeline = reactive({ clips: [], moments: [], duration: 0, audioLane: [] });
    const silenceClip = ref(null);
    const showExport = ref(false);
    const localFiles = ref([]);
    const playerState = reactive({
      currentTime: 0,
      duration: 0,
      isPlaying: false,
      volume: 1.0,
    });
    const zoom = reactive({ startSeconds: 0, endSeconds: null });
    const selectedRange = ref(null);  // { start, end } | null — persistent yellow band from drag-select

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
      const out = { filter: null, transform: null, subtitles: [], vertical: null, textOverlays: [] };
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
          // Audio files go to the parallel audio lane (mixed with video).
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
            body: { media_file_id: f.id, label: f.original_name },
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
      if (!confirm("¿Quitar este audio de la pista?")) return;
      try {
        await api(`/api/projects/${props.project.slug}/audio-lane/${id}`, { method: "DELETE" });
        await refreshTimeline();
      } catch (e) { error.value = e.message; }
    }

    async function removeClip(clipId) {
      if (!confirm("¿Quitar este clip del timeline?")) return;
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

    function openSilenceModal(clip) { silenceClip.value = clip; }
    async function applySilenceRemoval(payload) {
      try {
        const r = await api(
          `/api/projects/${props.project.slug}/timeline/clips/${payload.clip.id}/remove-silences`,
          {
            method: "POST",
            body: {
              threshold_db: payload.threshold_db,
              min_silence_seconds: payload.min_silence_seconds,
            },
          }
        );
        await refreshTimeline();
        payload.setResult(r);
      } catch (e) {
        payload.setError(e.message);
      }
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
      if (!next) { alert("No hay momento posterior para saltar."); return; }
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

    async function removeMoment(id) {
      if (!confirm("¿Eliminar momento?")) return;
      try {
        await api(`/api/projects/${props.project.slug}/moments/${id}`, { method: "DELETE" });
        if (selectedMomentId.value === id) selectedMomentId.value = null;
        await refreshTimeline();
      } catch (e) { error.value = e.message; }
    }

    async function addOperation(op) {
      if (!selectedMoment.value) return;
      try {
        const r = await api(`/api/projects/${props.project.slug}/moments/${selectedMoment.value.id}/operations`, {
          method: "POST",
          body: { type: op.type, params: op.params },
        });
        await refreshTimeline();
        if (r && r.silence_result) {
          const s = r.silence_result;
          if (s.silences_detected === 0) {
            alert("No se detectaron silencios en ese rango.");
          } else {
            alert(
              `Silencios removidos:\n` +
              `• ${s.silences_detected} silencio(s) detectado(s)\n` +
              `• ${s.removed_seconds}s eliminados\n` +
              `• ${s.splits} segmento(s) generado(s)` +
              (s.skipped_no_audio ? `\n• ${s.skipped_no_audio} clip(s) sin audio fueron saltados` : "")
            );
          }
        }
      } catch (e) { error.value = e.message; alert(e.message); }
    }

    async function removeOperation(opId) {
      try {
        await api(`/api/projects/${props.project.slug}/operations/${opId}`, { method: "DELETE" });
        await refreshTimeline();
      } catch (e) { error.value = e.message; }
    }

    async function updateOperation({ id, type, params }) {
      try {
        await api(`/api/projects/${props.project.slug}/operations/${id}`, {
          method: "PUT", body: { params },
        });
        await refreshTimeline();
      } catch (e) { error.value = e.message; }
    }

    const editingOverlay = ref(null);
    function setEditingOverlay(p) { editingOverlay.value = p; }

    function onSeek(t) {
      videoPlayerRef.value?.seek(t);
      // Click outside the selected range clears it; click inside preserves it.
      const r = selectedRange.value;
      if (r && (t < r.start - 0.01 || t > r.end + 0.01)) {
        selectedRange.value = null;
      }
    }

    function previewMoment(m) {
      // Seek a touch before the moment so the user can see the effect enter, then play.
      const lead = 0.4; // seconds
      const start = Math.max(0, m.timeline_seconds - lead);
      // seek(..., autoPlay=true) handles src swap + starts playback once loaded.
      videoPlayerRef.value?.seek(start, true);
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
    function onUpdateZoom({ start, end }) {
      zoom.startSeconds = start;
      zoom.endSeconds = end;
    }

    function onFilesRefresh(payload) {
      if (payload?.local) localFiles.value = payload.local;
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

    onMounted(() => {
      refreshTimeline();
      window.addEventListener("keydown", onKey);
    });
    onBeforeUnmount(() => window.removeEventListener("keydown", onKey));

    return {
      timeline, localFiles, playerState, zoom, selectedMomentId, selectedMoment,
      capture, clipsWithStarts, activeEffects, videoPlayerRef, error,
      refreshTimeline, addClipToTimeline, removeClip, reorderClip, trimClip, seekToClip,
      createMoment, updateMomentLabel, updateMomentType, removeMoment,
      addJumpToNext, setTrackAtMoment, toggleTrackAtMoment, applyRangeAsZoom,
      setClipTrack, updateLaneClip, removeLaneClip,
      laneEditing, onLaneClipClick, saveLaneEdit,
      clipEditing, onClipClick, saveClipEdit,
      updateOperation, editingOverlay, setEditingOverlay,
      addOperation, removeOperation,
      onSeek, onZoomTo, onUpdateZoom, onFilesRefresh, previewMoment,
      showFiles, showClips, focusMode, selectedRange,
      silenceClip, openSilenceModal, applySilenceRemoval,
      showExport,
      formatShort,
    };
  },
  template: `
    <div class="editor-wide"
         :class="{
           'no-left':   !showFiles && !focusMode,
           'no-right':  !showClips && !selectedMoment,
           'focus-mode': focusMode,
           'has-ops':    focusMode && selectedMoment != null
         }">
      <FilesPanel
        v-if="showFiles"
        :project="project"
        @add-to-timeline="addClipToTimeline"
        @refresh="onFilesRefresh"
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
          @jump-next="addJumpToNext"
          @set-track="setTrackAtMoment"
          @toggle-track="toggleTrackAtMoment"
          @select="(id) => selectedMomentId = id"
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
          :audio-lane="timeline.audioLane"
          :editing-overlay="editingOverlay"
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
            <button v-if="selectedRange" :disabled="timeline.clips.length === 0" @click="applyRangeAsZoom"
                    class="ghost" style="margin-left:8px;" title="Zoom al rango seleccionado (Z)">
              🔍 Zoom selección <span class="kbd" style="margin-left:6px;">Z</span>
            </button>
            <button :disabled="timeline.clips.length === 0" @click="showExport = true" style="margin-left:8px;">
              ⇪ Exportar
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
          @jump-next="addJumpToNext"
          @set-track="setTrackAtMoment"
          @toggle-track="toggleTrackAtMoment"
          @select="(id) => selectedMomentId = id"
        />

        <CaptureMomentModal
          :show="capture.show"
          :current-time="playerState.currentTime"
          @capture="createMoment"
          @cancel="capture.show = false"
        />
      </div>

      <aside v-if="showClips || selectedMoment" class="right-col">
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
          :clip="silenceClip"
          @apply="applySilenceRemoval"
          @cancel="silenceClip = null"
        />
        <OperationsPanel
          v-if="selectedMoment"
          :moment="selectedMoment"
          :clips="clipsWithStarts"
          :local-files="localFiles"
          :moments="timeline.moments"
          @add="addOperation"
          @update="updateOperation"
          @remove="removeOperation"
          @editing-overlay="setEditingOverlay"
        />
      </aside>

      <ExportModal v-if="showExport" :slug="project.slug" @close="showExport = false" />
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

    async function checkAuth() {
      state.loading = true;
      try { const d = await api("/api/auth/me"); state.username = d.username; }
      catch (_) { state.username = null; }
      finally { state.loading = false; }
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
    onMounted(() => { checkAuth(); setInterval(syncTally, 250); });

    return { state, isPlaying, onLoggedIn, onOpen, onBack, logout };
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
          <span class="mark">post<em>Pod</em></span>
          <span class="tag">studio · v0.3</span>
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
