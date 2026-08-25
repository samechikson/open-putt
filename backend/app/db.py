"""Firestore persistence for the Putting Gate app.

This is the *only* database client in the system: the browser and iOS app never
talk to the DB directly, so every read and write goes through here, and ownership
is enforced on every query by a `user_id` (the Firebase UID) stored on each
document. The Firestore Admin SDK connects as the service account and bypasses
security rules, so ownership is enforced here in application code — exactly as it
was under Postgres.

Data model (all Native-mode Firestore collections):
  * `putters/{putterId}`   — one doc per user-owned club. `putterId` is a uuid4.
  * `sessions/{sessionId}` — one doc per analyzed video / gate session.
    `sessionId` is the iOS recording UUID (idempotent upsert key).
  * `putts/{sessionId_index}` — a *top-level* collection, one doc per detected
    putt. The doc id is `"{session_id}_{putt_index}"`, which makes the device's
    per-(session, index) upsert idempotent. Each putt doc carries `session_id`
    and `user_id` (denormalized from its session) so putts can be queried and
    ownership-checked without a join.

To avoid managing composite indexes, every query filters on a *single* field
(equality) and does any remaining ordering / secondary filtering in Python. Putt
and session counts per user are small, so this is cheap.

Connection:
  * Prod / Cloud Run: Application Default Credentials + the project id from
    `GOOGLE_CLOUD_PROJECT` / `FIREBASE_PROJECT_ID` / `GCP_PROJECT`.
  * Local dev: the Firestore emulator, via `FIRESTORE_EMULATOR_HOST` (set by
    start.sh); the project id can be anything.
It fails soft: if neither a project nor the emulator is configured the calls
no-op (local analysis keeps working without a DB).
"""

from __future__ import annotations

import logging
import os
import uuid
from datetime import datetime, timezone
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

_client = None
_client_ready = False

# Collection names.
_PUTTERS = "putters"
_SESSIONS = "sessions"
_PUTTS = "putts"

# Fields returned to the frontend, kept in sync with the TS types in
# frontend/src/sessions.ts and putters.ts. Sessions are gate-only (the iOS app
# relays hardware-gate putts); the old video/calibration columns are gone.
_SESSION_FIELDS = (
    "created_at", "length_feet", "break_type", "putt_count", "putter_id",
)
_PUTT_FIELDS = (
    "putt_index", "offset_mm", "direction", "speed_mps", "sensor_offsets_mm",
)
_PUTTER_FIELDS = (
    "name", "brand", "model", "length_in", "lie_deg", "grip", "is_active",
)


def _configured() -> bool:
    """True when a Firestore target (real project or emulator) is available."""
    return bool(
        os.environ.get("FIRESTORE_EMULATOR_HOST")
        or os.environ.get("GOOGLE_CLOUD_PROJECT")
        or os.environ.get("FIREBASE_PROJECT_ID")
        or os.environ.get("GCP_PROJECT")
    )


def _get_client():
    """Lazily create the Firestore client (or None if unconfigured)."""
    global _client, _client_ready
    if _client_ready:
        return _client
    _client_ready = True

    if not _configured():
        logger.warning(
            "No Firestore configured (set GOOGLE_CLOUD_PROJECT/FIREBASE_PROJECT_ID"
            " or FIRESTORE_EMULATOR_HOST) — session persistence is disabled."
        )
        _client = None
        return None

    from google.cloud import firestore  # lazy import so the dep is optional

    # Against the emulator the project id is arbitrary; still pass one so the
    # client doesn't try to discover it from metadata.
    project = (
        os.environ.get("GOOGLE_CLOUD_PROJECT")
        or os.environ.get("FIREBASE_PROJECT_ID")
        or os.environ.get("GCP_PROJECT")
        or "putting-gate"
    )
    _client = firestore.Client(project=project)
    return _client


def close() -> None:
    """Close the Firestore client (call on app shutdown). Safe if never opened."""
    global _client, _client_ready
    if _client is not None:
        try:
            _client.close()
        except Exception:  # noqa: BLE001 — best-effort
            pass
    _client = None
    _client_ready = False


# ---- helpers ----------------------------------------------------------------


