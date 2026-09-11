"""Tests for synced file share notice (from-line display name in code ticks)."""

from types import SimpleNamespace
from unittest.mock import MagicMock, patch

from helpers.core import format_file_share_notice, format_synced_from_line
from helpers.slack_write import slack_write_create
from tests.event_fixtures import make_event_context


def _write(ctx, direct_files, *, user_name="Ada", thread_ts=None):
    return slack_write_create(
        envelope={
            "source_workspace_id": 1,
            "source_user_id": ctx["user_id"],
            "user_name": user_name,
            "user_avatar_url": "https://src/icon",
            "workspace_name": "Workspace A",
            "text": ctx["msg_text"],
            "blocks": ctx.get("content_blocks") or [],
            "file_refs": direct_files or [],
            "reply_broadcast": bool(ctx.get("reply_broadcast")),
        },
        sync_channel=SimpleNamespace(channel_id="C_TGT", id=2),
        workspace=SimpleNamespace(id=2, team_id="T2", bot_token="enc"),
        source_client=MagicMock(),
        thread_ts=thread_ts,
    )


class TestFromLineUsername:
    def test_mapped_is_display_name_only(self):
        assert format_synced_from_line("Ada Lovelace") == "Ada Lovelace"

    def test_unmapped_includes_workspace(self):
        assert format_synced_from_line("Ada Lovelace", "Workspace A") == "Ada Lovelace (Workspace A)"

    def test_blank_falls_back_to_someone(self):
        assert format_synced_from_line("  ", None) == "Someone"

    def test_file_share_notice_never_tags(self):
        assert format_file_share_notice("Ada Lovelace") == "`Ada Lovelace` shared a file"
        assert format_file_share_notice("Ada Lovelace", "Workspace A") == "`Ada Lovelace (Workspace A)` shared a file"

    def test_code_ticked_matches_file_share_and_unmapped_mentions(self):
        from helpers.core import code_ticked_display_name
        from helpers.user_map import format_unmapped_author_label

        assert code_ticked_display_name("F3 Tulsa - TEST", "F3 T-Town Test") == "`F3 Tulsa - TEST (F3 T-Town Test)`"
        assert format_unmapped_author_label("F3 Tulsa - TEST", "F3 T-Town Test") == "`F3 Tulsa - TEST (F3 T-Town Test)`"
        assert "@" not in code_ticked_display_name("Ada", "WS")
        assert "[" not in code_ticked_display_name("Ada", "WS")


