"""Supabase persistence for analyzed putting sessions.

The API is otherwise stateless; this module writes one `sessions` row plus its
`putts` rows after a successful `analyze_session`. It fails soft: if the Supabase
env vars are unset the calls no-op (local analysis keeps working without a DB), and
callers are expected to catch/log any write errors so persistence never breaks the
analysis response.
"""

from __future__ import annotations

import logging
import os
from typing import Any, Optional

from dotenv import load_dotenv

load_dotenv()

logger = logging.getLogger(__name__)

_client = None
_client_ready = False


def _get_client():
    """Lazily create the service-role Supabase client (or None if unconfigured)."""
    global _client, _client_ready
    if _client_ready:
        return _client
    _client_ready = True

    url = os.environ.get("SUPABASE_URL")
    key = os.environ.get("SUPABASE_SECRET_KEY")
    if not url or not key:
        logger.warning(
            "SUPABASE_URL / SUPABASE_SECRET_KEY not set — session persistence "
            "is disabled."
        )
        _client = None
        return None

    from supabase import create_client  # imported lazily so the dep is optional

    _client = create_client(url, key)
    return _client


def _session_row(
    session_id: str, metadata: dict[str, Any], result: dict[str, Any]
) -> dict[str, Any]:
    """Flatten iOS metadata + analysis result + calibration into one `sessions` row."""
    cal = result.get("calibration") or {}
    aim_top = cal.get("aim_top")  # [x, y] or None

    return {
        "id": session_id,
        "user_id": metadata.get("user_id"),
        "file_name": metadata.get("file_name"),
        "captured_at": metadata.get("captured_at"),
        "ios_duration_s": metadata.get("ios_duration_s"),
        "length_feet": metadata.get("length_feet"),
        "break_type": metadata.get("break_type"),
        "video_path": metadata.get("video_path"),
        "status": "done",
        "error": None,
        "fps": result.get("fps"),
        "frame_count": result.get("frame_count"),
        "duration_s": result.get("duration_s"),
        "segments_detected": result.get("segments_detected"),
        "putt_count": len(result.get("putts") or []),
        "cal_gate_center_x": cal.get("gate_center_x"),
        "cal_gate_line_y": cal.get("gate_line_y"),
        "cal_aim_top_x": aim_top[0] if aim_top else None,
        "cal_aim_top_y": aim_top[1] if aim_top else None,
        "cal_ball_radius_px": cal.get("ball_radius_px"),
        "cal_mm_per_px": cal.get("mm_per_px"),
        "cal_frame": cal.get("calibration_frame"),
        "cal_scale_source": cal.get("scale_source"),
    }


def _putt_row(session_id: str, putt: dict[str, Any]) -> dict[str, Any]:
    """Map one analysis putt to a `putts` row, dropping the raw tracking arrays."""
    crossing = putt.get("crossing_pos")  # [x, y] or None
    return {
        "session_id": session_id,
        "putt_index": putt.get("index"),
        "start_frame": putt.get("start_frame"),
        "end_frame": putt.get("end_frame"),
        "start_s": putt.get("start_s"),
        "end_s": putt.get("end_s"),
        "offset_px": putt.get("offset_px"),
        "offset_mm": putt.get("offset_mm"),
        "direction": putt.get("direction"),
        "speed_mps": putt.get("speed_mps"),
        "track_count": putt.get("track_count"),
        "crossing_x": crossing[0] if crossing else None,
        "crossing_y": crossing[1] if crossing else None,
    }


def create_pending_session(
    session_id: str, metadata: dict[str, Any]
) -> Optional[str]:
    """Insert (or reset) a session row in the 'queued' state before analysis.

    Written up-front so the async job has a row to update and the client can
    watch it via Realtime. Returns the id, or None when persistence is disabled.
    """
    client = _get_client()
    if client is None:
        return None

    row = {
        "id": session_id,
        "user_id": metadata.get("user_id"),
        "file_name": metadata.get("file_name"),
        "captured_at": metadata.get("captured_at"),
        "ios_duration_s": metadata.get("ios_duration_s"),
        "length_feet": metadata.get("length_feet"),
        "break_type": metadata.get("break_type"),
        "status": "queued",
        "error": None,
        "putt_count": 0,
    }
    client.table("sessions").upsert(row, on_conflict="id").execute()
    # Clear any putts from a previous analysis of the same id (re-upload).
    client.table("putts").delete().eq("session_id", session_id).execute()
    return session_id


def get_session_video_path(session_id: str) -> Optional[str]:
    """Return the retained GCS object path for a session's video, or None."""
    client = _get_client()
    if client is None:
        return None
    resp = (
        client.table("sessions")
        .select("video_path")
        .eq("id", session_id)
        .limit(1)
        .execute()
    )
    rows = resp.data or []
    return rows[0].get("video_path") if rows else None


def delete_session(session_id: str) -> None:
    """Delete a session and its putts. No-op when persistence is disabled.
    Idempotent: deleting a missing session is not an error."""
    client = _get_client()
    if client is None:
        return
    # Putts cascade on the FK, but delete explicitly to be safe.
    client.table("putts").delete().eq("session_id", session_id).execute()
    client.table("sessions").delete().eq("id", session_id).execute()


def update_session_metadata(
    session_id: str, length_feet: Optional[int], break_type: Optional[str]
) -> None:
    """Update a session's editable metadata (putt distance and break type).

    Both fields are set to exactly what's passed (None clears them). No-op when
    persistence is disabled."""
    client = _get_client()
    if client is None:
        return
    client.table("sessions").update(
        {"length_feet": length_feet, "break_type": break_type}
    ).eq("id", session_id).execute()


def set_session_status(
    session_id: str,
    status: str,
    error: Optional[str] = None,
    video_path: Optional[str] = None,
) -> None:
    """Update a session's status (and optional error message). Pass `video_path`
    to also record the retained video for a session that ended in error, so the
    clip stays linked to the row for review and cleanup. No-op when persistence
    is disabled."""
    client = _get_client()
    if client is None:
        return
    update: dict[str, Any] = {"status": status, "error": error}
    if video_path is not None:
        update["video_path"] = video_path
    client.table("sessions").update(update).eq("id", session_id).execute()


def persist_session(
    session_id: str, metadata: dict[str, Any], result: dict[str, Any]
) -> Optional[str]:
    """Upsert the session and replace its putts. Returns the session id, or None
    when persistence is disabled (no Supabase config). Raises on write failure so
    the caller can log and continue."""
    client = _get_client()
    if client is None:
        return None

    client.table("sessions").upsert(
        _session_row(session_id, metadata, result), on_conflict="id"
    ).execute()

    # Replace putts wholesale so re-analysis of the same clip is idempotent.
    client.table("putts").delete().eq("session_id", session_id).execute()
    putt_rows = [_putt_row(session_id, p) for p in (result.get("putts") or [])]
    if putt_rows:
        client.table("putts").insert(putt_rows).execute()

    return session_id
