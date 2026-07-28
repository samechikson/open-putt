"""Firebase Auth verification for user-facing endpoints.

The backend is now the sole DB client, so it must authenticate every user request
and derive the user's id (Firebase UID) from a verified ID token — replacing the
old scheme where the client simply asserted its own `user_id` in the body.

`require_user` is a FastAPI dependency returning the UID. In local development
(`AUTH_DEV_UID` set, e.g. by start.sh), it returns that fixed UID without
verifying, so the stack runs without Firebase Admin credentials. Otherwise it
verifies the token against Firebase — which needs Application Default
Credentials (`gcloud auth application-default login` locally; the runtime
service account on Cloud Run) and the project id in `FIREBASE_PROJECT_ID` /
`GOOGLE_CLOUD_PROJECT`.
"""

from __future__ import annotations

import hmac
import logging
import os
from typing import Optional

from fastapi import Header, HTTPException

logger = logging.getLogger(__name__)

_app = None
_app_ready = False


def _get_app():
    """Lazily initialize the Firebase Admin app (ADC creds on Cloud Run)."""
    global _app, _app_ready
    if _app_ready:
        return _app
    _app_ready = True
    try:
        import firebase_admin  # imported lazily so the dep is optional

        project = (
            os.environ.get("FIREBASE_PROJECT_ID")
            or os.environ.get("GOOGLE_CLOUD_PROJECT")
            or os.environ.get("GCLOUD_PROJECT")
        )
        options = {"projectId": project} if project else None
        _app = firebase_admin.initialize_app(options=options)
    except Exception:  # noqa: BLE001
        logger.exception("Could not initialize firebase-admin — auth unavailable.")
        _app = None
    return _app


def require_user(authorization: Optional[str] = Header(default=None)) -> str:
    """Return the caller's Firebase UID, or raise 401/503.

    Verifies the `Authorization: Bearer <idToken>` header against Firebase. In
    local dev, `AUTH_DEV_UID` short-circuits verification.
    """
    dev_uid = os.environ.get("AUTH_DEV_UID")
    if dev_uid:
        return dev_uid

    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Missing bearer token.")
    token = authorization.split(" ", 1)[1].strip()

    app = _get_app()
    if app is None:
        raise HTTPException(status_code=503, detail="Auth is not configured.")

    from firebase_admin import auth as fb_auth

    try:
        decoded = fb_auth.verify_id_token(token, app=app)
    except Exception as e:  # noqa: BLE001 — any verify failure is a 401
        logger.warning("Token verification failed: %s: %s", type(e).__name__, e)
        raise HTTPException(status_code=401, detail="Invalid or expired token.")
    return decoded["uid"]


def require_device(x_device_token: Optional[str] = Header(default=None)) -> str:
    """Return the Firebase UID a hardware device's putts are attributed to.

    Embedded devices (the ESP32 putt gate) can't do a full Firebase sign-in, so
    they authenticate with a single long-lived secret instead of an ID token —
    the same shared-secret pattern `/process` uses. `DEVICE_INGEST_TOKEN` is the
    secret (compared constant-time against the `X-Device-Token` header) and
    `DEVICE_INGEST_UID` is the owner all device sessions are attributed to.
    Single-tenant by design: one token → one user.
    """
    expected = os.environ.get("DEVICE_INGEST_TOKEN")
    uid = os.environ.get("DEVICE_INGEST_UID")
    if not expected or not uid:
        raise HTTPException(status_code=503, detail="Device ingestion is not configured.")
    if not x_device_token or not hmac.compare_digest(x_device_token, expected):
        raise HTTPException(status_code=401, detail="Invalid device token.")
    return uid
