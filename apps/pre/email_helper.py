"""
SMTP email sender for thePod. All emails use the branded table-based
HTML template designed by Claude Design — same letterhead + footer across
RSVP invitations, pre-recording prep, host invitations, and future types.

Reads SMTP config from `~/.podpod/config.json` under an `smtp` key.
"""

from __future__ import annotations

import html as html_mod
import logging
import smtplib
import ssl
from email.message import EmailMessage
from typing import Optional

from shared_config import load_shared_config


_log = logging.getLogger(__name__)


def _smtp_config():
    cfg = load_shared_config()
    smtp = cfg.get("smtp") or {}
    if not smtp.get("host") or not smtp.get("user") or not smtp.get("password"):
        return None
    port = int(smtp.get("port") or 587)
    return {
        "host": str(smtp["host"]),
        "port": port,
        "user": str(smtp["user"]),
        "password": str(smtp["password"]),
        "from_email": str(smtp.get("from_email") or smtp["user"]),
        "from_name": str(smtp.get("from_name") or ""),
        "use_ssl": smtp.get("use_ssl", port == 465),
        "use_tls": smtp.get("use_tls", port == 587),
    }


def is_configured() -> bool:
    return _smtp_config() is not None


def _public_base_url() -> str:
    cfg = load_shared_config()
    base = (cfg.get("prepod_url") or "").rstrip("/")
    return base


def _format_when(scheduled_at: str | None, scheduled_date: str | None) -> str:
    return (scheduled_at or scheduled_date or "Sin fecha aún").replace("T", " ")


def _esc(s: str) -> str:
    return html_mod.escape(str(s)) if s else ""


# ---------------------------------------------------------------------------
# Branded base template (Claude Design — thePod invitation email style)
# ---------------------------------------------------------------------------

def _base_html(
    *,
    preheader: str,
    meta_label: str,
    accent_color: str = "#5a8bff",
    body_html: str,
    footer_extra: str = "",
) -> str:
    """Wrap body_html in the full thePod branded email shell.

    accent_color: top strip color (podcast brand color, defaults to blue).
    meta_label: top-right label in the letterhead (e.g. "Invitación", "Preparación").
    preheader: hidden text that appears in inbox preview.
    body_html: the inner content (goes inside the white card after the accent strip).
    footer_extra: optional line below the standard footer.
    """
    return f"""\
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" lang="es">
<head>
  <meta http-equiv="Content-Type" content="text/html; charset=UTF-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <meta name="x-apple-disable-message-reformatting" />
  <meta name="color-scheme" content="light" />
  <meta name="supported-color-schemes" content="light" />
  <!--[if mso]>
  <style type="text/css">
    table, td, div, h1, p {{font-family: Arial, sans-serif !important;}}
  </style>
  <![endif]-->
</head>
<body style="margin:0;padding:0;background-color:#f4f1ea;-webkit-text-size-adjust:100%;-ms-text-size-adjust:100%;">

  <div style="display:none;font-size:1px;color:#f4f1ea;line-height:1px;max-height:0;max-width:0;opacity:0;overflow:hidden;mso-hide:all;">
    {_esc(preheader)}
  </div>

  <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="background-color:#f4f1ea;">
    <tr>
      <td align="center" style="padding:32px 16px;">

        <!-- LETTERHEAD -->
        <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="600" style="max-width:600px;width:100%;">
          <tr>
            <td style="padding:0 8px 16px 8px;font-family:Georgia, 'Times New Roman', serif;color:#1a1511;">
              <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">
                <tr>
                  <td align="left" style="font-family:Georgia, 'Times New Roman', serif;font-size:20px;line-height:1;color:#1a1511;letter-spacing:-0.01em;">
                    <span style="font-style:italic;font-weight:400;color:#554632;">the</span><span style="font-weight:700;color:#1a1511;">Pod</span>
                    <span style="display:inline-block;width:6px;height:6px;background-color:#5a8bff;border-radius:50%;margin-left:4px;vertical-align:middle;">&nbsp;</span>
                  </td>
                  <td align="right" style="font-family:'Courier New', Courier, monospace;font-size:11px;color:#8a7d65;letter-spacing:0.05em;text-transform:uppercase;">
                    {_esc(meta_label)}
                  </td>
                </tr>
              </table>
            </td>
          </tr>

          <!-- CARD -->
          <tr>
            <td style="background-color:#ffffff;border:1px solid #e6dfd1;border-radius:12px;overflow:hidden;">
              <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">
                <tr><td height="4" style="background-color:{accent_color};line-height:4px;font-size:0;">&nbsp;</td></tr>
              </table>

{body_html}

            </td>
          </tr>

          <!-- FOOTER -->
          <tr>
            <td style="padding:24px 8px 8px 8px;">
              <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">
                <tr>
                  <td align="left" style="font-family:Arial, Helvetica, sans-serif;font-size:11px;color:#8a7d65;line-height:1.5;">
                    Enviado desde
                    <span style="font-family:Georgia, 'Times New Roman', serif;color:#1a1511;font-size:12px;">
                      <span style="font-style:italic;color:#554632;">the</span><span style="font-weight:700;">Pod</span>
                    </span>
                    &middot;
                    <a href="https://thepod.rtfb.space" target="_blank" style="color:#5a8bff;text-decoration:none;">thepod.rtfb.space</a>
                  </td>
                  <td align="right" style="font-family:'Courier New', Courier, monospace;font-size:10px;color:#a89a82;letter-spacing:0.05em;">
                    pre &middot; prod &middot; post
                  </td>
                </tr>
                <tr>
                  <td colspan="2" style="padding-top:12px;font-family:Arial, Helvetica, sans-serif;font-size:11px;color:#a89a82;line-height:1.55;">
                    {footer_extra}
                  </td>
                </tr>
              </table>
            </td>
          </tr>

        </table>

      </td>
    </tr>
  </table>

</body>
</html>"""