def _field_filter(field: str, value: Any):
    """A single-field equality filter (the modern, non-deprecated `where` form)."""
    from google.cloud.firestore_v1.base_query import FieldFilter

    return FieldFilter(field, "==", value)


def _iso(value: Any) -> Optional[str]:
    """Render a stored timestamp as an ISO-8601 string (matching the old
    Postgres → FastAPI behavior). Passes through strings and None untouched."""
    if value is None or isinstance(value, str):
        return value
    if isinstance(value, datetime):
        return value.isoformat()
    # Firestore returns DatetimeWithNanoseconds, a datetime subclass; the branch
    # above handles it. Anything else, stringify defensively.
    return str(value)


def _putt_doc_id(session_id: str, putt_index: int) -> str:
    """Deterministic putt doc id, so a per-(session, index) write is idempotent."""
    return f"{session_id}_{putt_index}"


def _project(data: dict[str, Any], fields, extra: dict[str, Any] | None = None) -> dict[str, Any]:
    """Build the client-facing row: exactly `fields` (missing → None) plus any
    `extra` (e.g. the doc id as `id`)."""
    row: dict[str, Any] = {k: data.get(k) for k in fields}
    if extra:
        row.update(extra)
    return row


def _session_row(doc) -> dict[str, Any]:
    data = doc.to_dict() or {}
    row = _project(data, _SESSION_FIELDS, {"id": doc.id})
    row["created_at"] = _iso(row.get("created_at"))
    return row


def _putter_row(doc) -> dict[str, Any]:
    data = doc.to_dict() or {}
    return _project(data, _PUTTER_FIELDS, {"id": doc.id})


def _count_putts(client, session_id: str) -> int:
    """Number of putt docs for a session (denormalized into session.putt_count)."""
    q = client.collection(_PUTTS).where(filter=_field_filter("session_id", session_id))
    return sum(1 for _ in q.stream())


def _owned_session(client, uid: str, session_id: str):
    """The session doc snapshot if it exists and belongs to `uid`, else None."""
    snap = client.collection(_SESSIONS).document(session_id).get()
    if not snap.exists:
        return None
    if (snap.to_dict() or {}).get("user_id") != uid:
        return None
    return snap


def _owns_putter(client, uid: str, putter_id: Optional[str]) -> Optional[str]:
    """Return `putter_id` iff the user owns that putter, else None (untagged)."""
    if not putter_id:
        return None
    snap = client.collection(_PUTTERS).document(putter_id).get()
    if snap.exists and (snap.to_dict() or {}).get("user_id") == uid:
        return putter_id
    return None


def _delete_putts_for_session(client, session_id: str) -> None:
    """Delete every putt doc belonging to a session (cascade helper)."""
    q = client.collection(_PUTTS).where(filter=_field_filter("session_id", session_id))
    for snap in q.stream():
        snap.reference.delete()


# ---- device ingestion (hardware gate; the only putt source) -----------------


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
    doc; each putt upserts into it, so a dropped connection costs at most one putt
    and a retry is idempotent (the putt doc id keys on session_id + putt_index).
    `putt_count` is kept in sync with the actual docs. No-op / None when
    persistence is disabled.
    """
    client = _get_client()
    if client is None:
        return None

    from google.cloud import firestore

    session_ref = client.collection(_SESSIONS).document(session_id)
    snap = session_ref.get()
    if snap.exists:
        # Later putt: leave ownership/created_at untouched, just keep it `done`.
        session_ref.set({"status": "done"}, merge=True)
    else:
        # First putt: create the video-less, already-`done` session.
        session_ref.set(
            {
                "user_id": uid,
                "status": "done",
                "error": None,
                "putt_count": 0,
                "created_at": firestore.SERVER_TIMESTAMP,
            }
        )

    client.collection(_PUTTS).document(_putt_doc_id(session_id, putt_index)).set(
        {
            "session_id": session_id,
            "user_id": uid,
            "putt_index": putt_index,
            "offset_mm": offset_mm,
            "direction": direction,
            "speed_mps": speed_mps,
            "sensor_offsets_mm": sensor_offsets,
        },
        merge=True,
    )

    session_ref.set({"putt_count": _count_putts(client, session_id)}, merge=True)
    return session_id


# ---- session user-facing operations (ownership-scoped by uid) ---------------


def list_sessions(uid: str) -> list[dict[str, Any]]:
    """All of a user's sessions, newest first."""
    client = _get_client()
    if client is None:
        return []
    q = client.collection(_SESSIONS).where(filter=_field_filter("user_id", uid))
    rows = [_session_row(d) for d in q.stream()]
    # ISO-8601 strings sort chronologically; None sorts last.
    rows.sort(key=lambda r: r.get("created_at") or "", reverse=True)
    return rows


