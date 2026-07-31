"""Postgres persistence for the Putting Gate app.

This is the *only* database client in the system: the browser and iOS app no
longer talk to the DB directly (as they did with Supabase's PostgREST + RLS), so
every read and write goes through here, and ownership is enforced in SQL via a
`user_id` (the Firebase UID) on each query.

The database stays on Supabase (Postgres); we just connect straight to it with
`psycopg` (via Supabase's connection pooler) instead of the PostgREST client, so
the backend can run real SQL/transactions and bypass RLS as the service role.

Connection: a plain `psycopg` connection pool built from env.
  * `DATABASE_URL` (a libpq conninfo/URL) — e.g. the Supabase pooler string.
  * or `DB_HOST` / `DB_NAME` / `DB_USER` / `DB_PASSWORD`.
It fails soft: if nothing is configured the calls no-op (local analysis keeps
working without a DB).
"""

from __future__ import annotations

import json
import logging
import os
from pathlib import Path
from typing import Any, Optional

from dotenv import load_dotenv

# Env precedence: real shell env > backend/.env.local > backend/.env. load_dotenv
# never overrides an already-set var, so loading .env.local first lets it win
# over .env for local-dev overrides while the shell still wins over both. Paths
# are anchored to the backend dir so it works regardless of the process cwd.
_BACKEND_DIR = Path(__file__).resolve().parents[1]
load_dotenv(_BACKEND_DIR / ".env.local")  # local-dev overrides, if present
load_dotenv(_BACKEND_DIR / ".env")        # shared defaults

logger = logging.getLogger(__name__)

_pool = None
_pool_ready = False

# Columns returned to the frontend, kept in sync with the TS column lists in
# frontend/src/sessions.ts and putters.ts.
_SESSION_COLS = (
    "id, created_at, captured_at, file_name, length_feet, break_type, "
    "putt_count, duration_s, segments_detected, status, error, video_path, "
    "putter_id"
)
_PUTT_COLS = (
    "putt_index, start_s, end_s, offset_mm, direction, speed_mps, track_count, "
    "crossing_frame, sensor_offsets_mm"
)
_PUTTER_COLS = (
    "id, name, brand, model, length_in, lie_deg, grip, is_active"
)


def _conninfo() -> Optional[str]:
    """Build a libpq conninfo from env, or None when the DB is unconfigured."""
    url = os.environ.get("DATABASE_URL")
    if url:
        return url
    host = os.environ.get("DB_HOST")
    name = os.environ.get("DB_NAME")
    user = os.environ.get("DB_USER")
    if not (host and name and user):
        return None
    password = os.environ.get("DB_PASSWORD", "")
    # host may be a Unix socket dir (/cloudsql/<ICN>) or a TCP host.
    parts = [f"host={host}", f"dbname={name}", f"user={user}"]
    if password:
        parts.append(f"password={password}")
    return " ".join(parts)


def _get_pool():
    """Lazily create the connection pool (or None if the DB is unconfigured)."""
    global _pool, _pool_ready
    if _pool_ready:
        return _pool
    _pool_ready = True

    conninfo = _conninfo()
    if not conninfo:
        logger.warning(
            "No database configured (set DATABASE_URL or DB_HOST/DB_NAME/"
            "DB_USER) — session persistence is disabled."
        )
        _pool = None
        return None

    from psycopg_pool import ConnectionPool  # lazy import so the dep is optional
    from psycopg.rows import dict_row

    _pool = ConnectionPool(
        conninfo,
        min_size=1,
        max_size=4,
        # prepare_threshold=None disables server-side prepared statements, which
        # Supabase's transaction-mode connection pooler (Supavisor) doesn't
        # support; harmless on a direct/session connection.
        kwargs={"row_factory": dict_row, "prepare_threshold": None},
        open=True,
    )
    return _pool


def close() -> None:
    """Close the connection pool (call on app shutdown). Safe if never opened."""
    global _pool, _pool_ready
    if _pool is not None:
        _pool.close()
    _pool = None
    _pool_ready = False


# ---- session write path (background analysis pipeline; not user-scoped) -----

