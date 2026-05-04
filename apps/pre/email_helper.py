"""
Optional SMTP email sender for RSVP invitations.

Reads SMTP config from `~/.podpod/config.json` under an `smtp` key:
    {
      "smtp": {
        "host": "smtp.example.com",
        "port": 587,
        "user": "you@example.com",
        "password": "...",
        "from_email": "you@example.com",   (optional — defaults to user)
        "from_name":  "Tu Podcast",        (optional)
        "use_tls": true                    (optional — defaults to true)
      }
    }

If no SMTP block is present, `send_rsvp_email` returns a structured
"no_smtp" result so the caller (UI or API) can fall back to a copy-link
flow without raising. We do not want to invent an SMTP relay; we just
report cleanly.
"""

from __future__ import annotations

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
    """Returns one of:
        {"ok": True,  "sent_to": "...",            "rsvp_url": "..."}
        {"ok": False, "reason": "no_smtp",         "rsvp_url": "..."}
        {"ok": False, "reason": "send_failed",     "rsvp_url": "...", "error": "..."}
    The caller is expected to surface `rsvp_url` to the user when ok is
    False so they can paste it manually. We never raise.
    """
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

    html_body = f"""\
<!doctype html>
<html><body style="font-family: -apple-system, 'Segoe UI', sans-serif; color: #1a1a1a; line-height: 1.5;">
  <div style="max-width: 540px; margin: 0 auto; padding: 24px;">
    <div style="font-size: 11px; letter-spacing: 0.18em; text-transform: uppercase; color: #666;">
      {podcast_name} · invitación
    </div>
    <h1 style="margin: 8px 0 4px; font-size: 22px;">{title_line}</h1>
    <div style="color: #555; margin-bottom: 18px;">
      <strong>Cuándo:</strong> {when_str}{(' · ' + duration_str) if duration_str else ''}
    </div>
    <p>Hola <strong>{to_name}</strong>, te invitamos a participar en este episodio.</p>
    {f'<p style="white-space: pre-wrap;">{description}</p>' if description.strip() else ''}
    <p style="margin: 28px 0;">
      <a href="{rsvp_url}"
         style="display: inline-block; padding: 12px 22px; border-radius: 8px;
                background: #5a8bff; color: #fff; text-decoration: none; font-weight: 600;">
        Responder a la invitación
      </a>
    </p>
    <p style="font-size: 12px; color: #888;">
      Si el botón no funciona, copia este link: <br>
      <a href="{rsvp_url}" style="color: #5a8bff;">{rsvp_url}</a>
    </p>
    <p style="font-size: 11px; color: #aaa; margin-top: 32px;">— {podcast_name}</p>
  </div>
</body></html>
"""

    msg = EmailMessage()
    msg["Subject"] = f"{podcast_name} · {title_line}"
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
            filename="invitacion.ics",
            params={"method": "REQUEST", "charset": "utf-8"},
        )

    return _deliver(smtp, msg, to_email, extra={"rsvp_url": rsvp_url})


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

    rundown_text = ""
    rundown_html = ""
    if rundown:
        lines = []
        html_rows = []
        for b in rundown:
            dur = f" ({int(b['duration_estimate'])} min)" if b.get("duration_estimate") else ""
            lines.append(f"  • {b.get('title') or b.get('kind', '?')}{dur}")
            html_rows.append(
                f'<tr><td style="padding:4px 8px;border-bottom:1px solid #eee;">{b.get("title") or b.get("kind","—")}</td>'
                f'<td style="padding:4px 8px;border-bottom:1px solid #eee;color:#888;">{dur.strip(" ()")}</td></tr>'
            )
        rundown_text = "\nOrden del episodio:\n" + "\n".join(lines) + "\n"
        rundown_html = (
            '<div style="margin:16px 0;">'
            '<div style="font-size:11px;letter-spacing:0.12em;text-transform:uppercase;color:#888;margin-bottom:6px;">Orden del episodio</div>'
            '<table style="width:100%;border-collapse:collapse;font-size:14px;">'
            + "".join(html_rows)
            + "</table></div>"
        )

    rec_text = f"\nEnlace de grabación:\n  {recording_url}\n" if recording_url else ""
    rec_html = (
        f'<p style="margin:20px 0;"><a href="{recording_url}" '
        f'style="display:inline-block;padding:12px 22px;border-radius:8px;'
        f'background:#5a8bff;color:#fff;text-decoration:none;font-weight:600;">'
        f'Entrar a la sala de grabación</a></p>'
        if recording_url else ""
    )

    text_body = (
        f"Hola {to_name},\n\n"
        f"Estos son los preparativos para tu participación en {podcast_name}.\n\n"
        f"  {title_line}\n"
        f"  Cuándo: {when_str}{(' · ' + duration_str) if duration_str else ''}\n"
        f"{rundown_text}"
        f"{rec_text}\n"
        f"Recomendaciones:\n"
        f"  • Usa auriculares con micrófono\n"
        f"  • Busca un lugar silencioso con buena iluminación\n"
        f"  • Usa Chrome o Edge para mejor compatibilidad\n"
        f"  • Conecta unos minutos antes para probar audio y video\n\n"
        f"— {podcast_name}\n"
    )

    html_body = f"""\
<!doctype html>
<html><body style="font-family: -apple-system, 'Segoe UI', sans-serif; color: #1a1a1a; line-height: 1.5;">
  <div style="max-width: 540px; margin: 0 auto; padding: 24px;">
    <div style="font-size: 11px; letter-spacing: 0.18em; text-transform: uppercase; color: #666;">
      {podcast_name} · preparación
    </div>
    <h1 style="margin: 8px 0 4px; font-size: 22px;">{title_line}</h1>
    <div style="color: #555; margin-bottom: 18px;">
      <strong>Cuándo:</strong> {when_str}{(' · ' + duration_str) if duration_str else ''}
    </div>
    <p>Hola <strong>{to_name}</strong>, estos son los preparativos para tu participación.</p>
    {rundown_html}
    {rec_html}
    <div style="background: #f7f7f9; border-radius: 8px; padding: 14px 18px; margin: 20px 0;">
      <div style="font-size: 11px; letter-spacing: 0.12em; text-transform: uppercase; color: #888; margin-bottom: 6px;">Recomendaciones</div>
      <ul style="margin: 0; padding-left: 18px; font-size: 14px; color: #444;">
        <li>Usa auriculares con micrófono</li>
        <li>Busca un lugar silencioso con buena iluminación</li>
        <li>Usa Chrome o Edge para mejor compatibilidad</li>
        <li>Conecta unos minutos antes para probar audio y video</li>
      </ul>
    </div>
    <p style="font-size: 11px; color: #aaa; margin-top: 32px;">— {podcast_name}</p>
  </div>
</body></html>
"""

    msg = EmailMessage()
    msg["Subject"] = f"{podcast_name} · Preparación: {title_line}"
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
            filename="grabacion.ics",
            params={"method": "REQUEST", "charset": "utf-8"},
        )

    return _deliver(smtp, msg, to_email)
