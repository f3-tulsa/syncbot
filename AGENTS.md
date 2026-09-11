# AGENTS — SyncBot

This file is the primary instruction set for AI coding agents (Cursor, GitHub Copilot, Codex, Claude via `CLAUDE.md`).

## Project snapshot

SyncBot is a **Slack app** that syncs messages, threads, edits, deletes, reactions, and media across **multiple Slack workspaces** (and optional **federation** between instances). The runtime is **Python 3.12+**, **Poetry** for dependencies, **SQLAlchemy** + **Alembic** for the database, and **Slack Bolt**.

Deployments supported in-repo: **AWS** (Lambda + SAM) and **GCP** (Cloud Run + Terraform). Application code under `syncbot/` must stay **cloud‑neutral**; provider-specific pieces live only under `infra/aws/`, `infra/gcp/`, and deploy workflows.

## Repo map (short)

- `syncbot/` — application (`app.py`, handlers, db, federation).
- `syncbot/db/alembic/` — schema migrations.
- `tests/`, `infra/aws/tests/`, `infra/gcp/tests/` — pytest suites.
- `infra/aws/`, `infra/gcp/` — SAM/Terraform, bootstrap, CI deploy helpers.
- `docs/` — architecture, deploy, infra contract, user guide.
- `.github/workflows/` — CI, deploy, release automation.

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for Dev Container / Docker Compose / native setup.

## Setup (local)

```bash
poetry install --with dev
pre-commit install
pre-commit install --hook-type commit-msg
```

## Verify changes (run before opening a PR)

```bash
pre-commit run --all-files
poetry run ruff check .
poetry run ruff format --check .
poetry run pytest -q tests/ infra/aws/tests infra/gcp/tests
```

On PRs, GitHub Actions runs the same test command (see `.github/workflows/ci.yml`).

## Hard rules (guardrails)

1. **Provider-neutral `syncbot/`** — do not add `boto3`, `google.cloud`, or other cloud SDK imports under `syncbot/`. Use `infra/<provider>/` and workflows for provider code. This is also enforced in CI (`forbidden-imports` job).
2. **Version & changelog** — do not bump `pyproject.toml`’s `version` or add a `## [X.Y.Z]` heading in a feature PR. Releases on `main` are automated with **python-semantic-release**. Put Keep a Changelog notes (**Added** / **Changed** / **Fixed**, **[1.2.0](CHANGELOG.md)** length) under `## [Unreleased]` below `<!-- version list -->`; the release job retitles that heading to the version and date and copies that section onto the GitHub Release. If Unreleased is missing, PSR drafts from `feat` / `fix` / `perf` subjects. Polishing an already-released heading is OK. See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) and [CONTRIBUTING.md](CONTRIBUTING.md).
3. **Requirements files** — do not edit `syncbot/requirements.txt` by hand. Change dependencies in `pyproject.toml` and run the pre-commit `sync-requirements` hook or `poetry export` as in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).
4. **Secrets** — never commit real `.env`, `.env.deploy.*` (only `*.example` templates), private keys, or large artifacts. Do not commit `.aws-sam/build` output.
5. **Deployment branches** — on a **fork**, do not push to `test` or `prod` as a casual step; those branches deploy. Canonical releases run only on **F3Nation-Community/slack-syncbot** `main` (see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)). Forks pull `main` and promote to `test`/`prod` themselves.
6. **Conventional Commits** — PR titles and commit subjects are one short imperative line (`fix: …`, about 72 characters). Skip the body unless you need `BREAKING CHANGE:` or a single clause that will not fit. See [CONTRIBUTING.md](CONTRIBUTING.md).
7. **Docs** — if behavior, env vars, or deploy steps change, update the relevant `docs/*.md` (and [docs/INFRA_CONTRACT.md](docs/INFRA_CONTRACT.md) if the runtime contract changes). Follow **Docs voice** below.
8. **Plan files** — write working plans only under **`.plans/`** at the repo root (gitignored). Never put them under `docs/` even if ignored — that looks like operator docs. Never commit plan files. `docs/PLAN_*.md` and `PLAN_*.md` stay gitignored as a safety net for leftovers.