class TestFileOnlyAuthorAttribution:
    def test_pdf_uses_single_upload_with_ticked_notice(self):
        ctx = make_event_context(msg_text=" ", user_id="U_SRC", reply_broadcast=False)
        with (
            patch("helpers.slack_write.decrypt_bot_token", return_value="xoxb"),
            patch("helpers.slack_write.WebClient"),
            patch(
                "helpers.slack_write.get_display_name_and_icon_for_synced_message",
                return_value=("Ada Lovelace", "https://icon", False, None),
            ),
            patch("helpers.slack_write.apply_mentioned_users", side_effect=lambda t, *_a, **_k: t),
            patch("helpers.slack_write.resolve_channel_references", side_effect=lambda t, *_a, **_k: t),
            patch("helpers.workspace.get_workspace_by_id", return_value=None),
            patch("helpers.slack_write.post_message") as post_msg,
            patch("helpers.slack_write.upload_files_to_slack", return_value=(None, "200.0")) as upload,
        ):
            ts, split, _posted_as = _write(
                ctx,
                [{"path": "/tmp/a.pdf", "name": "a.pdf", "mimetype": "application/pdf"}],
                user_name="Ada Lovelace",
            )
        assert split is None
        assert ts == "200.0"
        post_msg.assert_not_called()
        upload.assert_called_once()
        assert upload.call_args.kwargs["initial_comment"] == "`Ada Lovelace (Workspace A)` shared a file"
        assert upload.call_args.kwargs["thread_ts"] is None

    def test_file_only_thread_reply_uses_parent_thread_ts(self):
        ctx = make_event_context(msg_text="", user_id="U_SRC", reply_broadcast=False)
        with (
            patch("helpers.slack_write.decrypt_bot_token", return_value="xoxb"),
            patch("helpers.slack_write.WebClient"),
            patch(
                "helpers.slack_write.get_display_name_and_icon_for_synced_message",
                return_value=("Ada", "https://icon", True, "U_MAP"),
            ),
            patch("helpers.slack_write.apply_mentioned_users", side_effect=lambda t, *_a, **_k: t),
            patch("helpers.slack_write.resolve_channel_references", side_effect=lambda t, *_a, **_k: t),
            patch("helpers.workspace.get_workspace_by_id", return_value=None),
            patch("helpers.slack_write.post_message") as post_msg,
            patch("helpers.slack_write.upload_files_to_slack", return_value=(None, "350.0")) as upload,
        ):
            ts, split, _posted_as = _write(
                ctx,
                [{"path": "/tmp/a.pdf", "name": "a.pdf", "mimetype": "application/pdf"}],
                thread_ts="20.000000",
            )
        assert split is None
        assert ts == "350.0"
        post_msg.assert_not_called()
        assert upload.call_args.kwargs["thread_ts"] == "20.000000"
        assert upload.call_args.kwargs["initial_comment"] == "`Ada` shared a file"

    def test_image_file_uses_same_notice_as_pdf(self):
        ctx = make_event_context(msg_text="", user_id="U_SRC", reply_broadcast=False)
        with (
            patch("helpers.slack_write.decrypt_bot_token", return_value="xoxb"),
            patch("helpers.slack_write.WebClient"),
            patch(
                "helpers.slack_write.get_display_name_and_icon_for_synced_message",
                return_value=("Ada", "https://icon", True, "U_MAP"),
            ),
            patch("helpers.slack_write.apply_mentioned_users", side_effect=lambda t, *_a, **_k: t),
            patch("helpers.slack_write.resolve_channel_references", side_effect=lambda t, *_a, **_k: t),
            patch("helpers.workspace.get_workspace_by_id", return_value=None),
            patch("helpers.slack_write.post_message") as post_msg,
            patch("helpers.slack_write.upload_files_to_slack", return_value=(None, "200.0")) as upload,
        ):
            _write(ctx, [{"path": "/tmp/a.png", "name": "photo.png", "mimetype": "image/png"}])
        post_msg.assert_not_called()
        assert upload.call_args.kwargs["initial_comment"] == "`Ada` shared a file"
        assert upload.call_args.kwargs["thread_ts"] is None


class TestTextPlusFileUpload:
    def test_threaded_file_uses_same_notice(self):
        ctx = make_event_context(msg_text="see attached", user_id="U_SRC", reply_broadcast=False)
        with (
            patch("helpers.slack_write.decrypt_bot_token", return_value="xoxb"),
            patch("helpers.slack_write.WebClient"),
            patch(
                "helpers.slack_write.get_display_name_and_icon_for_synced_message",
                return_value=("Ada", "https://icon", True, "U_MAP"),
            ),
            patch("helpers.slack_write.apply_mentioned_users", side_effect=lambda t, *_a, **_k: t),
            patch("helpers.slack_write.resolve_channel_references", side_effect=lambda t, *_a, **_k: t),
            patch("helpers.workspace.get_workspace_by_id", return_value=None),
            patch("helpers.slack_write.post_message", return_value={"ts": "100.0"}),
            patch("helpers.slack_write.upload_files_to_slack", return_value=(None, "200.0")) as upload_files,
        ):
            _write(ctx, [{"path": "/tmp/a.pdf", "name": "a.pdf"}])
        assert upload_files.call_args.kwargs["initial_comment"] == "`Ada` shared a file"
        assert upload_files.call_args.kwargs["thread_ts"] == "100.0"
        assert upload_files.call_args.kwargs["reply_broadcast"] is True

    def test_thread_reply_text_plus_file_uploads_at_parent_thread(self):
        ctx = make_event_context(msg_text="see attached", user_id="U_SRC", reply_broadcast=False)
        with (
            patch("helpers.slack_write.decrypt_bot_token", return_value="xoxb"),
            patch("helpers.slack_write.WebClient"),
            patch(
                "helpers.slack_write.get_display_name_and_icon_for_synced_message",
                return_value=("Ada", "https://icon", True, "U_MAP"),
            ),
            patch("helpers.slack_write.apply_mentioned_users", side_effect=lambda t, *_a, **_k: t),
            patch("helpers.slack_write.resolve_channel_references", side_effect=lambda t, *_a, **_k: t),
            patch("helpers.workspace.get_workspace_by_id", return_value=None),
            patch("helpers.slack_write.post_message", return_value={"ts": "250.0"}),
            patch("helpers.slack_write.upload_files_to_slack", return_value=(None, "350.0")) as upload_files,
        ):
            _write(
                ctx,
                [{"path": "/tmp/a.pdf", "name": "a.pdf"}],
                thread_ts="20.000000",
            )
        assert upload_files.call_args.kwargs["thread_ts"] == "20.000000"
        assert upload_files.call_args.kwargs["initial_comment"] == "`Ada` shared a file"
        assert upload_files.call_args.kwargs["reply_broadcast"] is False


