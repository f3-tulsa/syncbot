"""Apply a sync envelope to one local target channel."""

from __future__ import annotations

import logging
from typing import Any

from slack_sdk import WebClient

from db import DbManager, schemas
from helpers.envelope import (
    ACTION_ADD,
    ACTION_CREATE,
    ACTION_DELETE,
    ACTION_EDIT,
    ACTION_REMOVE,
    KIND_MESSAGE,
    KIND_REACTION,
)
from helpers.post_meta import get_target_post_meta
from helpers.slack_write import slack_write_create, slack_write_delete, slack_write_edit
from helpers.sync_participation import channel_subscribes, get_live_sync_channel
from helpers.user_action_echo import post_meta_ts
from logger import log_sync

_logger = logging.getLogger(__name__)


def apply_target(
    envelope: dict[str, Any],
    sync_channel: schemas.SyncChannel,
    workspace: schemas.Workspace,
    *,
    source_client: WebClient | None = None,
    source_sync_channel: schemas.SyncChannel | None = None,
    thread_ts: str | None = None,
    target_post_meta: schemas.PostMeta | None = None,
    name_probe_cache: dict | None = None,
) -> list[schemas.PostMeta]:
    """Apply *envelope* to one target. Returns new PostMeta rows (if any)."""
    live = get_live_sync_channel(sync_channel)
    if not live or not channel_subscribes(live):
        return []
    sync_channel = live

    kind = envelope.get("kind")
    action = envelope.get("action")
    post_id = envelope.get("post_id")
    created: list[schemas.PostMeta] = []

    if kind == KIND_MESSAGE and action == ACTION_CREATE:
        if envelope.get("thread_post_id") and not thread_ts:
            return []
        ts, split_ts, posted_as = slack_write_create(
            envelope=envelope,
            sync_channel=sync_channel,
            workspace=workspace,
            source_client=source_client,
            thread_ts=thread_ts,
        )
        log_sync(
            "apply_create",
            channel_id=sync_channel.channel_id,
            ts=ts,
            split_ts=split_ts,
            thread_ts=thread_ts,
            post_id=post_id,
            file_count=len(envelope.get("file_refs") or []),
        )
        if not ts and (envelope.get("file_refs") or envelope.get("thread_post_id")):
            _logger.warning(
                "apply_create_missing_ts",
                extra={
                    "channel_id": sync_channel.channel_id,
                    "thread_ts": thread_ts,
                    "post_id": post_id,
                },
            )
        if ts:
            created.append(
                schemas.PostMeta(
                    post_id=post_id,
                    sync_channel_id=sync_channel.id,
                    ts=post_meta_ts(ts),
                    posted_as_user_id=posted_as,
                    source_user_id=envelope.get("source_user_id"),
                    source_workspace_id=envelope.get("source_workspace_id"),
                )
            )
        if split_ts:
            created.append(
                schemas.PostMeta(
                    post_id=post_id,
                    sync_channel_id=sync_channel.id,
                    ts=post_meta_ts(split_ts),
                    posted_as_user_id=posted_as,
                    source_user_id=envelope.get("source_user_id"),
                    source_workspace_id=envelope.get("source_workspace_id"),
                )
            )
        if created:
            DbManager.create_records(created)
        return created

    if kind == KIND_MESSAGE and action == ACTION_EDIT:
        meta = target_post_meta or get_target_post_meta(str(post_id), sync_channel)
        if not meta:
            return []
        slack_write_edit(
            envelope=envelope,
            sync_channel=sync_channel,
            workspace=workspace,
            target_post_meta=meta,
            source_client=source_client,
        )
        return []

    if kind == KIND_MESSAGE and action == ACTION_DELETE:
        meta = target_post_meta or get_target_post_meta(str(post_id), sync_channel)
        if not meta:
            return []
        slack_write_delete(sync_channel=sync_channel, workspace=workspace, target_post_meta=meta)
        return []

    if kind == KIND_REACTION and action in (ACTION_ADD, ACTION_REMOVE):
        from helpers.reaction import apply_reaction_to_target

        meta = target_post_meta or get_target_post_meta(str(post_id), sync_channel)
        if not meta or source_sync_channel is None:
            return []
        mapped_user_id = envelope.get("mapped_user_id")
        _result, notice = apply_reaction_to_target(
            action=action,
            reaction=envelope.get("reaction") or "",
            source_user_id=envelope.get("source_user_id"),
            source_workspace_id=envelope.get("source_workspace_id"),
            source_sync_channel=source_sync_channel,
            target_post_meta=meta,
            target_sync_channel=sync_channel,
            target_workspace=workspace,
            display_name=envelope.get("user_name") or "Someone",
            icon_url=envelope.get("user_avatar_url"),
            posted_from=f"({envelope.get('workspace_name')})" if envelope.get("workspace_name") else "",
            author_is_mapped=bool(mapped_user_id),
            mapped_user_id=mapped_user_id,
            name_probe_cache=name_probe_cache,
        )
        if notice:
            created.append(notice)
            DbManager.create_records(created)
        return created

    return []
