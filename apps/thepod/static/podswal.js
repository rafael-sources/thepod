/**
 * podSwal — thin wrapper around SweetAlert2 that injects each app's brand
 * theme so all confirmations/alerts feel consistent.
 *
 * Loaded after sweetalert2.min.js. Reads colors from CSS variables on
 * <html>/<body> so it picks up whatever the app already defines.
 *
 * Replaces:
 *   alert(msg)              → podSwal.toast(msg)            (or .info(msg))
 *   if (confirm(q)) {...}   → if (await podSwal.confirm(q)) {...}
 *   prompt(q, def)          → await podSwal.prompt(q, def)
 *
 * Errors:
 *   podSwal.error(msg)
 * Success:
 *   podSwal.success(msg)
 */
(function () {
  if (typeof Swal === "undefined") return;

  function readVar(name, fallback) {
    try {
      const v = getComputedStyle(document.documentElement).getPropertyValue(name).trim();
      return v || fallback;
    } catch (_) { return fallback; }
  }

  const theme = {
    primary:    readVar("--signal",       "#5a8bff"),
    danger:     readVar("--signal-hot",   "#e85a4f"),
    success:    readVar("--signal-cool",  "#8db36a"),
    bg:         readVar("--ink-panel",    readVar("--ink-deep", "#15161c")),
    bgRaised:   readVar("--ink-raised",   "#1c2030"),
    fg:         readVar("--paper",        "#ecedf2"),
    fgDim:      readVar("--paper-dim",    "#9ca0b3"),
    border:     readVar("--ink-line",     "#2a2f44"),
    fontDisplay: readVar("--font-display", "Fraunces, Georgia, serif"),
    fontBody:    readVar("--font-body",    "system-ui, sans-serif"),
  };

  const baseDefaults = {
    background: theme.bg,
    color: theme.fg,
    confirmButtonColor: theme.primary,
    cancelButtonColor:  theme.bgRaised,
    iconColor: theme.primary,
    customClass: {
      popup:        "podswal-popup",
      title:        "podswal-title",
      htmlContainer: "podswal-body",
      confirmButton: "podswal-btn-confirm",
      cancelButton:  "podswal-btn-cancel",
      input:         "podswal-input",
    },
    buttonsStyling: true,
    showClass: { popup: "swal2-show" },
    hideClass: { popup: "swal2-hide" },
  };

  // Shared CSS for the custom classes (matches each pod's tokens via theme).
  const styleEl = document.createElement("style");
  styleEl.textContent = `
    .podswal-popup {
      border: 1px solid ${theme.border};
      border-radius: 12px;
      font-family: ${theme.fontBody};
    }
    .podswal-title {
      font-family: ${theme.fontDisplay};
      font-weight: 600;
      letter-spacing: -0.01em;
      color: ${theme.fg};
    }
    .podswal-body { color: ${theme.fgDim}; line-height: 1.55; font-size: 14px; }
    .podswal-btn-confirm, .podswal-btn-cancel {
      font-family: ${theme.fontBody};
      font-weight: 600;
      letter-spacing: 0.04em;
      border-radius: 6px !important;
      padding: 10px 22px !important;
    }
    .podswal-btn-cancel { color: ${theme.fg} !important; }
    .podswal-input {
      background: ${theme.bgRaised} !important;
      border: 1px solid ${theme.border} !important;
      color: ${theme.fg} !important;
      box-shadow: none !important;
      font-family: ${theme.fontBody};
    }
    .podswal-input:focus { border-color: ${theme.primary} !important; }
    .swal2-icon.swal2-warning { border-color: ${theme.primary}; color: ${theme.primary}; }
    .swal2-icon.swal2-error   { border-color: ${theme.danger};  color: ${theme.danger}; }
    .swal2-icon.swal2-success { border-color: ${theme.success}; color: ${theme.success}; }
    .swal2-icon.swal2-question { border-color: ${theme.primary}; color: ${theme.primary}; }
    .swal2-icon.swal2-info     { border-color: ${theme.primary}; color: ${theme.primary}; }
    /* Toast variant */
    .podswal-toast { font-family: ${theme.fontBody}; }
    .podswal-toast .podswal-title { font-size: 13px; }
  `;
  document.head.appendChild(styleEl);

  const Toast = Swal.mixin({
    ...baseDefaults,
    toast: true,
    position: "top-end",
    showConfirmButton: false,
    timer: 3500,
    timerProgressBar: true,
    customClass: { ...baseDefaults.customClass, popup: "podswal-popup podswal-toast" },
  });

  const podSwal = {
    /** Quiet success/info notification at the top-right. */
    toast(text, kind = "info") {
      return Toast.fire({ icon: kind === "info" ? "success" : kind, title: text });
    },
    /** Modal "info" with OK button. Returns Promise. */
    info(text, title) {
      return Swal.fire({ ...baseDefaults, icon: "info", title: title || "Aviso", text });
    },
    /** Modal success. */
    success(text, title) {
      return Swal.fire({ ...baseDefaults, icon: "success", title: title || "✓", text });
    },
    /** Modal error. */
    error(text, title) {
      return Swal.fire({
        ...baseDefaults, icon: "error",
        confirmButtonColor: theme.danger,
        title: title || "Error", text,
      });
    },
    /** Yes/No confirm. Returns Promise<boolean>. */
    async confirm(text, opts = {}) {
      const r = await Swal.fire({
        ...baseDefaults,
        icon: opts.danger ? "warning" : "question",
        title: opts.title || "¿Estás seguro?",
        text,
        showCancelButton: true,
        confirmButtonText: opts.confirmText || (opts.danger ? "Sí, eliminar" : "Confirmar"),
        cancelButtonText:  opts.cancelText  || "Cancelar",
        confirmButtonColor: opts.danger ? theme.danger : theme.primary,
        focusCancel: !!opts.danger,
      });
      return !!r.isConfirmed;
    },
    /** Single text input. Returns Promise<string|null>. */
    async prompt(text, defaultValue = "", opts = {}) {
      const r = await Swal.fire({
        ...baseDefaults,
        icon: "question",
        title: opts.title || "Escribe un valor",
        text,
        input: opts.inputType || "text",
        inputValue: defaultValue || "",
        inputPlaceholder: opts.placeholder || "",
        showCancelButton: true,
        confirmButtonText: opts.confirmText || "Aceptar",
        cancelButtonText:  opts.cancelText  || "Cancelar",
        inputValidator: opts.validator,
      });
      return r.isConfirmed ? (r.value || "") : null;
    },
  };

  window.podSwal = podSwal;
})();
