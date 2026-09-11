"""File upload/download helpers for message sync."""

import contextlib
import logging
import os
import re
import time as _time
from collections.abc import Callable
from logging import Logger

import requests
from slack_sdk import WebClient

from helpers.user_action_echo import slack_message_ts
from logger import log_sync

_logger = logging.getLogger(__name__)

_DOWNLOAD_TIMEOUT = 30  # seconds
_MAX_FILE_BYTES = 100 * 1024 * 1024  # 100 MB
_STREAM_CHUNK = 8192
_EXTRACT_TRIES = 8
_EXTRACT_SLEEP_S = 0.5


def cleanup_temp_files(photos: list[dict] | None, direct_files: list[dict] | None) -> None:
    """Remove temporary files created during message sync."""
    for item in photos or []:
        path = item.get("path")
        if path:
            with contextlib.suppress(OSError):
                os.remove(path)
    for item in direct_files or []:
        path = item.get("path")
        if path:
            with contextlib.suppress(OSError):
                os.remove(path)


def _safe_file_parts(f: dict) -> tuple[str, str, str]:
    """Return ``(safe_id, safe_ext, default_name)`` with path-safe characters only."""
    safe_id = re.sub(r"[^a-zA-Z0-9_-]", "", f.get("id", "file"))
    safe_ext = re.sub(r"[^a-zA-Z0-9]", "", f.get("filetype", "bin"))
    return safe_id, safe_ext, f"{safe_id}.{safe_ext}"


def _download_to_file(url: str, file_path: str, headers: dict | None = None) -> None:
    """Stream a URL to disk, aborting if the response exceeds *_MAX_FILE_BYTES*.

    Removes the partial file on any failure so /tmp doesn't fill up.
    """
    try:
        with requests.get(url, headers=headers, timeout=_DOWNLOAD_TIMEOUT, stream=True) as r:
            r.raise_for_status()
            written = 0
            with open(file_path, "wb") as fh:
                for chunk in r.iter_content(chunk_size=_STREAM_CHUNK):
                    written += len(chunk)
                    if written > _MAX_FILE_BYTES:
                        raise ValueError(f"File exceeds {_MAX_FILE_BYTES} byte limit")
                    fh.write(chunk)
    except Exception:
        with contextlib.suppress(OSError):
            os.remove(file_path)
        raise


def download_slack_files(files: list[dict], client: WebClient, logger: Logger) -> list[dict]:
    """Download files from Slack to /tmp for direct re-upload.

    Skips stubs that have no private URL (tombstones, access-restricted, and
    external files without ``url_private``). Keeps Slack's original ``name`` so
    ``files_upload_v2`` can infer type from the extension.
    """
    downloaded: list[dict] = []
    auth_headers = {"Authorization": f"Bearer {client.token}"}
    skip_modes = frozenset({"file_access", "tombstone", "hidden_by_limit"})

    for f in files:
        try:
            url = f.get("url_private")
            mode = f.get("mode")
            if not url:
                continue
            if mode in skip_modes:
                continue

            safe_id, safe_ext, default_name = _safe_file_parts(f)
            file_name = f.get("name") or default_name
            file_path = f"/tmp/{safe_id}.{safe_ext}"

            _download_to_file(url, file_path, headers=auth_headers)

            downloaded.append(
                {
                    "path": file_path,
                    "name": file_name,
                    "mimetype": f.get("mimetype", "application/octet-stream"),
                }
            )
        except Exception as e:
            logger.error(f"download_slack_files: failed for {f.get('id')}: {e}")
    return downloaded


def _read_local_file_bytes(path: str) -> bytes:
    with open(path, "rb") as handle:
        return handle.read()


