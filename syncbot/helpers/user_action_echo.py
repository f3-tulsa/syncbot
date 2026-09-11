"""Remember user-token Slack writes so matching inbound events can be skipped.

Used when SyncBot acts as a mapped person (``xoxp``). Slack emits a normal
``reaction_added`` / ``reaction_removed`` or ``file_share`` / ``message`` with
``event.user`` set to that person, not the bot. Call :func:`remember_user_action`
after a successful write (file ids before the file is shared into the Channel).
:func:`take_user_action_echo` is consume-once (reactions).
:func:`has_user_action_echo` peeks without deleting (file ids and message ts). Both run
inside ``run_claimed`` before fan-out.

:func:`slack_message_ts` is the string form (API kwargs and echo fingerprints).
:func:`post_meta_ts` is the Decimal form for ``post_meta.ts``. Do not ``float()``
that column, and do not add a third converter.
"""

from __future__ import annotations

import logging
from datetime import UTC, datetime, timedelta
from decimal import Decimal, InvalidOperation

from sqlalchemy.exc import IntegrityError

from db import close_session, get_session, schemas

_logger = logging.getLogger(__name__)

_TTL = timedelta(minutes=10)
_PENDING_SHARE_KIND = "pending_share"


def slack_message_ts(ts: object) -> str:
    """Six-decimal Slack message ts as a string (API kwargs and echo fingerprints).

    Persist or compare ``post_meta.ts`` with :func:`post_meta_ts`. ``str(Decimal)``
    drops trailing zeros, so fingerprints must not use a raw Decimal or float.
    """
    raw = str(ts).strip()
    if not raw:
        return raw
    if "." in raw:
        whole, frac = raw.split(".", 1)
        return f"{whole}.{(frac + '000000')[:6]}"
    return f"{raw}.000000"


def post_meta_ts(ts: object) -> Decimal:
    """The only value to persist or compare on ``post_meta.ts``.

    That column is DECIMAL(16, 6). A current Slack ts does not fit in a Python
    float, so ``float(ts)`` misses existing rows. Do not add another converter.
    """
    padded = slack_message_ts(ts)
    if not padded:
        raise ValueError("empty Slack message ts")
    try:
        return Decimal(padded)
    except (InvalidOperation, ArithmeticError) as exc:
        raise ValueError(f"invalid Slack message ts {ts!r}") from exc


def reaction_echo_fingerprint(channel_id: str, ts: str, name: str) -> str:
    """Stable key for a native reaction on *channel_id* at *ts*."""
    return f"{channel_id}:{slack_message_ts(ts)}:{name}"


def _utcnow() -> datetime:
    return datetime.now(UTC).replace(tzinfo=None)


def _purge_expired(session) -> None:
    cutoff = _utcnow() - _TTL
    session.query(schemas.UserActionEcho).filter(schemas.UserActionEcho.created_at < cutoff).delete(
        synchronize_session=False
    )


def remember_user_action(team_id: str, user_id: str, kind: str, fingerprint: str) -> None:
    """Record a user-token side effect on *team_id* so the matching event can be ignored."""
    if not team_id or not user_id or not kind or not fingerprint:
        return
    session = get_session()
    try:
        _purge_expired(session)
        session.add(
            schemas.UserActionEcho(
                team_id=team_id,
                user_id=user_id,
                kind=kind,
                fingerprint=fingerprint,
                created_at=_utcnow(),
            )
        )
        session.commit()
    except IntegrityError:
        session.rollback()
    except Exception as exc:
        session.rollback()
        _logger.warning(
            "remember_user_action_failed",
            extra={"kind": kind, "error": str(exc)},
        )
    finally:
        close_session(session)


def _find_echo(session, team_id: str, user_id: str, kind: str, fingerprint: str):
    return (
        session.query(schemas.UserActionEcho)
        .filter(
            schemas.UserActionEcho.team_id == team_id,
            schemas.UserActionEcho.user_id == user_id,
            schemas.UserActionEcho.kind == kind,
            schemas.UserActionEcho.fingerprint == fingerprint,
        )
        .one_or_none()
    )


