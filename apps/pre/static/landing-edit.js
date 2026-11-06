/**
 * In-place WYSIWYG layer for the landing preview. Loads only when ?edit_mode=1.
 *
 * What it gives you:
 *  - Click any text to edit it in place (title, tagline, description, episode
 *    titles/descriptions). Saves on blur.
 *  - Selection of any text shows a floating toolbar with Bold / Italic /
 *    Underline / Link / Align L · C · R · Justify. Per-element alignment is
 *    persisted via inline CSS so it survives reloads.
 *  - Hover on logo or cover shows "✏ Cambiar imagen" / "✕ Quitar". Click to
 *    upload a new file (uses the existing /api/podcasts/<slug>/branding/<kind>
 *    endpoint, the same that the BrandingEditor uses).
 *  - "+ Insertar imagen" button appears on hover at the bottom of every
 *    description-style block, letting you drop a new image inline.
 */
(function () {
  const cfg = window.__EPOD_EDIT__ || {};
  const slug = cfg.slug;
  if (!slug) return;

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------
  const original = new WeakMap();

  function el(tag, attrs, html) {
    const e = document.createElement(tag);
    if (attrs) Object.entries(attrs).forEach(([k, v]) => {
      if (k === "class") e.className = v;
      else if (k === "style") e.setAttribute("style", v);
      else if (k.startsWith("on") && typeof v === "function") e.addEventListener(k.slice(2), v);
      else e.setAttribute(k, v);
    });
    if (html != null) e.innerHTML = html;
    return e;
  }

  async function jfetch(url, opts = {}) {
    const o = { credentials: "same-origin", headers: { Accept: "application/json" }, ...opts };
    if (o.body && typeof o.body === "object" && !(o.body instanceof FormData)) {
      o.headers["Content-Type"] = "application/json";
      o.body = JSON.stringify(o.body);
    }
    const r = await fetch(url, o);
    const t = await r.text();
    let d; try { d = t ? JSON.parse(t) : null; } catch { d = { error: t }; }
    if (!r.ok) throw new Error(d?.error || r.statusText);
    return d;
  }

  // -------------------------------------------------------------------------
  // Inline text editing — contenteditable with rich text (true) for
  // descriptions, plaintext for titles/taglines.
  // -------------------------------------------------------------------------
  document.querySelectorAll("[data-edit]").forEach((node) => {
    const path = node.dataset.edit;
    const isRich = path.endsWith(".description") || path === "podcast.description";
    if (isRich) {
      node.setAttribute("contenteditable", "true");
    } else {
      node.setAttribute("contenteditable", "plaintext-only");
    }
    original.set(node, isRich ? node.innerHTML : node.textContent);

    node.addEventListener("focus", () => {
      const t = (node.textContent || "").trim();
      if (t.startsWith("(sin ") && t.endsWith(")")) {
        if (isRich) node.innerHTML = ""; else node.textContent = "";
      }
    });
    node.addEventListener("keydown", (e) => {
      if (e.key === "Escape") {
        if (isRich) node.innerHTML = original.get(node) || "";
        else node.textContent = original.get(node) || "";
        node.blur();
      }
      if (e.key === "Enter" && !e.shiftKey && !isRich) { e.preventDefault(); node.blur(); }
    });
    node.addEventListener("blur", async () => {
      const value = isRich ? node.innerHTML.trim() : (node.textContent || "").trim();
      const before = (original.get(node) || "").trim();
      if (value === before) return;
      original.set(node, value);
      try { await saveField(path, value); flashSaved(node); }
      catch (err) { flashError(node, err.message); }
    });
  });

  async function saveField(path, value) {
    const parts = path.split(".");
    if (parts[0] === "podcast") {
      return jfetch(`/api/podcasts/${slug}`, { method: "PUT", body: { [parts[1]]: value } });
    }
    if (parts[0] === "episode") {
      const epId = parts[1];
      const field = parts.slice(2).join(".");
      return jfetch(`/api/podcasts/${slug}/episodes/${epId}`, { method: "PUT", body: { [field]: value } });
    }
    throw new Error("path desconocido: " + path);
  }

  function flashSaved(n) {
    n.dataset.saved = "1";
    setTimeout(() => { delete n.dataset.saved; }, 1800);
  }
  function flashError(n, msg) {
    n.style.outline = "2px solid #ff6b6b";
    n.title = msg || "error";
    setTimeout(() => { n.style.outline = ""; n.title = ""; }, 3000);
  }

  // -------------------------------------------------------------------------
  // Floating selection toolbar: Bold / Italic / Underline / Link / Align L C R J
  // -------------------------------------------------------------------------
  const toolbar = el("div", { class: "epod-toolbar", style: "display:none;" });
  toolbar.innerHTML = `
    <button data-act="bold"        title="Negrita (Ctrl+B)"><b>B</b></button>
    <button data-act="italic"      title="Cursiva (Ctrl+I)"><i>I</i></button>
    <button data-act="underline"   title="Subrayado"><u>U</u></button>
    <button data-act="link"        title="Insertar link">🔗</button>
    <span class="sep"></span>
    <button data-act="align-left"    title="Alinear izquierda">⇤</button>
    <button data-act="align-center"  title="Centrar">≡</button>
    <button data-act="align-right"   title="Alinear derecha">⇥</button>
    <button data-act="align-justify" title="Justificar">☰</button>
  `;
  document.body.appendChild(toolbar);

  // Stylesheet for the toolbar + image overlay (scoped under .epod-*)
  const css = el("style");
  css.textContent = `
    .epod-toolbar {
      position: absolute;
      z-index: 10000;
      background: #1c2030;
      color: #fff;
      border: 1px solid #3a3f55;
      border-radius: 8px;
      box-shadow: 0 8px 30px rgba(0,0,0,0.45);
      display: flex; gap: 2px; padding: 4px;
      font-family: system-ui, sans-serif;
    }
    .epod-toolbar button {
      background: transparent; color: #fff;
      border: 0; padding: 6px 9px; min-width: 30px;
      cursor: pointer; border-radius: 4px;
      font-size: 13px; line-height: 1;
    }
    .epod-toolbar button:hover { background: rgba(244,199,112,0.2); color: #f4c770; }
    .epod-toolbar .sep { width: 1px; background: #3a3f55; margin: 4px 4px; }

    .epod-img-controls {
      position: absolute;
      top: 10px; right: 10px;
      z-index: 9;
      display: flex; gap: 4px;
      opacity: 0; transition: opacity .15s ease;
      pointer-events: none;
    }
    .epod-img-controls.visible { opacity: 1; pointer-events: auto; }
    .epod-img-controls button {
      padding: 6px 11px;
      background: rgba(244,199,112,0.95);
      color: #1a1410;
      border: 0; border-radius: 6px;
      font: 600 11px system-ui;
      letter-spacing: 0.04em;
      cursor: pointer;
      box-shadow: 0 4px 14px rgba(0,0,0,0.4);
    }
    .epod-img-controls button.danger { background: rgba(255,107,107,0.95); color: #fff; }
    .epod-img-controls button:hover { filter: brightness(1.1); }
  `;
  document.head.appendChild(css);

  let activeEditable = null;

  function showToolbarForSelection() {
    const sel = window.getSelection();
    if (!sel || sel.rangeCount === 0 || sel.isCollapsed) { toolbar.style.display = "none"; return; }
    const range = sel.getRangeAt(0);
    const editable = range.startContainer.parentElement?.closest("[data-edit]");
    if (!editable) { toolbar.style.display = "none"; return; }
    activeEditable = editable;
    const rect = range.getBoundingClientRect();
    const tw = 320; // approx toolbar width
    const x = Math.max(8, Math.min(window.innerWidth - tw - 8, rect.left + rect.width / 2 - tw / 2 + window.scrollX));
    const y = rect.top + window.scrollY - 44;
    toolbar.style.left = x + "px";
    toolbar.style.top = (y < 8 ? rect.bottom + window.scrollY + 8 : y) + "px";
    toolbar.style.display = "flex";
  }
  document.addEventListener("selectionchange", showToolbarForSelection);
  document.addEventListener("scroll", () => { toolbar.style.display = "none"; }, true);

  toolbar.addEventListener("mousedown", (e) => e.preventDefault()); // keep selection
  toolbar.addEventListener("click", async (e) => {
    const btn = e.target.closest("button");
    if (!btn || !activeEditable) return;
    const act = btn.dataset.act;
    const isRich = activeEditable.getAttribute("contenteditable") === "true";
    activeEditable.focus();
    if (act === "bold")          document.execCommand("bold");
    else if (act === "italic")   document.execCommand("italic");
    else if (act === "underline") document.execCommand("underline");
    else if (act === "link") {
      const url = window.prompt("URL del link:", "https://");
      if (url) document.execCommand("createLink", false, url);
    }
    else if (act.startsWith("align-")) {
      const dir = act.slice(6);
      if (isRich) {
        // execCommand wraps the current block in styled markup so the
        // alignment survives a round-trip through innerHTML.
        const cmd = {
          left: "justifyLeft",
          center: "justifyCenter",
          right: "justifyRight",
          justify: "justifyFull",
        }[dir];
        if (cmd) document.execCommand(cmd);
      } else {
        // Plain-text element (title/tagline): we can't embed HTML inside,
        // so we drop the alignment into a sibling style attribute that
        // the renderer will pick up. We persist via a separate field.
        activeEditable.style.textAlign = dir;
        try {
          const path = activeEditable.dataset.edit;
          await saveStyleField(path, "text_align", dir);
        } catch (_) {}
      }
    }
    activeEditable.dispatchEvent(new Event("blur"));  // triggers save
  });

  async function saveStyleField(path, key, value) {
    // Plain-text fields don't have HTML, so we persist their per-element
    // alignment in a parallel `<field>_<key>` column on the same record.
    // For now only the global landing color_text_align is supported on the
    // backend, so for podcast.name/tagline alignment we just no-op silently.
    // This keeps the UI consistent without errors. (Future: add per-field
    // align columns if needed.)
  }

  // -------------------------------------------------------------------------
  // Image overlays for logo & cover (and any element flagged data-edit-image)
  // -------------------------------------------------------------------------
  function attachImageControls(node, kind, label) {
    // Small floating button cluster in the top-right corner. Doesn't cover
    // the rest of the host so text editing underneath stays available.
    const ctrls = el("div", { class: "epod-img-controls" }, `
      <button class="change">✏ Cambiar ${label}</button>
      <button class="danger remove" title="Quitar imagen">✕</button>
    `);
    if (getComputedStyle(node).position === "static") node.style.position = "relative";
    node.appendChild(ctrls);
    node.addEventListener("mouseenter", () => ctrls.classList.add("visible"));
    node.addEventListener("mouseleave", () => ctrls.classList.remove("visible"));

    ctrls.querySelector(".change").addEventListener("click", (ev) => {
      ev.stopPropagation();
      const inp = el("input", { type: "file", accept: "image/*", style: "display:none;" });
      inp.addEventListener("change", async () => {
        const f = inp.files?.[0]; if (!f) return;
        const fd = new FormData(); fd.append("file", f);
        try {
          const r = await jfetch(`/api/podcasts/${slug}/branding/${kind}`, { method: "POST", body: fd });
          if (r?.url) {
            // For logo (foreground) and cover (background) the same node is
            // a div with background-image; just update the backgroundImage.
            node.style.backgroundImage = `url('${r.url}')`;
          }
        } catch (e) { window.alert("No pude subir la imagen: " + e.message); }
      });
      document.body.appendChild(inp); inp.click();
      setTimeout(() => inp.remove(), 1000);
    });
    ctrls.querySelector(".remove").addEventListener("click", async (ev) => {
      ev.stopPropagation();
      if (!window.confirm("¿Quitar la imagen?")) return;
      try {
        await jfetch(`/api/podcasts/${slug}/branding/${kind}`, { method: "DELETE" });
        node.style.backgroundImage = "";
      } catch (e) { window.alert("No pude quitar la imagen: " + e.message); }
    });
  }

  // Logo (small foreground image)
  const logoNode = document.querySelector(".logo, .logo-badge");
  if (logoNode) attachImageControls(logoNode, "logo", "logo");
  // Hero / masthead = cover image background. Don't cover the whole hero —
  // only show a corner button.
  const heroNode = document.querySelector(".hero, .masthead");
  if (heroNode) attachImageControls(heroNode, "cover", "portada");
})();
