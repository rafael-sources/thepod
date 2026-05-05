"""
AI Engine — Core LLM module for postPod.

Handles all communication with the LLM via an OpenAI-SDK-compatible proxy
(claude-max-api-proxy running on localhost:3456).

Public API:
    analyze_episode(transcript_text, language) -> dict
    regenerate_notes(transcript_text, language)  -> dict
    regenerate_clips(transcript_text, language)  -> list
    ensure_ai_config()                           -> None
"""

import json
import re

from shared_config import SHARED_FILE, load_shared_config, update_shared_config

# ---------------------------------------------------------------------------
# Prompt constants (Spanish, instructing Claude to return structured JSON)
# ---------------------------------------------------------------------------

_SYSTEM_PROMPT = """Eres un asistente experto en producción de podcasts y videocasts.
Tu tarea es analizar la transcripción de un episodio y devolver un JSON estructurado
con dos secciones: notas del episodio y clips recomendados.

El JSON debe tener exactamente esta forma:
{
  "notes": {
    "summary": "<resumen del episodio en 2-4 párrafos>",
    "highlights": ["<punto destacado 1>", "<punto destacado 2>", ...]
  },
  "clips": [
    {
      "start": "MM:SS",
      "end": "MM:SS",
      "title": "<título corto del clip>",
      "reason": "<por qué este clip es interesante>",
      "type": "<anecdote|debate|tip|humor|insight|emotional>"
    }
  ]
}

Reglas importantes:
- Devuelve ÚNICAMENTE el JSON, sin texto adicional antes o después.
- Los timestamps deben estar en formato MM:SS o H:MM:SS.
- Cada clip debe durar entre 30 segundos y 3 minutos.
- Elige entre 3 y 8 clips por episodio.
- El resumen debe estar en el idioma indicado por el usuario.
- Los tipos de clip permitidos son: anecdote, debate, tip, humor, insight, emotional.
"""

_NOTES_ONLY_PROMPT = """Eres un asistente experto en producción de podcasts y videocasts.
Tu tarea es analizar la transcripción de un episodio y devolver ÚNICAMENTE las notas,
sin clips.

El JSON debe tener exactamente esta forma:
{
  "notes": {
    "summary": "<resumen del episodio en 2-4 párrafos>",
    "highlights": ["<punto destacado 1>", "<punto destacado 2>", ...]
  }
}

Reglas importantes:
- Devuelve ÚNICAMENTE el JSON, sin texto adicional antes o después.
- El resumen debe estar en el idioma indicado por el usuario.
"""

_CLIPS_ONLY_PROMPT = """Eres un asistente experto en producción de podcasts y videocasts.
Tu tarea es analizar la transcripción de un episodio y devolver ÚNICAMENTE los clips
recomendados para redes sociales, sin notas ni resumen.

El JSON debe tener exactamente esta forma:
{
  "clips": [
    {
      "start": "MM:SS",
      "end": "MM:SS",
      "title": "<título corto del clip>",
      "reason": "<por qué este clip es interesante>",
      "type": "<anecdote|debate|tip|humor|insight|emotional>"
    }
  ]
}

Reglas importantes:
- Devuelve ÚNICAMENTE el JSON, sin texto adicional antes o después.
- Los timestamps deben estar en formato MM:SS o H:MM:SS.
- Cada clip debe durar entre 30 segundos y 3 minutos.
- Elige entre 3 y 8 clips por episodio.
- Los tipos de clip permitidos son: anecdote, debate, tip, humor, insight, emotional.
"""

# ---------------------------------------------------------------------------
# Config helpers
# ---------------------------------------------------------------------------

_DEFAULT_AI_CONFIG = {
    "base_url": "http://127.0.0.1:3456/v1",
    "api_key": "not-needed",
    "model": "claude-sonnet-4",
}


def _get_ai_config() -> dict:
    """Read the 'ai' section from ~/.podpod/config.json.

    Raises:
        RuntimeError: if the 'ai' section is absent from the config.
    """
    cfg = load_shared_config()
    ai = cfg.get("ai")
    if not ai:
        raise RuntimeError(
            "Sección 'ai' no encontrada en ~/.podpod/config.json. "
            "Ejecuta ensure_ai_config() o añade la sección manualmente."
        )
    return ai


def ensure_ai_config() -> None:
    """Add default 'ai' section to shared config if not already present."""
    cfg = load_shared_config()
    if "ai" not in cfg:
        update_shared_config({"ai": _DEFAULT_AI_CONFIG})


# ---------------------------------------------------------------------------
# OpenAI client factory  (import deferred so the module loads without proxy)
# ---------------------------------------------------------------------------

def _get_client():
    """Create and return an OpenAI client configured from shared config."""
    try:
        from openai import OpenAI  # deferred — not needed at import time
    except ImportError as exc:
        raise RuntimeError(
            "El paquete 'openai' no está instalado. "
            "Ejecuta: pip install openai"
        ) from exc

    ai = _get_ai_config()
    return OpenAI(
        base_url=ai["base_url"],
        api_key=ai["api_key"],
    )


