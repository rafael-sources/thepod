"""
Unit tests for ai_engine.py.

Covers: config loading, JSON parsing, timestamp conversions.
Does NOT make actual LLM calls — all tests are pure-function unit tests.
"""

import json
import sys
import tempfile
from pathlib import Path
from unittest import mock

import pytest

# Ensure project root is on sys.path so `import ai_engine` works from any cwd.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import ai_engine


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_config(ai_section=None):
    """Return a minimal shared-config dict, optionally including 'ai'."""
    cfg = {
        "secret_key": "test-secret",
        "integration_secret": "test-integration",
    }
    if ai_section is not None:
        cfg["ai"] = ai_section
    return cfg


_VALID_AI_SECTION = {
    "base_url": "http://127.0.0.1:3456/v1",
    "api_key": "not-needed",
    "model": "claude-sonnet-4",
}


# ---------------------------------------------------------------------------
# Config loading
# ---------------------------------------------------------------------------

class TestGetAiConfig:
    def test_returns_ai_section_when_present(self):
        cfg = _make_config(ai_section=_VALID_AI_SECTION)
        with mock.patch("ai_engine.load_shared_config", return_value=cfg):
            result = ai_engine._get_ai_config()
        assert result == _VALID_AI_SECTION

    def test_raises_runtime_error_when_ai_section_missing(self):
        cfg = _make_config()  # no 'ai' key
        with mock.patch("ai_engine.load_shared_config", return_value=cfg):
            with pytest.raises(RuntimeError, match="ai"):
                ai_engine._get_ai_config()

    def test_raises_runtime_error_when_ai_section_is_none(self):
        cfg = _make_config()
        cfg["ai"] = None
        with mock.patch("ai_engine.load_shared_config", return_value=cfg):
            with pytest.raises(RuntimeError):
                ai_engine._get_ai_config()

    def test_returns_correct_base_url(self):
        cfg = _make_config(ai_section=_VALID_AI_SECTION)
        with mock.patch("ai_engine.load_shared_config", return_value=cfg):
            result = ai_engine._get_ai_config()
        assert result["base_url"] == "http://127.0.0.1:3456/v1"

    def test_returns_correct_model(self):
        cfg = _make_config(ai_section=_VALID_AI_SECTION)
        with mock.patch("ai_engine.load_shared_config", return_value=cfg):
            result = ai_engine._get_ai_config()
        assert result["model"] == "claude-sonnet-4"


# ---------------------------------------------------------------------------
# JSON parsing
# ---------------------------------------------------------------------------

class TestParseAnalysisResponse:
    def test_parses_plain_json(self):
        data = {"notes": {"summary": "Test", "highlights": []}, "clips": []}
        raw = json.dumps(data)
        result = ai_engine._parse_analysis_response(raw)
        assert result == data

    def test_extracts_from_json_fence(self):
        data = {"clips": [{"start": "01:00", "end": "02:00", "title": "Clip"}]}
        raw = f"```json\n{json.dumps(data)}\n```"
        result = ai_engine._parse_analysis_response(raw)
        assert result == data

    def test_extracts_from_plain_fence(self):
        data = {"notes": {"summary": "Hello", "highlights": ["a", "b"]}}
        raw = f"```\n{json.dumps(data)}\n```"
        result = ai_engine._parse_analysis_response(raw)
        assert result == data

    def test_raises_value_error_on_invalid_json(self):
        with pytest.raises(ValueError, match="JSON"):
            ai_engine._parse_analysis_response("this is not json at all")

    def test_raises_value_error_on_empty_string(self):
        with pytest.raises(ValueError):
            ai_engine._parse_analysis_response("")

    def test_raises_value_error_on_fence_with_invalid_json(self):
        with pytest.raises(ValueError):
            ai_engine._parse_analysis_response("```json\nnot-json\n```")

    def test_handles_whitespace_around_json(self):
        data = {"key": "value"}
        raw = f"   {json.dumps(data)}   "
        result = ai_engine._parse_analysis_response(raw)
        assert result == data

    def test_handles_nested_structure(self):
        data = {
            "notes": {
                "summary": "Un episodio sobre tecnología.",
                "highlights": ["IA", "Python", "Podcasts"],
            },
            "clips": [
                {
                    "start": "05:30",
                    "end": "07:00",
                    "title": "Intro a la IA",
                    "reason": "Muy informativo",
                    "type": "insight",
                }
            ],
        }
        raw = json.dumps(data)
        result = ai_engine._parse_analysis_response(raw)
        assert result["clips"][0]["type"] == "insight"