def get_session(uid: str, session_id: str) -> Optional[dict[str, Any]]:
    """One session, only if it belongs to `uid`."""
    client = _get_client()
    if client is None:
        return None
    snap = _owned_session(client, uid, session_id)
    return _session_row(snap) if snap else None


def list_putts(uid: str, session_id: str) -> list[dict[str, Any]]:
    """A session's putts, ordered, only if the session belongs to `uid`."""
    client = _get_client()
    if client is None:
        return []
    q = client.collection(_PUTTS).where(filter=_field_filter("session_id", session_id))
    rows = [
        _project(d.to_dict() or {}, _PUTT_FIELDS)
        for d in q.stream()
        if (d.to_dict() or {}).get("user_id") == uid
    ]
    rows.sort(key=lambda r: r.get("putt_index") if r.get("putt_index") is not None else 0)
    return rows


def delete_putt(uid: str, session_id: str, putt_index: int) -> bool:
    """Delete one putt from a user's session, keeping putt_count in sync.

    Ownership is enforced through the session's user_id, so a putt in someone
    else's session (or a missing one) deletes nothing and returns False. The
    remaining putts keep their putt_index values — indices are the stable putt
    identity (the crossing-frame endpoint and the device's idempotent upsert both
    key on them), so a delete leaves a gap rather than renumbering."""
    client = _get_client()
    if client is None:
        return False
    if _owned_session(client, uid, session_id) is None:
        return False
    putt_ref = client.collection(_PUTTS).document(_putt_doc_id(session_id, putt_index))
    if not putt_ref.get().exists:
        return False
    putt_ref.delete()
    client.collection(_SESSIONS).document(session_id).set(
        {"putt_count": _count_putts(client, session_id)}, merge=True
    )
    return True


def offsets_for_sessions(uid: str, session_ids: list[str]) -> list[float]:
    """offset_mm for every putt across the given sessions (owned by `uid`).
    Batched for the dashboard summary."""
    client = _get_client()
    if client is None or not session_ids:
        return []
    wanted = set(session_ids)
    # One single-field query scoped to the user; filter to the requested
    # sessions (and drop null offsets) in Python. user_id on each putt enforces
    # ownership without a per-session read.
    q = client.collection(_PUTTS).where(filter=_field_filter("user_id", uid))
    offsets: list[float] = []
    for snap in q.stream():
        data = snap.to_dict() or {}
        if data.get("session_id") in wanted and data.get("offset_mm") is not None:
            offsets.append(data["offset_mm"])
    return offsets


def delete_session(uid: str, session_id: str) -> bool:
    """Delete a user's session (putts cascade). Returns True if a doc was
    deleted. Idempotent; no-op when persistence is disabled."""
    client = _get_client()
    if client is None:
        return False
    if _owned_session(client, uid, session_id) is None:
        return False
    _delete_putts_for_session(client, session_id)
    client.collection(_SESSIONS).document(session_id).delete()
    return True


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
    client = _get_client()
    if client is None:
        return False
    if _owned_session(client, uid, session_id) is None:
        return False
    client.collection(_SESSIONS).document(session_id).set(
        {
            "length_feet": length_feet,
            "break_type": break_type,
            "putter_id": _owns_putter(client, uid, putter_id),
        },
        merge=True,
    )
    return True


# ---- putters (ownership-scoped by uid) --------------------------------------