def create_pending_session(
    session_id: str, metadata: dict[str, Any]
) -> Optional[str]:
    """Insert (or reset) a session row in the 'queued' state before analysis.

    Written up-front so the async job has a row to update and the client can
    poll it. `metadata["putter_id"]` tags the session's putter, and is only
    applied if it names a putter the user owns (otherwise the row is left
    untagged). Returns the id, or None when persistence is disabled.
    """
    pool = _get_pool()
    if pool is None:
        return None
    with pool.connection() as conn, conn.cursor() as cur:
        cur.execute(
            """
            insert into sessions
              (id, user_id, file_name, captured_at, ios_duration_s,
               length_feet, break_type, putter_id, status, error, putt_count)
            values
              (%s::uuid, %s, %s, %s, %s, %s, %s::putt_break,
               (select id from putters where id = %s::uuid and user_id = %s),
               'queued', null, 0)
            on conflict (id) do update set
              user_id        = excluded.user_id,
              file_name      = excluded.file_name,
              captured_at    = excluded.captured_at,
              ios_duration_s = excluded.ios_duration_s,
              length_feet    = excluded.length_feet,
              break_type     = excluded.break_type,
              putter_id      = excluded.putter_id,
              status         = 'queued',
              error          = null,
              putt_count     = 0
            """,
            (
                session_id,
                metadata.get("user_id"),
                metadata.get("file_name"),
                metadata.get("captured_at"),
                metadata.get("ios_duration_s"),
                metadata.get("length_feet"),
                metadata.get("break_type"),
                # Only tag a putter the caller actually owns; a null/unknown id
                # resolves to NULL (untagged), matching update_session_metadata.
                metadata.get("putter_id"),
                metadata.get("user_id"),
            ),
        )
        # Clear any putts from a previous analysis of the same id (re-upload).
        cur.execute("delete from putts where session_id = %s::uuid", (session_id,))
    return session_id


def set_session_status(
    session_id: str,
    status: str,
    error: Optional[str] = None,
    video_path: Optional[str] = None,
) -> None:
    """Update a session's status (and optional error / retained video path).
    No-op when persistence is disabled."""
    pool = _get_pool()
    if pool is None:
        return
    with pool.connection() as conn, conn.cursor() as cur:
        if video_path is not None:
            cur.execute(
                "update sessions set status = %s::session_status, error = %s, "
                "video_path = %s where id = %s::uuid",
                (status, error, video_path, session_id),
            )
        else:
            cur.execute(
                "update sessions set status = %s::session_status, error = %s "
                "where id = %s::uuid",
                (status, error, session_id),
            )