def _cta_button(url: str, label: str, color: str = "#1a1511") -> str:
    """Bulletproof CTA button (works in Outlook via VML)."""
    return f"""\
              <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">
                <tr>
                  <td align="center" style="padding:0 48px 16px 48px;">
                    <table role="presentation" cellpadding="0" cellspacing="0" border="0">
                      <tr>
                        <td align="center" bgcolor="{color}" style="background-color:{color};border-radius:8px;">
                          <!--[if mso]>
                          <v:roundrect xmlns:v="urn:schemas-microsoft-com:vml" xmlns:w="urn:schemas-microsoft-com:office:word" href="{_esc(url)}" style="height:48px;v-text-anchor:middle;width:280px;" arcsize="17%" stroke="f" fillcolor="{color}">
                            <w:anchorlock/>
                            <center style="color:#ffffff;font-family:Arial, sans-serif;font-size:15px;font-weight:bold;letter-spacing:0.02em;">{_esc(label)}</center>
                          </v:roundrect>
                          <![endif]-->
                          <!--[if !mso]><!-- -->
                          <a href="{_esc(url)}" target="_blank" style="display:inline-block;padding:14px 36px;font-family:Arial, Helvetica, sans-serif;font-size:15px;font-weight:700;color:#ffffff;text-decoration:none;background-color:{color};border-radius:8px;letter-spacing:0.02em;mso-hide:all;">
                            {_esc(label)}
                          </a>
                          <!--<![endif]-->
                        </td>
                      </tr>
                    </table>
                  </td>
                </tr>
                <tr>
                  <td align="center" style="padding:0 48px 40px 48px;font-family:Arial, Helvetica, sans-serif;font-size:12px;color:#8a7d65;">
                    O copia este enlace en tu navegador:<br />
                    <a href="{_esc(url)}" target="_blank" style="color:#5a8bff;text-decoration:underline;word-break:break-all;">{_esc(url)}</a>
                  </td>
                </tr>
              </table>"""


# ---------------------------------------------------------------------------
# Deliver helper
# ---------------------------------------------------------------------------

