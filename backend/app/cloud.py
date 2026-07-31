"""Google Cloud helpers: Cloud Storage for the transient video, Cloud Tasks to
hand the analysis to a background `/process` request.

All config comes from the environment so the module imports cleanly with none of
it set (e.g. in tests). Clients are created lazily. The Google libraries pick up
credentials from Application Default Credentials — on Cloud Run that's the
service account, so no key file is needed.
"""

from __future__ import annotations

import json
import logging
import os
import shutil
import tempfile
from datetime import timedelta
from pathlib import Path
from typing import Any, Optional

logger = logging.getLogger(__name__)

GCP_PROJECT = os.environ.get("GCP_PROJECT")
GCS_BUCKET = os.environ.get("GCS_BUCKET")
TASKS_QUEUE = os.environ.get("TASKS_QUEUE")
TASKS_LOCATION = os.environ.get("TASKS_LOCATION")
PROCESS_URL = os.environ.get("PROCESS_URL")
TASKS_INTERNAL_TOKEN = os.environ.get("TASKS_INTERNAL_TOKEN")
# Service account used to sign upload URLs (must have Token Creator on itself).
GCS_SIGNER_SA = os.environ.get("GCS_SIGNER_SA")
# How long a browser/iOS client has to PUT the video to the signed URL.
UPLOAD_URL_TTL = timedelta(minutes=30)
# How long a signed playback URL stays valid.
DOWNLOAD_URL_TTL = timedelta(hours=1)

# Cloud Tasks adds this header to the /process request; the handler checks it.
TASK_TOKEN_HEADER = "X-Tasks-Token"

# Local mode (LOCAL_MODE=1): storage is a local directory and analysis runs
# in-process, so the whole flow works on a laptop with no GCP. The upload/
# playback URLs point back at this backend (LOCAL_BASE_URL). The API is mounted
# under /api (see app/main.py), so the base includes that prefix.
LOCAL_MODE = os.environ.get("LOCAL_MODE") == "1"
LOCAL_BASE_URL = os.environ.get("LOCAL_BASE_URL", "http://localhost:8000/api")
LOCAL_STORAGE_DIR = Path(
    os.environ.get("LOCAL_STORAGE_DIR", Path(tempfile.gettempdir()) / "putting-gate-local")
)

_storage_client = None
_tasks_client = None


def is_local() -> bool:
    """True when running against local disk instead of GCS/Cloud Tasks."""
    return LOCAL_MODE


def storage_ready() -> bool:
    """True when uploads can be handled — either GCP is configured or local mode."""
    return is_local() or tasks_enabled()


def tasks_enabled() -> bool:
    """True when Cloud Storage + Cloud Tasks are configured (the async path)."""
    return bool(GCS_BUCKET and TASKS_QUEUE and TASKS_LOCATION and PROCESS_URL and GCP_PROJECT)


def _bucket():
    global _storage_client
    if _storage_client is None:
        from google.cloud import storage  # imported lazily

        _storage_client = storage.Client(project=GCP_PROJECT)
    return _storage_client.bucket(GCS_BUCKET)


def _tasks():
    global _tasks_client
    if _tasks_client is None:
        from google.cloud import tasks_v2  # imported lazily

        _tasks_client = tasks_v2.CloudTasksClient()
    return _tasks_client


def object_name_for(session_id: str, filename: Optional[str]) -> str:
    """Storage path for a session's upload, preserving the file extension."""
    ext = os.path.splitext(filename or "")[1] or ".mp4"
    return f"uploads/{session_id}{ext}"


def retained_object_name(upload_object_name: str) -> str:
    """Path under the retained `sessions/` prefix (kept 90 days) for a clip that
    was uploaded to the transient `uploads/` prefix (deleted after 1 day)."""
    return "sessions/" + upload_object_name.removeprefix("uploads/")


# MARK: Local disk (LOCAL_MODE)


