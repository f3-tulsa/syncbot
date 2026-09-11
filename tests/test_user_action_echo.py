"""Tests for user-token echo remember/take helpers."""

import os
from unittest.mock import patch

import pytest
from sqlalchemy import inspect

from helpers.user_action_echo import (
    find_pending_file_share,
    has_user_action_echo,
    post_meta_ts,
    reaction_echo_fingerprint,
    remember_pending_file_share,
    remember_user_action,
    slack_message_ts,
    take_pending_file_share,
    take_user_action_echo,
)


class TestReactionEchoFingerprint:
    def test_fingerprint_pads_short_fraction(self):
        assert reaction_echo_fingerprint("C1", "100.0", "thumbsup") == "C1:100.000000:thumbsup"
        assert slack_message_ts("100.000001") == "100.000001"
        assert slack_message_ts(100.0) == "100.000000"

    def test_post_meta_ts_is_six_decimal_not_float(self):
        from decimal import Decimal

        slack_ts = "1757529600.123456"
        exact = Decimal("1757529600.123456")
        assert post_meta_ts(slack_ts) == exact
        assert post_meta_ts(slack_ts) != float(slack_ts)
        edge = "9999999999.123456"
        assert post_meta_ts(edge) == Decimal(edge)
        assert post_meta_ts(edge) != Decimal(str(float(edge)))


class TestRememberAndTake:
    @pytest.fixture
    def echo_db(self, tmp_path):
        import db as db_mod
        from db import get_engine, initialize_database

        url = f"sqlite:///{tmp_path / 'echo.db'}"
        old_engine = db_mod.GLOBAL_ENGINE
        old_schema = db_mod.GLOBAL_SCHEMA
        with patch.dict(os.environ, {"DATABASE_BACKEND": "sqlite", "DATABASE_URL": url}, clear=False):
            db_mod.GLOBAL_ENGINE = None
            db_mod.GLOBAL_SCHEMA = None
            initialize_database()
            yield get_engine()
            if db_mod.GLOBAL_ENGINE:
                db_mod.GLOBAL_ENGINE.dispose()
            db_mod.GLOBAL_ENGINE = old_engine
            db_mod.GLOBAL_SCHEMA = old_schema

    def test_remember_then_take_consume_once(self, echo_db):
        assert inspect(echo_db).has_table("user_action_echoes")
        fp = reaction_echo_fingerprint("C_TGT", "200.0", "thumbsup")
        remember_user_action("T2", "U_MAPPED", "reaction_added", fp)
        assert take_user_action_echo("T2", "U_MAPPED", "reaction_added", fp) is True
        assert take_user_action_echo("T2", "U_MAPPED", "reaction_added", fp) is False

    def test_take_misses_different_fingerprint(self, echo_db):
        remember_user_action("T2", "U1", "reaction_added", "C1:1.0:a")
        assert take_user_action_echo("T2", "U1", "reaction_added", "C1:1.0:b") is False

    def test_file_echo_peek_does_not_consume(self, echo_db):
        remember_user_action("T2", "U_MAPPED", "file", "F99")
        assert has_user_action_echo("T2", "U_MAPPED", "file", "F99") is True
        assert has_user_action_echo("T2", "U_MAPPED", "file", "F99") is True
        assert take_user_action_echo("T2", "U_MAPPED", "message", "C_TGT:200.000000") is False

    def test_message_echo_peek_does_not_consume(self, echo_db):
        remember_user_action("T2", "U_MAPPED", "message", "C_TGT:200.000000")
        assert has_user_action_echo("T2", "U_MAPPED", "message", "C_TGT:200.000000") is True
        assert has_user_action_echo("T2", "U_MAPPED", "message", "C_TGT:200.000000") is True

    def test_pending_file_share_find_then_take(self, echo_db):
        remember_pending_file_share("T2", "C_TGT", "F1", "postabc")
        assert find_pending_file_share("T2", "C_TGT", "F1") == "postabc"
        assert find_pending_file_share("T2", "C_TGT", "F1") == "postabc"
        assert take_pending_file_share("T2", "C_TGT", "F1") == "postabc"
        assert take_pending_file_share("T2", "C_TGT", "F1") is None