def _deliver(smtp: dict, msg: EmailMessage, to_email: str, *, extra: dict | None = None) -> dict:
    try:
        ctx = ssl.create_default_context()
        if smtp.get("use_ssl"):
            server = smtplib.SMTP_SSL(smtp["host"], smtp["port"], timeout=20, context=ctx)
        else:
            server = smtplib.SMTP(smtp["host"], smtp["port"], timeout=20)
            server.ehlo()
            if smtp.get("use_tls"):
                server.starttls(context=ctx)
                server.ehlo()
        with server:
            server.login(smtp["user"], smtp["password"])
            server.send_message(msg)
        out = {"ok": True, "sent_to": to_email}
        if extra:
            out.update(extra)
        return out
    except Exception as e:
        _log.warning("Email send failed to %s: %s", to_email, e)
        out = {"ok": False, "reason": "send_failed", "error": str(e)}
        if extra:
            out.update(extra)
        return out


def _build_and_send(
    *,
    smtp: dict,
    subject: str,
    to_email: str,
    to_name: str,
    text_body: str,
    html_body: str,
    ics_bytes: Optional[bytes] = None,
    ics_filename: str = "invitacion.ics",
    extra: dict | None = None,
) -> dict:
    msg = EmailMessage()
    msg["Subject"] = subject
    from_addr = (
        f"{smtp['from_name']} <{smtp['from_email']}>"
        if smtp["from_name"]
        else smtp["from_email"]
    )
    msg["From"] = from_addr
    msg["To"] = f"{to_name} <{to_email}>" if to_name else to_email
    msg.set_content(text_body)
    msg.add_alternative(html_body, subtype="html")
    if ics_bytes:
        msg.add_attachment(
            ics_bytes,
            maintype="text",
            subtype="calendar",
            filename=ics_filename,
            params={"method": "REQUEST", "charset": "utf-8"},
        )
    return _deliver(smtp, msg, to_email, extra=extra)


# ---------------------------------------------------------------------------
# RSVP invitation email
# ---------------------------------------------------------------------------

def send_rsvp_email(
    *,
    to_email: str,
    to_name: str,
    podcast_name: str,
    episode_title: str,
    episode_number: Optional[int],
    scheduled_at: Optional[str],
    scheduled_date: Optional[str],
    duration_estimate: Optional[float],
    description: str,
    rsvp_token: str,
    ics_bytes: Optional[bytes],
) -> dict:
    base = _public_base_url()
    rsvp_url = f"{base}/rsvp/{rsvp_token}" if base else f"/rsvp/{rsvp_token}"

    smtp = _smtp_config()
    if not smtp:
        return {"ok": False, "reason": "no_smtp", "rsvp_url": rsvp_url}

    when_str = _format_when(scheduled_at, scheduled_date)
    duration_str = f"~{int(duration_estimate)} min" if duration_estimate else ""
    title_line = (
        f"Ep {episode_number}: {episode_title}" if episode_number else episode_title
    )

    text_body = (
        f"Hola {to_name},\n\n"
        f"Te invitamos a participar en un episodio de {podcast_name}.\n\n"
        f"  {title_line}\n"
        f"  Cuándo: {when_str}{(' · ' + duration_str) if duration_str else ''}\n\n"
        f"{description.strip()}\n\n"
        f"Por favor confirma tu disponibilidad acá:\n"
        f"  {rsvp_url}\n\n"
        f"Adjuntamos el evento de calendario.\n\n"
        f"— {podcast_name}\n"
    )

    inner = f"""\
              <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">
                <tr>
                  <td style="padding:40px 48px 16px 48px;font-family:Georgia, 'Times New Roman', serif;">
                    <p style="margin:0 0 24px 0;font-family:'Courier New', Courier, monospace;font-size:11px;color:#8a7d65;letter-spacing:0.12em;text-transform:uppercase;">
                      {_esc(podcast_name)} &middot; Invitación
                    </p>
                    <p style="margin:0 0 8px 0;font-family:Arial, Helvetica, sans-serif;font-size:15px;line-height:1.5;color:#554632;">
                      Hola {_esc(to_name)},
                    </p>
                    <h1 style="margin:0 0 16px 0;font-family:Georgia, 'Times New Roman', serif;font-size:28px;line-height:1.2;font-weight:400;color:#1a1511;letter-spacing:-0.01em;">
                      <span style="font-style:italic;color:#8a7d65;">Te invitaron a participar en</span><br />
                      <span style="font-weight:700;">{_esc(title_line)}</span>
                    </h1>
                    <p style="margin:0 0 8px 0;font-family:Arial, Helvetica, sans-serif;font-size:15px;line-height:1.55;color:#554632;">
                      <strong style="color:#1a1511;">Cuándo:</strong> {_esc(when_str)}{(' &middot; ' + _esc(duration_str)) if duration_str else ''}
                    </p>
                    {"<p style='margin:0 0 32px 0;font-family:Arial, Helvetica, sans-serif;font-size:14px;line-height:1.55;color:#554632;white-space:pre-wrap;'>" + _esc(description.strip()) + "</p>" if description.strip() else "<div style='height:16px;'></div>"}
                  </td>
                </tr>
              </table>

{_cta_button(rsvp_url, "Responder a la invitación")}"""

    html_body = _base_html(
        preheader=f"Te invitaron a {title_line} en {podcast_name}",
        meta_label="Invitación",
        accent_color="#5a8bff",
        body_html=inner,
        footer_extra=f"Recibiste este correo porque te invitaron a participar en un episodio de {_esc(podcast_name)}. Si no esperabas esta invitación, puedes ignorar este mensaje.",
    )

    return _build_and_send(
        smtp=smtp,
        subject=f"{podcast_name} · {title_line}",
        to_email=to_email,
        to_name=to_name,
        text_body=text_body,
        html_body=html_body,
        ics_bytes=ics_bytes,
        ics_filename="invitacion.ics",
        extra={"rsvp_url": rsvp_url},
    )


