# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Deploy script: `--bootstrap`, `--setup-github` (both modes), `CLOUD_PROVIDER` auto-select, `_SM_ID` secret resolution, auto-gen `DATA_ENCRYPTION_KEY`/`DATABASE_PASSWORD`, interactive config save
- `.env.deploy.example` for cloud deployments (separate from `.env.example`)
- CI: bootstrap sync, `workflow_dispatch`, concurrency groups, `pip-audit`, `GITHUB_STEP_SUMMARY`
- CloudWatch Logs 30-day retention; X-Ray tracing now optional

### Changed

- **`TOKEN_ENCRYPTION_KEY` renamed to `DATA_ENCRYPTION_KEY`:** More accurately reflects its use (encrypts OAuth tokens, federation keys, and backup HMAC). SAM parameter is `DataEncryptionKey`; Terraform variable is `data_encryption_key`. Legacy `TOKEN_ENCRYPTION_KEY` env var still accepted as fallback.
- **Database deploy naming:** User-facing env files, GitHub environment variables, and docs use unprefixed `DATABASE_*` names instead of `EXISTING_DATABASE_*`. CloudFormation `ExistingDatabase*` and Terraform `existing_db_*` identifiers are unchanged. Deploy scripts still honor legacy `EXISTING_DATABASE_*` env vars. Interactive deploy applies the same alias layer as the `--env` path; non-interactive AWS `--setup-github` pushes the full external-DB variable set for CI parity.
- AWS: Lambda Function URLs replace API Gateway; Secrets Manager removed (secrets via SAM `NoEcho` params)
- GCP: Secret Manager removed (secrets via sensitive Terraform variables)
- `DbSetup` conditional — skipped when `DATABASE_USER` + `DATABASE_PASSWORD` provided directly
- `.env.example` simplified for local dev (default SQLite)
- Docs: `DEPLOYMENT.md` renamed to `DEPLOY.md`

### Removed

- AWS API Gateway and Secrets Manager resources
- GCP Secret Manager resources

## [1.0.2] - 2026-03-28

### Added

- External DB deploy parameters: `ExistingDatabasePort`, `ExistingDatabaseCreateAppUser`, `ExistingDatabaseCreateSchema`, `ExistingDatabaseUsernamePrefix`, `ExistingDatabaseAppUsername` (AWS) / GCP equivalents — support TiDB Cloud and other managed DB providers with cluster-prefixed usernames and 32-char limits

### Changed

- Synced message author shows local display name and avatar for mapped users, including federated messages (no workspace suffix)
- Shortened default DB usernames: `sbadmin_{stage}` (was `syncbot_admin_{stage}`), `sbapp_{stage}` (was `syncbot_user_{stage}`). Existing RDS instances keep their original master username.
- Bumped GitHub Actions: `actions/checkout` v6, `actions/setup-python` v6, `actions/upload-artifact` v7, `actions/download-artifact` v8, `aws-actions/configure-aws-credentials` v6
- Dependabot: ignore semver-major updates for the Docker `python` image (keeps base image on Python 3.12.x line)
- AWS Lambda: Alembic migrations now run via a post-deploy invoke instead of on every cold start, fixing Slack ack timeouts after deployment; Cloud Run and local dev unchanged
- AWS Lambda memory increased from 128 MB to 256 MB for faster cold starts
- EventBridge keep-warm invokes now return a clean JSON response instead of falling through to Slack Bolt
- AWS bootstrap deploy policy: added `lambda:InvokeFunction` -- **re-run the deploy script (Bootstrap task) or `aws cloudformation deploy` the bootstrap stack to pick up this permission**

### Fixed

- Replaced deprecated `datetime.utcnow()` with `datetime.now(UTC)` in backup/migration export helpers

## [1.0.1] - 2026-03-26

### Changed

- Cross-workspace `#channel` links resolve to native local channels when the channel is part of the same sync; otherwise use workspace archive URLs with a code-formatted fallback
- `@mentions` and `#channel` links in federated messages are now resolved on the receiving instance (native tags when mapped/synced, fallbacks otherwise)
- `ENABLE_DB_RESET` is now a boolean (`true` / `1` / `yes`) instead of a Slack Team ID; requires `PRIMARY_WORKSPACE` to match

### Added

- `PRIMARY_WORKSPACE` env var: must be set to a Slack Team ID for backup/restore to appear. Also scopes DB reset to that workspace.

## [1.0.0] - 2026-03-25

### Added

- Multi-workspace message sync: messages, threads, edits, deletes, reactions, images, videos, and GIFs
- Cross-workspace @mention resolution (email, name, and manual matching)
- Workspace Groups with invite codes (many-to-many collaboration; direct and group-wide sync modes)
- Pause, resume, and stop per-channel sync controls
- App Home tab for configuration (no slash commands)
- Cross-instance federation (optional, HMAC-authenticated)
- Backup/restore and workspace data migration
- Bot token encryption at rest (Fernet)
- AWS deployment (SAM/CloudFormation) with optional CI/CD via GitHub Actions
- GCP deployment (Terraform/Cloud Run) with interactive deploy script; GitHub Actions workflow for GCP is not yet fully wired
- Dev Container and Docker Compose for local development
- Structured JSON logging with correlation IDs and CloudWatch alarms (AWS)
- PostgreSQL, MySQL, and SQLite database backends
- Alembic-managed schema migrations applied at startup