def persist_session(
    session_id: str, metadata: dict[str, Any], result: dict[str, Any]
) -> Optional[str]:
    """Upsert the finished session and replace its putts. Returns the session id,
    or None when persistence is disabled. Raises on write failure so the caller
    can log and continue."""
    pool = _get_pool()
    if pool is None:
        return None

    cal = result.get("calibration") or {}
    aim_top = cal.get("aim_top")  # [x, y] or None
    putts = result.get("putts") or []

    with pool.connection() as conn, conn.cursor() as cur:
        cur.execute(
            """
            insert into sessions
              (id, user_id, file_name, captured_at, ios_duration_s, length_feet,
               break_type, video_path, status, error, fps, frame_count,
               duration_s, segments_detected, putt_count, cal_gate_center_x,
               cal_gate_line_y, cal_aim_top_x, cal_aim_top_y, cal_ball_radius_px,
               cal_mm_per_px, cal_frame, cal_scale_source)
            values
              (%s::uuid, %s, %s, %s, %s, %s, %s::putt_break, %s, 'done', null,
               %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
               %s::scale_source)
            on conflict (id) do update set
              user_id           = excluded.user_id,
              file_name         = excluded.file_name,
              captured_at       = excluded.captured_at,
              ios_duration_s    = excluded.ios_duration_s,
              length_feet       = excluded.length_feet,
              break_type        = excluded.break_type,
              video_path        = excluded.video_path,
              status            = 'done',
              error             = null,
              fps               = excluded.fps,
              frame_count       = excluded.frame_count,
              duration_s        = excluded.duration_s,
              segments_detected = excluded.segments_detected,
              putt_count        = excluded.putt_count,
              cal_gate_center_x = excluded.cal_gate_center_x,
              cal_gate_line_y   = excluded.cal_gate_line_y,
              cal_aim_top_x     = excluded.cal_aim_top_x,
              cal_aim_top_y     = excluded.cal_aim_top_y,
              cal_ball_radius_px = excluded.cal_ball_radius_px,
              cal_mm_per_px     = excluded.cal_mm_per_px,
              cal_frame         = excluded.cal_frame,
              cal_scale_source  = excluded.cal_scale_source
            """,
            (
                session_id,
                metadata.get("user_id"),
                metadata.get("file_name"),
                metadata.get("captured_at"),
                metadata.get("ios_duration_s"),
                metadata.get("length_feet"),
                metadata.get("break_type"),
                metadata.get("video_path"),
                result.get("fps"),
                result.get("frame_count"),
                result.get("duration_s"),
                result.get("segments_detected"),
                len(putts),
                cal.get("gate_center_x"),
                cal.get("gate_line_y"),
                aim_top[0] if aim_top else None,
                aim_top[1] if aim_top else None,
                cal.get("ball_radius_px"),
                cal.get("mm_per_px"),
                cal.get("calibration_frame"),
                cal.get("scale_source"),
            ),
        )

        # Replace putts wholesale so re-analysis of the same clip is idempotent.
        cur.execute("delete from putts where session_id = %s::uuid", (session_id,))
        for p in putts:
            crossing = p.get("crossing_pos")  # [x, y] or None
            cur.execute(
                """
                insert into putts
                  (session_id, putt_index, start_frame, end_frame, start_s,
                   end_s, offset_px, offset_mm, direction, speed_mps,
                   track_count, crossing_x, crossing_y, crossing_frame)
                values
                  (%s::uuid, %s, %s, %s, %s, %s, %s, %s, %s::putt_direction, %s,
                   %s, %s, %s, %s)
                """,
                (
                    session_id,
                    p.get("index"),
                    p.get("start_frame"),
                    p.get("end_frame"),
                    p.get("start_s"),
                    p.get("end_s"),
                    p.get("offset_px"),
                    p.get("offset_mm"),
                    p.get("direction"),
                    p.get("speed_mps"),
                    p.get("track_count"),
                    crossing[0] if crossing else None,
                    crossing[1] if crossing else None,
                    p.get("crossing_frame"),
                ),
            )
    return session_id


# ---- device ingestion (hardware gate; no video, pre-measured putts) ---------

def ingest_device_putt(
    uid: str,
    session_id: str,
    putt_index: int,
    offset_mm: float,
    direction: str,
    speed_mps: Optional[float] = None,
    sensor_offsets: Optional[list] = None,
) -> Optional[str]:
    """Record one putt measured by the hardware gate, upserting its session.

    Unlike the video pipeline, the device has already done the analysis: there's
    no clip, calibration, or fps — just a measured offset, side, (when the ball
    tripped more than one sensor) speed, and the per-sensor offsets behind that
    average. The first putt of a session creates the (video-less, already-`done`)
    row; each putt upserts into it, so a dropped connection costs at most one putt
    and a retry is idempotent (unique on session_id + putt_index). `putt_count` is
    kept in sync with the actual rows. No-op / None when persistence is disabled.
    """
    pool = _get_pool()
    if pool is None:
        return None
    with pool.connection() as conn, conn.cursor() as cur:
        # Create the session on first putt; leave ownership untouched on later
        # putts. Video/calibration columns stay null — this session has no clip.
        cur.execute(
            """
            insert into sessions (id, user_id, status, putt_count)
            values (%s::uuid, %s, 'done', 0)
            on conflict (id) do update set status = 'done'
            """,
            (session_id, uid),
        )
        cur.execute(
            """
            insert into putts
              (session_id, putt_index, offset_mm, direction, speed_mps, sensor_offsets_mm)
            values (%s::uuid, %s, %s, %s::putt_direction, %s, %s::jsonb)
            on conflict (session_id, putt_index) do update set
              offset_mm = excluded.offset_mm,
              direction = excluded.direction,
              speed_mps = excluded.speed_mps,
              sensor_offsets_mm = excluded.sensor_offsets_mm
            """,
            (
                session_id, putt_index, offset_mm, direction, speed_mps,
                json.dumps(sensor_offsets) if sensor_offsets is not None else None,
            ),
        )
        cur.execute(
            "update sessions set putt_count = "
            "(select count(*) from putts where session_id = %s::uuid) "
            "where id = %s::uuid",
            (session_id, session_id),
        )
    return session_id