def upload_files_to_slack(
    bot_token: str,
    channel_id: str,
    files: list[dict],
    initial_comment: str | None = None,
    thread_ts: str | None = None,
    reply_broadcast: bool = False,
    after_upload: Callable | None = None,
    after_share_ts: Callable | None = None,
) -> tuple[dict | None, str | None]:
    """Upload one or more local files directly to a Slack channel.

    *after_upload* receives file ids before ``files.completeUploadExternal``
    shares them into the Channel. *after_share_ts* runs once the share
    message ts is known, before ``chat.update``.

    ``files.completeUploadExternal`` does not support ``reply_broadcast``.
    When broadcasting is requested for a thread upload, complete first, then
    ``chat.update`` the share with ``reply_broadcast=True``.
    """
    if not files:
        return None, None

    slack_client = WebClient(bot_token)
    try:
        prepared: list[dict] = []
        for item in files:
            data = _read_local_file_bytes(item["path"])
            filename = item["name"]
            url_response = slack_client.files_getUploadURLExternal(filename=filename, length=len(data))
            file_id = url_response.get("file_id")
            upload_url = url_response.get("upload_url")
            if not file_id or not upload_url:
                raise RuntimeError("files.getUploadURLExternal did not return file_id and upload_url")
            prepared.append(
                {
                    "file_id": str(file_id),
                    "upload_url": upload_url,
                    "data": data,
                    "title": filename,
                }
            )

        if after_upload:
            after_upload([item["file_id"] for item in prepared])

        for item in prepared:
            put = requests.post(item["upload_url"], data=item["data"], timeout=_DOWNLOAD_TIMEOUT)
            if put.status_code != 200:
                raise RuntimeError(f"file upload POST returned {put.status_code}")

        complete_kwargs: dict = {
            "files": [{"id": item["file_id"], "title": item["title"]} for item in prepared],
            "channel_id": channel_id,
        }
        if initial_comment:
            complete_kwargs["initial_comment"] = initial_comment
        if thread_ts:
            complete_kwargs["thread_ts"] = thread_ts
        res = slack_client.files_completeUploadExternal(**complete_kwargs)

        msg_ts = _extract_file_message_ts(slack_client, res, channel_id, thread_ts=thread_ts)
        if after_share_ts and msg_ts:
            after_share_ts(msg_ts)
        if reply_broadcast and thread_ts and msg_ts:
            _broadcast_thread_file_share(slack_client, channel_id, msg_ts)
        return res, msg_ts
    except Exception as e:
        _logger.warning(f"upload_files_to_slack: failed for channel {channel_id}: {e}")
        return None, None


def _broadcast_thread_file_share(client: WebClient, channel_id: str, message_ts: str) -> None:
    """Also-send an existing thread file share to the channel via chat.update."""
    try:
        # Omit text/blocks so Slack only flips reply_broadcast (no content rewrite).
        client.chat_update(channel=channel_id, ts=message_ts, reply_broadcast=True)
    except Exception as e:
        _logger.warning(
            "upload_files_to_slack: reply_broadcast via chat.update failed",
            extra={"channel_id": channel_id, "ts": message_ts, "error": str(e)},
        )


def _share_ts_from_file_payload(
    file_obj: dict | None,
    channel_id: str,
    thread_ts: str | None = None,
) -> str | None:
    """Return the share *message* ts from a file object's ``shares`` map.

    A file uploaded into a thread is a new message: ``thread_ts`` is the
    parent and ``ts`` is the share. Slack may also list the parent
    (``ts == thread_ts``). That parent ts must not be used for PostMeta or
    user-token echo — the inbound ``file_share`` has the new ts, would miss
    both guards, and re-sync in a loop. Bot-token uploads are skipped via
    ``bot_id``; user-token uploads are not.
    """
    if not isinstance(file_obj, dict):
        return None
    shares = file_obj.get("shares") or {}
    if not isinstance(shares, dict):
        return None
    parent = str(thread_ts) if thread_ts else None
    for share_type in ("public", "private"):
        channel_shares = (shares.get(share_type) or {}).get(channel_id, [])
        if not channel_shares:
            continue
        if parent:
            for share in channel_shares:
                ts = share.get("ts")
                if not ts:
                    continue
                ts_s = str(ts)
                if ts_s == parent:
                    continue
                if str(share.get("thread_ts") or "") == parent:
                    return ts_s
            continue
        ts = channel_shares[0].get("ts")
        if ts:
            return str(ts)
    return None


def _file_id_from_upload_response(upload_response) -> str | None:
    """Best-effort file id from a complete-upload response."""
    if not upload_response:
        return None
    with contextlib.suppress(KeyError, TypeError, IndexError, AttributeError):
        file_id = upload_response["file"]["id"]
        if file_id:
            return str(file_id)
    with contextlib.suppress(KeyError, TypeError, IndexError, AttributeError):
        data = getattr(upload_response, "data", None) or upload_response
        file_id = data["file"]["id"]
        if file_id:
            return str(file_id)
    try:
        data = getattr(upload_response, "data", None) or upload_response
        files_list = data["files"]
        if files_list and len(files_list) > 0:
            first = files_list[0]
            file_id = first["id"] if isinstance(first, dict) else first.get("id")
            if file_id:
                return str(file_id)
    except (KeyError, TypeError, IndexError, AttributeError):
        pass
    return None


def file_ids_from_message_event(body: dict) -> list[str]:
    """File ids on a Slack message event, including ``message.files`` on edits."""
    event = body.get("event") or {}
    files = event.get("files") or event.get("message", {}).get("files") or []
    ids: list[str] = []
    for item in files:
        if isinstance(item, dict) and item.get("id"):
            ids.append(str(item["id"]))
    return ids