# ---------------------------------------------------------------------------
# Pre-recording preparation email
# ---------------------------------------------------------------------------

def send_pre_recording_email(
    *,
    to_email: str,
    to_name: str,
    podcast_name: str,
    episode_title: str,
    episode_number: Optional[int],
    scheduled_at: Optional[str],
    scheduled_date: Optional[str],
    duration_estimate: Optional[float],
    recording_url: Optional[str],
    rundown: list[dict],
    ics_bytes: Optional[bytes],
) -> dict:
    smtp = _smtp_config()
    if not smtp:
        return {"ok": False, "reason": "no_smtp"}

    when_str = _format_when(scheduled_at, scheduled_date)
    duration_str = f"~{int(duration_estimate)} min" if duration_estimate else ""
    title_line = (
        f"Ep {episode_number}: {episode_title}" if episode_number else episode_title
    )

    # --- plain text ---
    rundown_text = ""
    if rundown:
        lines = []
        for b in rundown:
            dur = f" ({int(b['duration_estimate'])} min)" if b.get("duration_estimate") else ""
            lines.append(f"  · {b.get('title') or b.get('kind', '?')}{dur}")
        rundown_text = "\nOrden del episodio:\n" + "\n".join(lines) + "\n"

    rec_text = f"\nEnlace de grabación:\n  {recording_url}\n" if recording_url else ""

    text_body = (
        f"Hola {to_name},\n\n"
        f"Estos son los preparativos para tu participación en {podcast_name}.\n\n"
        f"  {title_line}\n"
        f"  Cuándo: {when_str}{(' · ' + duration_str) if duration_str else ''}\n"
        f"{rundown_text}"
        f"{rec_text}\n"
        f"Recomendaciones:\n"
        f"  · Usa auriculares con micrófono\n"
        f"  · Busca un lugar silencioso con buena iluminación\n"
        f"  · Usa Chrome o Edge para mejor compatibilidad\n"
        f"  · Conecta unos minutos antes para probar audio y video\n\n"
        f"— {podcast_name}\n"
    )

    # --- rundown HTML ---
    rundown_html = ""
    if rundown:
        html_rows = []
        for b in rundown:
            dur = f"{int(b['duration_estimate'])} min" if b.get("duration_estimate") else ""
            html_rows.append(
                f'<tr><td style="padding:6px 10px;border-bottom:1px solid #ede5d3;font-family:Arial,Helvetica,sans-serif;font-size:13px;color:#1a1511;">{_esc(b.get("title") or b.get("kind","—"))}</td>'
                f'<td style="padding:6px 10px;border-bottom:1px solid #ede5d3;font-family:Arial,Helvetica,sans-serif;font-size:13px;color:#8a7d65;text-align:right;">{_esc(dur)}</td></tr>'
            )
        rundown_html = (
            '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="margin:16px 0;">'
            '<tr><td colspan="2" style="padding:0 0 8px 0;font-family:\'Courier New\', Courier, monospace;font-size:10px;color:#8a7d65;letter-spacing:0.12em;text-transform:uppercase;">Orden del episodio</td></tr>'
            + "".join(html_rows)
            + "</table>"
        )

    rec_html = _cta_button(recording_url, "Entrar a la sala de grabación") if recording_url else ""

    inner = f"""\
              <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">
                <tr>
                  <td style="padding:40px 48px 16px 48px;font-family:Georgia, 'Times New Roman', serif;">
                    <p style="margin:0 0 24px 0;font-family:'Courier New', Courier, monospace;font-size:11px;color:#8a7d65;letter-spacing:0.12em;text-transform:uppercase;">
                      {_esc(podcast_name)} &middot; Preparación
                    </p>
                    <p style="margin:0 0 8px 0;font-family:Arial, Helvetica, sans-serif;font-size:15px;line-height:1.5;color:#554632;">
                      Hola {_esc(to_name)},
                    </p>
                    <h1 style="margin:0 0 16px 0;font-family:Georgia, 'Times New Roman', serif;font-size:28px;line-height:1.2;font-weight:400;color:#1a1511;letter-spacing:-0.01em;">
                      <span style="font-style:italic;color:#8a7d65;">Preparativos para</span><br />
                      <span style="font-weight:700;">{_esc(title_line)}</span>
                    </h1>
                    <p style="margin:0 0 24px 0;font-family:Arial, Helvetica, sans-serif;font-size:15px;line-height:1.55;color:#554632;">
                      <strong style="color:#1a1511;">Cuándo:</strong> {_esc(when_str)}{(' &middot; ' + _esc(duration_str)) if duration_str else ''}
                    </p>
                    {rundown_html}
                  </td>
                </tr>
              </table>

{rec_html}

              <!-- Recommendations -->
              <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border-top:1px solid #ede5d3;">
                <tr>
                  <td style="padding:24px 48px;font-family:Arial, Helvetica, sans-serif;">
                    <p style="margin:0 0 12px 0;font-family:'Courier New', Courier, monospace;font-size:10px;color:#8a7d65;letter-spacing:0.12em;text-transform:uppercase;">
                      Recomendaciones
                    </p>
                    <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">
                      <tr><td style="padding:3px 0;font-size:13px;color:#554632;">· Usa auriculares con micrófono</td></tr>
                      <tr><td style="padding:3px 0;font-size:13px;color:#554632;">· Busca un lugar silencioso con buena iluminación</td></tr>
                      <tr><td style="padding:3px 0;font-size:13px;color:#554632;">· Usa Chrome o Edge para mejor compatibilidad</td></tr>
                      <tr><td style="padding:3px 0;font-size:13px;color:#554632;">· Conecta unos minutos antes para probar audio y video</td></tr>
                    </table>
                  </td>
                </tr>
              </table>"""

    html_body = _base_html(
        preheader=f"Preparación para {title_line} en {podcast_name}",
        meta_label="Preparación",
        accent_color="#ff3b3b",
        body_html=inner,
        footer_extra=f"Recibiste este correo porque participas en un episodio de {_esc(podcast_name)}.",
    )

    return _build_and_send(
        smtp=smtp,
        subject=f"{podcast_name} · Preparación: {title_line}",
        to_email=to_email,
        to_name=to_name,
        text_body=text_body,
        html_body=html_body,
        ics_bytes=ics_bytes,
        ics_filename="grabacion.ics",
    )


