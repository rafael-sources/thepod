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

/* Compute cumulative timeline starts for a list of clip objects. Each clip
   gets { ...clip, start, end } where start is its timeline start second. */
function withTimelineStarts(clips) {
  let t = 0;
  return clips.map((c) => {
    const dur = c.duration || 0;
    const item = { ...c, start: t, end: t + dur };
    t += dur;
    return item;
  });
}

/* Given a timeline time t and a list of clips (withTimelineStarts), return
   the clip that contains t (half-open interval). Falls back to last clip if
   t >= total duration. Returns null if there are no clips. */
function clipAtTime(clips, t) {
  if (!clips.length) return null;
  for (const c of clips) {
    if (t < c.end) return c;
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
  },
  setup(props) {
    const videoEl = ref(null);
    const rangeMode = ref("free");
    const currentClipId = ref(null);
    const lastTimelineT = ref(0);
    let jumpCooldownUntil = 0;  // epoch ms, suppresses double-jumps after a jump

    const activeClip = computed(() => clipAtTime(props.clips, props.playerState.currentTime));

    const visibleDuration = computed(() => {
      const end = props.zoom.endSeconds ?? props.playerState.duration;
      return Math.max(0, end - props.zoom.startSeconds);
    });
    const canSlowPlay = computed(() => visibleDuration.value > 0 && visibleDuration.value <= 10);

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
      const c = clipAtTime(props.clips, clamped);
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
      const volTarget = props.playerState?.volume ?? 1.0;
      if (Math.abs(v.volume - volTarget) > 0.001) v.volume = volTarget;
    }

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
      if (visibleDuration.value <= 0) return;
      rangeMode.value = "range";
      // Kick play() in the user-gesture tick so Firefox doesn't auto-mute.
      const v = videoEl.value;
      if (v) { _unmute(v); v.playbackRate = 1.0; v.play().catch(() => {}); }
      await seek(props.zoom.startSeconds, false);
      if (videoEl.value) {
        videoEl.value.playbackRate = 1.0;
        _unmute(videoEl.value);
        if (videoEl.value.paused) videoEl.value.play().catch(() => {});
      }
    }
    async function playSlow10s() {
      if (!canSlowPlay.value) return;
      rangeMode.value = "slow";
      const rate = Math.max(0.01, visibleDuration.value / 10.0);
      const v = videoEl.value;
      if (v) { _unmute(v); v.play().catch(() => {}); }
      await seek(props.zoom.startSeconds, false);
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

      // Did we cross clip.end? Advance to next clip automatically.
      const srcEnd = clip.end_offset ?? (clip.source?.duration ?? Infinity);
      if (localT >= srcEnd - 0.02) {
        const idx = props.clips.findIndex(c => c.id === clip.id);
        const next = props.clips[idx + 1];
        if (next) {
          swapTo(next, next.start, "resume");
        } else {
          v.pause();
          rangeMode.value = "free";
        }
      }

      // Bounded playback modes stop at zoom end
      const zEnd = props.zoom.endSeconds ?? props.playerState.duration;
      if (rangeMode.value !== "free" && timelineT >= zEnd - 0.01) {
        v.pause();
        v.playbackRate = 1.0;
        rangeMode.value = "free";
      }
    }

    function onPlay() { props.playerState.isPlaying = true; }
    function onPause() { props.playerState.isPlaying = false; }
    function onVolumeChange() {
      if (videoEl.value) props.playerState.volume = videoEl.value.volume;
    }

    watch(() => props.playerState.volume, (v) => {
      if (videoEl.value && Math.abs(videoEl.value.volume - v) > 0.001) videoEl.value.volume = v;
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

    return {
      videoEl, rangeMode, canSlowPlay, seek, togglePlay, playVisibleRange, playSlow10s,
      onTimeUpdate, onPlay, onPause, onVolumeChange,
      tc, tcTotal, activeClip, frameStyle, isVertical, verticalStyle,
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
  },
  emits: ["seek", "zoom-to", "select-moment"],
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
        width: `${Math.max(0, width)}%`,
        opacity: width < 0.4 ? 0.3 : (fullyVisible ? 1 : 0.85),
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

    return {
      root, cursorPct, selectRect, ticks, clipStyle, secToPct, onPointerDown,
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
          :class="[clip.source ? clip.source.file_type : 'video', { 'has-thumb': clip.source && clip.source.thumbnail_url }]"
          :style="{ ...clipStyle(clip), ...(clip.source && clip.source.thumbnail_url ? { backgroundImage: 'url(' + clip.source.thumbnail_url + ')' } : {}) }"
          :title="clip.label || (clip.source ? clip.source.original_name : '#' + clip.id)"
        >
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
  emits: ["goto", "preview", "update-label", "remove", "select"],
  setup(props, { emit }) {
    const sorted = computed(() => [...props.moments].sort((a, b) => a.timeline_seconds - b.timeline_seconds));

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

    return { sorted, formatTimecode, beginEdit, endEdit, onKey };
  },
  template: `
    <div class="moments-section">
      <div class="moments-head">
        <span class="label">Momentos</span>
        <span class="count">{{ moments.length }}</span>
        <div class="spacer"></div>
        <span class="muted">Clic para seleccionar · Doble clic edita la etiqueta · <span class="kbd">M</span> captura</span>
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
          <span class="time mono">
            <template v-for="(part, i) in [formatTimecode(m.timeline_seconds)]" :key="i">
              {{ part.hh }}:{{ part.mm }}:{{ part.ss }}<span style="color:var(--paper-faint);">.{{ part.cs }}</span>
            </template>
          </span>
          <span class="kind" :class="m.type">{{ m.type }}</span>
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
            {{ m.operations.length }} ops
          </span>
          <span class="actions" @click.stop>
            <button class="icon" @click="$emit('goto', m.timeline_seconds)" title="Saltar al momento (pausado)">⇥</button>
            <button class="icon primary-subtle" @click="$emit('preview', m)" title="Reproducir desde un poco antes">▶</button>
            <button class="icon danger" @click="$emit('remove', m.id)" title="Eliminar">✕</button>
          </span>
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
  emits: ["reorder", "remove", "trim", "seek-to", "remove-silences"],
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
  props: { type: String, clips: Array, localFiles: Array, moments: Array, currentMomentId: Number },
  emits: ["submit", "cancel"],
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
    }, { immediate: true });

    const audioFiles = computed(() => (props.localFiles || []).filter(f => f.file_type === "audio"));
    const videoFiles = computed(() => (props.localFiles || []).filter(f => f.file_type === "video"));
    const otherMoments = computed(() =>
      [...(props.moments || [])]
        .filter(m => m.id !== props.currentMomentId)
        .sort((a, b) => a.timeline_seconds - b.timeline_seconds)
    );

    function submit() { emit("submit", { ...params }); }

    return { params, audioFiles, videoFiles, otherMoments, submit };
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
  emits: ["add", "remove"],
  setup(props, { emit }) {
    const adding = ref(false);
    const newType = ref("color_effect");

    const availableTypes = computed(() => {
      const kind = props.moment?.type;
      if (!kind) return [];
      return OP_TYPES.filter(t => t.kinds.includes(kind));
    });

    watch(() => props.moment?.id, () => { adding.value = false; });

    function startAdd() {
      adding.value = true;
      // pick a default valid type
      const first = availableTypes.value[0];
      if (first) newType.value = first.value;
    }
    function submitOp(params) {
      emit("add", { type: newType.value, params });
      adding.value = false;
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
      return JSON.stringify(p);
    }

    return { adding, newType, availableTypes, startAdd, submitOp, opSummary };
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
          <div v-for="op in moment.operations" :key="op.id" class="op-row">
            <span class="op-type">{{ op.type }}</span>
            <span class="op-summary mono">{{ opSummary(op) }}</span>
            <button class="icon danger" @click="$emit('remove', op.id)" title="Eliminar">✕</button>
          </div>
        </div>

        <div v-if="adding" class="op-add">
          <label>Tipo de operación</label>
          <select v-model="newType">
            <option v-for="opt in availableTypes" :key="opt.value" :value="opt.value">{{ opt.label }}</option>
          </select>
          <OpForm :type="newType" :clips="clips" :local-files="localFiles"
                  :moments="moments" :current-moment-id="moment ? moment.id : null"
                  @submit="submitOp" @cancel="adding = false" />
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
    const timeline = reactive({ clips: [], moments: [], duration: 0 });
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
    const zoomOnSelect = ref(
      (localStorage.getItem("postpod.zoomOnSelect") ?? "1") === "1"
    );
    watch(zoomOnSelect, (v) => {
      localStorage.setItem("postpod.zoomOnSelect", v ? "1" : "0");
    });
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
      const out = { filter: null, transform: null, subtitles: [], vertical: null };
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
        timeline.duration = data.duration || 0;
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
        await api(`/api/projects/${props.project.slug}/timeline/clips`, {
          method: "POST",
          body: { media_file_id: f.id, label: f.original_name },
        });
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
      try {
        const m = await api(`/api/projects/${props.project.slug}/moments`, {
          method: "POST",
          body: {
            type: payload.type,
            timeline_seconds: playerState.currentTime,
            label: payload.label || "",
          },
        });
        capture.show = false;
        await refreshTimeline();
        // Auto-select so the user can immediately add operations on this moment.
        if (m && m.id) selectedMomentId.value = m.id;
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

    function onSeek(t) { videoPlayerRef.value?.seek(t); }

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
      if (!zoomOnSelect.value) {
        // Preserve zoom; just move the playhead to the start of the selection
        videoPlayerRef.value?.seek(a, false);
        return;
      }
      zoom.startSeconds = Math.max(0, a);
      zoom.endSeconds = Math.min(total, b);
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
      else if (ev.key === "m" || ev.key === "M") { ev.preventDefault(); capture.show = true; }
      else if (ev.key === "+" || ev.key === "=") { ev.preventDefault(); zoomByShortcut(0.9); }
      else if (ev.key === "-" || ev.key === "_") { ev.preventDefault(); zoomByShortcut(1.111); }
      else if (ev.key === "ArrowLeft") { ev.preventDefault(); onSeek(Math.max(0, playerState.currentTime - (ev.shiftKey ? 1/30 : 5))); }
      else if (ev.key === "ArrowRight") { ev.preventDefault(); onSeek(Math.min(playerState.duration, playerState.currentTime + (ev.shiftKey ? 1/30 : 5))); }
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
      createMoment, updateMomentLabel, removeMoment,
      addOperation, removeOperation,
      onSeek, onZoomTo, onUpdateZoom, onFilesRefresh, previewMoment, zoomOnSelect,
      silenceClip, openSilenceModal, applySilenceRemoval,
      showExport,
      formatShort,
    };
  },
  template: `
    <div class="editor-wide">
      <FilesPanel
        :project="project"
        @add-to-timeline="addClipToTimeline"
        @refresh="onFilesRefresh"
      />

      <div class="main">
        <div v-if="error" class="error" style="margin: 8px 22px 0;">{{ error }}</div>

        <VideoPlayer
          ref="videoPlayerRef"
          :clips="clipsWithStarts"
          :player-state="playerState"
          :zoom="zoom"
          :effects="activeEffects"
          :moments="timeline.moments"
        />

        <div class="timeline-section">
          <div class="timeline-head">
            <span class="label">Timeline</span>
            <span class="zoom-info">zoom: <b>{{ formatShort(zoom.startSeconds) }} → {{ formatShort(zoom.endSeconds ?? playerState.duration) }}</b></span>
            <div class="spacer"></div>
            <ZoomControls :zoom="zoom" :player-state="playerState" @update-zoom="onUpdateZoom" />
            <label class="zoom-toggle" :title="'Si está activo, al hacer drag-select se hace zoom al rango. Si no, sólo reposiciona el cursor.'">
              <input type="checkbox" v-model="zoomOnSelect">
              <span>zoom al seleccionar</span>
            </label>
            <button class="primary" :disabled="timeline.clips.length === 0" @click="capture.show = true" style="margin-left:8px;">
              ◉ Capturar momento <span class="kbd" style="margin-left:6px;">M</span>
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
            @seek="onSeek"
            @zoom-to="onZoomTo"
            @select-moment="(id) => selectedMomentId = id"
          />
        </div>

        <MomentsList
          :moments="timeline.moments"
          :selected-moment-id="selectedMomentId"
          @goto="onSeek"
          @preview="previewMoment"
          @remove="removeMoment"
          @update-label="updateMomentLabel"
          @select="(id) => selectedMomentId = id"
        />

        <CaptureMomentModal
          :show="capture.show"
          :current-time="playerState.currentTime"
          @capture="createMoment"
          @cancel="capture.show = false"
        />
      </div>

      <aside class="right-col">
        <ClipsPanel
          :clips="clipsWithStarts"
          :total-duration="timeline.duration"
          @reorder="reorderClip"
          @remove="removeClip"
          @trim="trimClip"
          @seek-to="seekToClip"
          @remove-silences="openSilenceModal"
        />
        <SilenceModal
          v-if="silenceClip"
          :clip="silenceClip"
          @apply="applySilenceRemoval"
          @cancel="silenceClip = null"
        />
        <OperationsPanel
          :moment="selectedMoment"
          :clips="clipsWithStarts"
          :local-files="localFiles"
          :moments="timeline.moments"
          @add="addOperation"
          @remove="removeOperation"
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