def list_putters(uid: str) -> list[dict[str, Any]]:
    """A user's putters, active first then newest."""
    client = _get_client()
    if client is None:
        return []
    q = client.collection(_PUTTERS).where(filter=_field_filter("user_id", uid))
    docs = list(q.stream())
    # Two stable passes: newest-first, then active-first. Python's sort is stable,
    # so the second pass keeps the created-at order within each group.
    docs.sort(key=lambda d: _iso((d.to_dict() or {}).get("created_at")) or "", reverse=True)
    docs.sort(key=lambda d: 0 if (d.to_dict() or {}).get("is_active") else 1)
    return [_putter_row(d) for d in docs]


def create_putter(uid: str, fields: dict[str, Any]) -> Optional[dict[str, Any]]:
    """Insert a putter owned by `uid`. Returns the created row."""
    client = _get_client()
    if client is None:
        return None

    from google.cloud import firestore

    putter_id = str(uuid.uuid4())
    ref = client.collection(_PUTTERS).document(putter_id)
    ref.set(
        {
            "user_id": uid,
            "name": fields.get("name"),
            "brand": fields.get("brand"),
            "model": fields.get("model"),
            "length_in": fields.get("length_in"),
            "lie_deg": fields.get("lie_deg"),
            "grip": fields.get("grip"),
            "is_active": False,
            "created_at": firestore.SERVER_TIMESTAMP,
        }
    )
    return _putter_row(ref.get())


# Putter fields a client is allowed to update.
_PUTTER_EDITABLE = ("name", "brand", "model", "length_in", "lie_deg", "grip")


def update_putter(
    uid: str, putter_id: str, fields: dict[str, Any]
) -> Optional[dict[str, Any]]:
    """Update the provided editable fields on a user's putter. Returns the
    updated row, or None if it doesn't exist / isn't owned by `uid`."""
    client = _get_client()
    if client is None:
        return None
    ref = client.collection(_PUTTERS).document(putter_id)
    snap = ref.get()
    if not snap.exists or (snap.to_dict() or {}).get("user_id") != uid:
        return None
    updates = {c: fields[c] for c in _PUTTER_EDITABLE if c in fields}
    if updates:
        ref.set(updates, merge=True)
        snap = ref.get()
    return _putter_row(snap)


def get_putter(uid: str, putter_id: str) -> Optional[dict[str, Any]]:
    """One putter, only if owned by `uid`."""
    client = _get_client()
    if client is None:
        return None
    snap = client.collection(_PUTTERS).document(putter_id).get()
    if not snap.exists or (snap.to_dict() or {}).get("user_id") != uid:
        return None
    return _putter_row(snap)


def delete_putter(uid: str, putter_id: str) -> bool:
    """Delete a user's putter. Its sessions are un-tagged (putter_id cleared),
    mirroring the old ON DELETE SET NULL. Returns True if a doc was deleted."""
    client = _get_client()
    if client is None:
        return False
    ref = client.collection(_PUTTERS).document(putter_id)
    snap = ref.get()
    if not snap.exists or (snap.to_dict() or {}).get("user_id") != uid:
        return False
    # Un-tag any sessions that referenced this putter.
    q = client.collection(_SESSIONS).where(filter=_field_filter("putter_id", putter_id))
    for sess in q.stream():
        sess.reference.set({"putter_id": None}, merge=True)
    ref.delete()
    return True


def set_active_putter(uid: str, putter_id: str) -> bool:
    """Atomically make `putter_id` the user's active putter, clearing any
    previously active one. Returns True if the target putter exists and is now
    active."""
    client = _get_client()
    if client is None:
        return False

    target = client.collection(_PUTTERS).document(putter_id)
    snap = target.get()
    if not snap.exists or (snap.to_dict() or {}).get("user_id") != uid:
        return False

    # Clear any other active putters for this user, then activate the target.
    # (No composite index needed: filter by user_id, check the flag in Python.)
    q = client.collection(_PUTTERS).where(filter=_field_filter("user_id", uid))
    batch = client.batch()
    for other in q.stream():
        if other.id != putter_id and (other.to_dict() or {}).get("is_active"):
            batch.set(other.reference, {"is_active": False}, merge=True)
    batch.set(target, {"is_active": True}, merge=True)
    batch.commit()
    return True