# ---------------------------------------------------------------------------
# Timestamp: _timestamp_to_seconds
# ---------------------------------------------------------------------------

class TestTimestampToSeconds:
    def test_mm_ss_simple(self):
        assert ai_engine._timestamp_to_seconds("01:30") == 90.0

    def test_mm_ss_zero(self):
        assert ai_engine._timestamp_to_seconds("00:00") == 0.0

    def test_mm_ss_large_minutes(self):
        assert ai_engine._timestamp_to_seconds("59:59") == 59 * 60 + 59

    def test_h_mm_ss(self):
        assert ai_engine._timestamp_to_seconds("1:02:03") == 3600 + 2 * 60 + 3

    def test_h_mm_ss_zero_hours(self):
        # '0:01:30' is valid H:MM:SS with hours=0
        assert ai_engine._timestamp_to_seconds("0:01:30") == 90.0

    def test_h_mm_ss_large(self):
        assert ai_engine._timestamp_to_seconds("2:00:00") == 7200.0

    def test_invalid_format_raises(self):
        with pytest.raises(ValueError):
            ai_engine._timestamp_to_seconds("30")  # no colon

    def test_invalid_too_many_parts_raises(self):
        with pytest.raises(ValueError):
            ai_engine._timestamp_to_seconds("1:02:03:04")

    def test_strips_whitespace(self):
        assert ai_engine._timestamp_to_seconds("  05:00  ") == 300.0


# ---------------------------------------------------------------------------
# Timestamp: _seconds_to_timestamp
# ---------------------------------------------------------------------------

class TestSecondsToTimestamp:
    def test_zero(self):
        assert ai_engine._seconds_to_timestamp(0) == "00:00"

    def test_under_one_minute(self):
        assert ai_engine._seconds_to_timestamp(45) == "00:45"

    def test_exactly_one_minute(self):
        assert ai_engine._seconds_to_timestamp(60) == "01:00"

    def test_mm_ss_no_hours(self):
        assert ai_engine._seconds_to_timestamp(90) == "01:30"

    def test_59_minutes_59_seconds(self):
        assert ai_engine._seconds_to_timestamp(3599) == "59:59"

    def test_exactly_one_hour(self):
        assert ai_engine._seconds_to_timestamp(3600) == "1:00:00"

    def test_h_mm_ss(self):
        assert ai_engine._seconds_to_timestamp(3723) == "1:02:03"

    def test_two_hours(self):
        assert ai_engine._seconds_to_timestamp(7200) == "2:00:00"

    def test_float_truncated(self):
        # Float seconds should be truncated (int conversion)
        assert ai_engine._seconds_to_timestamp(90.9) == "01:30"

    def test_roundtrip_mm_ss(self):
        ts = "45:30"
        assert ai_engine._seconds_to_timestamp(ai_engine._timestamp_to_seconds(ts)) == ts

    def test_roundtrip_h_mm_ss(self):
        ts = "1:23:45"
        assert ai_engine._seconds_to_timestamp(ai_engine._timestamp_to_seconds(ts)) == ts


# ---------------------------------------------------------------------------
# ensure_ai_config
# ---------------------------------------------------------------------------

class TestEnsureAiConfig:
    def test_adds_ai_section_when_missing(self):
        cfg = _make_config()  # no 'ai'
        with mock.patch("ai_engine.load_shared_config", return_value=cfg), \
             mock.patch("ai_engine.update_shared_config") as mock_update:
            ai_engine.ensure_ai_config()
        mock_update.assert_called_once()
        call_args = mock_update.call_args[0][0]
        assert "ai" in call_args
        assert "base_url" in call_args["ai"]

    def test_does_not_overwrite_existing_ai_section(self):
        custom_ai = {"base_url": "http://custom:9999/v1", "api_key": "secret", "model": "x"}
        cfg = _make_config(ai_section=custom_ai)
        with mock.patch("ai_engine.load_shared_config", return_value=cfg), \
             mock.patch("ai_engine.update_shared_config") as mock_update:
            ai_engine.ensure_ai_config()
        mock_update.assert_not_called()