def _stub_external_upload(client, *, file_id="F1"):
    client.files_getUploadURLExternal.return_value = {
        "file_id": file_id,
        "upload_url": "https://files.slack.com/upload/v1/x",
    }
    client.files_completeUploadExternal.return_value = {"file": {"id": file_id}}


class TestUploadReplyBroadcast:
    def test_broadcast_uses_chat_update_not_complete_kwarg(self):
        from helpers.files import upload_files_to_slack

        client = MagicMock()
        _stub_external_upload(client)
        put = MagicMock()
        put.status_code = 200
        with (
            patch("helpers.files.WebClient", return_value=client),
            patch("helpers.files._read_local_file_bytes", return_value=b"pdf"),
            patch("helpers.files.requests.post", return_value=put),
            patch("helpers.files._extract_file_message_ts", return_value="200.0"),
        ):
            upload_files_to_slack(
                "xoxb",
                "C1",
                [{"path": "/tmp/a.pdf", "name": "a.pdf"}],
                initial_comment="notice",
                thread_ts="100.0",
                reply_broadcast=True,
            )
        assert "reply_broadcast" not in client.files_completeUploadExternal.call_args.kwargs
        client.chat_update.assert_called_once_with(channel="C1", ts="200.0", reply_broadcast=True)

    def test_no_broadcast_skips_chat_update(self):
        from helpers.files import upload_files_to_slack

        client = MagicMock()
        _stub_external_upload(client)
        put = MagicMock()
        put.status_code = 200
        with (
            patch("helpers.files.WebClient", return_value=client),
            patch("helpers.files._read_local_file_bytes", return_value=b"pdf"),
            patch("helpers.files.requests.post", return_value=put),
            patch("helpers.files._extract_file_message_ts", return_value="200.0"),
        ):
            upload_files_to_slack(
                "xoxb",
                "C1",
                [{"path": "/tmp/a.pdf", "name": "a.pdf"}],
                thread_ts="100.0",
                reply_broadcast=False,
            )
        client.chat_update.assert_not_called()

    def test_after_upload_runs_before_complete_share(self):
        from helpers.files import upload_files_to_slack

        client = MagicMock()
        _stub_external_upload(client)
        put = MagicMock()
        put.status_code = 200
        order: list[str] = []

        def after(file_ids):
            order.append("after_upload")
            assert file_ids == ["F1"]

        def complete(**_kwargs):
            order.append("complete")
            return {"file": {"id": "F1"}}

        client.files_completeUploadExternal.side_effect = complete
        with (
            patch("helpers.files.WebClient", return_value=client),
            patch("helpers.files._read_local_file_bytes", return_value=b"pdf"),
            patch("helpers.files.requests.post", return_value=put),
            patch("helpers.files._extract_file_message_ts", return_value="200.0"),
        ):
            upload_files_to_slack(
                "xoxb",
                "C1",
                [{"path": "/tmp/a.pdf", "name": "a.pdf"}],
                after_upload=after,
            )
        assert order == ["after_upload", "complete"]


