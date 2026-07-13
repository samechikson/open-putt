"""Cloud SQL (Postgres) persistence for the Putting Gate app.

This is the *only* database client in the system: the browser and iOS app no
longer talk to the DB directly (as they did with Supabase's PostgREST + RLS), so
every read and write goes through here, and ownership is enforced in SQL via a
`user_id` (the Firebase UID) on each query.

Connection: a plain `psycopg` connection pool built from env.
  * On Cloud Run, `--add-cloudsql-instances` mounts a Unix socket; set
    `DB_HOST=/cloudsql/<INSTANCE_CONNECTION_NAME>`, `DB_NAME`, `DB_USER`,
    `DB_PASSWORD`.
  * Locally / anywhere, set `DATABASE_URL` (a libpq conninfo/URL) instead.
It fails soft: if nothing is configured the calls no-op (local analysis keeps
working without a DB), mirroring the previous Supabase behavior.
"""

from __future__ import annotations

import logging
import os
from typing import Any, Optional

from dotenv import load_dotenv

load_dotenv()

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
    "putt_index, start_s, end_s, offset_mm, direction, speed_mps, track_count"
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
        kwargs={"row_factory": dict_row},
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
    poll it. Returns the id, or None when persistence is disabled.
    """
    pool = _get_pool()
    if pool is None:
        return None
    with pool.connection() as conn, conn.cursor() as cur:
        cur.execute(
            """
            insert into sessions
              (id, user_id, file_name, captured_at, ios_duration_s,
               length_feet, break_type, status, error, putt_count)
            values
              (%s::uuid, %s, %s, %s, %s, %s, %s::putt_break, 'queued', null, 0)
            on conflict (id) do update set
              user_id        = excluded.user_id,
              file_name      = excluded.file_name,
              captured_at    = excluded.captured_at,
              ios_duration_s = excluded.ios_duration_s,
              length_feet    = excluded.length_feet,
              break_type     = excluded.break_type,
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
                   track_count, crossing_x, crossing_y)
                values
                  (%s::uuid, %s, %s, %s, %s, %s, %s, %s, %s::putt_direction, %s,
                   %s, %s, %s)
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
                ),
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
