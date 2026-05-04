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
    return {
        "host": str(smtp["host"]),
        "port": int(smtp.get("port") or 587),
        "user": str(smtp["user"]),
        "password": str(smtp["password"]),
        "from_email": str(smtp.get("from_email") or smtp["user"]),
        "from_name": str(smtp.get("from_name") or ""),
        "use_tls": smtp.get("use_tls", True) is not False,
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

    try:
        with smtplib.SMTP(smtp["host"], smtp["port"], timeout=20) as server:
            server.ehlo()
            if smtp["use_tls"]:
                server.starttls(context=ssl.create_default_context())
                server.ehlo()
            server.login(smtp["user"], smtp["password"])
            server.send_message(msg)
        return {"ok": True, "sent_to": to_email, "rsvp_url": rsvp_url}
    except Exception as e:
        _log.warning("RSVP email send failed: %s", e)
        return {
            "ok": False, "reason": "send_failed",
            "rsvp_url": rsvp_url, "error": str(e),
        }
