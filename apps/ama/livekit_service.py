import asyncio
import logging
from config import LIVEKIT_API_KEY, LIVEKIT_API_SECRET, LIVEKIT_URL

log = logging.getLogger(__name__)

def _new_loop():
    return asyncio.new_event_loop()

def _run(coro):
    loop = _new_loop()
    try:
        return loop.run_until_complete(coro)
    finally:
        loop.close()

def create_room(room_name: str, max_participants: int = 10):
    try:
        from livekit import api
        async def _do():
            lk = api.LiveKitAPI(LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET)
            try:
                return await lk.room.create_room(
                    api.CreateRoomRequest(name=room_name, max_participants=max_participants, empty_timeout=3600)
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
    can_publish: bool = True,
    ttl_seconds: int = 6 * 3600,
) -> str:
    from livekit import api
    grants = api.VideoGrants(
        room_join=True,
        room=room_name,
        can_publish=can_publish,
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

def room_name_for_event(event_id: int) -> str:
    return f"amapod_event_{event_id}"

def start_recording_egress(room_name: str, output_filepath: str, layout: str = "speaker"):
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
                    file=api.EncodedFileOutput(
                        file_type=api.EncodedFileType.MP4,
                        filepath=output_filepath,
                    ),
                )
                return await lk.egress.start_room_composite_egress(req)
            finally:
                await lk.aclose()
        return _run(_do())
    except Exception as e:
        log.warning("LiveKit start_recording_egress failed for %s: %s", room_name, e)
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

def mute_participant(room_name: str, identity: str, muted: bool = True):
    try:
        from livekit import api
        async def _do():
            lk = api.LiveKitAPI(LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET)
            try:
                participants = await lk.room.list_participants(api.ListParticipantsRequest(room=room_name))
                for p in participants.participants:
                    if p.identity == identity:
                        for track in p.tracks:
                            if track.source == api.TrackSource.MICROPHONE:
                                await lk.room.mute_published_track(
                                    api.MuteRoomTrackRequest(room=room_name, identity=identity, track_sid=track.sid, muted=muted)
                                )
                        break
            finally:
                await lk.aclose()
        return _run(_do())
    except Exception as e:
        log.warning("LiveKit mute_participant failed for %s/%s: %s", room_name, identity, e)
        return None

def update_participant_permissions(room_name: str, identity: str, can_publish: bool):
    try:
        from livekit import api
        async def _do():
            lk = api.LiveKitAPI(LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET)
            try:
                await lk.room.update_participant(
                    api.UpdateParticipantRequest(
                        room=room_name,
                        identity=identity,
                        permission=api.ParticipantPermission(
                            can_publish=can_publish,
                            can_subscribe=True,
                            can_publish_data=True,
                        ),
                    )
                )
            finally:
                await lk.aclose()
        return _run(_do())
    except Exception as e:
        log.warning("LiveKit update_participant_permissions failed for %s/%s: %s", room_name, identity, e)
        return None

def remove_participant(room_name: str, identity: str):
    try:
        from livekit import api
        async def _do():
            lk = api.LiveKitAPI(LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET)
            try:
                await lk.room.remove_participant(api.RoomParticipantIdentity(room=room_name, identity=identity))
            finally:
                await lk.aclose()
        return _run(_do())
    except Exception as e:
        log.warning("LiveKit remove_participant failed for %s/%s: %s", room_name, identity, e)
        return None
