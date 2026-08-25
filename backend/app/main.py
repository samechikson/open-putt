from fastapi import FastAPI, HTTPException, Request, Depends
from fastapi.concurrency import run_in_threadpool
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
import logging
import os
import uuid
from . import db
from .db import (
    delete_putt,
    delete_session,
    update_session_metadata,
    list_sessions,
    get_session,
    list_putts,
    offsets_for_sessions,
    list_putters,
    create_putter,
    update_putter,
    delete_putter,
    set_active_putter,
    ingest_device_putt,
)
from .auth import require_user, require_user_or_device

logger = logging.getLogger(__name__)

# The `putt_break` values (mirror of BREAK_TYPES in frontend/src/sessions.ts).
# Used to validate the break_type on a session metadata edit.
_BREAK_TYPES = frozenset(
    {
        "straight",
        "leftToRight",
        "rightToLeft",
        "uphillStraight",
        "uphillLeftToRight",
        "uphillRightToLeft",
        "downhillStraight",
        "downhillLeftToRight",
        "downhillRightToLeft",
    }
)

app = FastAPI(title="Putting Gate")

# Allowed browser origins. Defaults cover local dev; set CORS_ALLOW_ORIGINS to a
# comma-separated list (e.g. the deployed frontend URL) in production.
_default_origins = "http://localhost:5173,http://localhost:3000"
allow_origins = [
    o.strip()
    for o in os.environ.get("CORS_ALLOW_ORIGINS", _default_origins).split(",")
    if o.strip()
]