# ---- session user-facing operations (ownership-scoped by uid) ---------------

def list_sessions(uid: str) -> list[dict[str, Any]]:
    """All of a user's sessions, newest first."""
    pool = _get_pool()
    if pool is None:
        return []
    with pool.connection() as conn, conn.cursor() as cur:
        cur.execute(
            f"select {_SESSION_COLS} from sessions where user_id = %s "
            "order by created_at desc",
            (uid,),
        )
        return cur.fetchall()


def get_session(uid: str, session_id: str) -> Optional[dict[str, Any]]:
    """One session, only if it belongs to `uid`."""
    pool = _get_pool()
    if pool is None:
        return None
    with pool.connection() as conn, conn.cursor() as cur:
        cur.execute(
            f"select {_SESSION_COLS} from sessions "
            "where id = %s::uuid and user_id = %s",
            (session_id, uid),
        )
        return cur.fetchone()


def list_putts(uid: str, session_id: str) -> list[dict[str, Any]]:
    """A session's putts, ordered, only if the session belongs to `uid`."""
    pool = _get_pool()
    if pool is None:
        return []
    with pool.connection() as conn, conn.cursor() as cur:
        cur.execute(
            f"select {_PUTT_COLS} from putts p "
            "where p.session_id = %s::uuid and exists ("
            "  select 1 from sessions s where s.id = p.session_id "
            "  and s.user_id = %s) order by putt_index",
            (session_id, uid),
        )
        return cur.fetchall()


def delete_putt(uid: str, session_id: str, putt_index: int) -> bool:
    """Delete one putt from a user's session, keeping putt_count in sync.

    Ownership is enforced through the session's user_id, so a putt in someone
    else's session (or a missing one) deletes nothing and returns False. The
    remaining putts keep their putt_index values — indices are the stable putt
    identity (the crossing-frame endpoint and the device's idempotent upsert both
    key on them), so a delete leaves a gap rather than renumbering."""
    pool = _get_pool()
    if pool is None:
        return False
    with pool.connection() as conn, conn.cursor() as cur:
        cur.execute(
            "delete from putts p using sessions s "
            "where p.session_id = s.id and s.id = %s::uuid and s.user_id = %s "
            "and p.putt_index = %s",
            (session_id, uid, putt_index),
        )
        if cur.rowcount == 0:
            return False
        cur.execute(
            "update sessions set putt_count = "
            "(select count(*) from putts where session_id = %s::uuid) "
            "where id = %s::uuid",
            (session_id, session_id),
        )
        return True


def get_putt_crossing_frame(
    uid: str, session_id: str, putt_index: int
) -> Optional[int]:
    """The gate-crossing frame index for one putt, if the session belongs to
    `uid`. Returns None when the putt doesn't exist or predates crossing_frame
    (legacy row) — callers treat both as "no still available"."""
    pool = _get_pool()
    if pool is None:
        return None
    with pool.connection() as conn, conn.cursor() as cur:
        cur.execute(
            "select p.crossing_frame from putts p "
            "where p.session_id = %s::uuid and p.putt_index = %s and exists ("
            "  select 1 from sessions s where s.id = p.session_id "
            "  and s.user_id = %s)",
            (session_id, putt_index, uid),
        )
        row = cur.fetchone()
        return row["crossing_frame"] if row else None


