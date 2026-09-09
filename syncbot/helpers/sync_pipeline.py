"""Discover subscribers and apply one envelope to each target."""

from __future__ import annotations

import logging
from typing import Any

from slack_sdk import WebClient

from db import schemas
from helpers.envelope import ACTION_ADD, ACTION_DELETE, ACTION_EDIT, ACTION_REMOVE
from helpers.post_meta import get_post_records
from helpers.sync_apply import apply_target
from helpers.sync_participation import iter_publish_targets
from helpers.user_action_echo import slack_message_ts
from helpers.workspace import get_federated_workspace_for_sync

_logger = logging.getLogger(__name__)


def run_sync_pipeline(
    envelope: dict[str, Any],
    *,
    source_channel_id: str,
    source_client: WebClient | None = None,
    source_sync_channel: schemas.SyncChannel | None = None,
    origin_ts: str | None = None,
    thread_parent_ts_by_channel: dict[str, str] | None = None,
) -> list[schemas.PostMeta]:
    """Discover subscribers, dedupe, apply. Returns PostMeta rows to persist (targets only)."""
    targets = iter_publish_targets(source_channel_id)
    if not targets:
        return []

    post_list: list[schemas.PostMeta] = []
    name_probe_cache: dict = {}
    source_workspace_id = envelope.get("source_workspace_id")

    post_records_by_channel: dict[str, schemas.PostMeta] = {}
    if envelope.get("action") in (ACTION_EDIT, ACTION_DELETE, ACTION_ADD, ACTION_REMOVE):
        lookup_ts = origin_ts or envelope.get("source_ts")
        if lookup_ts:
            for pm, sc, _ws in get_post_records(lookup_ts):
                post_records_by_channel[sc.channel_id] = pm

    for sync_channel, workspace in targets:
        try:
            fed_ws = get_federated_workspace_for_sync(sync_channel.sync_id)
            is_remote = bool(fed_ws and source_workspace_id and workspace.id != source_workspace_id)
            target_meta = post_records_by_channel.get(sync_channel.channel_id)
            thread_ts = None
            if thread_parent_ts_by_channel:
                thread_ts = thread_parent_ts_by_channel.get(sync_channel.channel_id)

            if is_remote and fed_ws:
                from federation.deliver import deliver_remote

                env = dict(envelope)
                env["sync_id"] = sync_channel.sync_id
                if target_meta is not None:
                    env["target_ts"] = slack_message_ts(target_meta.ts)
                deliver_remote(env, fed_ws, sync_channel.channel_id)
                continue

            created = apply_target(
                envelope,
                sync_channel,
                workspace,
                source_client=source_client,
                source_sync_channel=source_sync_channel,
                thread_ts=thread_ts,
                target_post_meta=target_meta,
                name_probe_cache=name_probe_cache,
            )
            post_list.extend(created)
        except Exception as exc:
            _logger.warning(
                "run_sync_pipeline_target_failed",
                extra={"channel_id": sync_channel.channel_id, "error": str(exc)},
            )
    return post_list