def local_path(object_name: str) -> Path:
    """Filesystem path for an object under the local storage dir. Rejects any
    path that escapes the storage root or the uploads/ | sessions/ prefixes."""
    if ".." in object_name or object_name.startswith("/"):
        raise ValueError("invalid object name")
    if not (object_name.startswith("uploads/") or object_name.startswith("sessions/")):
        raise ValueError("invalid object name")
    return LOCAL_STORAGE_DIR / object_name


# MARK: Mode-aware storage API


def object_exists(object_name: str) -> bool:
    """True if the object is present. Blocking."""
    if is_local():
        return local_path(object_name).exists()
    return _bucket().blob(object_name).exists()


def download_to_temp(object_name: str) -> str:
    """Copy/download an object to a temp file and return its path. Blocking."""
    suffix = os.path.splitext(object_name)[1] or ".mp4"
    fd, tmp_path = tempfile.mkstemp(suffix=suffix)
    os.close(fd)
    if is_local():
        shutil.copyfile(local_path(object_name), tmp_path)
    else:
        _bucket().blob(object_name).download_to_filename(tmp_path)
    return tmp_path


def copy_object(src: str, dst: str) -> None:
    """Copy within storage (server-side for GCS). Blocking."""
    if is_local():
        dest = local_path(dst)
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(local_path(src), dest)
    else:
        bucket = _bucket()
        bucket.copy_blob(bucket.blob(src), bucket, dst)


def delete_object(object_name: str) -> None:
    """Best-effort delete. Blocking."""
    try:
        if is_local():
            local_path(object_name).unlink(missing_ok=True)
        else:
            _bucket().blob(object_name).delete()
    except Exception:  # noqa: BLE001 — cleanup is best-effort
        logger.warning("Could not delete object %s", object_name, exc_info=True)


def upload_url_for(object_name: str) -> str:
    """URL the client PUTs the video to: a signed GCS URL, or this backend's
    /local-storage endpoint in local mode."""
    if is_local():
        return f"{LOCAL_BASE_URL}/local-storage/{object_name}"
    return _signed_url(object_name, "PUT", UPLOAD_URL_TTL)


def download_url_for(object_name: str) -> str:
    """URL the frontend streams a retained video from."""
    if is_local():
        return f"{LOCAL_BASE_URL}/local-storage/{object_name}"
    return _signed_url(object_name, "GET", DOWNLOAD_URL_TTL)


def _signed_url(object_name: str, method: str, ttl: timedelta) -> str:
    """A short-lived V4 signed URL for the object.

    On Cloud Run the runtime credentials have no private key, so signing goes
    through the IAM signBlob API — the signer service account (`GCS_SIGNER_SA`)
    must hold `roles/iam.serviceAccountTokenCreator` on itself.
    """
    from google.auth import default as google_default
    from google.auth.transport.requests import Request as AuthRequest

    creds, _ = google_default()
    creds.refresh(AuthRequest())
    signer_email = GCS_SIGNER_SA or getattr(creds, "service_account_email", None)
    return _bucket().blob(object_name).generate_signed_url(
        version="v4",
        expiration=ttl,
        method=method,
        service_account_email=signer_email,
        access_token=creds.token,
    )


# MARK: Cloud Tasks


def enqueue_process_task(payload: dict[str, Any]) -> None:
    """Enqueue a task that POSTs `payload` to PROCESS_URL. Blocking."""
    from google.cloud import tasks_v2  # imported lazily

    parent = _tasks().queue_path(GCP_PROJECT, TASKS_LOCATION, TASKS_QUEUE)
    task = {
        "http_request": {
            "http_method": tasks_v2.HttpMethod.POST,
            "url": PROCESS_URL,
            "headers": {
                "Content-Type": "application/json",
                TASK_TOKEN_HEADER: TASKS_INTERNAL_TOKEN or "",
            },
            "body": json.dumps(payload).encode(),
        }
    }
    _tasks().create_task(parent=parent, task=task)