# ---------------------------------------------------------------------------
# Host invitation email
# ---------------------------------------------------------------------------

def send_host_invitation_email(
    *,
    to_email: str,
    host_name: str,
    inviter_name: str,
    podcast_name: str,
    podcast_color: str = "#5a8bff",
    podcast_logo_url: str = "",
    action_url: str,
) -> dict:
    smtp = _smtp_config()
    if not smtp:
        return {"ok": False, "reason": "no_smtp", "action_url": action_url}

    text_body = (
        f"Hola {host_name},\n\n"
        f"{inviter_name} te invitó como Host de {podcast_name}.\n\n"
        f"Como host vas a poder planear episodios, grabar en vivo con invitados "
        f"y publicar los clips finales.\n\n"
        f"Acepta la invitación acá:\n  {action_url}\n\n"
        f"— thePod\n"
    )

    logo_cell = ""
    if podcast_logo_url:
        logo_cell = f"""\
                        <td width="64" style="padding:16px 0 16px 16px;vertical-align:middle;">
                          <table role="presentation" cellpadding="0" cellspacing="0" border="0">
                            <tr>
                              <td width="56" height="56" align="center" valign="middle" style="background-color:{podcast_color};border-radius:8px;width:56px;height:56px;">
                                <img src="{_esc(podcast_logo_url)}" alt="" width="56" height="56" style="display:block;border:0;outline:none;text-decoration:none;border-radius:8px;width:56px;height:56px;" />
                              </td>
                            </tr>
                          </table>
                        </td>"""
    else:
        logo_cell = f"""\
                        <td width="64" style="padding:16px 0 16px 16px;vertical-align:middle;">
                          <table role="presentation" cellpadding="0" cellspacing="0" border="0">
                            <tr>
                              <td width="56" height="56" align="center" valign="middle" style="background-color:{podcast_color};border-radius:8px;width:56px;height:56px;font-family:Georgia,'Times New Roman',serif;font-size:24px;font-weight:700;color:#ffffff;">
                                {_esc(podcast_name[:1].upper())}
                              </td>
                            </tr>
                          </table>
                        </td>"""

    inner = f"""\
              <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">
                <tr>
                  <td style="padding:40px 48px 16px 48px;font-family:Georgia, 'Times New Roman', serif;">
                    <p style="margin:0 0 24px 0;font-family:'Courier New', Courier, monospace;font-size:11px;color:#8a7d65;letter-spacing:0.12em;text-transform:uppercase;">
                      Nueva invitación &middot; Host
                    </p>
                    <p style="margin:0 0 8px 0;font-family:Arial, Helvetica, sans-serif;font-size:15px;line-height:1.5;color:#554632;">
                      Hola {_esc(host_name)},
                    </p>
                    <h1 style="margin:0 0 16px 0;font-family:Georgia, 'Times New Roman', serif;font-size:30px;line-height:1.2;font-weight:400;color:#1a1511;letter-spacing:-0.01em;">
                      <span style="font-style:italic;color:#8a7d65;">Te invitaron como</span><br />
                      <span style="font-weight:700;">Host de {_esc(podcast_name)}.</span>
                    </h1>
                    <p style="margin:0 0 32px 0;font-family:Arial, Helvetica, sans-serif;font-size:15px;line-height:1.55;color:#554632;">
                      <strong style="color:#1a1511;font-weight:600;">{_esc(inviter_name)}</strong> te sumó al equipo. Como host vas a poder planear episodios, grabar en vivo con invitados y publicar los clips finales.
                    </p>
                  </td>
                </tr>
              </table>

              <!-- Podcast card -->
              <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">
                <tr>
                  <td style="padding:0 48px 32px 48px;">
                    <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="background-color:#faf7f0;border:1px solid #ede5d3;border-radius:8px;">
                      <tr>
{logo_cell}
                        <td style="padding:16px;vertical-align:middle;font-family:Arial, Helvetica, sans-serif;">
                          <p style="margin:0 0 4px 0;font-family:'Courier New', Courier, monospace;font-size:10px;color:#8a7d65;letter-spacing:0.12em;text-transform:uppercase;">
                            Podcast
                          </p>
                          <p style="margin:0 0 2px 0;font-family:Georgia, 'Times New Roman', serif;font-size:18px;line-height:1.2;font-weight:700;color:#1a1511;">
                            {_esc(podcast_name)}
                          </p>
                          <p style="margin:0;font-family:Arial, Helvetica, sans-serif;font-size:13px;color:#8a7d65;">
                            Tu rol: <span style="color:#1a1511;font-weight:600;">Host</span>
                          </p>
                        </td>
                        <td width="48" align="right" style="padding:0 20px 0 0;vertical-align:middle;">
                          <table role="presentation" cellpadding="0" cellspacing="0" border="0">
                            <tr>
                              <td width="8" height="8" style="background-color:{podcast_color};border-radius:50%;width:8px;height:8px;line-height:8px;font-size:0;">&nbsp;</td>
                            </tr>
                          </table>
                        </td>
                      </tr>
                    </table>
                  </td>
                </tr>
              </table>

{_cta_button(action_url, "Aceptar invitación")}

              <!-- Flow hint -->
              <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border-top:1px solid #ede5d3;">
                <tr>
                  <td style="padding:24px 48px;font-family:Arial, Helvetica, sans-serif;">
                    <p style="margin:0 0 12px 0;font-family:'Courier New', Courier, monospace;font-size:10px;color:#8a7d65;letter-spacing:0.12em;text-transform:uppercase;">
                      Qué sigue
                    </p>
                    <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">
                      <tr>
                        <td width="33%" valign="top" style="padding-right:8px;">
                          <p style="margin:0 0 4px 0;font-family:Georgia, 'Times New Roman', serif;font-size:13px;font-weight:700;color:#5a8bff;">
                            01 &middot; prePod
                          </p>
                          <p style="margin:0;font-family:Arial, Helvetica, sans-serif;font-size:12px;line-height:1.45;color:#554632;">
                            Planeas el episodio, armas el guion y agendas a los invitados.
                          </p>
                        </td>
                        <td width="34%" valign="top" style="padding:0 8px;">
                          <p style="margin:0 0 4px 0;font-family:Georgia, 'Times New Roman', serif;font-size:13px;font-weight:700;color:#ff3b3b;">
                            02 &middot; prodPod
                          </p>
                          <p style="margin:0;font-family:Arial, Helvetica, sans-serif;font-size:12px;line-height:1.45;color:#554632;">
                            Grabas en vivo con cámara automática y soundboard.
                          </p>
                        </td>
                        <td width="33%" valign="top" style="padding-left:8px;">
                          <p style="margin:0 0 4px 0;font-family:Georgia, 'Times New Roman', serif;font-size:13px;font-weight:700;color:#c89548;">
                            03 &middot; postPod
                          </p>
                          <p style="margin:0;font-family:Arial, Helvetica, sans-serif;font-size:12px;line-height:1.45;color:#554632;">
                            Marcas momentos y exportas clips para TikTok, Reels y Shorts.
                          </p>
                        </td>
                      </tr>
                    </table>
                  </td>
                </tr>
              </table>"""

    html_body = _base_html(
        preheader=f"{inviter_name} te invitó como Host de {podcast_name}. Acepta la invitación para empezar.",
        meta_label="Invitación",
        accent_color=podcast_color,
        body_html=inner,
        footer_extra=f"Recibiste este correo porque {_esc(inviter_name)} te invitó a colaborar en {_esc(podcast_name)}. Si no esperabas esta invitación, puedes ignorar este mensaje.",
    )

    return _build_and_send(
        smtp=smtp,
        subject=f"Te invitaron a {podcast_name}",
        to_email=to_email,
        to_name=host_name,
        text_body=text_body,
        html_body=html_body,
        extra={"action_url": action_url},
    )