## Docs voice

Operator-facing docs (README, `docs/*.md`, `.env*.example`, `infra/gcp/example.tfvars`) should read like a helpful teammate: friendly and explanatory, not clipped or telegraphic. Write full sentences (do not drop “the” or “a” to shorten a line). Prefer a short paragraph over a dense jargon pile.

Stage is only **`test`** or **`prod`**. Do not use `YOURSTAGE` as if the name were arbitrary. Show the real values (`--env test`, `slack-manifest_test.json`, `syncbot_test`) and mention `prod` as the other choice. Keep `YOUR_*` for values that really vary (region, host, username).

**Changelog / GitHub Release notes** follow Keep a Changelog and **[1.2.0](CHANGELOG.md)** length: one short line per bullet, not the operator-docs paragraph style. See `.cursor/rules/50-changelog.mdc`.

## Definition of done (AI-resolved issues)

1. **Tests** — add or update tests under `tests/` or `infra/*/tests/` for the change.
2. **Pre-commit** — `pre-commit run --all-files` passes.
3. **CI** — no new failures in `ci-gate` (requirements sync, ruff, SAM lint, pip-audit, forbidden path checks, tests).
4. **PR title** — Conventional Commit format (enforced by `.github/workflows/pr-title.yml`).
5. **PR description** — use `.github/pull_request_template.md`; a few short bullets, not a design essay. Link issues with `Fixes #123` when applicable.

## Common pitfalls

