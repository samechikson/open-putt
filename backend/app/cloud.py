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
import tempfile
from datetime import timedelta
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

# Cloud Tasks adds this header to the /process request; the handler checks it.
TASK_TOKEN_HEADER = "X-Tasks-Token"

_storage_client = None
_tasks_client = None


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


# MARK: Cloud Storage


def upload_file_to_gcs(local_path: str, object_name: str) -> None:
    """Upload a local temp file to the bucket. Blocking; call via a threadpool."""
    _bucket().blob(object_name).upload_from_filename(local_path)


def download_gcs_to_temp(object_name: str) -> str:
    """Download an object to a temp file and return its path. Blocking."""
    suffix = os.path.splitext(object_name)[1] or ".mp4"
    fd, tmp_path = tempfile.mkstemp(suffix=suffix)
    os.close(fd)
    _bucket().blob(object_name).download_to_filename(tmp_path)
    return tmp_path


def object_exists(object_name: str) -> bool:
    """True if the object is present in the bucket. Blocking."""
    return _bucket().blob(object_name).exists()


def generate_upload_url(object_name: str) -> str:
    """A short-lived V4 signed URL the client PUTs the video to directly.

    On Cloud Run the runtime credentials have no private key, so signing goes
    through the IAM signBlob API — the signer service account (`GCS_SIGNER_SA`)
    must hold `roles/iam.serviceAccountTokenCreator` on itself. Content-Type is
    intentionally not signed, so clients may PUT with any/no Content-Type.
    """
    from google.auth import default as google_default
    from google.auth.transport.requests import Request as AuthRequest

    creds, _ = google_default()
    creds.refresh(AuthRequest())
    signer_email = GCS_SIGNER_SA or getattr(creds, "service_account_email", None)
    return _bucket().blob(object_name).generate_signed_url(
        version="v4",
        expiration=UPLOAD_URL_TTL,
        method="PUT",
        service_account_email=signer_email,
        access_token=creds.token,
    )


def delete_gcs_object(object_name: str) -> None:
    """Best-effort delete of the transient upload. Blocking."""
    try:
        _bucket().blob(object_name).delete()
    except Exception:  # noqa: BLE001 — cleanup is best-effort (lifecycle rule backs it up)
        logger.warning("Could not delete GCS object %s", object_name, exc_info=True)


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
