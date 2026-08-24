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
    is_director: bool = False,
    ttl_seconds: int = 6 * 3600,
) -> str:
    """
    Create a JWT access token the browser uses to join the LiveKit room.
    `is_host` gets extra grants (record, can-update-metadata).
    `is_director` can publish audio (IFB push-to-talk) but not video.
    """
    from livekit import api

    grants = api.VideoGrants(
        room_join=True,
        room=room_name,
        can_publish=True,
        can_subscribe=True,
        can_publish_data=True,
    )
    if is_director:
        grants.can_publish_sources = ["microphone"]
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


def start_rtmp_egress(room_name: str, rtmp_urls: list, layout: str = "grid"):
    """
    Start a Room Composite egress that renders a grid of all participants and
    pushes it to one or more RTMP destinations. Returns the EgressInfo proto
    (has .egress_id, .status, ...) or None on failure.
    """
    try:
        from livekit import api
        async def _do():
            lk = api.LiveKitAPI(LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET)
            try:
                req = api.RoomCompositeEgressRequest(
                    room_name=room_name,
                    layout=layout,
                    audio_only=False,
                    video_only=False,
                    stream=api.StreamOutput(
                        protocol=api.StreamProtocol.RTMP,
                        urls=list(rtmp_urls),
                    ),
                )
                return await lk.egress.start_room_composite_egress(req)
            finally:
                await lk.aclose()
        return _run(_do())
    except Exception as e:
        log.warning("LiveKit start_rtmp_egress failed for %s: %s", room_name, e)
        return None


def stop_egress(egress_id: str):
    try:
        from livekit import api
        async def _do():
            lk = api.LiveKitAPI(LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET)
            try:
                return await lk.egress.stop_egress(api.StopEgressRequest(egress_id=egress_id))
            finally:
                await lk.aclose()
        return _run(_do())
    except Exception as e:
        log.warning("LiveKit stop_egress failed for %s: %s", egress_id, e)
        return None


def generate_multi_room_token(
    rooms: list,
    identity: str,
    display_name: str,
    is_host: bool = False,
    ttl_seconds: int = 6 * 3600,
) -> str:
    from livekit import api
    grants = api.VideoGrants(
        room_join=True,
        room=",".join(rooms),
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


def list_egress(room_name: str = None, active_only: bool = True):
    try:
        from livekit import api
        async def _do():
            lk = api.LiveKitAPI(LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET)
            try:
                kwargs = {"active": active_only}
                if room_name:
                    kwargs["room_name"] = room_name
                return await lk.egress.list_egress(api.ListEgressRequest(**kwargs))
            finally:
                await lk.aclose()
        return _run(_do())
    except Exception as e:
        log.warning("LiveKit list_egress failed: %s", e)
        return None