class TestExtractFileMessageTs:
    def test_uses_upload_response_shares_without_files_info(self):
        from helpers.files import _extract_file_message_ts

        client = MagicMock()
        upload = {
            "file": {
                "id": "F1",
                "shares": {"public": {"C1": [{"ts": "200.0"}]}},
            }
        }
        ts = _extract_file_message_ts(client, upload, "C1")
        assert ts == "200.0"
        client.files_info.assert_not_called()

    def test_prefers_share_matching_thread_ts(self):
        from helpers.files import _extract_file_message_ts

        client = MagicMock()
        client.files_info.return_value = {
            "file": {
                "shares": {
                    "public": {
                        "C1": [
                            {"ts": "100.0"},
                            {"ts": "200.0", "thread_ts": "150.0"},
                        ]
                    }
                }
            }
        }
        ts = _extract_file_message_ts(client, {"file": {"id": "F1"}}, "C1", thread_ts="150.0")
        assert ts == "200.0"

    def test_threaded_upload_skips_parent_share_ts(self):
        from helpers.files import _extract_file_message_ts

        client = MagicMock()
        upload = {
            "file": {
                "id": "F1",
                "shares": {
                    "public": {
                        "C1": [
                            {"ts": "150.0"},
                            {"ts": "200.0", "thread_ts": "150.0"},
                        ]
                    }
                },
            }
        }
        ts = _extract_file_message_ts(client, upload, "C1", thread_ts="150.0")
        assert ts == "200.0"
        client.files_info.assert_not_called()

    def test_parent_only_upload_shares_poll_files_info_for_reply_ts(self):
        from helpers.files import _extract_file_message_ts

        client = MagicMock()
        client.files_info.return_value = {
            "file": {
                "shares": {
                    "public": {
                        "C1": [
                            {"ts": "150.0"},
                            {"ts": "200.0", "thread_ts": "150.0"},
                        ]
                    }
                }
            }
        }
        upload = {"file": {"id": "F1", "shares": {"public": {"C1": [{"ts": "150.0"}]}}}}
        with patch("helpers.files._time.sleep"):
            ts = _extract_file_message_ts(client, upload, "C1", thread_ts="150.0")
        assert ts == "200.0"
        client.files_info.assert_called()

    def test_channel_history_fallback_when_shares_never_appear(self):
        from helpers.files import _extract_file_message_ts

        client = MagicMock()
        client.files_info.return_value = {"file": {"id": "F1", "shares": {}}}
        client.conversations_history.return_value = {
            "messages": [{"ts": "200.000000", "files": [{"id": "F1"}]}],
        }
        with patch("helpers.files._time.sleep"):
            ts = _extract_file_message_ts(client, {"file": {"id": "F1"}}, "C1")
        assert ts == "200.000000"

    def test_thread_history_fallback_skips_parent_share(self):
        from helpers.files import _extract_file_message_ts

        client = MagicMock()
        client.files_info.return_value = {"file": {"id": "F1", "shares": {}}}
        client.conversations_replies.return_value = {
            "messages": [
                {"ts": "150.0", "files": [{"id": "F1"}]},
                {"ts": "200.000000", "files": [{"id": "F1"}]},
            ],
        }
        with patch("helpers.files._time.sleep"):
            ts = _extract_file_message_ts(client, {"file": {"id": "F1"}}, "C1", thread_ts="150.0")
        assert ts == "200.000000"

    def test_retries_history_when_first_lookup_is_empty(self):
        from helpers.files import _extract_file_message_ts

        client = MagicMock()
        client.files_info.return_value = {"file": {"id": "F1", "shares": {}}}
        client.conversations_history.side_effect = [
            {"messages": [{"ts": "199.0", "files": [{"id": "F_OTHER"}]}]},
            {"messages": [{"ts": "200.000000", "files": [{"id": "F1"}]}]},
        ]
        with patch("helpers.files._time.sleep"):
            ts = _extract_file_message_ts(client, {"file": {"id": "F1"}}, "C1")
        assert ts == "200.000000"
        assert client.conversations_history.call_count == 2
