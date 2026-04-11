# SyncBot on GCP (Terraform)

Minimal Terraform scaffold to run SyncBot on Google Cloud. Satisfies the [infrastructure contract](../../docs/INFRA_CONTRACT.md): Cloud Run (public HTTPS), optional Cloud SQL, and optional Cloud Scheduler keep-warm. Secrets are passed as sensitive Terraform variables — no GCP Secret Manager dependency.

## Prerequisites

- [Terraform](https://www.terraform.io/downloads) >= 1.0
- [gcloud](https://cloud.google.com/sdk/docs/install) CLI, authenticated
- A GCP project with billing enabled

## Quick start

1. **Create a `.env.deploy.test` file** (see `.env.deploy.example` at repo root):

   ```bash
   cp .env.deploy.example .env.deploy.test
   # Edit with your Slack credentials, DATA_ENCRYPTION_KEY, DATABASE_PASSWORD, etc.
   ```

2. **Deploy non-interactively:**

   ```bash
   ./deploy.sh --env test gcp
   ```

   Or deploy interactively (prompts for all values):

   ```bash
   ./deploy.sh gcp
   ```

3. **Set the Cloud Run image**  
   By default the service uses a placeholder image. Build and push your SyncBot image to Artifact Registry, then update `CLOUD_RUN_IMAGE` in your `.env.deploy` file and re-deploy.

## Variables (summary)

| Variable | Description |
|----------|-------------|
| `project_id` | GCP project ID (required) |
| `region` | Region for Cloud Run and optional Cloud SQL (default `us-central1`) |
| `stage` | Stage name, e.g. `test` or `prod` |
| `slack_signing_secret` | Slack app signing secret (sensitive) |
| `slack_client_id` | Slack app client ID |
| `slack_client_secret` | Slack app client secret (sensitive) |
| `data_encryption_key` | Encryption key for data at rest — OAuth tokens and federation keys (sensitive) |
| `database_password` | App database password (sensitive) |
| `database_user` | App database username (optional; defaults to `sbapp_{stage}`) |
| `use_existing_database` | If `true`, use `existing_db_*` vars instead of creating Cloud SQL |
| `existing_db_host`, `existing_db_schema`, `existing_db_user` | Existing MySQL connection (when `use_existing_database = true`) |
| `existing_db_username_prefix` | Optional (e.g. TiDB Cloud `abc123`). A dot separator is added automatically. When set, `DATABASE_USER` is `{prefix}.sbapp_{stage}` unless `existing_db_app_username` is set; `existing_db_user` is ignored |
| `existing_db_app_username` | Optional full `DATABASE_USER` (bypasses prefix + `sbapp_{stage}` and `existing_db_user`) |
| `cloud_run_image` | Container image URL for Cloud Run (set after first build) |
| `slack_bot_scopes` | Bot OAuth scopes (runtime `SLACK_BOT_SCOPES`). Must match `oauth_config.scopes.bot` in the Slack manifest. |
| `slack_user_scopes` | User OAuth scopes for Cloud Run (`SLACK_USER_SCOPES`). Default matches repo standard; must match manifest `oauth_config.scopes.user`. |
| `log_level` | Python logging level for the app (`LOG_LEVEL`): `DEBUG`, `INFO`, `WARNING`, `ERROR`, or `CRITICAL` (default `INFO`). |
| `enable_keep_warm` | Create Cloud Scheduler job to ping the service (default `true`) |

See [variables.tf](variables.tf) for all options.

## Outputs (deploy contract)

After `terraform apply`, outputs align with [docs/INFRA_CONTRACT.md](../../docs/INFRA_CONTRACT.md):

- **service_url** — Public base URL (for Slack app configuration)
- **region** — Primary region
- **project_id** — GCP project ID
- **artifact_registry_repository** — Image registry URL (CI pushes here)
- **deploy_service_account_email** — Service account for CI (use with Workload Identity Federation)

Use the [GCP bootstrap output script](scripts/print-bootstrap-outputs.sh) to print these as GitHub variable suggestions.

## Keep-warm

If `enable_keep_warm` is `true`, a Cloud Scheduler job pings the service at `/health` on the configured interval. The app implements `GET /health` (JSON `{"status":"ok"}`).

## HTTP port

Cloud Run sets the `PORT` environment variable (default `8080`). The container entrypoint (`python app.py`) listens on `PORT`, falling back to `3000` when unset (local Docker).

## Security

- The Cloud Run service is publicly invokable so Slack can reach it. For production, consider Cloud Armor or IAP.
- Deploy uses a dedicated service account; prefer [Workload Identity Federation](https://cloud.google.com/iam/docs/workload-identity-federation) for GitHub Actions instead of long-lived keys.