def has_user_action_echo(team_id: str, user_id: str, kind: str, fingerprint: str) -> bool:
    """True when a remembered row exists. Does not consume it.

    File ids and message ts stay until TTL so Slack can emit more than one
    event for the same write. Reactions still use consume-once.
    """
    if not team_id or not user_id or not kind or not fingerprint:
        return False
    session = get_session()
    try:
        _purge_expired(session)
        row = _find_echo(session, team_id, user_id, kind, fingerprint)
        session.commit()
        return row is not None
    except Exception as exc:
        session.rollback()
        _logger.warning(
            "has_user_action_echo_failed",
            extra={"kind": kind, "error": str(exc)},
        )
        return False
    finally:
        close_session(session)


def remember_pending_file_share(team_id: str, channel_id: str, file_id: str, post_id: str) -> None:
    """Remember a target upload whose share ts was not in the complete response.

    Slack often omits ``shares`` for a few seconds. The inbound ``file_share``
    (own-bot or user-token echo) carries the ts; :func:`take_pending_file_share`
    consumes this row so copy PostMeta can be written then.
    """
    if not team_id or not channel_id or not file_id or not post_id:
        return
    remember_user_action(team_id, post_id, _PENDING_SHARE_KIND, f"{channel_id}:{file_id}")


def _pending_share_row(session, team_id: str, fingerprint: str):
    return (
        session.query(schemas.UserActionEcho)
        .filter(
            schemas.UserActionEcho.team_id == team_id,
            schemas.UserActionEcho.kind == _PENDING_SHARE_KIND,
            schemas.UserActionEcho.fingerprint == fingerprint,
        )
        .order_by(schemas.UserActionEcho.created_at.desc())
        .first()
    )


def find_pending_file_share(team_id: str, channel_id: str, file_id: str) -> str | None:
    """Return the *post_id* for a pending target share without consuming it."""
    if not team_id or not channel_id or not file_id:
        return None
    fingerprint = f"{channel_id}:{file_id}"
    session = get_session()
    try:
        _purge_expired(session)
        row = _pending_share_row(session, team_id, fingerprint)
        session.commit()
        return row.user_id if row is not None else None
    except Exception as exc:
        session.rollback()
        _logger.warning(
            "find_pending_file_share_failed",
            extra={"error": str(exc)},
        )
        return None
    finally:
        close_session(session)


def take_pending_file_share(team_id: str, channel_id: str, file_id: str) -> str | None:
    """Return the *post_id* for a pending target share, if any. Consumes the row."""
    if not team_id or not channel_id or not file_id:
        return None
    fingerprint = f"{channel_id}:{file_id}"
    session = get_session()
    try:
        _purge_expired(session)
        row = _pending_share_row(session, team_id, fingerprint)
        if row is None:
            session.commit()
            return None
        post_id = row.user_id
        session.delete(row)
        session.commit()
        return post_id
    except Exception as exc:
        session.rollback()
        _logger.warning(
            "take_pending_file_share_failed",
            extra={"error": str(exc)},
        )
        return None
    finally:
        close_session(session)


def take_user_action_echo(team_id: str, user_id: str, kind: str, fingerprint: str) -> bool:
    """If a remembered row exists, delete it and return True (consume-once)."""
    if not team_id or not user_id or not kind or not fingerprint:
        return False
    session = get_session()
    try:
        _purge_expired(session)
        row = _find_echo(session, team_id, user_id, kind, fingerprint)
        if row is None:
            session.commit()
            return False
        session.delete(row)
        session.commit()
        return True
    except Exception as exc:
        session.rollback()
        _logger.warning(
            "take_user_action_echo_failed",
            extra={"kind": kind, "error": str(exc)},
        )
        return False
    finally:
        close_session(session)