- **Bot identity is per workspace.** Never cache `auth.test` under a process-wide key. A warm Lambda handles many workspaces; reusing workspace A's bot member ID on B makes `conversations.invite` fail with `user_not_found` and can skip the unconfigured-channel leave handler. Prefer Bolt's request-scoped `context["bot_user_id"]`, and cache `auth.test` keyed by bot token.
- **Settings are modal-only.** Instance fields (`federation_enabled`, `broadcast_allowed_workspaces`, `soft_delete_retention_days`) use `instance_settings` on the primary workspace. Workspace fields (`allow_private_channels(team_id)`, extra managers) use `workspace_settings`. Leftover env (`ALLOW_PRIVATE_CHANNELS`, `BROADCAST_ALLOWED_WORKSPACES`, `SOFT_DELETE_RETENTION_DAYS`, `SYNCBOT_FEDERATION_ENABLED`, `REQUIRE_ADMIN`) is ignored and warned. `PRIMARY_WORKSPACE` and `ENABLE_DB_RESET` stay env.
- **Federation on/off** is `helpers.federation_enabled()` at call time (Settings DB), not an import-time constant. Do not freeze at HTTP listen. Default off on a new install.
- **Private membership.** Write `Sync`/`SyncChannel` then invite. Public = bot `conversations.join`; private = `conversations.invite` with the acting user's `xoxp` only, gated by `allow_private_channels(team_id)`. Failed invite rolls back and DMs. Leave-on-unconfigured stays. Treat `already_in_channel` / `cant_invite_self` / `method_post_only` as success. Invite only `U…` member IDs, never `B…`. Resume passes Bolt `context` only when the channel's workspace is this request's workspace. Use `lookup_channel_meta` for Channel names (the bot cannot see a private Channel it has not joined).
- **Native `conversations_select`.** Do not rebuild channel pickers from `conversations.list` (~100 cap). The filter is advisory; validate on submit.
- **Helpers import submodules only.** Never `import helpers` inside `helpers/*.py` — `helpers/__init__.py` circular-imports at Lambda cold start. See [`syncbot/helpers/sync_cleanup.py`](syncbot/helpers/sync_cleanup.py).
- **`is_workspace_admin` vs `is_workspace_manager`.** Admins open Settings, Backup, Reset, and External Connections (primary only). Managers configure groups and syncs. Authorize and Refresh stay for everyone.
- **Direct reactions** use `get_user_token(target_team_id, mapped_user_id)`, never the event team. Never send `xoxp` on federation wire payloads. Do not store reverse-map results as target `xoxp` lookup keys.
- **User-token echo.** Native `reaction_added` is the mapped person, not the bot. After user-token add/remove, `remember_user_action`; `take_user_action_echo` **inside** `run_claimed` (not `processed_events`; consume-once). Fingerprint target channel + six-decimal Slack `item.ts` + emoji (`slack_message_ts`). File shares posted as the mapped person have no `bot_id`: remember Slack file ids from `files.getUploadURLExternal` **before** `files.completeUploadExternal` shares into the Channel; inbound events **peek** `kind=file` and `kind=message` (`has_user_action_echo`, do not consume) so `file_share` and a later `message_changed` skip. Remember the share message ts, never the thread parent. Copy PostMeta is written when the target post lands. Inbound *creates* of that copy are skipped by echo and `post_meta_exists_for_channel_ts`. Follow-ups on a publishing Channel (reaction, thread, edit, delete) still originate from the shared `post_id`; echo skips the apply SyncBot just wrote.
- **`post_meta.ts` is DECIMAL(16, 6).** Never `float(ts)` to persist or compare. A current Slack ts does not fit in a float, so reactions and thread replies miss older rows. Use `post_meta_ts(ts)` for that column (write and `==`). `slack_message_ts` is the string form for Slack API kwargs and echo fingerprints (`str(Decimal)` drops trailing zeros). Do not add another converter.
- **Hybrid thread.** Target `invalid_name` never threads. Probe target emoji names with the bot token **only** when about to post a Hybrid thread in **another workspace** (no target `xoxp`, or that token hit `_NO_AUTHORIZE_ERRORS`). Same-workspace Hybrid skips the probe (shared emoji catalog). Federation inbound is a different Slack workspace — probe it the same as same-instance cross-workspace. Origin having the emoji does not mean the target has it. Direct-only and a successful native add never probe. Off is a no-op for add and remove. Do not use `emoji.list`; the target bot `reactions_add`/`reactions_remove` probe is the current method. Unreact `chat.delete`s target Hybrid notices (children first); never reuse the parent message `post_id`. Off does not delete leftover notices. A target user deleting a notice is a local tombstone only — no origin `reactions_remove`, no other target rows. Same-channel `apply_reaction_to_target` is always skip. Pre-1.4.1 uuid notices: leftover thread scan deletes only bot posts whose text is `reacted with :emoji:`; never a human reply that merely mentions the emoji.
- **Token encryption at rest.** `workspaces.bot_token` and Bolt `slack_installations` / `slack_bots` (via `EncryptedSQLAlchemyInstallationStore`). Never compare two Fernet ciphertexts for equality — decrypt stored token and compare plaintext when refreshing.
- **Home hash is per user** (`home_tab_hash:{team_id}:{user_id}`). Prefix delete on restore still works. Hash payload must include manager/admin role and extra-manager lists. `app_home_opened` short-circuits on that hash the same way Refresh does.
- **Home push is the acting user plus hash invalidation.** Do not call `get_admin_ids` / `users.list` to fan out Home. Others refresh on `app_home_opened`.
- **User Mapping is a modal.** Open from DB mappings only (`views.open` on `trigger_id`); never seed/map/crawl before open. **Auto Map Now** updates the open modal via `view_id` (Mapping users... → directory map → last-run line). Never `views.publish` Home for mapping. Auto Map Now from `user_directory.email` with `allow_slack_email_lookup=False` on the button (no source `users.info` either); do not crawl `users.list` on open, Refresh List, Auto Map Now, or group join. **On-the-fly author map** (`ensure_mapped_target_user_id`) is one person, email only (directory then one target `lookupByEmail`); not a full Auto Map Now.
- **Route through `routing.py`.** Do not add Bolt `@app.action` / `@app.event` — `app.py` already matches `.*` into `MAIN_MAPPER` / `VIEW_ACK_MAPPER`. A second decorator double-fires.
- **Clean Slack ID renames.** Rename the `action_id` / `callback_id`, the constant in `slack/actions.py`, the handler, and the `routing.py` entry together. Do not keep leftover Slack IDs mapped to the new handler. A stale Home tab may `no_handler` until Refresh; that is expected. Prefixed Home buttons (`join_sync_{id}`) must not share a prefix with a modal picker: `select_join_sync`, not `join_sync_select`. `create_sync` is not prefixed, so `create_sync_select` is fine. Two current buttons may share a handler (`decline_group_invite` / `cancel_group_invite`). Leftover env still warn-and-coalesce; old backup keys still import.
- **Modal field errors only in the ack phase.** `VIEW_ACK_MAPPER` may return `{"response_action": "errors", ...}` (3s budget, no Slack/DB of consequence). After ack, work-phase failures DM the user.
- **`DbManager.get_record` uses each model's `get_id()` column, not always the integer PK.** Pass that value positional or as `id=` only (`team_id=` TypeErrors). `Workspace` → Slack `team_id`. `SyncChannel` → integer primary key. `PostMeta` → `post_id`. Objects are expunged; each call is its own session.
- **Soft-delete + no `ON DELETE CASCADE`.** Active queries need `deleted_at.is_(None)`. Hard deletes go through `purge_sync` / `purge_workspace` (children first, including soft-deleted rows).
- **Imports are `import helpers`, not `from syncbot.helpers`.** Pytest `pythonpath` is `syncbot/` (and `infra/aws/lambda`). Do not add `tests` to it; import fixtures as `from tests.event_fixtures import …`.
- **Link buttons still need a no-op in `ACTION_MAPPER`.** Slack fires `block_actions` for URL buttons (`handle_authorize_syncbot` is the example); without a handler you get `no_handler` in the logs.
- **Never log tokens.** `_redact_sensitive` must include `user_token` and `bot_token`. Do not print `xoxp` / `xoxb`.
- **Leave Sync** removes this workspace's `SyncChannel`. Pause/resume only toggles that workspace's channel and ask for confirmation (not red). Pause, Resume, Leave, uninstall, and Edit Sync invalidate every Channel in that sync (`publish_targets:` and membership). `apply_target` re-reads the SyncChannel row so a stale cache cannot write to a paused or left Channel. The last publisher to Leave Sync ends the sync for everyone (`purge_sync`) after a warning. There are no sync owners; any group workspace can Create Sync later.
- **Participation owns reaction direction.** Create Sync offers `publish_only` / `publish_and_subscribe`. Join Sync and Edit Sync offer those plus `subscribe_only`. Reaction UI chooses Hybrid, Direct, or Off. Off does not apply incoming add or remove. Do not revive leftover reaction-direction action IDs or radio fields.
- **Events API dedup is Slack envelope `event_id` + `team_id`** (`run_claimed`), not `event.ts` or `X-Slack-Retry-Num`. Sync fan-out uses one source-canonical envelope (`kind` + `action`) through `run_sync_pipeline`. Missing `event_id` always runs. Failed work releases the claim. Work that is not ready yet (`return False`, for example a reaction before origin PostMeta exists) also releases the claim so Slack can retry. Own-bot, pending-`file_share`, and unsynced subtypes complete the claim as no-ops so retries do not re-run them.
- **Publish/subscribe pipeline.** An origin must publish and a target must subscribe. Discover fan-out with `iter_publish_targets`; `get_sync_list` is gone and must not be reintroduced. Dedupe targets by workspace and channel. A copy's inbound create never originates a second hop (echo + copy PostMeta). Reactions, thread replies, edits, and deletes on a publishing Channel still fan out on that message's `post_id` even when the row is a copy. Thread replies, files in a thread, edits, deletes, and reactions stay on the original message's PostMeta records (`thread_post_id` or that message's `post_id`).
- **Helper names.** Verb-led (`build_`, `get_`, `_format_`, `_parse_`, `_handle_`). Reuse source/target, origin, PostMeta, post_records, envelope, people, channel_ref. Do not invent graph, dest, member_ref, or other synonyms for those.
- **Slack action icons.** Lead Home/modal action buttons and in-channel/DM action notices with one Slack shortcode from `.cursor/rules/85-slack-icons.mdc`. Pause `:double_vertical_bar:`, resume `:arrow_forward:`, leave `:octagonal_sign:`, live sync/Refresh `:arrows_counterclockwise:`. Do not icon form labels, context metadata, or Authorize.
- **Message loop / double-post.** Skip only SyncBot's own `bot_id`, not other bots. A plain **top-level** `message` with files waits for `file_share`. Thread replies do not: Slack copies the parent file onto a text reply (`thread_ts` ≠ `ts`, no subtype) and never sends a second `file_share`. A new file in a thread is `subtype=file_share` with `upload` not false. `upload: false` on a thread `file_share` is a later share of the parent file, not a new upload — read `event.get("upload")` (`safe_get` treats `False` as missing). `thread_ts == ts` is the parent, not a reply. File-id echo skips only that new `file_share` (the share we just wrote), not a later reply that lists the parent file. Message-ts echo and copy PostMeta skip the inbound *create* of the copy. If complete-upload omits the share ts, retry channel history; if still missing, the inbound own-bot or file-echo `file_share` writes copy PostMeta from a pending file-id row. Follow-ups (reply, edit, delete, reaction) look up the parent by ts; if that PostMeta is not stored yet, return `False` so the claim is released. Other bots' `bot_message` events are synced. User-token file shares look like the mapped person; echo and PostMeta must use the share ts, not the parent.
- **Caption-only file shares** are one native upload. User-token uploads put the file on the same message as the source caption (`initial_comment`, or none when there is no text). When the source has Block Kit, `chat.update` those blocks onto that same share. Do not `post_message` then nest the file under that ts. Bot-token text plus file still posts the text first, then uploads in that thread. Top-level bot text plus file then `chat.update`s the file share with `reply_broadcast` — complete-upload does not accept that flag. Bot file notices never `@`mention.
- **Block Kit is the message body.** Slack `event.text` is a notification fallback: it often strips newlines and truncates (the client "Show more" is chrome on `blocks`, not a second payload). Copy content blocks (`section`, `header`, `rich_text`, …), drop `actions`/`input`, rewrite mentions in place. Do not prepend flattened `text` when those body blocks are present. Do not probe target emoji catalogs for message body emoji; that probe is reactions-only.
- **In-process cache is per warm container (60s).** Writes that change fan-out or Home must invalidate the relevant participation/settings keys, the `home_tab_hash:` prefix, and `fed_ws_for_sync:` after federation pair/unpair/restore. Pause/Leave/uninstall must invalidate **every** Channel in the sync, not only this workspace's Channel — `publish_targets:{origin}` is keyed by the publisher.
- **Message-body `#channel` stays source.** Never remap a synced message's `#channel` mention to the target twin. Render `` `#name (Workspace)` `` (code ticks), including federation. Do not emit target `<#C>`, `slack://`, `app.slack.com/client`, or channel-only `archives/C` URLs. Home may still use native `<#C>` for **this** workspace's own channel. Rich_text `{type: channel}` becomes a `text` element with `style.code`.
- **Source message permalinks stay labeled source URLs.** Keep `…/archives/C…/p…`. Slack pastes those as `message_mention`; convert to `{type: link}`. Unlabeled permalinks get `message in #channel (Workspace)`; existing link text stays. Do not emit `slack://` or `app.slack.com/client`. Target `chat.postMessage` / `chat.update` set `unfurl_links=false`. Never leave mrkdwn `<url|label>` inside a rich_text `text` node; emit a real `link` element.
- **Scope lockstep.** `slack_manifest_scopes.py` + `slack-manifest.json` / `_test` / `_prod` + SAM/Terraform defaults + env examples. User scopes that do not match the Slack app fail install with `invalid_scope`.
- **`get_oauth_flow()` is `None` in local single-workspace mode.** Hide Authorize if there is no install URL.
- **`PRIMARY_WORKSPACE` gates instance Settings fields, backup/restore, DB reset, and External Connections** — not the Settings button on other workspaces (Slack admins there edit workspace fields only). Backup/reset also need the matching team; reset also needs `ENABLE_DB_RESET`.
- **Channels may participate in multiple syncs.** This enables fan-in. A Channel may be published in more than one group. Reject subscribing one workspace to the same published source twice; do not reject a target merely because it participates in another sync.
- **Files live in `/tmp`.** That is the only writable disk on Lambda. Clean up on failure.
- **Encrypt bot tokens on write, decrypt on read.** Encryption is off when the key is missing, shorter than 16 characters, or a placeholder (`123`, `changeme`, `secret`, `password`). Federation webhooks are HTTPS-only in production; HTTP only when `LOCAL_DEVELOPMENT`.
- **Group role `admin` is reserved and never written.** Do not start using it; no permission attaches yet.
- **Lambda migrations**: AWS deploy invokes migrations **once post-deploy** — avoid relying on slow migration work during Slack request handling / cold start ack timeouts. The function timeout is 120s for that invoke; do not drop it back to 30s.
- **SQLite vs MySQL/Postgres** — local SQLite behaves differently for locking and types; don’t assume parity without checking migration scripts.
- **`ENABLE_DB_RESET`** — boolean (`true`/`1`/`yes`), gated by `PRIMARY_WORKSPACE`; don't treat as team-id string anymore.
- **`DATABASE_BACKEND`** + **`DATABASE_*`** — use `DATABASE_BACKEND` (`mysql` / `postgresql` / `sqlite`) and `DATABASE_HOST` / `DATABASE_USER` / `DATABASE_PASSWORD` / `DATABASE_SCHEMA` per [docs/INFRA_CONTRACT.md](docs/INFRA_CONTRACT.md).
- **Fork vs upstream** — `origin` may be your fork; open PRs against the repo you were asked to target (usually **F3Nation-Community/slack-syncbot** `main`). `release.yml` and Dependabot auto-merge run only on that canonical repository. Canonical GitHub bot identity is App **`f3n-community-automation`** (see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)); forks do not install it.
- **User scopes on Home** — do not paste Slack API names (`groups:write`) onto **Authorize SyncBot**. Add the scope to `USER_SCOPES` *and* a row (or an existing fold) in `USER_PERMISSION_GROUPS` in [`syncbot/slack_manifest_scopes.py`](syncbot/slack_manifest_scopes.py). The comment on that constant is the labeling recipe: Slack scopes docs → 2–4 ordinary words, fold read/write twins, keep `groups:write` separate. Tests in `tests/test_slack_manifest_scopes.py` require every user scope in exactly one group.
- **OAuth starts at `/slack/install`.** Never link at `slack.com/oauth/v2/authorize`. Bolt requires the state cookie that only this instance's install path sets; otherwise Allow fails with `invalid_browser`. After a successful callback, refresh that user's Home (`refresh_home_after_oauth_install`) so Authorize disappears without a manual Refresh. On Lambda Function URL payload 2.0, put that cookie in the `cookies` array (not `Set-Cookie` headers) and 404 stray GETs such as `/favicon.ico` so they do not overwrite it. After a user-token revoke, `InstallationStore.delete_installation` for that `user_id` (do not leave a tokenless row). After uninstall, `delete_all` plus workspace pause. Do not enable Bolt's `enable_token_revocation_listeners()`: Slack may send `tokens.bot` on a personal revoke, and that builtin would drop the workspace bot token. Uninstall only if `auth.test` on the stored bot token fails, or on `app_uninstalled`.
- **Public origin is request Host, not `SYNCBOT_PUBLIC_URL`.** Use `get_public_base_url` / `capture_public_base` (Authorize and federation). Leftover `SYNCBOT_PUBLIC_URL` and `SYNCBOT_INSTANCE_ID` are ignored and warned. The federation instance id is a SHA-256 fingerprint of the Ed25519 public key. Do not add those leftover names back as required env vars.

## More detail

- AI-focused workflow: [docs/AI_AGENTS.md](docs/AI_AGENTS.md)
