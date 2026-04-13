# Deployment Guide

This guide explains **what the guided deploy scripts do**, how to perform the **same steps manually** on **AWS** or **GCP**, and how **GitHub Actions** fits in. For the runtime environment variables the app expects in any cloud, see [INFRA_CONTRACT.md](INFRA_CONTRACT.md).

**Runtime baseline:** Python 3.12 — keep `pyproject.toml`, `syncbot/requirements.txt`, Lambda/Cloud Run runtimes, and CI aligned.

> **Which env file?** `.env.example` is for **local development** (`cp .env.example .env`; see [DEVELOPMENT.md](DEVELOPMENT.md)). `.env.deploy.example` is for **cloud deployments** (`cp .env.deploy.example .env.deploy.test`; used by `./deploy.sh --env test`).

---

## Quick start: root launcher

From the **repository root**:

| OS | Command |
|----|---------|
| macOS / Linux | `./deploy.sh` |
| Windows (PowerShell) | `.\deploy.ps1` |

The launcher discovers `infra/<provider>/scripts/deploy.sh`, shows a numbered menu, and runs the script you pick.

**Non-interactive (env file):** `./deploy.sh --env test aws` or `./deploy.sh --env prod gcp` — sources `.env.deploy.test` / `.env.deploy.prod` and runs without prompts. If `CLOUD_PROVIDER` is set in the env file, the provider argument is optional: `./deploy.sh --env test`. See `.env.deploy.example` for the template.

**Provider shortcut:** `./deploy.sh aws`, `./deploy.sh gcp` (same for `deploy.ps1`) — runs the interactive script for that provider.

**Bootstrap (AWS):** Add `--bootstrap` to create or sync the bootstrap CloudFormation stack before deploying: `./deploy.sh --env test --bootstrap aws`. The interactive path already includes bootstrap as a task menu option. GCP has no separate bootstrap stack (everything runs through `terraform apply`), so `--bootstrap` is ignored for GCP.

**GitHub setup:** Add `--setup-github` to push config to GitHub environment variables and secrets after deploy. Works with both `--env` (non-interactive) and interactive modes: `./deploy.sh --env test --setup-github aws` or `./deploy.sh --setup-github aws`.

**Verbose output:** Add `--verbose` for extended deploy receipts (SAM/Terraform parameters, inline Slack manifest) and extra screen output during deploy — useful for debugging deploy issues: `./deploy.sh --env test --verbose aws`.

**Force `update-stack` (AWS):** Set `UPDATE_STACK=true` in `.env.deploy.<stage>` or pass **`--update-stack`** on `./deploy.sh` to skip `sam deploy` and use direct CloudFormation `update-stack` (optional; the AWS script normally auto-retries after an `EarlyValidation::ResourceExistenceCheck` changeset failure).

**Secret auto-generation:** If `DATA_ENCRYPTION_KEY` is empty, a secure key is generated automatically and saved back to the `.env.deploy` file. Similarly, when using `DbSetup` (admin credentials provided), `DATABASE_PASSWORD` and `DATABASE_USER` are auto-generated if empty.

**Interactive save:** After a successful interactive deploy, the script prompts to save all config to `.env.deploy.<stage>` for future non-interactive runs.