# ---------------------------------------------------------------------------
# Timestamp utilities
# ---------------------------------------------------------------------------

def _timestamp_to_seconds(ts: str) -> float:
    """Convert 'MM:SS' or 'H:MM:SS' string to total seconds.

    Args:
        ts: Timestamp string, e.g. '1:23' or '1:02:45'.

    Returns:
        Total seconds as a float.

    Raises:
        ValueError: if the string format is not recognised.
    """
    parts = ts.strip().split(":")
    if len(parts) == 2:
        minutes, seconds = parts
        return int(minutes) * 60 + float(seconds)
    elif len(parts) == 3:
        hours, minutes, seconds = parts
        return int(hours) * 3600 + int(minutes) * 60 + float(seconds)
    else:
        raise ValueError(f"Formato de timestamp no reconocido: '{ts}'")


def _seconds_to_timestamp(secs: float) -> str:
    """Convert total seconds to 'MM:SS' or 'H:MM:SS' string.

    Uses 'H:MM:SS' only when the duration is 1 hour or more.

    Args:
        secs: Total seconds (non-negative).

    Returns:
        Formatted timestamp string.
    """
    secs = int(secs)
    hours = secs // 3600
    minutes = (secs % 3600) // 60
    seconds = secs % 60
    if hours > 0:
        return f"{hours}:{minutes:02d}:{seconds:02d}"
    return f"{minutes:02d}:{seconds:02d}"


# ---------------------------------------------------------------------------
# Response parsing
# ---------------------------------------------------------------------------

def _parse_analysis_response(raw: str) -> dict:
    """Extract and parse JSON from an LLM response string.

    Handles plain JSON and responses wrapped in ```json ... ``` fences.

    Args:
        raw: Raw text returned by the LLM.

    Returns:
        Parsed dict.

    Raises:
        ValueError: if no valid JSON can be extracted.
    """
    # Try to strip markdown code fences (```json ... ``` or ``` ... ```)
    fence_match = re.search(r"```(?:json)?\s*([\s\S]*?)```", raw, re.IGNORECASE)
    candidate = fence_match.group(1).strip() if fence_match else raw.strip()

    try:
        return json.loads(candidate)
    except json.JSONDecodeError as exc:
        raise ValueError(
            f"No se pudo extraer JSON válido de la respuesta del LLM: {exc}"
        ) from exc


# ---------------------------------------------------------------------------
# LLM call
# ---------------------------------------------------------------------------

def _call_llm(system: str, user_text: str) -> str:
    """Make a single LLM call and return the raw text response.

    Args:
        system: System prompt string.
        user_text: User message (typically the transcript + language instruction).

    Returns:
        Raw text content of the assistant's reply.
    """
    ai = _get_ai_config()
    client = _get_client()
    response = client.chat.completions.create(
        model=ai.get("model", "claude-sonnet-4"),
        temperature=0.3,
        max_tokens=4096,
        messages=[
            {"role": "system", "content": system},
            {"role": "user", "content": user_text},
        ],
    )
    return response.choices[0].message.content


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def _build_user_message(transcript_text: str, language: str) -> str:
    lang_names = {"es": "español", "en": "inglés", "pt": "portugués"}
    lang_label = lang_names.get(language, language)
    return (
        f"Por favor analiza la siguiente transcripción. "
        f"Responde en {lang_label}.\n\n"
        f"TRANSCRIPCIÓN:\n{transcript_text}"
    )


def analyze_episode(transcript_text: str, language: str = "es") -> dict:
    """Perform full analysis: notes + clips.

    Args:
        transcript_text: Full transcript of the episode.
        language: ISO 639-1 language code for the response (default 'es').

    Returns:
        Dict with keys 'notes' and 'clips'.
    """
    user_text = _build_user_message(transcript_text, language)
    raw = _call_llm(_SYSTEM_PROMPT, user_text)
    return _parse_analysis_response(raw)


def regenerate_notes(transcript_text: str, language: str = "es") -> dict:
    """Re-generate only the notes section (summary + highlights).

    Args:
        transcript_text: Full transcript of the episode.
        language: ISO 639-1 language code for the response (default 'es').

    Returns:
        Dict with key 'notes'.
    """
    user_text = _build_user_message(transcript_text, language)
    raw = _call_llm(_NOTES_ONLY_PROMPT, user_text)
    return _parse_analysis_response(raw)


def regenerate_clips(transcript_text: str, language: str = "es") -> list:
    """Re-generate only the clips list.

    Args:
        transcript_text: Full transcript of the episode.
        language: ISO 639-1 language code for the response (default 'es').

    Returns:
        List of clip dicts (each with start, end, title, reason, type).
    """
    user_text = _build_user_message(transcript_text, language)
    raw = _call_llm(_CLIPS_ONLY_PROMPT, user_text)
    result = _parse_analysis_response(raw)
    return result.get("clips", [])