def offsets_for_sessions(uid: str, session_ids: list[str]) -> list[float]:
    """offset_mm for every putt across the given sessions (owned by `uid`).
    Batched for the dashboard summary."""
    pool = _get_pool()
    if pool is None or not session_ids:
        return []
    with pool.connection() as conn, conn.cursor() as cur:
        cur.execute(
            "select p.offset_mm from putts p join sessions s "
            "on s.id = p.session_id where s.user_id = %s "
            "and p.session_id = any(%s::uuid[]) and p.offset_mm is not null",
            (uid, list(session_ids)),
        )
        return [r["offset_mm"] for r in cur.fetchall()]


def get_session_video_path(uid: str, session_id: str) -> Optional[str]:
    """The retained GCS object path for a user's session video, or None."""
    pool = _get_pool()
    if pool is None:
        return None
    with pool.connection() as conn, conn.cursor() as cur:
        cur.execute(
            "select video_path from sessions "
            "where id = %s::uuid and user_id = %s",
            (session_id, uid),
        )
        row = cur.fetchone()
        return row["video_path"] if row else None


def begin_reanalysis(uid: str, session_id: str) -> Optional[dict[str, Any]]:
    """Reset an owned session to 'queued' for a fresh analysis of its retained
    video, clearing its prior putts, and return what the re-run needs.

    Returns ``{video_path, fps, metadata}`` (the metadata shape ``persist_session``
    expects, carrying the current file_name / captured_at / duration / length /
    break so re-analysis doesn't null the user's edits), or None when the session
    doesn't exist, isn't owned by ``uid``, has no retained video, or persistence
    is disabled. The status reset and putt-clear happen in one transaction so the
    row never sits half-reset.
    """
    pool = _get_pool()
    if pool is None:
        return None
    with pool.connection() as conn, conn.cursor() as cur:
        cur.execute(
            "select video_path, fps, file_name, captured_at, ios_duration_s, "
            "length_feet, break_type from sessions "
            "where id = %s::uuid and user_id = %s",
            (session_id, uid),
        )
        row = cur.fetchone()
        if row is None or not row.get("video_path"):
            return None
        cur.execute(
            "update sessions set status = 'queued', error = null, putt_count = 0 "
            "where id = %s::uuid and user_id = %s",
            (session_id, uid),
        )
        cur.execute("delete from putts where session_id = %s::uuid", (session_id,))
    # captured_at comes back from the DB as a datetime; the metadata dict is JSON-
    # serialized into the Cloud Tasks payload, so hand it back as an ISO string
    # (matching the upload path, where captured_at arrives as a string). Postgres
    # parses it fine on re-persist.
    captured_at = row.get("captured_at")
    return {
        "video_path": row["video_path"],
        "fps": row.get("fps"),
        "metadata": {
            "user_id": uid,
            "file_name": row.get("file_name"),
            "captured_at": captured_at.isoformat() if captured_at is not None else None,
            "ios_duration_s": row.get("ios_duration_s"),
            "length_feet": row.get("length_feet"),
            "break_type": row.get("break_type"),
        },
    }


def delete_session(uid: str, session_id: str) -> bool:
    """Delete a user's session (putts cascade). Returns True if a row was
    deleted. Idempotent; no-op when persistence is disabled."""
    pool = _get_pool()
    if pool is None:
        return False
    with pool.connection() as conn, conn.cursor() as cur:
        cur.execute(
            "delete from sessions where id = %s::uuid and user_id = %s",
            (session_id, uid),
        )
        return cur.rowcount > 0


def update_session_metadata(
    uid: str,
    session_id: str,
    length_feet: Optional[int],
    break_type: Optional[str],
    putter_id: Optional[str],
) -> bool:
    """Update a user's session metadata (distance, break, putter). Each field is
    set to exactly what's passed (None clears it). `putter_id` is only applied if
    it names a putter the user owns (otherwise the tag is cleared). Returns True
    if the session existed and was updated."""
    pool = _get_pool()
    if pool is None:
        return False
    with pool.connection() as conn, conn.cursor() as cur:
        cur.execute(
            """
            update sessions set
              length_feet = %s,
              break_type  = %s::putt_break,
              putter_id   = (select id from putters
                             where id = %s::uuid and user_id = %s)
            where id = %s::uuid and user_id = %s
            """,
            (length_feet, break_type, putter_id, uid, session_id, uid),
        )
        return cur.rowcount > 0