def event_is_new_file_share(event: dict | None) -> bool:
    """True when this event uploaded files, not a later share of an existing file.

    Slack ``file_share`` with ``upload`` omitted or true is a new share.
    ``upload: false`` is a later share of a parent file (often a text reply).
    Read ``event.get("upload")`` so ``False`` is not treated as missing.
    """
    if not isinstance(event, dict) or event.get("subtype") != "file_share":
        return False
    return event.get("upload") is not False


def _extract_file_message_ts(
    client: WebClient,
    upload_response,
    channel_id: str,
    thread_ts: str | None = None,
) -> str | None:
    """Extract the message ts created by a file upload.

    Prefer ``shares`` on the upload response when that ts is the new share,
    not the thread parent. The share is already in channel history; poll
    ``files.info`` only if that ts is not listed yet.
    """
    if not upload_response:
        return None

    data = getattr(upload_response, "data", None) or upload_response
    with contextlib.suppress(KeyError, TypeError, IndexError, AttributeError):
        ts = _share_ts_from_file_payload(data.get("file"), channel_id, thread_ts=thread_ts)
        if ts:
            log_sync("file_share_ts", channel_id=channel_id, ts=ts, source="upload_shares", thread_ts=thread_ts)
            return ts
    with contextlib.suppress(KeyError, TypeError, IndexError, AttributeError):
        files_list = data.get("files") or []
        if files_list:
            first = files_list[0] if isinstance(files_list[0], dict) else None
            ts = _share_ts_from_file_payload(first, channel_id, thread_ts=thread_ts)
            if ts:
                log_sync("file_share_ts", channel_id=channel_id, ts=ts, source="upload_shares", thread_ts=thread_ts)
                return ts

    file_id = _file_id_from_upload_response(upload_response)
    if not file_id:
        _logger.warning("_extract_file_message_ts: could not find file_id in upload response")
        return None

    # completeUploadExternal and the first files.info often have empty shares;
    # the share message is also missing from history for a few seconds.
    for attempt in range(_EXTRACT_TRIES):
        ts = _share_ts_from_channel_history(client, channel_id, file_id, thread_ts=thread_ts)
        if ts:
            log_sync(
                "file_share_ts",
                channel_id=channel_id,
                ts=ts,
                source="history",
                thread_ts=thread_ts,
                attempt=attempt,
            )
            return ts
        try:
            info_resp = client.files_info(file=file_id)
            payload = getattr(info_resp, "data", None) or info_resp
            file_obj = payload.get("file") if isinstance(payload, dict) else None
            if file_obj is None:
                file_obj = info_resp.get("file")
            ts = _share_ts_from_file_payload(file_obj, channel_id, thread_ts=thread_ts)
            if ts:
                log_sync(
                    "file_share_ts",
                    channel_id=channel_id,
                    ts=ts,
                    source="files_info",
                    thread_ts=thread_ts,
                    attempt=attempt,
                )
                return ts
        except Exception as e:
            _logger.warning(f"_extract_file_message_ts: files.info error (attempt {attempt}): {e}")

        if attempt < _EXTRACT_TRIES - 1:
            _time.sleep(_EXTRACT_SLEEP_S)

    _logger.warning(f"_extract_file_message_ts: could not resolve ts for file {file_id} after retries")
    log_sync("file_share_ts", channel_id=channel_id, ts=None, source="none", thread_ts=thread_ts, file_id=file_id)
    return None


def _share_ts_from_channel_history(
    client: WebClient,
    channel_id: str,
    file_id: str,
    thread_ts: str | None = None,
) -> str | None:
    """Find the share message ts by looking up *file_id* in recent channel messages."""
    parent = str(thread_ts) if thread_ts else None
    try:
        if parent:
            res = client.conversations_replies(channel=channel_id, ts=parent, limit=20)
        else:
            res = client.conversations_history(channel=channel_id, limit=10)
    except Exception as exc:
        _logger.debug("_extract_file_message_ts: history fallback failed: %s", exc)
        return None
    messages = res.get("messages") if hasattr(res, "get") else None
    if messages is None:
        data = getattr(res, "data", None)
        messages = data.get("messages") if isinstance(data, dict) else None
    if not isinstance(messages, list):
        return None
    for msg in messages:
        if not isinstance(msg, dict):
            continue
        files = msg.get("files") or []
        ids = {str(item["id"]) for item in files if isinstance(item, dict) and item.get("id")}
        if file_id not in ids:
            continue
        ts = msg.get("ts")
        if not ts:
            continue
        ts_s = str(ts)
        if parent and slack_message_ts(ts_s) == slack_message_ts(parent):
            continue
        return ts_s
    return None