# ---------------------------------------------------------------------------
# Password reset email
# ---------------------------------------------------------------------------

def send_password_reset_email(
    *,
    to_email: str,
    display_name: str,
    reset_url: str,
) -> dict:
    smtp = _smtp_config()
    if not smtp:
        return {"ok": False, "reason": "no_smtp"}

    text_body = (
        f"Hola {display_name},\n\n"
        f"Recibimos una solicitud para restablecer tu contraseña en thePod.\n\n"
        f"Usa este enlace para crear una nueva contraseña:\n"
        f"  {reset_url}\n\n"
        f"El enlace expira en 1 hora.\n\n"
        f"Si no solicitaste esto, puedes ignorar este mensaje.\n\n"
        f"— thePod\n"
    )

    inner = f"""\
              <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">
                <tr>
                  <td style="padding:40px 48px 16px 48px;font-family:Georgia, 'Times New Roman', serif;">
                    <p style="margin:0 0 24px 0;font-family:'Courier New', Courier, monospace;font-size:11px;color:#8a7d65;letter-spacing:0.12em;text-transform:uppercase;">
                      Restablecer contraseña
                    </p>
                    <p style="margin:0 0 8px 0;font-family:Arial, Helvetica, sans-serif;font-size:15px;line-height:1.5;color:#554632;">
                      Hola {_esc(display_name)},
                    </p>
                    <h1 style="margin:0 0 16px 0;font-family:Georgia, 'Times New Roman', serif;font-size:28px;line-height:1.2;font-weight:400;color:#1a1511;letter-spacing:-0.01em;">
                      <span style="font-style:italic;color:#8a7d65;">Solicitud para</span><br />
                      <span style="font-weight:700;">restablecer tu contraseña.</span>
                    </h1>
                    <p style="margin:0 0 32px 0;font-family:Arial, Helvetica, sans-serif;font-size:15px;line-height:1.55;color:#554632;">
                      Recibimos una solicitud para cambiar tu contraseña. Haz clic en el botón de abajo para crear una nueva. El enlace expira en <strong style="color:#1a1511;">1 hora</strong>.
                    </p>
                  </td>
                </tr>
              </table>

{_cta_button(reset_url, "Restablecer contraseña")}"""

    html_body = _base_html(
        preheader="Restablece tu contraseña en thePod",
        meta_label="Seguridad",
        accent_color="#5a8bff",
        body_html=inner,
        footer_extra="Recibiste este correo porque alguien solicitó restablecer la contraseña de tu cuenta en thePod. Si no fuiste tú, puedes ignorar este mensaje.",
    )

    return _build_and_send(
        smtp=smtp,
        subject="thePod · Restablecer contraseña",
        to_email=to_email,
        to_name=display_name,
        text_body=text_body,
        html_body=html_body,
    )