# ---- putters (ownership-scoped by uid) --------------------------------------

def list_putters(uid: str) -> list[dict[str, Any]]:
    """A user's putters, active first then newest."""
    pool = _get_pool()
    if pool is None:
        return []
    with pool.connection() as conn, conn.cursor() as cur:
        cur.execute(
            f"select {_PUTTER_COLS} from putters where user_id = %s "
            "order by is_active desc, created_at desc",
            (uid,),
        )
        return cur.fetchall()


def create_putter(uid: str, fields: dict[str, Any]) -> Optional[dict[str, Any]]:
    """Insert a putter owned by `uid`. Returns the created row."""
    pool = _get_pool()
    if pool is None:
        return None
    with pool.connection() as conn, conn.cursor() as cur:
        cur.execute(
            f"""
            insert into putters (user_id, name, brand, model, length_in,
                                 lie_deg, grip)
            values (%s, %s, %s, %s, %s, %s, %s)
            returning {_PUTTER_COLS}
            """,
            (
                uid,
                fields.get("name"),
                fields.get("brand"),
                fields.get("model"),
                fields.get("length_in"),
                fields.get("lie_deg"),
                fields.get("grip"),
            ),
        )
        return cur.fetchone()


# Putter columns a client is allowed to update.
_PUTTER_EDITABLE = ("name", "brand", "model", "length_in", "lie_deg", "grip")


def update_putter(
    uid: str, putter_id: str, fields: dict[str, Any]
) -> Optional[dict[str, Any]]:
    """Update the provided editable fields on a user's putter. Returns the
    updated row, or None if it doesn't exist / isn't owned by `uid`."""
    pool = _get_pool()
    if pool is None:
        return None
    cols = [c for c in _PUTTER_EDITABLE if c in fields]
    if not cols:
        return get_putter(uid, putter_id)
    assignments = ", ".join(f"{c} = %s" for c in cols)
    params = [fields[c] for c in cols] + [putter_id, uid]
    with pool.connection() as conn, conn.cursor() as cur:
        cur.execute(
            f"update putters set {assignments} "
            f"where id = %s::uuid and user_id = %s returning {_PUTTER_COLS}",
            params,
        )
        return cur.fetchone()


def get_putter(uid: str, putter_id: str) -> Optional[dict[str, Any]]:
    """One putter, only if owned by `uid`."""
    pool = _get_pool()
    if pool is None:
        return None
    with pool.connection() as conn, conn.cursor() as cur:
        cur.execute(
            f"select {_PUTTER_COLS} from putters "
            "where id = %s::uuid and user_id = %s",
            (putter_id, uid),
        )
        return cur.fetchone()


def delete_putter(uid: str, putter_id: str) -> bool:
    """Delete a user's putter (its sessions are un-tagged via ON DELETE SET
    NULL). Returns True if a row was deleted."""
    pool = _get_pool()
    if pool is None:
        return False
    with pool.connection() as conn, conn.cursor() as cur:
        cur.execute(
            "delete from putters where id = %s::uuid and user_id = %s",
            (putter_id, uid),
        )
        return cur.rowcount > 0


def set_active_putter(uid: str, putter_id: str) -> bool:
    """Atomically make `putter_id` the user's active putter. Clears the previous
    active row first to avoid transiently violating the one-active-per-user
    unique index. Returns True if the target putter exists and is now active."""
    pool = _get_pool()
    if pool is None:
        return False
    with pool.connection() as conn, conn.cursor() as cur:
        cur.execute(
            "update putters set is_active = false "
            "where user_id = %s and is_active",
            (uid,),
        )
        cur.execute(
            "update putters set is_active = true "
            "where id = %s::uuid and user_id = %s",
            (putter_id, uid),
        )
        return cur.rowcount > 0