**Windows:** `deploy.ps1` requires **Git Bash** or **WSL** with bash, then runs the same `infra/.../deploy.sh` as macOS/Linux. Alternatively install [Git for Windows](https://git-scm.com/download/win) or [WSL](https://learn.microsoft.com/windows/wsl/install) and run `./deploy.sh` from Git Bash or a WSL shell.

**Prerequisites** (short list in the root [README](../README.md); full detail below):

- **AWS path:** AWS CLI v2, SAM CLI, Docker (`sam build --use-container`), Python 3 (`python3`), **`curl`** (Slack manifest API). **Optional:** `gh` (GitHub Actions setup). The script prints a CLI status line per tool (✓ / !) and Slack doc links; if `gh` is missing, it asks whether to continue.
- **GCP path:** Terraform, `gcloud`, Python 3, **`curl`**. **Optional:** `gh` — same behavior as AWS.

**Slack install error `invalid_scope` / “Invalid permissions requested”:** The OAuth authorize URL is built from **`SLACK_BOT_SCOPES`** and **`SLACK_USER_SCOPES`** in your deployed app (Lambda / Cloud Run). They must **exactly match** the scopes on your Slack app (`slack-manifest.json` → **OAuth & Permissions** after manifest update) and `BOT_SCOPES` / `USER_SCOPES` in `syncbot/slack_manifest_scopes.py`. SAM and GCP Terraform defaults include both bot and user scope strings; if your environment has **stale** overrides, redeploy with parameters matching the manifest or update the Slack app to match. On GCP, `slack_user_scopes` must stay aligned with `oauth_config.scopes.user`. **Renames (older stacks):** `SLACK_SCOPES` → `SLACK_BOT_SCOPES`; SAM `SlackOauthScopes` → `SlackOauthBotScopes`; SAM `SlackUserOauthScopes` → `SlackOauthUserScopes` (`SLACK_USER_SCOPES` unchanged).

---

## What the deploy scripts do

### Root: `deploy.sh` / `deploy.ps1`

- Scans `infra/*/scripts/deploy.sh` and lists providers (e.g. **aws**, **gcp**).
- Runs the selected provider script in Bash.
- **`./deploy.sh` (macOS / Linux):** Invokes `bash` with the chosen `infra/<provider>/scripts/deploy.sh`.
- **`.\deploy.ps1` (Windows):** Verifies **Git Bash** or **WSL** bash is available (shows which one will be used), then runs the same `deploy.sh` path. There are **no** `deploy.ps1` files under `infra/` — only the repo-root launcher uses PowerShell. Provider prerequisite checks (AWS/GCP tools, optional `gh`, Slack links) run **inside** the bash `deploy.sh` scripts.

### AWS: `infra/aws/scripts/deploy.sh`

Runs from repo root (or via `./deploy.sh` → **aws**). It:

1. **Prerequisites** — Verifies `aws`, `sam`, `docker`, `python3`, `curl` are on `PATH` (with install hints). Prints a status matrix; if optional `gh` is missing, shows install hints and asks whether to continue. Prints Slack app / API token / manifest API links.
2. **AWS auth** — Checks credentials; suggests `aws login`, SSO, or `aws configure` as appropriate.
3. **Bootstrap probe** — Reads bootstrap stack outputs if the stack exists (for suggested stack names and later CI/CD). Full **bootstrap** create/sync runs only if you select it in **Deploy Tasks** (see below).
4. **App stack identity** — Prompts for stage (`test`/`prod`) and stack name; detects an existing CloudFormation stack for update.
5. **Deploy Tasks** — Multi-select menu (comma-separated, default all): **Bootstrap** (create/sync bootstrap stack; respects `SYNCBOT_SKIP_BOOTSTRAP_SYNC=1` for sync), **Build/Deploy** (full config + SAM), **CI/CD** (`gh` / GitHub Actions), **Slack API**. Omitting **Build/Deploy** requires an existing stack for tasks that need live outputs.
6. **Configuration** (if Build/Deploy selected) — **Database source** (stack-managed RDS vs existing RDS host) and **engine** (MySQL vs PostgreSQL). **Slack app credentials** (signing secret, client secret, client ID). **App secrets** (`DATA_ENCRYPTION_KEY`, `DATABASE_PASSWORD`, optionally `DATABASE_USER`) — passed as SAM parameters with `NoEcho` (no Secrets Manager dependency). **Existing database host** mode: RDS endpoint, admin user/password, optional **ExistingDatabasePort** (blank = engine default; use for non-standard ports e.g. TiDB **4000**), optional **ExistingDatabaseUsernamePrefix** (e.g. TiDB Cloud cluster prefix `abc123`; a dot separator is added automatically; prepended to **ExistingDatabaseAdminUser** and the default app user `{prefix}.sbapp_{stage}` — use bare admin names like `root` when set), optional **ExistingDatabaseAppUsername** (full app username override when the default would exceed provider limits, e.g. MySQL 32 chars), whether to **create a dedicated app DB user** and whether to run **`CREATE DATABASE IF NOT EXISTS`**, **public vs private** network mode, and for **private** mode: subnet IDs and Lambda security group (with optional auto-detect and **connectivity preflight** using the effective DB port). **New RDS in stack** mode: summarizes auto-generated DB users and prompts for **DatabaseSchema** and **DatabaseAdminPassword**. **Log level** (numbered list `1`–`5` with `Choose level [N]:`, default from prior stack or **INFO**), **deploy summary**, then **SAM build** (`--use-container`) and **sam deploy**.
7. **Post-deploy** — According to selected tasks: stack outputs, `slack-manifest_<stage>.json`, Slack API, **`gh`** setup, and deploy receipt under `deploy-receipts/` (gitignored). The receipt includes all configuration, secrets, and Slack URLs (events, install, OAuth redirect). Use `--verbose` to also include the full SAM parameters array and inline Slack manifest in the receipt.

### GCP: `infra/gcp/scripts/deploy.sh`

Runs from repo root (or `./deploy.sh` → **gcp**). It:

1. Verifies **Terraform**, **gcloud**, **python3**, **curl**; optional **gh** handling (same as AWS).
2. Guides **auth** (`gcloud auth login` plus `gcloud auth application-default login`; quota project as needed).
3. **Project / stage / existing service** — Prompts for project, region, stage; can detect existing Cloud Run for defaults.
4. **Deploy Tasks** — Multi-select menu (comma-separated, default all): **Build/Deploy** (full Terraform flow), **CI/CD**, **Slack API**. Skipping **Build/Deploy** requires existing Terraform state/outputs for tasks that need them.
5. **Secrets** (if Build/Deploy selected) — Prompts for `SLACK_SIGNING_SECRET`, `SLACK_CLIENT_ID`, `SLACK_CLIENT_SECRET`, `DATA_ENCRYPTION_KEY`, `DATABASE_PASSWORD`, and optionally `DATABASE_USER`. Passed as sensitive Terraform variables (no GCP Secret Manager dependency).
6. **Terraform** (if Build/Deploy selected) — Prompts for DB mode, `cloud_run_image` (required), log level, etc.; `terraform init` / `plan` / `apply` in `infra/gcp` (no separate y/n gates on plan/apply).
7. **Post-deploy** — According to selected tasks: manifest, Slack API, deploy receipt, **`gh`**, `print-bootstrap-outputs.sh`. The receipt includes all configuration, secrets, and Slack URLs. Use `--verbose` to also include the full Terraform variables array and inline Slack manifest.

See [infra/gcp/README.md](../infra/gcp/README.md) for Terraform variables and outputs.

---

## Fork-First model (recommended for forks)

**Branch roles** (see [CONTRIBUTING.md](../CONTRIBUTING.md)): use **`main`** to track upstream and merge contributions; on your fork, use **`test`** and **`prod`** for automated deploys (CI runs on push to those branches).

1. Keep `syncbot/` provider-neutral; use only env vars from [INFRA_CONTRACT.md](INFRA_CONTRACT.md).
2. Put provider code in `infra/<provider>/` and `.github/workflows/deploy-<provider>.yml`.
3. Prefer the AWS layout as reference; treat other providers as swappable scaffolds.

---

## Provider selection (CI)

| Provider | Infra | CI workflow | Default |
|----------|-------|-------------|---------|
| **AWS** | `infra/aws/` | `.github/workflows/deploy-aws.yml` | Yes |
| **GCP** | `infra/gcp/` | `.github/workflows/deploy-gcp.yml` | Opt-in |

- **AWS only:** Do not set `DEPLOY_TARGET=gcp` (or set it to something other than `gcp`).
- **GCP only:** Set repository variable **`DEPLOY_TARGET`** = **`gcp`**, complete GCP bootstrap + WIF, and disable or skip the AWS workflow so only `deploy-gcp.yml` runs.

---

## Database backends

The app supports **MySQL** (default), **PostgreSQL**, and **SQLite**. Schema changes use Alembic (`alembic upgrade head`). **AWS Lambda:** Applied after each deploy via a workflow step that invokes the function with `{"action":"migrate"}` (not on every cold start). **Cloud Run / local:** Applied at process startup before serving HTTP.

- **AWS:** Choose engine in the deploy script or pass `DatabaseEngine=mysql` / `postgresql` to `sam deploy`.
- **Contract:** [INFRA_CONTRACT.md](INFRA_CONTRACT.md) — `DATABASE_BACKEND`, `DATABASE_URL` or host/user/password/schema.

---

## AWS — manual steps (no helper script)

Use this when you already know SAM/CloudFormation or are debugging.

### 1. One-time bootstrap

**Prerequisites:** AWS CLI, SAM CLI (for later app deploy).

```bash
aws cloudformation deploy \
  --template-file infra/aws/template.bootstrap.yaml \
  --stack-name syncbot-bootstrap \
  --parameter-overrides \
    GitHubRepository=YOUR_GITHUB_OWNER/YOUR_REPO \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-2
```

Optional: `CreateOIDCProvider=false` if the GitHub OIDC provider already exists.

**Outputs:**

```bash
./infra/aws/scripts/print-bootstrap-outputs.sh
```

Map **GitHubDeployRoleArn** → `AWS_ROLE_TO_ASSUME`, **DeploymentBucketName** → `AWS_S3_BUCKET`, **BootstrapRegion** → `AWS_REGION`.

### 2. Build and deploy the app stack

```bash
sam build -t infra/aws/template.yaml --use-container
sam deploy \
  -t .aws-sam/build/template.yaml \
  --stack-name syncbot-test \
  --s3-bucket YOUR_DEPLOYMENT_BUCKET_NAME \
  --capabilities CAPABILITY_IAM \
  --region us-east-2 \
  --parameter-overrides \
    Stage=test \
    SlackSigningSecret=... \
    SlackClientID=... \
    SlackClientSecret=... \
    SlackOauthBotScopes=... \
    SlackOauthUserScopes=... \
    DatabaseEngine=mysql \
    DatabaseSchema=syncbot_test \
    ...
```

Use **`sam deploy --guided`** the first time if you prefer prompts. For **existing RDS**, set `ExistingDatabaseHost`, `ExistingDatabaseAdminUser`, `ExistingDatabaseAdminPassword`, and for **private** DBs also `ExistingDatabaseNetworkMode=private`, `ExistingDatabaseSubnetIdsCsv`, `ExistingDatabaseLambdaSecurityGroupId`. Optional: `ExistingDatabasePort` (empty = engine default), `ExistingDatabaseCreateAppUser` / `ExistingDatabaseCreateSchema` (`true`/`false`). Omit `ExistingDatabaseHost` to create a **new** RDS in the stack.

**`DatabaseSchema` naming:** Use a per-stage database name such as `syncbot_test` / `syncbot_prod` (often `syncbot_` + `Stage`) so multiple environments can share one DB host without colliding. The app connects to the database named exactly by this parameter (and by the `DATABASE_SCHEMA` GitHub variable / `.env.deploy.*` value); it does **not** append the stage automatically. Match this name to the database your app user is granted on (e.g. same suffix as `sbapp_<stage>` from DbSetup).

**samconfig:** Predefined profiles in `samconfig.toml` (`test-new-rds`, `test-existing-rds`, etc.) — adjust placeholders before use.

**Secrets (SAM / CloudFormation):** `DATA_ENCRYPTION_KEY`, `DATABASE_PASSWORD`, and optionally `DATABASE_USER` are SAM parameters with `NoEcho: true`. The deploy script auto-generates `DATA_ENCRYPTION_KEY` if empty and saves it back to the `.env.deploy` file. Back it up securely — if lost, all workspaces must reinstall. When using `DbSetup` (admin creds provided), `DATABASE_PASSWORD` and `DATABASE_USER` are also auto-generated if empty.

**GitHub Actions:** `DATABASE_USER` is a **repository environment variable** (not a secret)—set it to the same value as in your local `.env.deploy.<stage>` so CI matches your deploy file.

**CloudWatch Logs:** Log retention is set to **30 days** in the SAM template (`RetentionInDays: 30`). Adjust in `infra/aws/template.yaml` if needed.

**Post-deploy migrate (Lambda only):** After `sam deploy`, run Alembic and warm the function (same as CI):

```bash
FUNCTION_ARN=$(aws cloudformation describe-stacks --stack-name syncbot-test \
  --query "Stacks[0].Outputs[?OutputKey=='SyncBotFunctionArn'].OutputValue" --output text)
aws lambda invoke --function-name "$FUNCTION_ARN" --payload '{"action":"migrate"}' \
  --cli-binary-format raw-in-base64-out /tmp/migrate.json && cat /tmp/migrate.json
```

The GitHub deploy role and bootstrap policy must allow `lambda:InvokeFunction` on `syncbot-*` functions; re-deploy the **bootstrap** stack if your policy predates that permission.

### 3. GitHub Actions (AWS)

Workflow: `.github/workflows/deploy-aws.yml` (runs on push to `test`/`prod` when not using GCP).

Configure **repository** variables: `AWS_ROLE_TO_ASSUME`, `AWS_S3_BUCKET`, `AWS_REGION`.

`AWS_S3_BUCKET` is the bootstrap **SAM deploy artifact** bucket (`DeploymentBucketName`): CI uses it for `sam deploy --s3-bucket` (Lambda package uploads) only. It is **not** for Slack file hosting or other app media. The guided deploy script resolves the target repo from **git remotes** (origin, upstream, then others): if your fork and upstream differ, it asks which `owner/repo` should receive variables, then passes `-R owner/repo` to `gh` so writes go there (not whatever `gh` infers from context alone).

Configure **per-environment** (`test` / `prod`) variables and secrets so they match your stack — especially if you use **existing RDS** or **private** networking:

| Type | Name | Notes |
|------|------|--------|
| Var | `AWS_STACK_NAME` | CloudFormation stack name |
| Var | `STAGE_NAME` | `test` or `prod` |
| Var | `DATABASE_SCHEMA` | MySQL/Postgres **database name** (e.g. `syncbot_test`, `syncbot_prod`). Convention: `syncbot_<stage>` when sharing a host across stages; must match `DatabaseSchema` / grants for your app user. |
| Var | `LOG_LEVEL` | Optional. `DEBUG`, `INFO`, `WARNING`, `ERROR`, or `CRITICAL`. Passed to SAM as `LogLevel`; defaults to `INFO` in the workflow when unset. |
| Var | `SLACK_CLIENT_ID` | From Slack app |
| Var | `DATABASE_ENGINE` | `mysql` or `postgresql` (workflow defaults to `mysql` if unset) |
| Var | `DATABASE_HOST` | Empty for **new** RDS in stack |
| Var | `DATABASE_ADMIN_USER` | When using existing host |
| Var | `DATABASE_NETWORK_MODE` | `public` or `private` |
| Var | `DATABASE_SUBNET_IDS_CSV` | **Private** mode: comma-separated subnet IDs (no spaces) |
| Var | `DATABASE_LAMBDA_SECURITY_GROUP_ID` | **Private** mode: Lambda ENI security group |
| Var | `DATABASE_PORT` | Optional; non-standard TCP port (e.g. `4000`). Empty = engine default in SAM. |
| Var | `DATABASE_CREATE_APP_USER` | `true` / `false` (default `true`). Set `false` when the DB cannot create a dedicated app user. |
| Var | `DATABASE_CREATE_SCHEMA` | `true` / `false` (default `true`). Set `false` when the database/schema already exists. |
| Var | `DATABASE_USERNAME_PREFIX` | Optional. Provider-specific username prefix (e.g. TiDB Cloud `abc123`; dot separator added automatically). Prepended to admin and default app user `{prefix}.sbapp_{stage}` in the bootstrap Lambda; use bare `DATABASE_ADMIN_USER` (e.g. `root`). Empty for RDS/standard MySQL. |
| Var | `DATABASE_APP_USERNAME` | Optional. Full dedicated app DB username (bypasses prefix + default `sbapp_{stage}`). Use if the auto name exceeds provider limits. Empty = default. |
| Secret | `SLACK_SIGNING_SECRET`, `SLACK_CLIENT_SECRET` | |
| Secret | `DATA_ENCRYPTION_KEY` | Required; back up securely |
| Secret | `DATABASE_PASSWORD` | App database password |
| Var | `DATABASE_USER` | App DB username (same as local `.env.deploy.*`; not a secret) |
| Secret | `DATABASE_ADMIN_PASSWORD` | When `DATABASE_HOST` is set |
| Var | `ENABLE_XRAY` | Optional. `true` / `false`. AWS X-Ray tracing (default `false`). |

The interactive deploy script can set these via `gh` when you opt in. Use `--setup-github` to push config to GitHub — works with both `--env` (non-interactive) and interactive deploys. Re-run that step after changing DB mode or engine so CI stays aligned.

**Bootstrap sync in CI:** The deploy workflow includes a conditional step that syncs the bootstrap CloudFormation stack (`template.bootstrap.yaml`) when the template has changed since the last deploy. The step compares template hashes and skips if unchanged. First-time bootstrap must be done locally with `./deploy.sh --env <stage> --bootstrap aws`.

**Dependency hygiene:** The CI workflow runs `pip-audit` on `syncbot/requirements.txt` and `infra/aws/db_setup/requirements.txt`. After changing `pyproject.toml`, run `poetry lock` and commit; the **pre-commit `sync-requirements` hook** (see [.pre-commit-config.yaml](../.pre-commit-config.yaml)) regenerates both requirements files when `poetry.lock` changes. If you do not use pre-commit, run the export commands documented in [DEVELOPMENT.md](DEVELOPMENT.md).

### 4. Ongoing local deploys (least privilege)

Assume the bootstrap **GitHubDeployRole** (or equivalent) and run `sam build` / `sam deploy` as in step 2.

---

## GCP — manual steps

### 1. Terraform bootstrap

From `infra/gcp` (or repo root with paths adjusted):

```bash
terraform init
terraform plan -var="project_id=YOUR_PROJECT_ID" -var="stage=test"
terraform apply -var="project_id=YOUR_PROJECT_ID" -var="stage=test"
```

Pass secrets as sensitive Terraform variables (`-var="slack_signing_secret=..."`, `-var="data_encryption_key=..."`, etc.). Set **`cloud_run_image`** after building and pushing the container. Capture outputs: service URL, region, project, Artifact Registry, deploy service account.

```bash
./infra/gcp/scripts/print-bootstrap-outputs.sh
```

### 2. GitHub Actions (GCP)

1. Configure [Workload Identity Federation](https://cloud.google.com/iam/docs/workload-identity-federation) for GitHub → deploy service account.
2. Set **`DEPLOY_TARGET=gcp`** at repo level so `deploy-gcp.yml` runs and `deploy-aws.yml` is skipped.
3. Set variables: `GCP_PROJECT_ID`, `GCP_REGION`, `GCP_WORKLOAD_IDENTITY_PROVIDER`, `GCP_SERVICE_ACCOUNT`, etc.

   The interactive `infra/gcp/scripts/deploy.sh` uses the same GitHub `owner/repo` selection as the AWS script (based on git remotes when fork and upstream differ).

**Note:** `.github/workflows/deploy-gcp.yml` is intentionally configured to fail until real CI steps are implemented (WIF auth, image build/push, deploy). Keep using `infra/gcp/scripts/deploy.sh` for interactive deploys until CI is fully wired.

### 3. Ongoing deploys

Build and push an image to Artifact Registry, then `gcloud run deploy` or `terraform apply` with updated `cloud_run_image`.

---

## Using an existing RDS host (AWS)

When **ExistingDatabaseHost** is set, the template **does not** create VPC/RDS; a custom resource can create the schema and optionally a dedicated app user (default `sbapp_<stage>`, or **ExistingDatabaseAppUsername** if set). When **`ExistingDatabaseCreateAppUser=false`** and admin credentials are omitted, `DATABASE_USER` and `DATABASE_PASSWORD` must be provided directly (e.g. via `.env.deploy` file) and the `DbSetup` custom resource is skipped entirely.

- **Public:** Lambda is not in your VPC; the DB must be reachable on the Internet on the configured port (**`ExistingDatabasePort`**, or **3306** / **5432** by engine).
- **Private:** Lambda uses `ExistingDatabaseSubnetIdsCsv` and `ExistingDatabaseLambdaSecurityGroupId`; DB security group must allow the Lambda SG; subnets need **NAT** egress for Slack API calls.

See also [Sharing infrastructure across apps](#sharing-infrastructure-across-apps-aws) below.

---

## Swapping providers

1. Keep [INFRA_CONTRACT.md](INFRA_CONTRACT.md) satisfied.
2. Disable the old provider’s workflow; set `DEPLOY_TARGET` if using GCP.
3. Bootstrap the new provider; reconfigure GitHub and Slack URLs.

---

## Helper scripts

| Script | Purpose |
|--------|---------|
| `infra/aws/scripts/print-bootstrap-outputs.sh` | Bootstrap stack outputs → suggested GitHub vars |
| `infra/aws/scripts/deploy.sh` | Interactive AWS deploy (see [What the deploy scripts do](#what-the-deploy-scripts-do)) |
| `infra/gcp/scripts/print-bootstrap-outputs.sh` | Terraform outputs → suggested GitHub vars |
| `infra/gcp/scripts/deploy.sh` | Interactive GCP deploy |

---

## Security summary

- **Bootstrap** runs once with elevated credentials; creates deploy identity + artifact storage.
- **GitHub:** Short-lived **AWS OIDC** or **GCP WIF** — no long-lived cloud API keys in repos for deploy.
- **Prod:** Use GitHub environment protection rules as needed.

---

## Database schema (Alembic)

Schema lives under `syncbot/db/alembic/`. **`alembic upgrade head`** runs:

- **AWS (GitHub Actions):** After `sam deploy`, the workflow invokes the Lambda with `{"action":"migrate"}` (migrations + warm instance). Manual `sam deploy` from the guided script should be followed by the same invoke (see script post-deploy or run `aws lambda invoke` with that payload using stack output `SyncBotFunctionArn`).
- **Cloud Run / `python app.py`:** At process startup before the server listens.

---

## Post-deploy: Slack deferred modal flows (manual smoke test)

After deploying a build that changes Slack listener wiring, verify **in the deployed workspace** (not only local dev) that modals using custom interaction responses still work. These flows rely on `view_submission` acks (`response_action`: `update`, `errors`, or `push`) being returned in the **first** Lambda response:

1. **Sync Channel (publish)** — Open **Sync Channel**, choose sync mode, press **Next**; confirm step 2 (channel picker) appears. Submit with an invalid state to confirm field errors if applicable.
2. **Backup / Restore** — Open Backup/Restore; try restore validation (e.g. missing file) and, if possible, the integrity-warning confirmation path (`push`).
3. **Data migration** (if federation enabled) — Same style of checks for import validation and confirmation.
4. **Optional** — Trigger a Home tab action that opens a modal via **`views_open`** (uses `trigger_id`) after a cold start to spot-check latency.

---

## Sharing infrastructure across apps (AWS)

Reuse one RDS with **different `DatabaseSchema`** per app/environment; set **ExistingDatabaseHost** and distinct schemas. Prefer names like `syncbot_test` vs `syncbot_prod` so each stage’s app user (`sbapp_<stage>` by default) maps cleanly to its own database. Lambda Function URLs remain per stack.

---

## Migrating from previous versions

### Secrets Manager removal (AWS)

Previous versions stored `DATA_ENCRYPTION_KEY` and database passwords in AWS Secrets Manager. This has been removed to reduce costs and complexity.

**Before upgrading**, retrieve your existing `DATA_ENCRYPTION_KEY`:

```bash
aws secretsmanager get-secret-value \
  --secret-id syncbot-<stage>-syncbot-token-encryption-key \
  --query SecretString --output text
```

Save this value in your `.env.deploy.<stage>` file as `DATA_ENCRYPTION_KEY=<value>`.

Similarly, if `DATABASE_PASSWORD` was in Secrets Manager:

```bash
aws secretsmanager get-secret-value \
  --secret-id syncbot-<stage>-syncbot-app-db-credentials \
  --query 'SecretString' --output text | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])"
```

After deploying with the new version, you can manually delete the orphaned secrets in AWS Secrets Manager to stop incurring charges.

### GitHub: `DATABASE_USER` is a variable (not a secret)

If your repo still has **`DATABASE_USER` under environment secrets**, remove it and create the same name under **environment variables** with the same value (or re-run `./deploy.sh` with CI/CD / `--setup-github` so `gh` writes the variable). The deploy workflow reads `${{ vars.DATABASE_USER }}`; a leftover secret is ignored.

### Secrets Manager removal (GCP)

Previous versions stored secrets in GCP Secret Manager. Retrieve existing values before upgrading:

```bash
gcloud secrets versions access latest --secret=syncbot-<stage>-syncbot-token-encryption-key
```

Save to your `.env.deploy.<stage>` file. After deploying with the new version, you can manually delete the orphaned secrets in GCP Secret Manager.

### API Gateway removal (AWS)

API Gateway has been replaced by Lambda Function URLs.

**New installs:** No special action needed — `template.yaml` works directly.

**Existing stacks upgrading from v1.0.x:** CloudFormation can reject **changesets** with `AWS::EarlyValidation::ResourceExistenceCheck` when a single update removes one kind of resource (for example API Gateway) and adds another (for example a Lambda Function URL). **`sam deploy` always creates a changeset**, so that path can fail.

**Automatic retry:** The AWS deploy script ([infra/aws/scripts/deploy.sh](infra/aws/scripts/deploy.sh)) and GitHub Actions ([infra/aws/scripts/ci_sam_deploy_with_fallback.sh](infra/aws/scripts/ci_sam_deploy_with_fallback.sh)) try `sam deploy` first; if the failure output contains `EarlyValidation::ResourceExistenceCheck`, they **retry using `aws cloudformation update-stack`** (no changeset), which bypasses that validation. No flags are required for most migrations.

**Optional:** Pass **`--update-stack`** to `./deploy.sh` to skip the initial `sam deploy` and go straight to `update-stack` when you already know the changeset will fail (saves one failed attempt).

```bash
./deploy.sh --env test aws
# or, to force update-stack only:
./deploy.sh --env test --update-stack aws
```

**Manual alternative:** From a SAM build output, run `sam package` (upload artifacts to your deploy bucket), upload the packaged template to S3, then `aws cloudformation update-stack --template-url ... --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND` with the same parameters as your stack, and `aws cloudformation wait stack-update-complete`.

**After migration:** Update your Slack app's **Request URL** and **Redirect URLs** to use the new Lambda Function URL (shown in deploy output as `SyncBotApiUrl` / `SyncBotInstallUrl`). The generated `slack-manifest_<stage>.json` already contains the correct URLs.

### New `.env.deploy` workflow

Create `.env.deploy.test` and/or `.env.deploy.prod` from `.env.deploy.example`:

```bash
cp .env.deploy.example .env.deploy.test
# Edit with your values, then:
./deploy.sh --env test aws
```

These files are gitignored. For CI/CD, use GitHub environment variables and secrets instead (set via `--setup-github` or manually).

### Database env names (`EXISTING_DATABASE_*` → `DATABASE_*`)

For external / existing RDS flows, GitHub environment **variables** and **secrets** now use unprefixed names (for example `DATABASE_HOST`, `DATABASE_ADMIN_USER`, `secrets.DATABASE_ADMIN_PASSWORD`) instead of `EXISTING_DATABASE_*`. SAM parameter names on the stack are unchanged (`ExistingDatabaseHost`, etc.). The deploy scripts still honor the old `EXISTING_DATABASE_*` names if set, so local env files can migrate gradually; GitHub Actions should use the new names to match `.github/workflows/deploy-aws.yml`.

---

## Secret Manager integration (optional)

For teams that store secrets in AWS Secrets Manager or GCP Secret Manager, the deploy script supports **`_SM_ID`** env vars. If a variable like `SLACK_SIGNING_SECRET` is empty but `SLACK_SIGNING_SECRET_SM_ID` is set to a secret name/ID, the script fetches the value automatically at deploy time.

```bash
# .env.deploy.test
SLACK_SIGNING_SECRET_SM_ID=syncbot/slack-signing-secret
DATA_ENCRYPTION_KEY_SM_ID=syncbot/token-encryption-key
```

Direct values always take precedence over `_SM_ID` refs. The resolution happens once in the root `deploy.sh` after sourcing the env file, using the `CLOUD_PROVIDER` to select `aws secretsmanager` or `gcloud secrets`. See `.env.deploy.example` for commented examples.
