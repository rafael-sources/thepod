"""
LiveKit integration. Uses the `livekit-api` SDK for room management and JWT
token generation. Failures against the LiveKit server are non-fatal — prodPod
keeps working locally even if the LiveKit dev server is down (the user just
can't join a room until it's back).
"""

import asyncio
import logging
from contextlib import contextmanager

from config import LIVEKIT_API_KEY, LIVEKIT_API_SECRET, LIVEKIT_URL, MAX_SESSION_PARTICIPANTS


log = logging.getLogger(__name__)


def _new_loop():
    return asyncio.new_event_loop()


def _run(coro):
    loop = _new_loop()
    try:
        return loop.run_until_complete(coro)
    finally:
        loop.close()


def create_room(room_name: str, max_participants: int = MAX_SESSION_PARTICIPANTS):
    """Create or get-or-create the LiveKit room. Best-effort."""
    try:
        from livekit import api
        async def _do():
            lk = api.LiveKitAPI(LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET)
            try:
                return await lk.room.create_room(
                    api.CreateRoomRequest(
                        name=room_name,
                        max_participants=max_participants,
                        empty_timeout=3600,
                    )
                )
            finally:
                await lk.aclose()
        return _run(_do())
    except Exception as e:
        log.warning("LiveKit create_room failed for %s: %s", room_name, e)
        return None


def delete_room(room_name: str):
    try:
        from livekit import api
        async def _do():
            lk = api.LiveKitAPI(LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET)
            try:
                return await lk.room.delete_room(api.DeleteRoomRequest(room=room_name))
            finally:
                await lk.aclose()
        return _run(_do())
    except Exception as e:
        log.warning("LiveKit delete_room failed for %s: %s", room_name, e)
        return None


def list_participants(room_name: str):
    try:
        from livekit import api
        async def _do():
            lk = api.LiveKitAPI(LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET)
            try:
                res = await lk.room.list_participants(api.ListParticipantsRequest(room=room_name))
                return list(res.participants)
            finally:
                await lk.aclose()
        return _run(_do()) or []
    except Exception as e:
        log.warning("LiveKit list_participants failed: %s", e)
        return []


def generate_participant_token(
    room_name: str,
    identity: str,
    display_name: str,
    is_host: bool = False,
    ttl_seconds: int = 6 * 3600,
) -> str:
    """
    Create a JWT access token the browser uses to join the LiveKit room.
    `is_host` gets extra grants (record, can-update-metadata).
    """
    from livekit import api

    grants = api.VideoGrants(
        room_join=True,
        room=room_name,
        can_publish=True,
        can_subscribe=True,
        can_publish_data=True,
    )
    if is_host:
        grants.room_admin = True
        grants.room_record = True

    token = (
        api.AccessToken(LIVEKIT_API_KEY, LIVEKIT_API_SECRET)
        .with_identity(identity)
        .with_name(display_name)
        .with_grants(grants)
        .with_ttl(__import__("datetime").timedelta(seconds=ttl_seconds))
    )
    return token.to_jwt()


def room_name_for_session(session_id: int) -> str:
    return f"prodpod_session_{session_id}"