app.add_middleware(
    CORSMiddleware,
    allow_origins=allow_origins,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health")
def health():
    return {"status": "ok"}


# MARK: Device ingestion (hardware gate; the only putt source). Authenticated as
# either the signed-in user (the iOS app relaying the gate's putts over BLE) or
# the device itself (legacy ESP32 direct POST with X-Device-Token).

# The gate reports PUSH (past center) / PULL (short of center); map those to the
# app's putt_direction sides. Flip on the device (INVERT_PUSH_PULL) if a side
# comes out mirrored for your sensor mounting.
_LABEL_TO_DIRECTION = {"PUSH": "right", "PULL": "left", "CENTER": "center"}


@app.post("/device/putts", status_code=201)
async def device_putt(request: Request, uid: str = Depends(require_user_or_device)):
    """Ingest one pre-measured putt from the hardware gate.

    Body: `{session_id, putt_index, offset_mm, label, speed_mps?, sensors}`. The device has
    already done the analysis, so there's no video or calibration — this upserts
    an already-`done` session and appends the putt. Idempotent per (session_id,
    putt_index), so the device can safely retry. `sensors` (the per-sensor
    offsets) is required and must be complete: a putt is only counted when every
    sensor saw the ball, so a partial reading (a missing per-sensor value) is
    rejected as an errant trip rather than stored.
    """
    body = await request.json()

    session_id = body.get("session_id")
    try:
        session_id = str(uuid.UUID(str(session_id)))
    except (ValueError, TypeError, AttributeError):
        raise HTTPException(status_code=400, detail="session_id must be a UUID.")

    try:
        putt_index = int(body.get("putt_index"))
    except (TypeError, ValueError):
        raise HTTPException(status_code=400, detail="putt_index must be an integer.")

    try:
        offset_mm = float(body.get("offset_mm"))
    except (TypeError, ValueError):
        raise HTTPException(status_code=400, detail="offset_mm must be a number.")

    direction = _LABEL_TO_DIRECTION.get(str(body.get("label", "")).upper())
    if direction is None:
        raise HTTPException(status_code=400, detail="label must be PUSH, PULL, or CENTER.")

    # Speed is optional: the ball must trip at least two sensors to time it, so a
    # glancing pass sends null. Persist whatever the device measured.
    speed_mps = body.get("speed_mps")
    if speed_mps is not None:
        try:
            speed_mps = float(speed_mps)
        except (TypeError, ValueError):
            raise HTTPException(status_code=400, detail="speed_mps must be a number.")

    # Per-sensor offsets behind the average, in the device's mounting order; a
    # sensor that didn't see the ball sends null. Optional / forward-compatible.
    sensors = body.get("sensors")
    if sensors is not None:
        if not isinstance(sensors, list):
            raise HTTPException(status_code=400, detail="sensors must be a list.")
        try:
            sensors = [None if v is None else float(v) for v in sensors]
        except (TypeError, ValueError):
            raise HTTPException(status_code=400, detail="sensors must be numbers or null.")

    # Only count a putt where every sensor saw the ball. A real putt rolls over
    # all the in-line sensors; a partial reading (a missing per-sensor value, or
    # no sensors at all) is almost always an errant trip — e.g. sunlight tripping
    # a single sensor outdoors — so reject it rather than store a bogus putt. The
    # firmware and the app apply the same guard, so this is a backstop for an
    # old-firmware device or a direct post.
    if not sensors or any(v is None for v in sensors):
        raise HTTPException(
            status_code=422,
            detail="Putt ignored: not all sensors detected the ball.",
        )

    # The device isn't a camera, so it has no face-on mirror — but the shared
    # frontend applies one (golferSide negates offset_mm to get the golfer's
    # side). Pre-invert here so a PUSH (ball right of the line) reads as "right"
    # in the UI, matching the stored direction. Invert the per-sensor offsets
    # identically so every stored offset shares one sign convention.
    offset_mm = -offset_mm
    if sensors is not None:
        sensors = [None if v is None else -v for v in sensors]

    session = await run_in_threadpool(
        ingest_device_putt, uid, session_id, putt_index, offset_mm, direction,
        speed_mps, sensors,
    )
    if session is None:
        raise HTTPException(status_code=503, detail="Persistence is not configured.")
    return JSONResponse(
        {"session_id": session_id, "putt_index": putt_index}, status_code=201
    )


# MARK: Session reads (ownership-scoped by the authenticated user)


@app.get("/sessions")
async def sessions_list(uid: str = Depends(require_user)):
    """All of the signed-in user's sessions, newest first."""
    return await run_in_threadpool(list_sessions, uid)


@app.get("/sessions/{session_id}")
async def session_get(session_id: str, uid: str = Depends(require_user)):
    """One session, if it belongs to the signed-in user."""
    row = await run_in_threadpool(get_session, uid, session_id)
    if row is None:
        raise HTTPException(status_code=404, detail="Session not found.")
    return row


@app.get("/sessions/{session_id}/putts")
async def session_putts(session_id: str, uid: str = Depends(require_user)):
    """A session's putts, if the session belongs to the signed-in user. Clients
    poll this on a short interval while a session is live (a gate session keeps
    gaining putts) to pick up new putts."""
    return await run_in_threadpool(list_putts, uid, session_id)


@app.post("/putts/offsets")
async def putts_offsets(request: Request, uid: str = Depends(require_user)):
    """offset_mm for every putt across the given owned sessions (dashboard
    summary). Body: `{session_ids: [...]}`. POST (not GET) so a large id list
    isn't constrained by URL length."""
    body = await request.json()
    session_ids = body.get("session_ids") or []
    if not isinstance(session_ids, list):
        raise HTTPException(status_code=400, detail="session_ids must be a list.")
    offsets = await run_in_threadpool(offsets_for_sessions, uid, session_ids)
    return {"offsets": offsets}


@app.delete("/sessions/{session_id}/putts/{putt_index}")
async def delete_putt_endpoint(
    session_id: str, putt_index: int, uid: str = Depends(require_user)
):
    """Delete one putt from the user's session (e.g. a mishit or a false trip).
    Keeps the session's putt_count in sync. 404 if the putt doesn't exist or the
    session isn't the user's."""
    ok = await run_in_threadpool(delete_putt, uid, session_id, putt_index)
    if not ok:
        raise HTTPException(status_code=404, detail="Putt not found.")
    return JSONResponse({"status": "deleted"})


@app.delete("/sessions/{session_id}")
async def delete_session_endpoint(session_id: str, uid: str = Depends(require_user)):
    """Delete the user's session: its putts and the row. Idempotent — deleting a
    missing/other-owner session is a no-op."""
    await run_in_threadpool(delete_session, uid, session_id)
    return JSONResponse({"status": "deleted"})


@app.patch("/sessions/{session_id}")
async def update_session_endpoint(
    session_id: str, request: Request, uid: str = Depends(require_user)
):
    """Update the user's session metadata: putt distance, break type, putter.

    Body: `{length_feet?, break_type?, putter_id?}`. Any may be null to clear it.
    """
    body = await request.json()

    length_feet = body.get("length_feet")
    if length_feet is not None:
        try:
            length_feet = int(length_feet)
        except (TypeError, ValueError):
            raise HTTPException(status_code=400, detail="length_feet must be an integer.")
        if length_feet < 0:
            raise HTTPException(status_code=400, detail="length_feet must be non-negative.")

    break_type = body.get("break_type")
    if break_type is not None and break_type not in _BREAK_TYPES:
        raise HTTPException(status_code=400, detail="Unknown break_type.")

    putter_id = body.get("putter_id")
    if putter_id is not None:
        try:
            putter_id = str(uuid.UUID(str(putter_id)))
        except (TypeError, ValueError):
            raise HTTPException(status_code=400, detail="putter_id must be a UUID.")

    ok = await run_in_threadpool(
        update_session_metadata, uid, session_id, length_feet, break_type, putter_id
    )
    if not ok:
        raise HTTPException(status_code=404, detail="Session not found.")
    return JSONResponse({"status": "updated"})


# MARK: Putters (owned by the authenticated user)


def _putter_fields(body: dict, *, require_name: bool) -> dict:
    """Validate/coerce a putter payload. `name` is required on create."""
    fields: dict = {}
    if "name" in body or require_name:
        name = (body.get("name") or "").strip()
        if require_name and not name:
            raise HTTPException(status_code=400, detail="name is required.")
        if "name" in body:
            fields["name"] = name
    for k in ("brand", "model", "grip"):
        if k in body:
            v = body.get(k)
            fields[k] = v.strip() if isinstance(v, str) else v
    for k in ("length_in", "lie_deg"):
        if k in body:
            v = body.get(k)
            if v is None or v == "":
                fields[k] = None
            else:
                try:
                    fields[k] = float(v)
                except (TypeError, ValueError):
                    raise HTTPException(status_code=400, detail=f"{k} must be a number.")
    return fields


@app.get("/putters")
async def putters_list(uid: str = Depends(require_user)):
    """The user's putters, active first then newest."""
    return await run_in_threadpool(list_putters, uid)


@app.post("/putters", status_code=201)
async def putters_create(request: Request, uid: str = Depends(require_user)):
    """Create a putter owned by the user."""
    fields = _putter_fields(await request.json(), require_name=True)
    row = await run_in_threadpool(create_putter, uid, fields)
    if row is None:
        raise HTTPException(status_code=503, detail="Persistence is not configured.")
    return row  # status 201 from the decorator


@app.patch("/putters/{putter_id}")
async def putters_update(
    putter_id: str, request: Request, uid: str = Depends(require_user)
):
    """Update the user's putter."""
    fields = _putter_fields(await request.json(), require_name=False)
    row = await run_in_threadpool(update_putter, uid, putter_id, fields)
    if row is None:
        raise HTTPException(status_code=404, detail="Putter not found.")
    return row


@app.delete("/putters/{putter_id}")
async def putters_delete(putter_id: str, uid: str = Depends(require_user)):
    """Delete the user's putter (its sessions are un-tagged)."""
    ok = await run_in_threadpool(delete_putter, uid, putter_id)
    if not ok:
        raise HTTPException(status_code=404, detail="Putter not found.")
    return JSONResponse({"status": "deleted"})


@app.post("/putters/{putter_id}/activate")
async def putters_activate(putter_id: str, uid: str = Depends(require_user)):
    """Make this the user's active (default) putter."""
    ok = await run_in_threadpool(set_active_putter, uid, putter_id)
    if not ok:
        raise HTTPException(status_code=404, detail="Putter not found.")
    return JSONResponse({"status": "activated"})


# The public API is served under /api so the app can sit behind a same-origin
# proxy: Firebase Hosting rewrites `/api/**` to this Cloud Run service, so the
# web frontend never makes a cross-origin API call. Every caller targets the
# same prefix — the frontend (VITE_API_BASE=/api) and the iOS app
# (AppSettings.backendBaseURL + /api). The routes above stay defined at the root;
# this outer app is a thin mount. uvicorn serves `application` (see Dockerfile /
# start.sh).
application = FastAPI(title="Putting Gate (proxy root)")
application.mount("/api", app)


@application.on_event("shutdown")
def _close_db_client() -> None:
    # Mounted sub-apps don't receive lifespan events from the parent, so close
    # the Firestore client here on the served app's shutdown.
    db.close()