def send_signup_confirm_email(
    *,
    to_email: str,
    display_name: str,
    confirm_url: str,
) -> dict:
    smtp = _smtp_config()
    if not smtp:
        return {"ok": False, "reason": "no_smtp"}

    text_body = (
        f"Hola {display_name},\n\n"
        f"Gracias por registrarte en thePod.\n\n"
        f"Abre este enlace para activar tu cuenta:\n"
        f"  {confirm_url}\n\n"
        f"El enlace vence en 24 horas.\n\n"
        f"Si no te registraste, puedes ignorar este mensaje.\n\n"
        f"— thePod\n"
    )

    inner = f"""\
              <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">
                <tr>
                  <td style="padding:40px 48px 16px 48px;font-family:Georgia, 'Times New Roman', serif;">
                    <p style="margin:0 0 24px 0;font-family:'Courier New', Courier, monospace;font-size:11px;color:#8a7d65;letter-spacing:0.12em;text-transform:uppercase;">
                      Activa tu cuenta
                    </p>
                    <p style="margin:0 0 8px 0;font-family:Arial, Helvetica, sans-serif;font-size:15px;line-height:1.5;color:#554632;">
                      Hola {_esc(display_name)},
                    </p>
                    <h1 style="margin:0 0 16px 0;font-family:Georgia, 'Times New Roman', serif;font-size:28px;line-height:1.2;font-weight:400;color:#1a1511;letter-spacing:-0.01em;">
                      <span style="font-style:italic;color:#8a7d65;">Ya casi:</span><br />
                      <span style="font-weight:700;">confirma tu correo.</span>
                    </h1>
                    <p style="margin:0 0 32px 0;font-family:Arial, Helvetica, sans-serif;font-size:15px;line-height:1.55;color:#554632;">
                      Toca el botón para activar tu cuenta de thePod. El enlace vence en <strong style="color:#1a1511;">24 horas</strong>.
                    </p>
                  </td>
                </tr>
              </table>

{_cta_button(confirm_url, "Activar mi cuenta")}"""

    html_body = _base_html(
        preheader="Activa tu cuenta de thePod",
        meta_label="Bienvenida",
        accent_color="#5a8bff",
        body_html=inner,
        footer_extra="Recibiste este correo porque alguien se registró en thePod con esta dirección. Si no fuiste tú, ignora este mensaje: sin confirmar no se crea ninguna cuenta.",
    )

    return _build_and_send(
        smtp=smtp,
        subject="thePod · Activa tu cuenta",
        to_email=to_email,
        to_name=display_name,
        text_body=text_body,
        html_body=html_body,
    )
