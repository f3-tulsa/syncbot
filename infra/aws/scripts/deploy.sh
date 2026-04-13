#!/usr/bin/env bash
# Interactive AWS deploy helper for SyncBot.
# Handles: bootstrap (optional), sam build, sam deploy (new RDS or existing RDS).
#
# Run from repo root:
#   ./infra/aws/scripts/deploy.sh
#
# Non-interactive path (ENV_FILE_LOADED=true):
#   Sources .env.deploy.{stage}, builds SAM params from env vars, runs sam build + deploy.
#
# Interactive path (no --env flag):
#   1) Prerequisites: CLI checks, template paths
#   2) Authentication: AWS region and credentials
#   3) Bootstrap probe: read bootstrap stack outputs (create/sync runs only if task 1 selected)
#   4) Stack identity: stage, app stack name; detect existing stack for update
#   5) Deploy Tasks: multi-select menu (bootstrap, build/deploy, CI/CD, Slack API)
#   6) Configuration (if build/deploy): database, Slack creds, SAM build + deploy
#   7) Post-tasks: Slack manifest/API, GitHub Actions, deploy receipt

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

BOOTSTRAP_TEMPLATE="$REPO_ROOT/infra/aws/template.bootstrap.yaml"
APP_TEMPLATE="$REPO_ROOT/infra/aws/template.yaml"
SLACK_MANIFEST_GENERATED_PATH=""

# shellcheck source=/dev/null
source "$REPO_ROOT/deploy.sh"

# ---------------------------------------------------------------------------
# SAM deploy with fallback to direct CloudFormation update-stack
# When sam deploy fails because changeset early validation rejects the update
# (e.g. AWS::EarlyValidation::ResourceExistenceCheck), retry with update-stack,
# which skips changeset creation. Optional --update-stack skips sam deploy.
# Uses globals: STACK_NAME, REGION, S3_BUCKET, PARAMS (update-stack converts PARAMS to JSON)
# ---------------------------------------------------------------------------
delete_failed_changesets() {
  local stack_name="$1" region="$2" names cs
  names="$(aws cloudformation list-change-sets \
    --stack-name "$stack_name" \
    --region "$region" \
    --query 'Summaries[?Status==`FAILED`].ChangeSetName' \
    --output text 2>/dev/null || true)"
  [[ -z "$names" || "$names" == "None" ]] && return 0
  for cs in $names; do
    [[ -z "$cs" ]] && continue
    aws cloudformation delete-change-set \
      --change-set-name "$cs" \
      --stack-name "$stack_name" \
      --region "$region" 2>/dev/null || true
  done
}

# Lambda may auto-create /aws/lambda/<name> before CloudFormation's LogGroup resource runs,
# causing ResourceExistenceCheck / AlreadyExists on deploy. Delete those so CF can create them.
delete_orphaned_log_groups() {
  local stack="$1" region="$2" functions fn lg_name
  functions="$(aws cloudformation list-stack-resources \
    --stack-name "$stack" \
    --region "$region" \
    --query "StackResourceSummaries[?ResourceType=='AWS::Lambda::Function'].PhysicalResourceId" \
    --output text 2>/dev/null || true)"
  [[ -z "$functions" || "$functions" == "None" ]] && return 0
  for fn in $functions; do
    [[ -z "$fn" ]] && continue
    lg_name="/aws/lambda/${fn}"
    if aws logs describe-log-groups \
      --log-group-name-prefix "$lg_name" \
      --region "$region" \
      --query 'logGroups[].logGroupName' \
      --output text 2>/dev/null | tr '\t' '\n' | grep -Fxq "$lg_name"; then
      echo "=== Deleting orphaned log group: $lg_name ===" >&2
      aws logs delete-log-group --log-group-name "$lg_name" --region "$region" 2>/dev/null || true
    fi
  done
}

# GitHub Actions variables cannot be empty strings (HTTP 422). Delete if empty, set otherwise.
# Piping avoids gh treating --body "" as interactive stdin in some gh versions.
gh_variable_set_env() {
  local name="$1" env_name="$2" repo="$3" value="${4:-}"
  if [[ -z "$value" ]]; then
    gh variable delete "$name" --env "$env_name" -R "$repo" 2>/dev/null || true
  else
    printf '%s' "$value" | gh variable set "$name" --env "$env_name" -R "$repo"
  fi
}

# Convert Key=Value lines (stdin or pipe) to JSON for aws cloudformation update-stack --parameters.
params_to_json() {
  python3 -c "
import json, sys
result = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    k, _, v = line.partition('=')
    result.append({'ParameterKey': k, 'ParameterValue': v})
print(json.dumps(result))
"
}

deploy_via_update_stack() {
  local packaged template_key template_url cf_params_json

  mkdir -p .aws-sam/build
  packaged=".aws-sam/build/packaged-for-update-stack.yaml"

  echo "=== SAM Package (for CloudFormation update-stack) ===" >&2
  sam package \
    --template-file .aws-sam/build/template.yaml \
    --s3-bucket "$S3_BUCKET" \
    --output-template-file "$packaged" \
    --region "$REGION"

  template_key="packaged-templates/${STACK_NAME}-$(date +%s)-$$.yaml"
  echo "=== Upload packaged template to s3://${S3_BUCKET}/${template_key} ===" >&2
  aws s3 cp "$packaged" "s3://${S3_BUCKET}/${template_key}" --region "$REGION"

  template_url="https://${S3_BUCKET}.s3.${REGION}.amazonaws.com/${template_key}"

  cf_params_json="$(printf '%s\n' "${PARAMS[@]}" | params_to_json)"

  echo "=== CloudFormation update-stack ===" >&2
  aws cloudformation update-stack \
    --stack-name "$STACK_NAME" \
    --template-url "$template_url" \
    --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND \
    --region "$REGION" \
    --parameters "$cf_params_json"

  echo "=== Waiting for stack update to complete ===" >&2
  aws cloudformation wait stack-update-complete --stack-name "$STACK_NAME" --region "$REGION"
}

sam_deploy_or_fallback() {
  if [[ "${UPDATE_STACK:-}" == "true" ]]; then
    echo "=== SAM Deploy (direct update-stack; --update-stack set) ===" >&2
    deploy_via_update_stack
    return 0
  fi

  local log rc
  local -a sam_params=()
  local _p
  log="$(mktemp)"
  trap 'rm -f "$log"' RETURN

  for _p in "${PARAMS[@]}"; do
    [[ "$_p" == *"="?* ]] && sam_params+=("$_p")
  done

  set +e
  set -o pipefail
  sam deploy \
    -t .aws-sam/build/template.yaml \
    --stack-name "$STACK_NAME" \
    --s3-bucket "$S3_BUCKET" \
    --capabilities CAPABILITY_IAM \
    --region "$REGION" \
    --no-fail-on-empty-changeset \
    --parameter-overrides "${sam_params[@]}" 2>&1 | tee "$log"
  rc="${PIPESTATUS[0]}"
  set +o pipefail
  set -e

  if [[ "$rc" -eq 0 ]]; then
    return 0
  fi

  if grep -q 'EarlyValidation::ResourceExistenceCheck' "$log"; then
    echo "" >&2
    echo "=== Changeset rejected by CloudFormation early validation; retrying with direct update-stack... ===" >&2
    delete_failed_changesets "$STACK_NAME" "$REGION" || true
    delete_orphaned_log_groups "$STACK_NAME" "$REGION" || true
    deploy_via_update_stack
    return 0
  fi

  return "$rc"
}

prompt_default() {
  local prompt="$1"
  local default="$2"
  local value
  read -r -p "$prompt [$default]: " value
  if [[ -z "$value" ]]; then
    value="$default"
  fi
  echo "$value"
}

prompt_secret() {
  local prompt="$1"
  local value
  read -r -s -p "$prompt: " value
  # Keep the visual newline on the terminal even when called via $(...).
  printf '\n' >&2
  echo "$value"
}

prompt_required() {
  local prompt="$1"
  local value
  while true; do
    read -r -p "$prompt: " value
    if [[ -n "$value" ]]; then
      echo "$value"
      return 0
    fi
    echo "Error: $prompt is required." >&2
  done
}

prompt_secret_required() {
  local prompt="$1"
  local value
  while true; do
    value="$(prompt_secret "$prompt")"
    if [[ -n "$value" ]]; then
      echo "$value"
      return 0
    fi
    echo "Error: $prompt is required." >&2
  done
}

required_from_env_or_prompt() {
  local env_name="$1"
  local prompt="$2"
  local mode="${3:-plain}" # plain|secret
  local env_value="${!env_name:-}"
  if [[ -n "$env_value" ]]; then
    echo "Using $prompt from environment variable $env_name." >&2
    echo "$env_value"
    return 0
  fi
  if [[ "$mode" == "secret" ]]; then
    prompt_secret_required "$prompt"
  else
    prompt_required "$prompt"
  fi
}

# When local env overrides differ from the CloudFormation stack (e.g. GitHub-deployed TiDB vs .env RDS),
# prompt the operator instead of silently preferring env.
resolve_with_conflict_check() {
  local label="$1"
  local env_value="$2"
  local stack_value="$3"
  local prompt_default_value="$4"
  local mode="${5:-plain}" # plain|secret|bool

  if [[ -z "$env_value" ]]; then
    if [[ "$mode" == "secret" ]]; then
      prompt_secret_required "$label"
    elif [[ "$mode" == "bool" ]]; then
      local yn_def="${prompt_default_value:-y}"
      if prompt_yes_no "$label" "$yn_def"; then
        echo "true"
      else
        echo "false"
      fi
    else
      prompt_default "$label" "$prompt_default_value"
    fi
    return 0
  fi

  if [[ "$mode" == "bool" ]]; then
    if [[ "$env_value" != "true" && "$env_value" != "false" ]]; then
      echo "Error: environment value for $label must be true or false." >&2
      exit 1
    fi
    if [[ -z "$stack_value" || "$env_value" == "$stack_value" ]]; then
      echo "Using $label from environment variable." >&2
      echo "$env_value"
      return 0
    fi
    echo "" >&2
    echo "CONFLICT: $label differs between local env and deployed stack:" >&2
    echo "  Local env:  $env_value" >&2
    echo "  AWS stack:  $stack_value" >&2
    local choice
    read -r -p "Use (l)ocal env / (a)ws stack / (e)nter new value? [l/a/e]: " choice >&2
    case "$choice" in
      a | A) echo "$stack_value" ;;
      e | E)
        if prompt_yes_no "$label" "${prompt_default_value:-y}"; then
          echo "true"
        else
          echo "false"
        fi
        ;;
      *) echo "$env_value" ;;
    esac
    return 0
  fi

  if [[ -z "$stack_value" || "$env_value" == "$stack_value" ]]; then
    echo "Using $label from environment variable." >&2
    echo "$env_value"
    return 0
  fi

  local display_env="$env_value"
  local display_stack="$stack_value"
  if [[ "$mode" == "secret" ]]; then
    display_env="(hidden)"
    display_stack="(hidden)"
  fi
  echo "" >&2
  echo "CONFLICT: $label differs between local env and deployed stack:" >&2
  echo "  Local env:  $display_env" >&2
  echo "  AWS stack:  $display_stack" >&2
  local choice
  read -r -p "Use (l)ocal env / (a)ws stack / (e)nter new value? [l/a/e]: " choice >&2
  case "$choice" in
    a | A) echo "$stack_value" ;;
    e | E)
      if [[ "$mode" == "secret" ]]; then
        prompt_secret_required "$label"
      else
        prompt_required "$label"
      fi
      ;;
    *) echo "$env_value" ;;
  esac
}

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-y}"
  local answer
  local shown="y/N"
  [[ "$default" == "y" ]] && shown="Y/n"
  read -r -p "$prompt [$shown]: " answer
  if [[ -z "$answer" ]]; then
    answer="$default"
  fi
  [[ "$answer" =~ ^[Yy]$ ]]
}

ensure_aws_authenticated() {
  local profile active_profile sso_start_url sso_region
  profile="${AWS_PROFILE:-}"
  active_profile="$profile"
  if [[ -z "$active_profile" ]]; then
    active_profile="$(aws configure get profile 2>/dev/null || true)"
    [[ -z "$active_profile" ]] && active_profile="default"
  fi

  if aws sts get-caller-identity >/dev/null 2>&1; then
    return 0
  fi

  sso_start_url="$(aws configure get sso_start_url --profile "$active_profile" 2>/dev/null || true)"
  sso_region="$(aws configure get sso_region --profile "$active_profile" 2>/dev/null || true)"

  echo "AWS CLI is not authenticated."
  if [[ -n "$sso_start_url" && -n "$sso_region" ]]; then
    if prompt_yes_no "Run 'aws sso login --profile $active_profile' now?" "y"; then
      aws sso login --profile "$active_profile" || true
    fi
  else
    echo "No complete SSO config found for profile '$active_profile'."
    # Prefer the user's default interactive AWS login flow when available.
    if aws login help >/dev/null 2>&1; then
      if prompt_yes_no "Run 'aws login' now?" "y"; then
        aws login || true
      fi
    fi

    if ! aws sts get-caller-identity >/dev/null 2>&1; then
      if prompt_yes_no "Run 'aws configure sso --profile $active_profile' now?" "n"; then
        aws configure sso --profile "$active_profile" || true
        if prompt_yes_no "Run 'aws sso login --profile $active_profile' now?" "y"; then
          aws sso login --profile "$active_profile" || true
        fi
      else
        echo "Tip: use 'aws configure' if you authenticate with access keys."
      fi
    fi
  fi

  if ! aws sts get-caller-identity >/dev/null 2>&1; then
    echo "Unable to authenticate AWS CLI."
    echo "Run one of the following, then rerun deploy:"
    echo "  aws login"
    echo "  aws configure sso [--profile <profile>]"
    echo "  aws sso login [--profile <profile>]"
    echo "  aws configure"
    exit 1
  fi
}

ensure_gh_authenticated() {
  if ! command -v gh >/dev/null 2>&1; then
    prereqs_hint_gh_cli >&2
    return 1
  fi
  if gh auth status >/dev/null 2>&1; then
    return 0
  fi
  echo "gh CLI is not authenticated."
  if prompt_yes_no "Run 'gh auth login' now?" "y"; then
    gh auth login || true
  fi
  if gh auth status >/dev/null 2>&1; then
    return 0
  fi
  echo "gh authentication is still missing. Skipping automatic GitHub setup."
  return 1
}

slack_manifest_json_compact() {
  local manifest_file="$1"
  python3 - "$manifest_file" <<'PY'
import json
import sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
print(json.dumps(data, separators=(",", ":")))
PY
}

slack_api_configure_from_manifest() {
  local manifest_file="$1"
  local install_url="$2"
  local token app_id team_id manifest_json api_resp ok

  echo
  echo "=== Slack App API ==="

  token="$(required_from_env_or_prompt "SLACK_API_TOKEN" "Slack API token (required scopes: apps.manifest:write)" "secret")"
  app_id="$(prompt_default "Slack App ID (optional; blank = create new app)" "${SLACK_APP_ID:-}")"
  team_id="$(prompt_default "Slack Team ID (optional; usually blank)" "${SLACK_TEAM_ID:-}")"

  manifest_json="$(slack_manifest_json_compact "$manifest_file" 2>/dev/null || true)"
  if [[ -z "$manifest_json" ]]; then
    echo "Could not parse manifest JSON automatically."
    echo "Ensure $manifest_file is valid JSON and Python 3 is installed."
    return 0
  fi

  if [[ -n "$app_id" ]]; then
    if [[ -n "$team_id" ]]; then
      api_resp="$(curl -sS -X POST \
        -H "Authorization: Bearer $token" \
        --data-urlencode "app_id=$app_id" \
        --data-urlencode "team_id=$team_id" \
        --data-urlencode "manifest=$manifest_json" \
        "https://slack.com/api/apps.manifest.update" || true)"
    else
      api_resp="$(curl -sS -X POST \
        -H "Authorization: Bearer $token" \
        --data-urlencode "app_id=$app_id" \
        --data-urlencode "manifest=$manifest_json" \
        "https://slack.com/api/apps.manifest.update" || true)"
    fi
    ok="$(python3 - "$api_resp" <<'PY'
import json,sys
try:
    data=json.loads(sys.argv[1])
except Exception:
    print("invalid-json")
    sys.exit(0)
print("ok" if data.get("ok") else f"error:{data.get('error','unknown_error')}")
PY
)"
    if [[ "$ok" == "ok" ]]; then
      echo "Slack app manifest updated for App ID: $app_id"
      echo "Open install URL: $install_url"
    else
      echo "Slack API update failed: ${ok#error:}"
      echo "Response (truncated):"
      slack_api_echo_truncated_body "$api_resp"
      echo "Hint: check token scopes (apps.manifest:write), manifest JSON, and api.slack.com methods apps.manifest.update"
    fi
    return 0
  fi

  # No App ID supplied: create a new Slack app from manifest.
  if [[ -n "$team_id" ]]; then
    api_resp="$(curl -sS -X POST \
      -H "Authorization: Bearer $token" \
      --data-urlencode "team_id=$team_id" \
      --data-urlencode "manifest=$manifest_json" \
      "https://slack.com/api/apps.manifest.create" || true)"
  else
    api_resp="$(curl -sS -X POST \
      -H "Authorization: Bearer $token" \
      --data-urlencode "manifest=$manifest_json" \
      "https://slack.com/api/apps.manifest.create" || true)"
  fi
  ok="$(python3 - "$api_resp" <<'PY'
import json,sys
try:
    data=json.loads(sys.argv[1])
except Exception:
    print("invalid-json")
    sys.exit(0)
if not data.get("ok"):
    print(f"error:{data.get('error','unknown_error')}")
    sys.exit(0)
app_id = data.get("app_id") or (data.get("app", {}) or {}).get("id") or ""
print(f"ok:{app_id}")
PY
)"
  if [[ "$ok" == ok:* ]]; then
    app_id="${ok#ok:}"
    echo "Slack app created successfully."
    [[ -n "$app_id" ]] && echo "New Slack App ID: $app_id"
    echo "Open install URL: $install_url"
  else
    echo "Slack API create failed: ${ok#error:}"
    echo "Response (truncated):"
    slack_api_echo_truncated_body "$api_resp"
    echo "Hint: check token scopes (apps.manifest:write), manifest JSON, and api.slack.com methods apps.manifest.create"
  fi
}

bootstrap_describe_outputs() {
  local stack_name="$1"
  local region="$2"
  aws cloudformation describe-stacks \
    --stack-name "$stack_name" \
    --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' \
    --output text \
    --region "$region" 2>/dev/null || true
}

app_describe_outputs() {
  local stack_name="$1"
  local region="$2"
  aws cloudformation describe-stacks \
    --stack-name "$stack_name" \
    --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' \
    --output text \
    --region "$region" 2>/dev/null || true
}

output_value() {
  local outputs="$1"
  local key="$2"
  echo "$outputs" | awk -F'\t' -v k="$key" '$1==k {print $2}'
}

configure_github_actions_aws() {
  # $1  Bootstrap stack outputs (tab-separated OutputKey / OutputValue)
  # $2  Bootstrap CloudFormation stack name (for OIDC drift check vs gh repo)
  # $3  AWS region for this deploy session (fallback if bootstrap has no BootstrapRegion output)
  # $4  App CloudFormation stack name
  # $5  Stage name (test|prod) — GitHub environment name
  # $6  Database schema name
  # $7  DB source mode: 1 = stack-managed RDS, 2 = external or existing host (matches SAM / prompts)
  # $8  DB host (mode 2)
  # $9  DB admin user (mode 2)
  # $10 DB admin password (mode 2)
  # $11 DB network mode: public | private
  # $12 Comma-separated subnet IDs for Lambda in private mode
  # $13 Lambda ENI security group id in private mode
  # $14 Database engine: mysql | postgresql
  # $15 DB port override (empty = engine default in SAM)
  # $16 DATABASE_CREATE_APP_USER: true | false
  # $17 DATABASE_CREATE_SCHEMA: true | false
  # $18 DATABASE_USERNAME_PREFIX (e.g. TiDB cluster prefix; empty for RDS)
  # $19 DATABASE_APP_USERNAME (optional full app DB user; empty = default)
  local bootstrap_outputs="$1"
  local bootstrap_stack_name="$2"
  local aws_region="$3"
  local app_stack_name="$4"
  local deploy_stage="$5"
  local database_schema="$6"
  local db_mode="$7"
  local db_host="$8"
  local db_admin_user="$9"
  local db_admin_password="${10}"
  local db_network_mode="${11:-}"
  [[ -z "$db_network_mode" ]] && db_network_mode="public"
  local db_subnet_ids_csv="${12:-}"
  local db_lambda_sg_id="${13:-}"
  local database_engine="${14:-}"
  [[ -z "$database_engine" ]] && database_engine="mysql"
  local db_port="${15:-}"
  local db_create_app_user="${16:-true}"
  local db_create_schema="${17:-true}"
  local db_username_prefix="${18:-}"
  local db_app_username="${19:-}"
  [[ -z "$db_create_app_user" ]] && db_create_app_user="true"
  [[ -z "$db_create_schema" ]] && db_create_schema="true"
  local role bucket boot_region
  role="$(output_value "$bootstrap_outputs" "GitHubDeployRoleArn")"
  bucket="$(output_value "$bootstrap_outputs" "DeploymentBucketName")"
  boot_region="$(output_value "$bootstrap_outputs" "BootstrapRegion")"
  [[ -z "$boot_region" ]] && boot_region="$aws_region"
  local repo env_name
  env_name="$deploy_stage"

  echo
  echo "=== GitHub Actions (AWS) ==="
  echo "Detected bootstrap role:   $role"
  echo "Detected deploy bucket:    $bucket  (SAM/CI packaging for sam deploy — not Slack or app media)"
  echo "Detected bootstrap region: $boot_region"
  repo="$(prompt_github_repo_for_actions "$REPO_ROOT")"
  maybe_prompt_bootstrap_github_trust_update "$repo" "$bootstrap_stack_name" "$aws_region"

  if ! ensure_gh_authenticated; then
    echo
    echo "Set these GitHub Actions Variables manually (on the repo you intend):"
    echo "  AWS_ROLE_TO_ASSUME = $role"
    echo "  AWS_S3_BUCKET      = $bucket  (SAM deploy artifact bucket / DeploymentBucketName; not Slack file storage)"
    echo "  AWS_REGION         = $boot_region"
    echo "For environment '$env_name' also set AWS_STACK_NAME, STAGE_NAME, DATABASE_SCHEMA, DATABASE_ENGINE,"
    echo "and (if using external DB) DATABASE_* / private VPC vars — see docs/DEPLOY.md."
    return 0
  fi

  if prompt_yes_no "Create/update GitHub environments 'test' and 'prod' now?" "y"; then
    gh api -X PUT "repos/$repo/environments/test" >/dev/null
    gh api -X PUT "repos/$repo/environments/prod" >/dev/null
    echo "GitHub environments ensured: test, prod."
  fi

  if prompt_yes_no "Set repo variables with gh now (AWS_ROLE_TO_ASSUME, AWS_S3_BUCKET, AWS_REGION)? AWS_S3_BUCKET is SAM/CI packaging only (DeploymentBucketName)." "y"; then
    [[ -n "$role" ]] && gh variable set AWS_ROLE_TO_ASSUME --body "$role" -R "$repo"
    [[ -n "$bucket" ]] && gh variable set AWS_S3_BUCKET --body "$bucket" -R "$repo"
    [[ -n "$boot_region" ]] && gh variable set AWS_REGION --body "$boot_region" -R "$repo"
    echo "GitHub repository variables updated."
  fi

  if prompt_yes_no "Set environment variables for '$env_name' now (AWS_STACK_NAME, STAGE_NAME, DATABASE_SCHEMA, DB host/user vars)?" "y"; then
    gh_variable_set_env AWS_STACK_NAME "$env_name" "$repo" "$app_stack_name"
    gh_variable_set_env STAGE_NAME "$env_name" "$repo" "$deploy_stage"
    gh_variable_set_env DATABASE_SCHEMA "$env_name" "$repo" "$database_schema"
    gh_variable_set_env DATABASE_ENGINE "$env_name" "$repo" "$database_engine"
    gh_variable_set_env SLACK_CLIENT_ID "$env_name" "$repo" "${SLACK_CLIENT_ID:-}"
    if [[ "$db_mode" == "2" ]]; then
      gh_variable_set_env DATABASE_HOST "$env_name" "$repo" "$db_host"
      gh_variable_set_env DATABASE_ADMIN_USER "$env_name" "$repo" "$db_admin_user"
      gh_variable_set_env DATABASE_NETWORK_MODE "$env_name" "$repo" "$db_network_mode"
      if [[ "$db_network_mode" == "private" ]]; then
        gh_variable_set_env DATABASE_SUBNET_IDS_CSV "$env_name" "$repo" "$db_subnet_ids_csv"
        gh_variable_set_env DATABASE_LAMBDA_SECURITY_GROUP_ID "$env_name" "$repo" "$db_lambda_sg_id"
      else
        gh_variable_set_env DATABASE_SUBNET_IDS_CSV "$env_name" "$repo" ""
        gh_variable_set_env DATABASE_LAMBDA_SECURITY_GROUP_ID "$env_name" "$repo" ""
      fi
      gh_variable_set_env DATABASE_PORT "$env_name" "$repo" "$db_port"
      gh_variable_set_env DATABASE_CREATE_APP_USER "$env_name" "$repo" "$db_create_app_user"
      gh_variable_set_env DATABASE_CREATE_SCHEMA "$env_name" "$repo" "$db_create_schema"
      gh_variable_set_env DATABASE_USERNAME_PREFIX "$env_name" "$repo" "$db_username_prefix"
      gh_variable_set_env DATABASE_APP_USERNAME "$env_name" "$repo" "$db_app_username"
      gh_variable_set_env DATABASE_USER "$env_name" "$repo" "${DATABASE_USER:-}"
    else
      # Clear existing-host vars for new-RDS mode to avoid stale CI config.
      gh_variable_set_env DATABASE_HOST "$env_name" "$repo" ""
      gh_variable_set_env DATABASE_ADMIN_USER "$env_name" "$repo" ""
      gh_variable_set_env DATABASE_NETWORK_MODE "$env_name" "$repo" "public"
      gh_variable_set_env DATABASE_SUBNET_IDS_CSV "$env_name" "$repo" ""
      gh_variable_set_env DATABASE_LAMBDA_SECURITY_GROUP_ID "$env_name" "$repo" ""
      gh_variable_set_env DATABASE_PORT "$env_name" "$repo" ""
      gh_variable_set_env DATABASE_CREATE_APP_USER "$env_name" "$repo" "true"
      gh_variable_set_env DATABASE_CREATE_SCHEMA "$env_name" "$repo" "true"
      gh_variable_set_env DATABASE_USERNAME_PREFIX "$env_name" "$repo" ""
      gh_variable_set_env DATABASE_APP_USERNAME "$env_name" "$repo" ""
      gh_variable_set_env DATABASE_USER "$env_name" "$repo" ""
    fi
    echo "Environment variables updated for '$env_name'."
  fi

  echo "Setting GitHub environment secrets for '$env_name' (Slack, DATA_ENCRYPTION_KEY, DATABASE_PASSWORD, ...)..."
  if [[ -z "${SLACK_SIGNING_SECRET:-}" ]]; then
    SLACK_SIGNING_SECRET="$(required_from_env_or_prompt "SLACK_SIGNING_SECRET" "SlackSigningSecret" "secret")"
  fi
  if [[ -z "${SLACK_CLIENT_SECRET:-}" ]]; then
    SLACK_CLIENT_SECRET="$(required_from_env_or_prompt "SLACK_CLIENT_SECRET" "SlackClientSecret" "secret")"
  fi
  gh secret set SLACK_SIGNING_SECRET --env "$env_name" --body "$SLACK_SIGNING_SECRET" -R "$repo"
  gh secret set SLACK_CLIENT_SECRET --env "$env_name" --body "$SLACK_CLIENT_SECRET" -R "$repo"
  gh secret set DATA_ENCRYPTION_KEY --env "$env_name" --body "$DATA_ENCRYPTION_KEY" -R "$repo"
  gh secret set DATABASE_PASSWORD --env "$env_name" --body "$DATABASE_PASSWORD" -R "$repo"
  if [[ "$db_mode" == "2" && -n "$db_admin_password" ]]; then
    gh secret set DATABASE_ADMIN_PASSWORD --env "$env_name" --body "$db_admin_password" -R "$repo"
  fi
  echo "Environment secrets updated for '$env_name'."
}

generate_stage_slack_manifest() {
  local stage="$1"
  local api_url="$2"
  local install_url="$3"
  local template="$REPO_ROOT/slack-manifest.json"
  local manifest_out="$REPO_ROOT/slack-manifest_${stage}.json"
  local events_url base_url oauth_redirect_url

  if [[ ! -f "$template" ]]; then
    echo "Slack manifest template not found at $template"
    return 0
  fi
  if [[ -z "$api_url" ]]; then
    echo "Could not determine API URL from stack outputs. Skipping Slack manifest generation."
    return 0
  fi

  events_url="${api_url%/}"
  base_url="${events_url%/slack/events}"
  oauth_redirect_url="${base_url}/slack/oauth_redirect"

  if ! python3 - "$template" "$manifest_out" "$events_url" "$oauth_redirect_url" <<'PY'
import json
import sys

template_path, out_path, events_url, redirect_url = sys.argv[1:5]
with open(template_path, "r", encoding="utf-8") as f:
    manifest = json.load(f)

manifest.setdefault("oauth_config", {}).setdefault("redirect_urls", [])
manifest["oauth_config"]["redirect_urls"] = [redirect_url]
manifest.setdefault("settings", {}).setdefault("event_subscriptions", {})
manifest["settings"]["event_subscriptions"]["request_url"] = events_url
manifest.setdefault("settings", {}).setdefault("interactivity", {})
manifest["settings"]["interactivity"]["request_url"] = events_url

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
PY
  then
    echo "Failed to generate stage Slack manifest from JSON template."
    return 0
  fi

  SLACK_MANIFEST_GENERATED_PATH="$manifest_out"

  echo "=== Slack Manifest (${stage}) ==="
  echo "Saved file: $manifest_out"
  echo "Install URL: $install_url"
  echo
  sed 's/^/  /' "$manifest_out"
}

rds_lookup_admin_defaults() {
  local db_host="$1"
  local region="$2"
  aws rds describe-db-instances \
    --region "$region" \
    --query "DBInstances[?Endpoint.Address=='$db_host']|[0].[MasterUsername]" \
    --output text 2>/dev/null || true
}

write_deploy_receipt() {
  local ts_human ts_file receipt_dir receipt_path
  local api_url="${SYNCBOT_API_URL:-}"
  local base_url="${api_url%/slack/events}"
  local oauth_redirect_url=""
  [[ -n "$base_url" ]] && oauth_redirect_url="${base_url}/slack/oauth_redirect"

  ts_human="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"
  ts_file="$(date -u +"%Y%m%dT%H%M%SZ")"
  receipt_dir="$REPO_ROOT/deploy-receipts"
  receipt_path="$receipt_dir/deploy-aws-${STAGE}-${ts_file}.md"

  mkdir -p "$receipt_dir"
  {
    cat <<EOF
# SyncBot Deploy Receipt

- Provider: aws
- Stage: $STAGE
- Timestamp: $ts_human
- Project/Stack: $STACK_NAME
- Region: $REGION

## Slack URLs
- Events/API URL: ${api_url:-n/a}
- Install URL: ${SYNCBOT_INSTALL_URL:-n/a}
- OAuth Redirect URL: ${oauth_redirect_url:-n/a}
- Slack Manifest: ${SLACK_MANIFEST_GENERATED_PATH:-n/a}

## Configuration
- STACK_NAME=$STACK_NAME
- DATABASE_ENGINE=${DATABASE_ENGINE:-}
- DATABASE_SCHEMA=${DATABASE_SCHEMA:-}
- DATABASE_HOST=${DATABASE_HOST:-}
- DATABASE_PORT=${DATABASE_PORT:-}
- DATABASE_USER=${DATABASE_USER:-}
- DATABASE_TLS_ENABLED=${DATABASE_TLS_ENABLED:-}
- DATABASE_NETWORK_MODE=${DATABASE_NETWORK_MODE:-}
- LOG_LEVEL=${LOG_LEVEL:-INFO}
- REQUIRE_ADMIN=${REQUIRE_ADMIN:-true}
- SOFT_DELETE_RETENTION_DAYS=${SOFT_DELETE_RETENTION_DAYS:-30}
- SYNCBOT_FEDERATION_ENABLED=${SYNCBOT_FEDERATION_ENABLED:-false}
- SYNCBOT_INSTANCE_ID=${SYNCBOT_INSTANCE_ID:-}
- SYNCBOT_PUBLIC_URL=${SYNCBOT_PUBLIC_URL:-}
- PRIMARY_WORKSPACE=${PRIMARY_WORKSPACE:-}
- SLACK_CLIENT_ID=${SLACK_CLIENT_ID:-}
- ENABLE_XRAY=${ENABLE_XRAY:-false}
- ENABLE_DB_RESET=${ENABLE_DB_RESET:-false}

## Secrets
- SLACK_SIGNING_SECRET=${SLACK_SIGNING_SECRET:-}
- SLACK_CLIENT_SECRET=${SLACK_CLIENT_SECRET:-}
- DATA_ENCRYPTION_KEY=${DATA_ENCRYPTION_KEY:-}
- DATABASE_PASSWORD=${DATABASE_PASSWORD:-}
- DATABASE_ADMIN_PASSWORD=${DATABASE_ADMIN_PASSWORD:-}
EOF

    if [[ "${VERBOSE:-}" == "true" ]]; then
      echo ""
      echo "## SAM Parameters"
      if [[ ${#PARAMS[@]} -gt 0 ]]; then
        local p
        for p in "${PARAMS[@]}"; do
          echo "- $p"
        done
      else
        echo "(PARAMS array not available)"
      fi
      echo ""
      echo "## Slack Manifest (inline)"
      if [[ -n "${SLACK_MANIFEST_GENERATED_PATH:-}" && -f "${SLACK_MANIFEST_GENERATED_PATH:-}" ]]; then
        echo '```json'
        cat "$SLACK_MANIFEST_GENERATED_PATH"
        echo '```'
      else
        echo "(no manifest file generated)"
      fi
    fi
  } >"$receipt_path"

  echo "Deploy receipt written: $receipt_path"
  if [[ "${VERBOSE:-}" == "true" ]]; then
    echo "--- receipt contents ---"
    cat "$receipt_path"
    echo "--- end receipt ---"
  fi
}

rds_lookup_network_defaults() {
  local db_host="$1"
  local region="$2"
  aws rds describe-db-instances \
    --region "$region" \
    --query "DBInstances[?Endpoint.Address=='$db_host']|[0].[PubliclyAccessible,join(',',DBSubnetGroup.Subnets[].SubnetIdentifier),join(',',VpcSecurityGroups[].VpcSecurityGroupId),DBSubnetGroup.VpcId,DBInstanceIdentifier]" \
    --output text 2>/dev/null || true
}

ec2_subnet_vpc_ids() {
  local region="$1"
  shift
  aws ec2 describe-subnets \
    --region "$region" \
    --subnet-ids "$@" \
    --query 'Subnets[*].[SubnetId,VpcId]' \
    --output text 2>/dev/null || true
}

ec2_vpc_subnet_ids() {
  local vpc_id="$1"
  local region="$2"
  aws ec2 describe-subnets \
    --region "$region" \
    --filters "Name=vpc-id,Values=$vpc_id" \
    --query 'Subnets[].SubnetId' \
    --output text 2>/dev/null || true
}

ec2_security_group_vpc() {
  local sg_id="$1"
  local region="$2"
  aws ec2 describe-security-groups \
    --region "$region" \
    --group-ids "$sg_id" \
    --query 'SecurityGroups[0].VpcId' \
    --output text 2>/dev/null || true
}

ec2_sg_allows_from_sg_on_port() {
  local db_sg_id="$1"
  local source_sg_id="$2"
  local port="$3"
  local region="$4"
  local allowed_groups
  allowed_groups="$(aws ec2 describe-security-groups \
    --region "$region" \
    --group-ids "$db_sg_id" \
    --query "SecurityGroups[0].IpPermissions[?FromPort<=\`$port\` && ToPort>=\`$port\`].UserIdGroupPairs[].GroupId" \
    --output text 2>/dev/null || true)"
  [[ " $allowed_groups " == *" $source_sg_id "* ]]
}

ec2_subnet_route_table_id() {
  local subnet_id="$1"
  local vpc_id="$2"
  local region="$3"
  local rt_id
  rt_id="$(aws ec2 describe-route-tables \
    --region "$region" \
    --filters "Name=association.subnet-id,Values=$subnet_id" \
    --query 'RouteTables[0].RouteTableId' \
    --output text 2>/dev/null || true)"
  if [[ -z "$rt_id" || "$rt_id" == "None" ]]; then
    rt_id="$(aws ec2 describe-route-tables \
      --region "$region" \
      --filters "Name=vpc-id,Values=$vpc_id" "Name=association.main,Values=true" \
      --query 'RouteTables[0].RouteTableId' \
      --output text 2>/dev/null || true)"
  fi
  echo "$rt_id"
}

ec2_subnet_default_route_target() {
  local subnet_id="$1"
  local vpc_id="$2"
  local region="$3"
  local rt_id targets target
  rt_id="$(ec2_subnet_route_table_id "$subnet_id" "$vpc_id" "$region")"
  if [[ -z "$rt_id" || "$rt_id" == "None" ]]; then
    echo "none"
    return 0
  fi

  # Read all active default-route targets and pick the first concrete one.
  targets="$(aws ec2 describe-route-tables \
    --region "$region" \
    --route-table-ids "$rt_id" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0' && State=='active'].[NatGatewayId,GatewayId,TransitGatewayId,NetworkInterfaceId,VpcPeeringConnectionId]" \
    --output text 2>/dev/null || true)"
  for target in $targets; do
    [[ "$target" == "None" ]] && continue
    echo "$target"
    return 0
  done

  echo "none"
}

discover_private_lambda_subnets_for_db_vpc() {
  local vpc_id="$1"
  local region="$2"
  local subnet_ids subnet_id route_target out
  subnet_ids="$(ec2_vpc_subnet_ids "$vpc_id" "$region")"
  if [[ -z "$subnet_ids" || "$subnet_ids" == "None" ]]; then
    echo ""
    return 0
  fi

  out=""
  for subnet_id in $subnet_ids; do
    [[ -z "$subnet_id" ]] && continue
    route_target="$(ec2_subnet_default_route_target "$subnet_id" "$vpc_id" "$region")"
    # Lambda private-subnet candidates: active default route through NAT.
    if [[ "$route_target" == nat-* ]]; then
      if [[ -z "$out" ]]; then
        out="$subnet_id"
      else
        out="$out,$subnet_id"
      fi
    fi
  done
  echo "$out"
}

validate_private_db_connectivity() {
  local region="$1"
  local engine="$2"
  local subnet_csv="$3"
  local lambda_sg="$4"
  local db_vpc="$5"
  local db_sgs_csv="$6"
  local db_host="$7"
  local db_port_override="${8:-}"
  local db_port subnet_list subnet_vpcs first_vpc line subnet_id subnet_vpc db_sg_id lambda_sg_vpc db_sg_list route_target rt_id ingress_ok
  local -a no_nat_subnets

  db_port="3306"
  [[ "$engine" == "postgresql" ]] && db_port="5432"
  [[ -n "$db_port_override" ]] && db_port="$db_port_override"

  IFS=',' read -r -a subnet_list <<< "$subnet_csv"
  if [[ "${#subnet_list[@]}" -lt 1 ]]; then
    echo "Connectivity preflight failed: no subnet IDs provided for private mode." >&2
    return 1
  fi

  subnet_vpcs="$(ec2_subnet_vpc_ids "$region" "${subnet_list[@]}")"
  if [[ -z "$subnet_vpcs" || "$subnet_vpcs" == "None" ]]; then
    echo "Connectivity preflight failed: could not read VPC IDs for provided subnets." >&2
    return 1
  fi

  first_vpc=""
  while IFS=$'\t' read -r subnet_id subnet_vpc; do
    [[ -z "$subnet_id" || -z "$subnet_vpc" ]] && continue
    if [[ -z "$first_vpc" ]]; then
      first_vpc="$subnet_vpc"
    elif [[ "$subnet_vpc" != "$first_vpc" ]]; then
      echo "Connectivity preflight failed: subnets span multiple VPCs." >&2
      return 1
    fi
  done <<< "$subnet_vpcs"

  if [[ -z "$first_vpc" ]]; then
    echo "Connectivity preflight failed: unable to determine subnet VPC." >&2
    return 1
  fi

  if [[ -n "$db_vpc" && "$db_vpc" != "$first_vpc" ]]; then
    echo "Connectivity preflight failed: Lambda subnets are in $first_vpc but DB is in $db_vpc." >&2
    return 1
  fi

  lambda_sg_vpc="$(ec2_security_group_vpc "$lambda_sg" "$region")"
  if [[ -z "$lambda_sg_vpc" || "$lambda_sg_vpc" == "None" ]]; then
    echo "Connectivity preflight failed: Lambda security group '$lambda_sg' was not found." >&2
    return 1
  fi
  if [[ "$lambda_sg_vpc" != "$first_vpc" ]]; then
    echo "Connectivity preflight failed: Lambda security group is in $lambda_sg_vpc, expected $first_vpc." >&2
    return 1
  fi

  if [[ -n "$db_sgs_csv" ]]; then
    ingress_ok="false"
    IFS=',' read -r -a db_sg_list <<< "$db_sgs_csv"
    for db_sg_id in "${db_sg_list[@]}"; do
      db_sg_id="${db_sg_id// /}"
      [[ -z "$db_sg_id" ]] && continue
      if ec2_sg_allows_from_sg_on_port "$db_sg_id" "$lambda_sg" "$db_port" "$region"; then
        echo "Connectivity preflight passed: DB SG $db_sg_id allows Lambda SG $lambda_sg on port $db_port."
        ingress_ok="true"
        break
      fi
    done
    if [[ "$ingress_ok" != "true" ]]; then
      echo "Connectivity preflight failed: none of the DB security groups allow Lambda SG $lambda_sg on port $db_port." >&2
      echo "Fix: add an inbound SG rule on the DB security group from '$lambda_sg' to TCP $db_port." >&2
      return 1
    fi
  fi

  if [[ -z "$db_sgs_csv" ]]; then
    echo "Connectivity preflight warning: DB SGs could not be auto-detected for host $db_host." >&2
    echo "Cannot verify ingress rule automatically; continuing with subnet/VPC checks only." >&2
  fi

  no_nat_subnets=()
  for subnet_id in "${subnet_list[@]}"; do
    subnet_id="${subnet_id// /}"
    [[ -z "$subnet_id" ]] && continue
    route_target="$(ec2_subnet_default_route_target "$subnet_id" "$first_vpc" "$region")"
    if [[ "$route_target" != nat-* ]]; then
      no_nat_subnets+=("$subnet_id:$route_target")
    fi
  done

  if [[ "${#no_nat_subnets[@]}" -gt 0 ]]; then
    echo "Connectivity preflight failed: one or more selected private subnets do not have an active NAT default route." >&2
    for entry in "${no_nat_subnets[@]}"; do
      subnet_id="${entry%%:*}"
      route_target="${entry#*:}"
      rt_id="$(ec2_subnet_route_table_id "$subnet_id" "$first_vpc" "$region")"
      echo "  - Subnet $subnet_id (route table $rt_id) default route target: $route_target" >&2
    done
    echo "Fix before deploy:" >&2
    echo "  1) Use private subnets whose route table has 0.0.0.0/0 -> nat-xxxx" >&2
    echo "  2) Or update those route tables to point 0.0.0.0/0 to a NAT gateway" >&2
    echo "  3) Ensure DB SG allows Lambda SG '$lambda_sg' on TCP $db_port" >&2
    return 1
  fi

  echo "Connectivity preflight passed: private subnets have NAT egress."
  return 0
}

stack_status() {
  local stack_name="$1"
  local region="$2"
  aws cloudformation describe-stacks \
    --stack-name "$stack_name" \
    --region "$region" \
    --query 'Stacks[0].StackStatus' \
    --output text 2>/dev/null || true
}

stack_parameters() {
  local stack_name="$1"
  local region="$2"
  aws cloudformation describe-stacks \
    --stack-name "$stack_name" \
    --region "$region" \
    --query 'Stacks[0].Parameters[*].[ParameterKey,ParameterValue]' \
    --output text 2>/dev/null || true
}

stack_param_value() {
  local params="$1"
  local key="$2"
  echo "$params" | awk -F'\t' -v k="$key" '$1==k {print $2}'
}

# Keep bootstrap stack aligned with the checked-in template so IAM/policy fixes
# (for example CloudFormation changeset permissions) apply before app deploy.
# Set SYNCBOT_SKIP_BOOTSTRAP_SYNC=1 to opt out.
sync_bootstrap_stack_from_repo() {
  local bootstrap_stack="$1"
  local aws_region="$2"
  local params github_repo create_oidc bucket_prefix

  if [[ "${SYNCBOT_SKIP_BOOTSTRAP_SYNC:-}" == "1" ]]; then
    echo "Skipping bootstrap template sync (SYNCBOT_SKIP_BOOTSTRAP_SYNC=1)."
    return 0
  fi

  params="$(stack_parameters "$bootstrap_stack" "$aws_region")"
  if [[ -z "$params" ]]; then
    echo "Could not read bootstrap stack parameters for '$bootstrap_stack' in $aws_region; skipping bootstrap template sync." >&2
    return 0
  fi

  github_repo="$(stack_param_value "$params" "GitHubRepository")"
  github_repo="${github_repo//$'\r'/}"
  github_repo="${github_repo#"${github_repo%%[![:space:]]*}"}"
  github_repo="${github_repo%"${github_repo##*[![:space:]]}"}"
  if [[ -z "$github_repo" ]]; then
    echo "Bootstrap stack has no GitHubRepository parameter; skipping bootstrap template sync." >&2
    return 0
  fi

  create_oidc="$(stack_param_value "$params" "CreateOIDCProvider")"
  bucket_prefix="$(stack_param_value "$params" "DeploymentBucketPrefix")"
  [[ -z "$create_oidc" ]] && create_oidc="true"
  [[ -z "$bucket_prefix" ]] && bucket_prefix="syncbot-deploy"

  echo
  echo "Syncing bootstrap stack with repo template..."
  aws cloudformation deploy \
    --template-file "$BOOTSTRAP_TEMPLATE" \
    --stack-name "$bootstrap_stack" \
    --parameter-overrides \
      "GitHubRepository=$github_repo" \
      "CreateOIDCProvider=$create_oidc" \
      "DeploymentBucketPrefix=$bucket_prefix" \
    --capabilities CAPABILITY_NAMED_IAM \
    --no-fail-on-empty-changeset \
    --region "$aws_region"
}

# Compare GitHub owner/repo from bootstrap stack to the repo chosen for gh; offer to update OIDC trust.
maybe_prompt_bootstrap_github_trust_update() {
  local picked_repo="$1"
  local bootstrap_stack="$2"
  local aws_region="$3"
  local params trusted picked_lc trusted_lc create_oidc bucket_prefix

  if [[ -z "$bootstrap_stack" || -z "$picked_repo" ]]; then
    return 0
  fi

  params="$(stack_parameters "$bootstrap_stack" "$aws_region")"
  if [[ -z "$params" ]]; then
    echo "Could not read bootstrap stack parameters for '$bootstrap_stack' in $aws_region; skipping OIDC trust drift check." >&2
    return 0
  fi

  trusted="$(stack_param_value "$params" "GitHubRepository")"
  # CloudFormation / CLI sometimes surface trailing whitespace; normalize for compare + display.
  trusted="${trusted//$'\r'/}"
  trusted="${trusted#"${trusted%%[![:space:]]*}"}"
  trusted="${trusted%"${trusted##*[![:space:]]}"}"
  if [[ -z "$trusted" ]]; then
    echo "Bootstrap stack has no GitHubRepository parameter; skipping OIDC trust drift check." >&2
    return 0
  fi

  picked_lc="$(printf '%s' "$picked_repo" | tr '[:upper:]' '[:lower:]')"
  trusted_lc="$(printf '%s' "$trusted" | tr '[:upper:]' '[:lower:]')"
  if [[ "$picked_lc" == "$trusted_lc" ]]; then
    echo "Bootstrap OIDC: stack '$bootstrap_stack' has GitHubRepository=$trusted — matches your choice; no bootstrap update needed."
    return 0
  fi

  echo
  echo "Warning: Bootstrap stack '$bootstrap_stack' OIDC trust is scoped to:"
  echo "  GitHubRepository=$trusted"
  echo "You chose this repository for GitHub Actions variables:"
  echo "  $picked_repo"
  echo "GitHub Actions in '$picked_repo' cannot assume the deploy role until trust matches."
  echo
  if ! prompt_yes_no "Update bootstrap OIDC trust to '$picked_repo'? (CloudFormation stack update)" "n"; then
    echo "Leaving bootstrap GitHubRepository unchanged. Fix manually or update the bootstrap stack later." >&2
    return 0
  fi

  create_oidc="$(stack_param_value "$params" "CreateOIDCProvider")"
  bucket_prefix="$(stack_param_value "$params" "DeploymentBucketPrefix")"
  [[ -z "$create_oidc" ]] && create_oidc="true"
  [[ -z "$bucket_prefix" ]] && bucket_prefix="syncbot-deploy"

  echo "Updating bootstrap stack '$bootstrap_stack'..."
  aws cloudformation deploy \
    --template-file "$BOOTSTRAP_TEMPLATE" \
    --stack-name "$bootstrap_stack" \
    --parameter-overrides \
      "GitHubRepository=$picked_repo" \
      "CreateOIDCProvider=$create_oidc" \
      "DeploymentBucketPrefix=$bucket_prefix" \
    --capabilities CAPABILITY_NAMED_IAM \
    --region "$aws_region"
  echo "Bootstrap OIDC trust updated to $picked_repo."
}

print_recent_stack_failures() {
  local stack_name="$1"
  local region="$2"
  echo "Recent failure events for $stack_name:"
  aws cloudformation describe-stack-events \
    --stack-name "$stack_name" \
    --region "$region" \
    --query "StackEvents[?contains(ResourceStatus, 'FAILED')].[Timestamp,LogicalResourceId,ResourceStatus,ResourceStatusReason]" \
    --output table 2>/dev/null || true
}

handle_unhealthy_stack_state() {
  local stack_name="$1"
  local region="$2"
  local status
  status="$(stack_status "$stack_name" "$region")"
  if [[ -z "$status" || "$status" == "None" ]]; then
    return 0
  fi

  case "$status" in
    CREATE_FAILED|ROLLBACK_COMPLETE|ROLLBACK_FAILED|UPDATE_ROLLBACK_FAILED|DELETE_FAILED)
      echo
      echo "Stack $stack_name is in a failed state: $status"
      print_recent_stack_failures "$stack_name" "$region"
      echo
      if prompt_yes_no "Delete failed stack '$stack_name' now so deploy can continue?" "y"; then
        aws cloudformation delete-stack --stack-name "$stack_name" --region "$region"
        echo "Waiting for stack deletion to complete..."
        aws cloudformation wait stack-delete-complete --stack-name "$stack_name" --region "$region"
      else
        echo "Cannot continue deploy while stack is in $status."
        exit 1
      fi
      ;;
    *_IN_PROGRESS)
      echo "Error: stack $stack_name is currently $status. Wait for it to finish, then rerun." >&2
      exit 1
      ;;
    *)
      ;;
  esac
}

echo "=== Prerequisites ==="
prereqs_require_cmd aws prereqs_hint_aws_cli
prereqs_require_cmd sam prereqs_hint_sam_cli
prereqs_require_cmd docker prereqs_hint_docker
prereqs_require_cmd python3 prereqs_hint_python3
prereqs_require_cmd curl prereqs_hint_curl

prereqs_print_cli_status_matrix "AWS" aws sam docker python3 curl

if [[ ! -f "$APP_TEMPLATE" ]]; then
  echo "Error: app template not found at $APP_TEMPLATE" >&2
  exit 1
fi
if [[ ! -f "$BOOTSTRAP_TEMPLATE" ]]; then
  echo "Error: bootstrap template not found at $BOOTSTRAP_TEMPLATE" >&2
  exit 1
fi

# ====================================================================
# Non-interactive fast path (./deploy.sh --env test|prod aws)
# ====================================================================
if [[ "${ENV_FILE_LOADED:-}" == "true" ]]; then
  echo "=== SyncBot AWS Deploy (non-interactive) ==="
  REGION="${AWS_REGION:-us-east-2}"
  ensure_aws_authenticated
  BOOTSTRAP_STACK="${BOOTSTRAP_STACK_NAME:-syncbot-bootstrap}"

  if [[ "${BOOTSTRAP:-}" == "true" ]]; then
    echo "=== Bootstrap ==="
    BOOTSTRAP_OUTPUTS="$(bootstrap_describe_outputs "$BOOTSTRAP_STACK" "$REGION")"
    if [[ -z "$BOOTSTRAP_OUTPUTS" ]]; then
      GITHUB_REPO="${GITHUB_REPOSITORY:-$(cd "$REPO_ROOT" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "REPLACE_ME")}"
      echo "Creating bootstrap stack: $BOOTSTRAP_STACK"
      aws cloudformation deploy \
        --template-file "$BOOTSTRAP_TEMPLATE" \
        --stack-name "$BOOTSTRAP_STACK" \
        --parameter-overrides \
          "GitHubRepository=$GITHUB_REPO" \
          "CreateOIDCProvider=${CREATE_OIDC_PROVIDER:-true}" \
          "DeploymentBucketPrefix=${DEPLOY_BUCKET_PREFIX:-syncbot-deploy}" \
        --capabilities CAPABILITY_NAMED_IAM \
        --region "$REGION" \
        --no-fail-on-empty-changeset
    else
      sync_bootstrap_stack_from_repo "$BOOTSTRAP_STACK" "$REGION"
    fi
  fi

  BOOTSTRAP_OUTPUTS="$(bootstrap_describe_outputs "$BOOTSTRAP_STACK" "$REGION")"
  S3_BUCKET="${DEPLOYMENT_S3_BUCKET:-$(output_value "$BOOTSTRAP_OUTPUTS" "DeploymentBucketName")}"
  if [[ -z "$S3_BUCKET" ]]; then
    echo "Error: could not determine S3 deploy bucket. Set DEPLOYMENT_S3_BUCKET in env file or deploy bootstrap first." >&2
    exit 1
  fi
  STACK_NAME="${STACK_NAME:?STACK_NAME required in env file}"
  STAGE="${STAGE:?STAGE required}"

  handle_unhealthy_stack_state "$STACK_NAME" "$REGION"

  # Backward-compatible aliases: new name primary, EXISTING_ as fallback
  DATABASE_HOST="${DATABASE_HOST:-${EXISTING_DATABASE_HOST:-}}"
  DATABASE_PORT="${DATABASE_PORT:-${EXISTING_DATABASE_PORT:-}}"
  DATABASE_ADMIN_USER="${DATABASE_ADMIN_USER:-${EXISTING_DATABASE_ADMIN_USER:-}}"
  DATABASE_ADMIN_PASSWORD="${DATABASE_ADMIN_PASSWORD:-${EXISTING_DATABASE_ADMIN_PASSWORD:-}}"
  DATABASE_NETWORK_MODE="${DATABASE_NETWORK_MODE:-${EXISTING_DATABASE_NETWORK_MODE:-public}}"
  DATABASE_SUBNET_IDS_CSV="${DATABASE_SUBNET_IDS_CSV:-${EXISTING_DATABASE_SUBNET_IDS_CSV:-}}"
  DATABASE_LAMBDA_SECURITY_GROUP_ID="${DATABASE_LAMBDA_SECURITY_GROUP_ID:-${EXISTING_DATABASE_LAMBDA_SECURITY_GROUP_ID:-}}"
  DATABASE_CREATE_APP_USER="${DATABASE_CREATE_APP_USER:-${EXISTING_DATABASE_CREATE_APP_USER:-true}}"
  DATABASE_CREATE_SCHEMA="${DATABASE_CREATE_SCHEMA:-${EXISTING_DATABASE_CREATE_SCHEMA:-true}}"
  DATABASE_USERNAME_PREFIX="${DATABASE_USERNAME_PREFIX:-${EXISTING_DATABASE_USERNAME_PREFIX:-}}"
  DATABASE_APP_USERNAME="${DATABASE_APP_USERNAME:-${EXISTING_DATABASE_APP_USERNAME:-}}"
  DATABASE_ENGINE="${DATABASE_ENGINE:-mysql}"
  DATABASE_SCHEMA="${DATABASE_SCHEMA:-syncbot}"
  DATA_ENCRYPTION_KEY="${DATA_ENCRYPTION_KEY:-${TOKEN_ENCRYPTION_KEY:-}}"

  # Auto-generate DATA_ENCRYPTION_KEY if empty
  if [[ -z "${DATA_ENCRYPTION_KEY:-}" ]]; then
    DATA_ENCRYPTION_KEY="$(python3 -c 'import secrets; print(secrets.token_urlsafe(36))')"
    echo "Generated DATA_ENCRYPTION_KEY=$DATA_ENCRYPTION_KEY"
    echo "IMPORTANT: Store this key securely. You need it for disaster recovery."
    if [[ -n "${ENV_FILE_PATH:-}" ]]; then
      update_env_file "$ENV_FILE_PATH" "DATA_ENCRYPTION_KEY" "$DATA_ENCRYPTION_KEY"
      echo "  (saved to $ENV_FILE_PATH)"
    fi
  fi

  # Auto-generate DATABASE_PASSWORD + derive DATABASE_USER when DbSetup will run
  if [[ -n "${DATABASE_ADMIN_USER:-}" && -z "${DATABASE_PASSWORD:-}" ]]; then
    DATABASE_PASSWORD="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"
    echo "Generated DATABASE_PASSWORD=$DATABASE_PASSWORD"
    if [[ -n "${ENV_FILE_PATH:-}" ]]; then
      update_env_file "$ENV_FILE_PATH" "DATABASE_PASSWORD" "$DATABASE_PASSWORD"
      echo "  (saved to $ENV_FILE_PATH)"
    fi
  fi
  if [[ -n "${DATABASE_ADMIN_USER:-}" && -z "${DATABASE_USER:-}" ]]; then
    DATABASE_USER="${DATABASE_USERNAME_PREFIX:+${DATABASE_USERNAME_PREFIX}.}sbapp_${STAGE}"
    DATABASE_USER="${DATABASE_USER//-/_}"
    echo "Derived DATABASE_USER=$DATABASE_USER"
    if [[ -n "${ENV_FILE_PATH:-}" ]]; then
      update_env_file "$ENV_FILE_PATH" "DATABASE_USER" "$DATABASE_USER"
      echo "  (saved to $ENV_FILE_PATH)"
    fi
  fi

  DATABASE_PASSWORD="${DATABASE_PASSWORD:?DATABASE_PASSWORD required in env file}"
  DATABASE_USER="${DATABASE_USER:-}"

  PARAMS=(
    "Stage=$STAGE"
    "DatabaseEngine=$DATABASE_ENGINE"
    "SlackSigningSecret=${SLACK_SIGNING_SECRET:?SLACK_SIGNING_SECRET required}"
    "SlackClientSecret=${SLACK_CLIENT_SECRET:?SLACK_CLIENT_SECRET required}"
    "SlackClientID=${SLACK_CLIENT_ID:?SLACK_CLIENT_ID required}"
    "DatabaseSchema=$DATABASE_SCHEMA"
    "DataEncryptionKey=$DATA_ENCRYPTION_KEY"
    "DatabasePassword=$DATABASE_PASSWORD"
    "DatabaseUser=${DATABASE_USER:-}"
    "LogLevel=${LOG_LEVEL:-INFO}"
    "RequireAdmin=${REQUIRE_ADMIN:-true}"
    "SoftDeleteRetentionDays=${SOFT_DELETE_RETENTION_DAYS:-30}"
    "SyncbotFederationEnabled=${SYNCBOT_FEDERATION_ENABLED:-false}"
    "SyncbotInstanceId=${SYNCBOT_INSTANCE_ID:-}"
    "SyncbotPublicUrl=${SYNCBOT_PUBLIC_URL:-}"
    "PrimaryWorkspace=${PRIMARY_WORKSPACE:-}"
    "EnableDbReset=${ENABLE_DB_RESET:-}"
    "DatabaseTlsEnabled=${DATABASE_TLS_ENABLED:-}"
    "DatabaseSslCaPath=${DATABASE_SSL_CA_PATH:-}"
    "EnableXRay=${ENABLE_XRAY:-false}"
    "ExistingDatabaseHost=${DATABASE_HOST:-}"
    "ExistingDatabaseAdminUser=${DATABASE_ADMIN_USER:-}"
    "ExistingDatabaseAdminPassword=${DATABASE_ADMIN_PASSWORD:-}"
    "ExistingDatabaseNetworkMode=${DATABASE_NETWORK_MODE:-public}"
    "ExistingDatabaseSubnetIdsCsv=${DATABASE_SUBNET_IDS_CSV:-}"
    "ExistingDatabaseLambdaSecurityGroupId=${DATABASE_LAMBDA_SECURITY_GROUP_ID:-}"
    "ExistingDatabasePort=${DATABASE_PORT:-}"
    "ExistingDatabaseCreateAppUser=${DATABASE_CREATE_APP_USER:-true}"
    "ExistingDatabaseCreateSchema=${DATABASE_CREATE_SCHEMA:-true}"
    "ExistingDatabaseUsernamePrefix=${DATABASE_USERNAME_PREFIX:-}"
    "ExistingDatabaseAppUsername=${DATABASE_APP_USERNAME:-}"
    "DatabaseAdminPassword=${DATABASE_ADMIN_PASSWORD:-}"
    "SlackOauthBotScopes=${SLACK_BOT_SCOPES:-app_mentions:read,channels:history,channels:join,channels:read,channels:manage,chat:write,chat:write.customize,files:read,files:write,groups:history,groups:read,groups:write,im:write,reactions:read,reactions:write,team:read,users:read,users:read.email}"
    "SlackOauthUserScopes=${SLACK_USER_SCOPES:-chat:write,channels:history,channels:read,files:read,files:write,groups:history,groups:read,groups:write,im:write,reactions:read,reactions:write,team:read,users:read,users:read.email}"
    "DatabaseInstanceClass=${DATABASE_INSTANCE_CLASS:-db.t4g.micro}"
    "DatabaseBackupRetentionDays=${DATABASE_BACKUP_RETENTION_DAYS:-0}"
    "AllowedDBCidr=${ALLOWED_DB_CIDR:-0.0.0.0/0}"
    "VpcCidr=${VPC_CIDR:-10.0.0.0/16}"
  )

  echo "=== SAM Build ==="
  sam build -t "$APP_TEMPLATE" --use-container

  echo "=== SAM Deploy ==="
  sam_deploy_or_fallback

  APP_OUTPUTS="$(app_describe_outputs "$STACK_NAME" "$REGION")"
  FUNCTION_ARN="$(output_value "$APP_OUTPUTS" "SyncBotFunctionArn")"
  if [[ -n "$FUNCTION_ARN" ]]; then
    echo "=== Lambda migrate + warm-up ==="
    TMP_MIGRATE="$(mktemp)"
    aws lambda invoke \
      --function-name "$FUNCTION_ARN" \
      --payload '{"action":"migrate"}' \
      --cli-binary-format raw-in-base64-out \
      "$TMP_MIGRATE" \
      --region "$REGION"
    cat "$TMP_MIGRATE"
    echo
    rm -f "$TMP_MIGRATE"
  fi

  SYNCBOT_API_URL="$(output_value "$APP_OUTPUTS" "SyncBotApiUrl")"
  SYNCBOT_INSTALL_URL="$(output_value "$APP_OUTPUTS" "SyncBotInstallUrl")"
  generate_stage_slack_manifest "$STAGE" "$SYNCBOT_API_URL" "$SYNCBOT_INSTALL_URL"

  if [[ "${SETUP_GITHUB:-}" == "true" ]]; then
    echo
    echo "=== Push to GitHub Environment ==="
    prereqs_require_cmd gh prereqs_hint_gh_cli
    if ! gh auth status >/dev/null 2>&1; then
      echo "Error: gh CLI not authenticated. Run 'gh auth login' first." >&2
      exit 1
    fi
    REPO="$(prompt_github_repo_for_actions "$REPO_ROOT")"
    ENV_NAME="$STAGE"
    ROLE_ARN="${AWS_ROLE_ARN:-$(output_value "$BOOTSTRAP_OUTPUTS" "GitHubDeployRoleArn")}"

    gh api -X PUT "repos/$REPO/environments/$ENV_NAME" >/dev/null
    [[ -n "$ROLE_ARN" ]] && gh variable set AWS_ROLE_TO_ASSUME --body "$ROLE_ARN" -R "$REPO"
    [[ -n "$S3_BUCKET" ]] && gh variable set AWS_S3_BUCKET --body "$S3_BUCKET" -R "$REPO"
    gh variable set AWS_REGION --body "$REGION" -R "$REPO"
    gh_variable_set_env AWS_STACK_NAME "$ENV_NAME" "$REPO" "$STACK_NAME"
    gh_variable_set_env STAGE_NAME "$ENV_NAME" "$REPO" "$STAGE"
    gh_variable_set_env DATABASE_SCHEMA "$ENV_NAME" "$REPO" "$DATABASE_SCHEMA"
    gh_variable_set_env DATABASE_ENGINE "$ENV_NAME" "$REPO" "$DATABASE_ENGINE"
    gh_variable_set_env SLACK_CLIENT_ID "$ENV_NAME" "$REPO" "$SLACK_CLIENT_ID"
    if [[ -n "$DATABASE_HOST" ]]; then
      gh_variable_set_env DATABASE_HOST "$ENV_NAME" "$REPO" "$DATABASE_HOST"
      gh_variable_set_env DATABASE_ADMIN_USER "$ENV_NAME" "$REPO" "${DATABASE_ADMIN_USER:-}"
      gh_variable_set_env DATABASE_NETWORK_MODE "$ENV_NAME" "$REPO" "${DATABASE_NETWORK_MODE:-public}"
      if [[ "${DATABASE_NETWORK_MODE:-public}" == "private" ]]; then
        gh_variable_set_env DATABASE_SUBNET_IDS_CSV "$ENV_NAME" "$REPO" "${DATABASE_SUBNET_IDS_CSV:-}"
        gh_variable_set_env DATABASE_LAMBDA_SECURITY_GROUP_ID "$ENV_NAME" "$REPO" "${DATABASE_LAMBDA_SG_ID:-${DATABASE_LAMBDA_SECURITY_GROUP_ID:-}}"
      else
        gh_variable_set_env DATABASE_SUBNET_IDS_CSV "$ENV_NAME" "$REPO" ""
        gh_variable_set_env DATABASE_LAMBDA_SECURITY_GROUP_ID "$ENV_NAME" "$REPO" ""
      fi
      gh_variable_set_env DATABASE_PORT "$ENV_NAME" "$REPO" "${DATABASE_PORT:-}"
      gh_variable_set_env DATABASE_CREATE_APP_USER "$ENV_NAME" "$REPO" "${DATABASE_CREATE_APP_USER:-true}"
      gh_variable_set_env DATABASE_CREATE_SCHEMA "$ENV_NAME" "$REPO" "${DATABASE_CREATE_SCHEMA:-true}"
      gh_variable_set_env DATABASE_USERNAME_PREFIX "$ENV_NAME" "$REPO" "${DATABASE_USERNAME_PREFIX:-}"
      gh_variable_set_env DATABASE_APP_USERNAME "$ENV_NAME" "$REPO" "${DATABASE_APP_USERNAME:-}"
      gh_variable_set_env DATABASE_USER "$ENV_NAME" "$REPO" "${DATABASE_USER:-}"
    else
      gh_variable_set_env DATABASE_HOST "$ENV_NAME" "$REPO" ""
      gh_variable_set_env DATABASE_ADMIN_USER "$ENV_NAME" "$REPO" ""
      gh_variable_set_env DATABASE_NETWORK_MODE "$ENV_NAME" "$REPO" "public"
      gh_variable_set_env DATABASE_SUBNET_IDS_CSV "$ENV_NAME" "$REPO" ""
      gh_variable_set_env DATABASE_LAMBDA_SECURITY_GROUP_ID "$ENV_NAME" "$REPO" ""
      gh_variable_set_env DATABASE_PORT "$ENV_NAME" "$REPO" ""
      gh_variable_set_env DATABASE_CREATE_APP_USER "$ENV_NAME" "$REPO" "true"
      gh_variable_set_env DATABASE_CREATE_SCHEMA "$ENV_NAME" "$REPO" "true"
      gh_variable_set_env DATABASE_USERNAME_PREFIX "$ENV_NAME" "$REPO" ""
      gh_variable_set_env DATABASE_APP_USERNAME "$ENV_NAME" "$REPO" ""
      gh_variable_set_env DATABASE_USER "$ENV_NAME" "$REPO" ""
    fi
    echo "Setting GitHub environment secrets for '$ENV_NAME'..."
    gh secret set SLACK_SIGNING_SECRET --env "$ENV_NAME" --body "$SLACK_SIGNING_SECRET" -R "$REPO"
    gh secret set SLACK_CLIENT_SECRET --env "$ENV_NAME" --body "$SLACK_CLIENT_SECRET" -R "$REPO"
    gh secret set DATA_ENCRYPTION_KEY --env "$ENV_NAME" --body "$DATA_ENCRYPTION_KEY" -R "$REPO"
    gh secret set DATABASE_PASSWORD --env "$ENV_NAME" --body "$DATABASE_PASSWORD" -R "$REPO"
    [[ -n "${DATABASE_ADMIN_PASSWORD:-}" ]] && gh secret set DATABASE_ADMIN_PASSWORD --env "$ENV_NAME" --body "$DATABASE_ADMIN_PASSWORD" -R "$REPO"
    echo "GitHub environment '$ENV_NAME' updated for repo $REPO."
  fi

  echo
  echo "=== Deploy Receipt ==="
  write_deploy_receipt

  echo
  echo "=== Deploy Complete ==="
  echo "Stack:       $STACK_NAME"
  echo "Region:      $REGION"
  echo "API URL:     ${SYNCBOT_API_URL:-n/a}"
  echo "Install URL: ${SYNCBOT_INSTALL_URL:-n/a}"
  if [[ -n "${SYNCBOT_API_URL:-}" ]]; then
    echo "OAuth URL:   ${SYNCBOT_API_URL%/slack/events}/slack/oauth_redirect"
  fi
  exit 0
fi

# ====================================================================
# Interactive deploy path
# ====================================================================
echo "=== SyncBot AWS Deploy ==="
echo

# Backward-compatible aliases: new name primary, EXISTING_ as fallback (same as non-interactive path)
DATABASE_HOST="${DATABASE_HOST:-${EXISTING_DATABASE_HOST:-}}"
DATABASE_PORT="${DATABASE_PORT:-${EXISTING_DATABASE_PORT:-}}"
DATABASE_ADMIN_USER="${DATABASE_ADMIN_USER:-${EXISTING_DATABASE_ADMIN_USER:-}}"
DATABASE_ADMIN_PASSWORD="${DATABASE_ADMIN_PASSWORD:-${EXISTING_DATABASE_ADMIN_PASSWORD:-}}"
DATABASE_NETWORK_MODE="${DATABASE_NETWORK_MODE:-${EXISTING_DATABASE_NETWORK_MODE:-public}}"
DATABASE_SUBNET_IDS_CSV="${DATABASE_SUBNET_IDS_CSV:-${EXISTING_DATABASE_SUBNET_IDS_CSV:-}}"
DATABASE_LAMBDA_SECURITY_GROUP_ID="${DATABASE_LAMBDA_SECURITY_GROUP_ID:-${EXISTING_DATABASE_LAMBDA_SECURITY_GROUP_ID:-}}"
DATABASE_CREATE_APP_USER="${DATABASE_CREATE_APP_USER:-${EXISTING_DATABASE_CREATE_APP_USER:-true}}"
DATABASE_CREATE_SCHEMA="${DATABASE_CREATE_SCHEMA:-${EXISTING_DATABASE_CREATE_SCHEMA:-true}}"
DATABASE_USERNAME_PREFIX="${DATABASE_USERNAME_PREFIX:-${EXISTING_DATABASE_USERNAME_PREFIX:-}}"
DATABASE_APP_USERNAME="${DATABASE_APP_USERNAME:-${EXISTING_DATABASE_APP_USERNAME:-}}"
DATA_ENCRYPTION_KEY="${DATA_ENCRYPTION_KEY:-${TOKEN_ENCRYPTION_KEY:-}}"

DEFAULT_REGION="${AWS_REGION:-us-east-2}"
REGION="$(prompt_default "AWS region" "$DEFAULT_REGION")"
echo
echo "=== Authentication ==="
ensure_aws_authenticated
BOOTSTRAP_STACK="$(prompt_default "Bootstrap stack name" "syncbot-bootstrap")"

# Probe bootstrap outputs only; create/sync runs later if task 1 (Bootstrap) is selected.
BOOTSTRAP_OUTPUTS="$(bootstrap_describe_outputs "$BOOTSTRAP_STACK" "$REGION")"

SUGGESTED_TEST_STACK="$(output_value "$BOOTSTRAP_OUTPUTS" "SuggestedTestStackName")"
SUGGESTED_PROD_STACK="$(output_value "$BOOTSTRAP_OUTPUTS" "SuggestedProdStackName")"
[[ -z "$SUGGESTED_TEST_STACK" ]] && SUGGESTED_TEST_STACK="syncbot-test"
[[ -z "$SUGGESTED_PROD_STACK" ]] && SUGGESTED_PROD_STACK="syncbot-prod"

echo
echo "=== Stack Identity ==="
STAGE="$(prompt_default "Deploy stage (test/prod)" "test")"
if [[ "$STAGE" != "test" && "$STAGE" != "prod" ]]; then
  echo "Error: stage must be 'test' or 'prod'." >&2
  exit 1
fi

DEFAULT_STACK="$SUGGESTED_TEST_STACK"
[[ "$STAGE" == "prod" ]] && DEFAULT_STACK="$SUGGESTED_PROD_STACK"
STACK_NAME="$(prompt_default "App stack name" "$DEFAULT_STACK")"
EXISTING_STACK_STATUS="$(stack_status "$STACK_NAME" "$REGION")"
IS_STACK_UPDATE="false"
EXISTING_STACK_PARAMS=""
PREV_DATABASE_HOST=""
PREV_DATABASE_ADMIN_USER=""
PREV_DATABASE_NETWORK_MODE=""
PREV_DATABASE_SUBNET_IDS_CSV=""
PREV_DATABASE_LAMBDA_SG_ID=""
PREV_DATABASE_PORT=""
PREV_DATABASE_CREATE_APP_USER=""
PREV_DATABASE_CREATE_SCHEMA=""
PREV_DATABASE_USERNAME_PREFIX=""
PREV_DATABASE_APP_USERNAME=""
PREV_DATABASE_ENGINE=""
PREV_DATABASE_SCHEMA=""
PREV_LOG_LEVEL=""
PREV_REQUIRE_ADMIN=""
PREV_SOFT_DELETE=""
PREV_FEDERATION=""
PREV_INSTANCE_ID=""
PREV_PUBLIC_URL=""
PREV_PRIMARY_WORKSPACE=""
PREV_ENABLE_DB_RESET=""
PREV_DB_TLS=""
PREV_DB_SSL_CA=""
PREV_DATABASE_HOST_IN_USE=""
PREV_STACK_USES_EXTERNAL_DB="false"
EXISTING_STACK_OUTPUTS=""
if [[ -n "$EXISTING_STACK_STATUS" && "$EXISTING_STACK_STATUS" != "None" ]]; then
  echo "Detected existing CloudFormation stack: $STACK_NAME ($EXISTING_STACK_STATUS)"
  if ! prompt_yes_no "Continue and update this existing stack?" "y"; then
    echo "Aborted."
    exit 0
  fi
  IS_STACK_UPDATE="true"
  EXISTING_STACK_PARAMS="$(stack_parameters "$STACK_NAME" "$REGION")"
  PREV_DATABASE_HOST="$(stack_param_value "$EXISTING_STACK_PARAMS" "ExistingDatabaseHost")"
  PREV_DATABASE_ADMIN_USER="$(stack_param_value "$EXISTING_STACK_PARAMS" "ExistingDatabaseAdminUser")"
  PREV_DATABASE_NETWORK_MODE="$(stack_param_value "$EXISTING_STACK_PARAMS" "ExistingDatabaseNetworkMode")"
  PREV_DATABASE_SUBNET_IDS_CSV="$(stack_param_value "$EXISTING_STACK_PARAMS" "ExistingDatabaseSubnetIdsCsv")"
  PREV_DATABASE_LAMBDA_SG_ID="$(stack_param_value "$EXISTING_STACK_PARAMS" "ExistingDatabaseLambdaSecurityGroupId")"
  PREV_DATABASE_PORT="$(stack_param_value "$EXISTING_STACK_PARAMS" "ExistingDatabasePort")"
  PREV_DATABASE_CREATE_APP_USER="$(stack_param_value "$EXISTING_STACK_PARAMS" "ExistingDatabaseCreateAppUser")"
  PREV_DATABASE_CREATE_SCHEMA="$(stack_param_value "$EXISTING_STACK_PARAMS" "ExistingDatabaseCreateSchema")"
  PREV_DATABASE_USERNAME_PREFIX="$(stack_param_value "$EXISTING_STACK_PARAMS" "ExistingDatabaseUsernamePrefix")"
  PREV_DATABASE_APP_USERNAME="$(stack_param_value "$EXISTING_STACK_PARAMS" "ExistingDatabaseAppUsername")"
  PREV_DATABASE_ENGINE="$(stack_param_value "$EXISTING_STACK_PARAMS" "DatabaseEngine")"
  PREV_DATABASE_SCHEMA="$(stack_param_value "$EXISTING_STACK_PARAMS" "DatabaseSchema")"
  PREV_LOG_LEVEL="$(stack_param_value "$EXISTING_STACK_PARAMS" "LogLevel")"
  PREV_REQUIRE_ADMIN="$(stack_param_value "$EXISTING_STACK_PARAMS" "RequireAdmin")"
  PREV_SOFT_DELETE="$(stack_param_value "$EXISTING_STACK_PARAMS" "SoftDeleteRetentionDays")"
  PREV_FEDERATION="$(stack_param_value "$EXISTING_STACK_PARAMS" "SyncbotFederationEnabled")"
  PREV_INSTANCE_ID="$(stack_param_value "$EXISTING_STACK_PARAMS" "SyncbotInstanceId")"
  PREV_PUBLIC_URL="$(stack_param_value "$EXISTING_STACK_PARAMS" "SyncbotPublicUrl")"
  PREV_PRIMARY_WORKSPACE="$(stack_param_value "$EXISTING_STACK_PARAMS" "PrimaryWorkspace")"
  PREV_ENABLE_DB_RESET="$(stack_param_value "$EXISTING_STACK_PARAMS" "EnableDbReset")"
  PREV_DB_TLS="$(stack_param_value "$EXISTING_STACK_PARAMS" "DatabaseTlsEnabled")"
  PREV_DB_SSL_CA="$(stack_param_value "$EXISTING_STACK_PARAMS" "DatabaseSslCaPath")"
  EXISTING_STACK_OUTPUTS="$(app_describe_outputs "$STACK_NAME" "$REGION")"
  PREV_DATABASE_HOST_IN_USE="$(output_value "$EXISTING_STACK_OUTPUTS" "DatabaseHostInUse")"
  if [[ -n "$PREV_DATABASE_HOST" ]]; then
    PREV_STACK_USES_EXTERNAL_DB="true"
  fi
  if [[ -z "$PREV_DATABASE_HOST" && -n "$PREV_DATABASE_HOST_IN_USE" ]]; then
    PREV_DATABASE_HOST="$PREV_DATABASE_HOST_IN_USE"
  fi
fi

echo
prompt_deploy_tasks_aws

if [[ "$TASK_BOOTSTRAP" == "true" ]]; then
  echo
  echo "=== Bootstrap Stack ==="
  if [[ -z "$BOOTSTRAP_OUTPUTS" ]]; then
    echo "Bootstrap stack not found (or has no outputs): $BOOTSTRAP_STACK in $REGION"
    if prompt_yes_no "Deploy bootstrap stack now?" "y"; then
      GITHUB_REPO="$(prompt_default "GitHub repository (owner/repo)" "REPLACE_ME_OWNER/REPLACE_ME_REPO")"
      CREATE_OIDC="$(prompt_default "Create OIDC provider (true/false)" "true")"
      BUCKET_PREFIX="$(prompt_default "Deployment bucket prefix" "syncbot-deploy")"
      echo "Deploying bootstrap stack..."
      aws cloudformation deploy \
        --template-file "$BOOTSTRAP_TEMPLATE" \
        --stack-name "$BOOTSTRAP_STACK" \
        --parameter-overrides \
          "GitHubRepository=$GITHUB_REPO" \
          "CreateOIDCProvider=$CREATE_OIDC" \
          "DeploymentBucketPrefix=$BUCKET_PREFIX" \
        --capabilities CAPABILITY_NAMED_IAM \
        --region "$REGION"
      BOOTSTRAP_OUTPUTS="$(bootstrap_describe_outputs "$BOOTSTRAP_STACK" "$REGION")"
    else
      echo "Skipping bootstrap. You must provide deploy bucket manually when deploying."
    fi
  fi
  if [[ -n "$BOOTSTRAP_OUTPUTS" ]]; then
    sync_bootstrap_stack_from_repo "$BOOTSTRAP_STACK" "$REGION"
    BOOTSTRAP_OUTPUTS="$(bootstrap_describe_outputs "$BOOTSTRAP_STACK" "$REGION")"
  fi
fi

BOOTSTRAP_OUTPUTS="$(bootstrap_describe_outputs "$BOOTSTRAP_STACK" "$REGION")"
S3_BUCKET="$(output_value "$BOOTSTRAP_OUTPUTS" "DeploymentBucketName")"
if [[ -n "$S3_BUCKET" ]]; then
  echo "Detected deploy bucket from bootstrap: $S3_BUCKET"
elif [[ "$TASK_BUILD_DEPLOY" == "true" ]]; then
  S3_BUCKET="$(prompt_default "Deployment S3 bucket name" "REPLACE_ME_DEPLOY_BUCKET")"
else
  S3_BUCKET=""
fi

if [[ "$TASK_BUILD_DEPLOY" != "true" ]]; then
  if [[ "$TASK_CICD" == "true" || "$TASK_SLACK_API" == "true" ]]; then
    if [[ -z "${EXISTING_STACK_STATUS:-}" || "$EXISTING_STACK_STATUS" == "None" ]]; then
      echo "Error: CloudFormation stack '$STACK_NAME' does not exist in $REGION. Select task 2 (Build/Deploy) first or create the stack." >&2
      exit 1
    fi
  fi
fi

if [[ "$TASK_BUILD_DEPLOY" == "true" ]]; then
echo
echo "=== Configuration ==="
echo "=== Database Source ==="
# DB_MODE / GH_DB_MODE: 1 = stack-managed RDS in this template; 2 = external or existing RDS host.
DB_MODE_DEFAULT="1"
if [[ "$IS_STACK_UPDATE" == "true" ]]; then
  if [[ "$PREV_STACK_USES_EXTERNAL_DB" == "true" ]]; then
    DB_HOST_LABEL="$PREV_DATABASE_HOST"
    [[ -z "$DB_HOST_LABEL" ]] && DB_HOST_LABEL="not set"
    DB_MODE_DEFAULT="2"
    echo "  1) Use stack-managed RDS"
    echo "  2) Use external or existing RDS host: $DB_HOST_LABEL (default/current)"
  else
    DB_MODE_DEFAULT="1"
    echo "  1) Use stack-managed RDS (default/current)"
    echo "  2) Use external or existing RDS host"
  fi
else
  echo "  1) Use stack-managed RDS (default)"
  echo "  2) Use external or existing RDS host"
fi
DB_MODE="$(prompt_default "Choose database source (1 or 2)" "$DB_MODE_DEFAULT")"
if [[ "$DB_MODE" != "1" && "$DB_MODE" != "2" ]]; then
  echo "Error: invalid database mode." >&2
  exit 1
fi
if [[ "$IS_STACK_UPDATE" == "true" && "$PREV_STACK_USES_EXTERNAL_DB" != "true" && "$DB_MODE" == "2" ]]; then
  echo
  echo "Warning: switching from stack-managed RDS to existing external DB will remove stack-managed RDS/VPC resources."
  if ! prompt_yes_no "Continue with this destructive migration?" "n"; then
    echo "Keeping stack-managed RDS mode for this deploy."
    DB_MODE="1"
  fi
fi

DATABASE_ENGINE="mysql"
DB_ENGINE_DEFAULT="1"
if [[ "$IS_STACK_UPDATE" == "true" && "$PREV_DATABASE_ENGINE" == "postgresql" ]]; then
  DATABASE_ENGINE="postgresql"
  DB_ENGINE_DEFAULT="2"
fi
echo
echo "=== Database Engine ==="
if [[ "$DB_ENGINE_DEFAULT" == "2" ]]; then
  echo "  1) MySQL"
  echo "  2) PostgreSQL (default/current)"
else
  echo "  1) MySQL (default/current)"
  echo "  2) PostgreSQL"
fi
DB_ENGINE_MODE="$(prompt_default "Choose 1 or 2" "$DB_ENGINE_DEFAULT")"
if [[ "$DB_ENGINE_MODE" == "2" ]]; then
  DATABASE_ENGINE="postgresql"
elif [[ "$DB_ENGINE_MODE" != "1" ]]; then
  echo "Error: invalid database engine mode." >&2
  exit 1
fi

echo
echo "=== Slack App Credentials ==="
SLACK_SIGNING_SECRET_SOURCE="prompt"
[[ -n "${SLACK_SIGNING_SECRET:-}" ]] && SLACK_SIGNING_SECRET_SOURCE="env:SLACK_SIGNING_SECRET"
SLACK_CLIENT_SECRET_SOURCE="prompt"
[[ -n "${SLACK_CLIENT_SECRET:-}" ]] && SLACK_CLIENT_SECRET_SOURCE="env:SLACK_CLIENT_SECRET"
SLACK_SIGNING_SECRET="$(required_from_env_or_prompt "SLACK_SIGNING_SECRET" "SlackSigningSecret" "secret")"
SLACK_CLIENT_SECRET="$(required_from_env_or_prompt "SLACK_CLIENT_SECRET" "SlackClientSecret" "secret")"
SLACK_CLIENT_ID="$(required_from_env_or_prompt "SLACK_CLIENT_ID" "SlackClientID")"

ENV_DATABASE_HOST="${DATABASE_HOST:-}"
ENV_DATABASE_ADMIN_USER="${DATABASE_ADMIN_USER:-}"
ENV_DATABASE_ADMIN_PASSWORD="${DATABASE_ADMIN_PASSWORD:-}"
ENV_DATABASE_PORT="${DATABASE_PORT:-}"
ENV_DATABASE_CREATE_APP_USER="${DATABASE_CREATE_APP_USER:-}"
ENV_DATABASE_CREATE_SCHEMA="${DATABASE_CREATE_SCHEMA:-}"
ENV_DATABASE_USERNAME_PREFIX="${DATABASE_USERNAME_PREFIX:-}"
ENV_DATABASE_APP_USERNAME="${DATABASE_APP_USERNAME:-}"
DB_ADMIN_PASSWORD_SOURCE="prompt"
DATABASE_HOST=""
DATABASE_ADMIN_USER=""
DATABASE_ADMIN_PASSWORD=""
DATABASE_NETWORK_MODE="public"
DATABASE_SUBNET_IDS_CSV=""
DATABASE_LAMBDA_SG_ID=""
DATABASE_PORT=""
DATABASE_CREATE_APP_USER="true"
DATABASE_CREATE_SCHEMA="true"
DATABASE_USERNAME_PREFIX=""
DATABASE_APP_USERNAME=""
DB_EFFECTIVE_PORT=""
DATABASE_SCHEMA=""
DATABASE_SCHEMA_DEFAULT="syncbot_${STAGE}"
if [[ "$IS_STACK_UPDATE" == "true" && -n "$PREV_DATABASE_SCHEMA" ]]; then
  DATABASE_SCHEMA_DEFAULT="$PREV_DATABASE_SCHEMA"
fi

if [[ "$DB_MODE" == "2" ]]; then
  echo
  echo "=== Existing Database Host ==="
  DATABASE_HOST_DEFAULT="REPLACE_ME_RDS_HOST"
  [[ -n "$PREV_DATABASE_HOST" ]] && DATABASE_HOST_DEFAULT="$PREV_DATABASE_HOST"
  DATABASE_ADMIN_USER_DEFAULT="admin"
  [[ -n "$PREV_DATABASE_ADMIN_USER" ]] && DATABASE_ADMIN_USER_DEFAULT="$PREV_DATABASE_ADMIN_USER"

  DATABASE_HOST="$(resolve_with_conflict_check \
    "DATABASE_HOST (RDS endpoint hostname)" \
    "$ENV_DATABASE_HOST" \
    "$PREV_DATABASE_HOST" \
    "$DATABASE_HOST_DEFAULT")"

  DETECTED_ADMIN_USER=""
  if [[ "$IS_STACK_UPDATE" == "true" ]]; then
    DETECTED_ADMIN_USER="$(rds_lookup_admin_defaults "$DATABASE_HOST" "$REGION")"
    [[ "$DETECTED_ADMIN_USER" == "None" ]] && DETECTED_ADMIN_USER=""
  fi

  if [[ -z "$DATABASE_ADMIN_USER_DEFAULT" || "$DATABASE_ADMIN_USER_DEFAULT" == "admin" ]]; then
    [[ -n "$DETECTED_ADMIN_USER" ]] && DATABASE_ADMIN_USER_DEFAULT="$DETECTED_ADMIN_USER"
  fi
  DATABASE_ADMIN_USER="$(resolve_with_conflict_check \
    "DATABASE_ADMIN_USER" \
    "$ENV_DATABASE_ADMIN_USER" \
    "$PREV_DATABASE_ADMIN_USER" \
    "$DATABASE_ADMIN_USER_DEFAULT")"

  if [[ -n "$ENV_DATABASE_ADMIN_PASSWORD" ]]; then
    echo "Using DATABASE_ADMIN_PASSWORD from environment variable."
    DATABASE_ADMIN_PASSWORD="$ENV_DATABASE_ADMIN_PASSWORD"
  else
    DATABASE_ADMIN_PASSWORD="$(prompt_secret_required "DATABASE_ADMIN_PASSWORD")"
  fi

  echo
  echo "Database name (DatabaseSchema): use syncbot_${STAGE} or similar so each stage has its own DB on a shared host"
  echo "(e.g. syncbot_test, syncbot_prod). The default below includes the stage you chose."
  DATABASE_SCHEMA="$(prompt_default "DatabaseSchema" "$DATABASE_SCHEMA_DEFAULT")"

  echo
  echo "=== Existing database port and setup ==="
  echo "Leave port blank to use the engine default (3306 MySQL, 5432 PostgreSQL)."
  DEFAULT_DB_PORT=""
  [[ -n "$PREV_DATABASE_PORT" ]] && DEFAULT_DB_PORT="$PREV_DATABASE_PORT"
  DATABASE_PORT="$(resolve_with_conflict_check \
    "DATABASE_PORT (optional)" \
    "$ENV_DATABASE_PORT" \
    "$PREV_DATABASE_PORT" \
    "$DEFAULT_DB_PORT")"
  if [[ "$DATABASE_ENGINE" == "mysql" && "$DATABASE_PORT" == "3306" ]]; then
    DATABASE_PORT=""
  fi
  if [[ "$DATABASE_ENGINE" == "postgresql" && "$DATABASE_PORT" == "5432" ]]; then
    DATABASE_PORT=""
  fi
  DB_EFFECTIVE_PORT="3306"
  [[ "$DATABASE_ENGINE" == "postgresql" ]] && DB_EFFECTIVE_PORT="5432"
  [[ -n "$DATABASE_PORT" ]] && DB_EFFECTIVE_PORT="$DATABASE_PORT"

  CREATE_APP_DEFAULT="y"
  [[ "${PREV_DATABASE_CREATE_APP_USER:-}" == "false" ]] && CREATE_APP_DEFAULT="n"
  DATABASE_CREATE_APP_USER="$(resolve_with_conflict_check \
    "Create dedicated app DB user (CREATE USER / grants)?" \
    "$ENV_DATABASE_CREATE_APP_USER" \
    "${PREV_DATABASE_CREATE_APP_USER:-}" \
    "$CREATE_APP_DEFAULT" \
    bool)"

  CREATE_SCHEMA_DEFAULT="y"
  [[ "${PREV_DATABASE_CREATE_SCHEMA:-}" == "false" ]] && CREATE_SCHEMA_DEFAULT="n"
  DATABASE_CREATE_SCHEMA="$(resolve_with_conflict_check \
    "Run CREATE DATABASE IF NOT EXISTS for DatabaseSchema?" \
    "$ENV_DATABASE_CREATE_SCHEMA" \
    "${PREV_DATABASE_CREATE_SCHEMA:-}" \
    "$CREATE_SCHEMA_DEFAULT" \
    bool)"

  DATABASE_USERNAME_PREFIX_DEFAULT=""
  [[ -n "$PREV_DATABASE_USERNAME_PREFIX" ]] && DATABASE_USERNAME_PREFIX_DEFAULT="$PREV_DATABASE_USERNAME_PREFIX"
  DATABASE_USERNAME_PREFIX="$(resolve_with_conflict_check \
    "DB username prefix (e.g. abc123 for TiDB Cloud; blank for RDS/standard)" \
    "$ENV_DATABASE_USERNAME_PREFIX" \
    "$PREV_DATABASE_USERNAME_PREFIX" \
    "$DATABASE_USERNAME_PREFIX_DEFAULT")"

  DATABASE_APP_USERNAME_DEFAULT=""
  [[ -n "$PREV_DATABASE_APP_USERNAME" ]] && DATABASE_APP_USERNAME_DEFAULT="$PREV_DATABASE_APP_USERNAME"
  DATABASE_APP_USERNAME="$(resolve_with_conflict_check \
    "DATABASE_APP_USERNAME (optional; full app user, bypasses prefix+sbapp_{stage}; blank for default)" \
    "$ENV_DATABASE_APP_USERNAME" \
    "$PREV_DATABASE_APP_USERNAME" \
    "$DATABASE_APP_USERNAME_DEFAULT")"

  if [[ -z "$DATABASE_HOST" || "$DATABASE_HOST" == REPLACE_ME* ]]; then
    echo "Error: valid DATABASE_HOST is required for external DB mode." >&2
    exit 1
  fi

  RDS_LOOKUP="$(rds_lookup_network_defaults "$DATABASE_HOST" "$REGION")"
  DETECTED_PUBLIC=""
  DETECTED_SUBNETS=""
  DETECTED_SGS=""
  DETECTED_VPC=""
  DETECTED_DB_ID=""
  if [[ -n "$RDS_LOOKUP" && "$RDS_LOOKUP" != "None" ]]; then
    IFS=$'\t' read -r DETECTED_PUBLIC DETECTED_SUBNETS DETECTED_SGS DETECTED_VPC DETECTED_DB_ID <<< "$RDS_LOOKUP"
    [[ "$DETECTED_PUBLIC" == "None" ]] && DETECTED_PUBLIC=""
    [[ "$DETECTED_SUBNETS" == "None" ]] && DETECTED_SUBNETS=""
    [[ "$DETECTED_SGS" == "None" ]] && DETECTED_SGS=""
    [[ "$DETECTED_VPC" == "None" ]] && DETECTED_VPC=""
    [[ "$DETECTED_DB_ID" == "None" ]] && DETECTED_DB_ID=""
    echo
    echo "Detected RDS instance details:"
    [[ -n "$DETECTED_DB_ID" ]] && echo "  DB instance:   $DETECTED_DB_ID"
    [[ -n "$DETECTED_VPC" ]] && echo "  VPC:           $DETECTED_VPC"
    [[ -n "$DETECTED_PUBLIC" ]] && echo "  Public access: $DETECTED_PUBLIC"
  else
    echo
    echo "Could not auto-detect existing RDS network settings from host."
    echo "You can still continue by entering network values manually."
  fi

  DEFAULT_DB_NETWORK_MODE="public"
  if [[ -n "$PREV_DATABASE_NETWORK_MODE" ]]; then
    DEFAULT_DB_NETWORK_MODE="$PREV_DATABASE_NETWORK_MODE"
  fi
  if [[ "$DETECTED_PUBLIC" == "False" ]]; then
    DEFAULT_DB_NETWORK_MODE="private"
  fi
  DATABASE_NETWORK_MODE="$(prompt_default "Existing DB network mode (public/private)" "$DEFAULT_DB_NETWORK_MODE")"
  if [[ "$DATABASE_NETWORK_MODE" != "public" && "$DATABASE_NETWORK_MODE" != "private" ]]; then
    echo "Error: existing DB network mode must be 'public' or 'private'." >&2
    exit 1
  fi

  if [[ "$DATABASE_NETWORK_MODE" == "private" ]]; then
    AUTO_PRIVATE_SUBNETS=""
    if [[ -n "$DETECTED_VPC" ]]; then
      AUTO_PRIVATE_SUBNETS="$(discover_private_lambda_subnets_for_db_vpc "$DETECTED_VPC" "$REGION")"
      if [[ -n "$AUTO_PRIVATE_SUBNETS" ]]; then
        echo "Detected private Lambda subnet candidates (NAT-routed): $AUTO_PRIVATE_SUBNETS"
      fi
    fi

    DEFAULT_SUBNETS="$AUTO_PRIVATE_SUBNETS"
    [[ -z "$DEFAULT_SUBNETS" && -n "$PREV_DATABASE_SUBNET_IDS_CSV" ]] && DEFAULT_SUBNETS="$PREV_DATABASE_SUBNET_IDS_CSV"
    [[ -z "$DEFAULT_SUBNETS" ]] && DEFAULT_SUBNETS="$DETECTED_SUBNETS"
    [[ -z "$DEFAULT_SUBNETS" ]] && DEFAULT_SUBNETS="REPLACE_ME_SUBNET_1,REPLACE_ME_SUBNET_2"
    DEFAULT_SG="${DETECTED_SGS%%,*}"
    [[ -n "$PREV_DATABASE_LAMBDA_SG_ID" ]] && DEFAULT_SG="$PREV_DATABASE_LAMBDA_SG_ID"
    [[ -z "$DEFAULT_SG" ]] && DEFAULT_SG="REPLACE_ME_LAMBDA_SG_ID"

    echo
    echo "Private DB mode selected: Lambdas will run in VPC."
    echo "Note: app Lambda needs Internet egress (usually NAT) to call Slack APIs."
    DATABASE_SUBNET_IDS_CSV="$(prompt_default "DATABASE_SUBNET_IDS_CSV (comma-separated)" "$DEFAULT_SUBNETS")"
    DATABASE_LAMBDA_SG_ID="$(prompt_default "DATABASE_LAMBDA_SECURITY_GROUP_ID" "$DEFAULT_SG")"

    if [[ -z "$DATABASE_SUBNET_IDS_CSV" || "$DATABASE_SUBNET_IDS_CSV" == REPLACE_ME* ]]; then
      echo "Error: valid DATABASE_SUBNET_IDS_CSV is required for private mode." >&2
      exit 1
    fi
    if [[ -z "$DATABASE_LAMBDA_SG_ID" || "$DATABASE_LAMBDA_SG_ID" == REPLACE_ME* ]]; then
      echo "Error: valid DATABASE_LAMBDA_SECURITY_GROUP_ID is required for private mode." >&2
      exit 1
    fi

    echo
    echo "Running private-connectivity preflight checks..."
    if ! validate_private_db_connectivity \
      "$REGION" \
      "$DATABASE_ENGINE" \
      "$DATABASE_SUBNET_IDS_CSV" \
      "$DATABASE_LAMBDA_SG_ID" \
      "$DETECTED_VPC" \
      "$DETECTED_SGS" \
      "$DATABASE_HOST" \
      "$DB_EFFECTIVE_PORT"; then
      echo "Fix network settings and rerun deploy." >&2
      exit 1
    fi
  fi
else
  echo
  echo "=== New RDS Database ==="
  echo "New RDS mode uses:"
  echo "  - admin user: sbadmin_${STAGE}"
  echo
  echo "Database name (DatabaseSchema): use syncbot_${STAGE} or similar so each stage has its own DB on a shared host"
  echo "(e.g. syncbot_test, syncbot_prod). The default below includes the stage you chose."
  DATABASE_SCHEMA="$(prompt_default "DatabaseSchema" "$DATABASE_SCHEMA_DEFAULT")"
  echo "Admin password for new RDS instance:"
  DATABASE_ADMIN_PASSWORD="$(required_from_env_or_prompt "DATABASE_ADMIN_PASSWORD" "DatabaseAdminPassword" "secret")"
fi

echo
echo "=== App Secrets ==="

if [[ -z "${DATA_ENCRYPTION_KEY:-}" ]]; then
  DATA_ENCRYPTION_KEY="$(python3 -c 'import secrets; print(secrets.token_urlsafe(36))')"
  echo "Generated DATA_ENCRYPTION_KEY=$DATA_ENCRYPTION_KEY"
  echo "IMPORTANT: Store this key securely. You need it for disaster recovery."
fi
DATA_ENCRYPTION_KEY="$(required_from_env_or_prompt "DATA_ENCRYPTION_KEY" "DataEncryptionKey" "secret")"

if [[ -n "${DATABASE_ADMIN_USER:-}" && -z "${DATABASE_PASSWORD:-}" ]]; then
  DATABASE_PASSWORD="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"
  echo "Generated DATABASE_PASSWORD=$DATABASE_PASSWORD"
fi
DATABASE_PASSWORD="$(required_from_env_or_prompt "DATABASE_PASSWORD" "DatabasePassword" "secret")"

DATABASE_USER=""
if [[ "$DB_MODE" == "2" && -z "${DATABASE_ADMIN_USER:-}" ]]; then
  DATABASE_USER="$(required_from_env_or_prompt "DATABASE_USER" "DatabaseUser (pre-existing app DB user)")"
elif [[ -n "${DATABASE_ADMIN_USER:-}" && -z "${DATABASE_USER:-}" ]]; then
  DATABASE_USER="${DATABASE_USERNAME_PREFIX:+${DATABASE_USERNAME_PREFIX}.}sbapp_${STAGE}"
  DATABASE_USER="${DATABASE_USER//-/_}"
  echo "Derived DATABASE_USER=$DATABASE_USER"
fi

LOG_LEVEL_DEFAULT="INFO"
if [[ "$IS_STACK_UPDATE" == "true" && -n "$PREV_LOG_LEVEL" ]]; then
  LOG_LEVEL_DEFAULT="$PREV_LOG_LEVEL"
fi

REQUIRE_ADMIN="${PREV_REQUIRE_ADMIN:-true}"
SOFT_DELETE_RETENTION_DAYS="${PREV_SOFT_DELETE:-30}"
SYNCBOT_FEDERATION_ENABLED="${PREV_FEDERATION:-false}"
SYNCBOT_INSTANCE_ID="${PREV_INSTANCE_ID:-}"
SYNCBOT_PUBLIC_URL="${PREV_PUBLIC_URL:-}"
PRIMARY_WORKSPACE="${PREV_PRIMARY_WORKSPACE:-}"
ENABLE_DB_RESET="${PREV_ENABLE_DB_RESET:-}"
DATABASE_TLS_ENABLED="${PREV_DB_TLS:-}"
DATABASE_SSL_CA_PATH="${PREV_DB_SSL_CA:-}"

echo
echo "=== Log Level ==="
LOG_LEVEL="$(prompt_log_level "$LOG_LEVEL_DEFAULT")"

echo
echo "=== App Settings ==="
REQUIRE_ADMIN="$(prompt_require_admin "$REQUIRE_ADMIN")"
SOFT_DELETE_RETENTION_DAYS="$(prompt_soft_delete_retention_days "$SOFT_DELETE_RETENTION_DAYS")"
PRIMARY_WORKSPACE="$(prompt_primary_workspace "$PRIMARY_WORKSPACE")"
SYNCBOT_FEDERATION_ENABLED="$(prompt_federation_enabled "$SYNCBOT_FEDERATION_ENABLED")"
if [[ "$SYNCBOT_FEDERATION_ENABLED" == "true" ]]; then
  SYNCBOT_INSTANCE_ID="$(prompt_instance_id "$SYNCBOT_INSTANCE_ID")"
  SYNCBOT_PUBLIC_URL="$(prompt_public_url "$SYNCBOT_PUBLIC_URL")"
fi

echo
echo "=== Deploy Summary ==="
echo "Region:           $REGION"
echo "Stack:            $STACK_NAME"
echo "Stage:            $STAGE"
echo "Log level:        $LOG_LEVEL"
echo "Require admin:    $REQUIRE_ADMIN"
echo "Soft-delete days: $SOFT_DELETE_RETENTION_DAYS"
if [[ -n "$PRIMARY_WORKSPACE" ]]; then
  echo "Primary workspace: $PRIMARY_WORKSPACE"
else
  echo "Primary workspace: (not set — backup/restore hidden)"
fi
if [[ "$ENABLE_DB_RESET" == "true" ]]; then
  echo "DB reset:          enabled (PRIMARY_WORKSPACE must match)"
else
  echo "DB reset:          (disabled)"
fi
if [[ "$SYNCBOT_FEDERATION_ENABLED" == "true" ]]; then
  echo "Federation:       enabled"
  [[ -n "$SYNCBOT_INSTANCE_ID" ]] && echo "Instance ID:      $SYNCBOT_INSTANCE_ID"
  [[ -n "$SYNCBOT_PUBLIC_URL" ]] && echo "Public URL:       $SYNCBOT_PUBLIC_URL"
fi
echo "Deploy bucket:    $S3_BUCKET"
if [[ "$DB_MODE" == "2" ]]; then
  echo "DB mode:          existing host"
  echo "DB engine:        $DATABASE_ENGINE"
  echo "DB host:          $DATABASE_HOST"
  echo "DB network:       $DATABASE_NETWORK_MODE"
  if [[ "$DATABASE_NETWORK_MODE" == "private" ]]; then
    echo "DB subnets:       $DATABASE_SUBNET_IDS_CSV"
    echo "Lambda SG:        $DATABASE_LAMBDA_SG_ID"
  fi
  echo "DB port:          ${DB_EFFECTIVE_PORT:-engine default}"
  echo "DB create user:   $DATABASE_CREATE_APP_USER"
  echo "DB create schema: $DATABASE_CREATE_SCHEMA"
  echo "DB admin user (parameter): $DATABASE_ADMIN_USER"
  if [[ -n "$DATABASE_APP_USERNAME" ]]; then
    echo "DB app username override: $DATABASE_APP_USERNAME"
  fi
  if [[ -n "$DATABASE_USERNAME_PREFIX" ]]; then
    _dbpfx="$DATABASE_USERNAME_PREFIX"
    [[ "$_dbpfx" != *. ]] && _dbpfx="${_dbpfx}."
    echo "DB username prefix: $DATABASE_USERNAME_PREFIX"
    echo "  effective admin (bootstrap): ${_dbpfx}${DATABASE_ADMIN_USER}"
    if [[ -n "$DATABASE_APP_USERNAME" ]]; then
      echo "  effective app user (if created): $DATABASE_APP_USERNAME (override)"
    else
      echo "  effective app user (if created): ${_dbpfx}sbapp_${STAGE//-/_}"
    fi
  else
    echo "DB username prefix: (none)"
    echo "  admin (bootstrap): $DATABASE_ADMIN_USER"
    if [[ -n "$DATABASE_APP_USERNAME" ]]; then
      echo "  app user (if created): $DATABASE_APP_USERNAME (override)"
    else
      echo "  app user (if created): sbapp_${STAGE//-/_}"
    fi
  fi
  echo "DB schema:        $DATABASE_SCHEMA"
else
  echo "DB mode:          create new RDS"
  echo "DB engine:        $DATABASE_ENGINE"
  echo "DB admin user:    sbadmin_${STAGE} (auto password)"
  echo "DB app user:      sbapp_${STAGE} (auto password)"
  echo "DB schema:        $DATABASE_SCHEMA"
fi
echo "Token encryption: provided (NoEcho SAM parameter)"
echo "Database password: provided (NoEcho SAM parameter)"
if [[ -n "${DATABASE_USER:-}" ]]; then
  echo "Database user:    $DATABASE_USER (direct — DbSetup skipped)"
fi
echo

if ! prompt_yes_no "Proceed with build + deploy?" "y"; then
  echo "Aborted."
  exit 0
fi

echo
echo "=== Preflight ==="
handle_unhealthy_stack_state "$STACK_NAME" "$REGION"

echo

PARAMS=(
  "Stage=$STAGE"
  "DatabaseEngine=$DATABASE_ENGINE"
  "SlackSigningSecret=$SLACK_SIGNING_SECRET"
  "SlackClientSecret=$SLACK_CLIENT_SECRET"
  "DatabaseSchema=$DATABASE_SCHEMA"
  "DataEncryptionKey=$DATA_ENCRYPTION_KEY"
  "DatabasePassword=$DATABASE_PASSWORD"
  "LogLevel=$LOG_LEVEL"
  "RequireAdmin=$REQUIRE_ADMIN"
  "SoftDeleteRetentionDays=$SOFT_DELETE_RETENTION_DAYS"
  "SyncbotFederationEnabled=$SYNCBOT_FEDERATION_ENABLED"
)
[[ -n "${DATABASE_USER:-}" ]] && PARAMS+=("DatabaseUser=$DATABASE_USER")
[[ -n "$SYNCBOT_INSTANCE_ID" ]] && PARAMS+=("SyncbotInstanceId=$SYNCBOT_INSTANCE_ID")
[[ -n "$SYNCBOT_PUBLIC_URL" ]] && PARAMS+=("SyncbotPublicUrl=$SYNCBOT_PUBLIC_URL")
[[ -n "$PRIMARY_WORKSPACE" ]] && PARAMS+=("PrimaryWorkspace=$PRIMARY_WORKSPACE")
[[ -n "$ENABLE_DB_RESET" ]] && PARAMS+=("EnableDbReset=$ENABLE_DB_RESET")
[[ -n "$DATABASE_TLS_ENABLED" ]] && PARAMS+=("DatabaseTlsEnabled=$DATABASE_TLS_ENABLED")
[[ -n "$DATABASE_SSL_CA_PATH" ]] && PARAMS+=("DatabaseSslCaPath=$DATABASE_SSL_CA_PATH")

if [[ -n "$SLACK_CLIENT_ID" ]]; then
  PARAMS+=("SlackClientID=$SLACK_CLIENT_ID")
fi

if [[ "$DB_MODE" == "2" ]]; then
  PARAMS+=(
    "ExistingDatabaseHost=$DATABASE_HOST"
    "ExistingDatabaseNetworkMode=$DATABASE_NETWORK_MODE"
  )
  [[ -n "${DATABASE_ADMIN_USER:-}" ]] && PARAMS+=("ExistingDatabaseAdminUser=$DATABASE_ADMIN_USER")
  [[ -n "${DATABASE_ADMIN_PASSWORD:-}" ]] && PARAMS+=("ExistingDatabaseAdminPassword=$DATABASE_ADMIN_PASSWORD")
  if [[ "$DATABASE_NETWORK_MODE" == "private" ]]; then
    PARAMS+=(
      "ExistingDatabaseSubnetIdsCsv=$DATABASE_SUBNET_IDS_CSV"
      "ExistingDatabaseLambdaSecurityGroupId=$DATABASE_LAMBDA_SG_ID"
    )
  fi
  [[ -n "$DATABASE_PORT" ]] && PARAMS+=("ExistingDatabasePort=$DATABASE_PORT")
  PARAMS+=(
    "ExistingDatabaseCreateAppUser=$DATABASE_CREATE_APP_USER"
    "ExistingDatabaseCreateSchema=$DATABASE_CREATE_SCHEMA"
    "ExistingDatabaseUsernamePrefix=$DATABASE_USERNAME_PREFIX"
    "ExistingDatabaseAppUsername=$DATABASE_APP_USERNAME"
  )
else
  PARAMS+=("DatabaseAdminPassword=${DATABASE_ADMIN_PASSWORD:-}")
  PARAMS+=(
    "ExistingDatabaseHost="
    "ExistingDatabaseAdminUser="
    "ExistingDatabaseAdminPassword="
    "ExistingDatabaseNetworkMode=public"
    "ExistingDatabaseSubnetIdsCsv="
    "ExistingDatabaseLambdaSecurityGroupId="
    "ExistingDatabasePort="
    "ExistingDatabaseCreateAppUser=true"
    "ExistingDatabaseCreateSchema=true"
    "ExistingDatabaseUsernamePrefix="
    "ExistingDatabaseAppUsername="
  )
fi

PARAMS+=(
  "SlackOauthBotScopes=${SLACK_BOT_SCOPES:-app_mentions:read,channels:history,channels:join,channels:read,channels:manage,chat:write,chat:write.customize,files:read,files:write,groups:history,groups:read,groups:write,im:write,reactions:read,reactions:write,team:read,users:read,users:read.email}"
  "SlackOauthUserScopes=${SLACK_USER_SCOPES:-chat:write,channels:history,channels:read,files:read,files:write,groups:history,groups:read,groups:write,im:write,reactions:read,reactions:write,team:read,users:read,users:read.email}"
  "DatabaseInstanceClass=${DATABASE_INSTANCE_CLASS:-db.t4g.micro}"
  "DatabaseBackupRetentionDays=${DATABASE_BACKUP_RETENTION_DAYS:-0}"
  "AllowedDBCidr=${ALLOWED_DB_CIDR:-0.0.0.0/0}"
  "VpcCidr=${VPC_CIDR:-10.0.0.0/16}"
)

echo "=== SAM Build ==="
echo "Building app..."
sam build -t "$APP_TEMPLATE" --use-container

echo "=== SAM Deploy ==="
echo "Deploying stack..."
sam_deploy_or_fallback

APP_OUTPUTS="$(app_describe_outputs "$STACK_NAME" "$REGION")"

  FUNCTION_ARN="$(output_value "$APP_OUTPUTS" "SyncBotFunctionArn")"
  if [[ -n "$FUNCTION_ARN" ]]; then
    echo "=== Lambda migrate + warm-up ==="
    TMP_MIGRATE="$(mktemp)"
    aws lambda invoke \
      --function-name "$FUNCTION_ARN" \
      --payload '{"action":"migrate"}' \
      --cli-binary-format raw-in-base64-out \
      "$TMP_MIGRATE" \
      --region "$REGION"
    cat "$TMP_MIGRATE"
    echo
    rm -f "$TMP_MIGRATE"
  fi

else
  echo
  echo "Skipping Build/Deploy (task 2 not selected)."
  APP_OUTPUTS="${EXISTING_STACK_OUTPUTS:-}"
  DB_MODE="1"
  if [[ "$PREV_STACK_USES_EXTERNAL_DB" == "true" ]]; then
    DB_MODE="2"
  fi
  DATABASE_SCHEMA="${PREV_DATABASE_SCHEMA:-}"
  [[ -z "$DATABASE_SCHEMA" ]] && DATABASE_SCHEMA="syncbot_${STAGE}"
  DATABASE_ENGINE="${PREV_DATABASE_ENGINE:-mysql}"
  [[ -z "$DATABASE_ENGINE" ]] && DATABASE_ENGINE="mysql"
  DATABASE_HOST="${PREV_DATABASE_HOST:-}"
  DATABASE_ADMIN_USER="${PREV_DATABASE_ADMIN_USER:-}"
  DATABASE_ADMIN_PASSWORD="${DATABASE_ADMIN_PASSWORD:-}"
  DATABASE_NETWORK_MODE="${PREV_DATABASE_NETWORK_MODE:-public}"
  DATABASE_SUBNET_IDS_CSV="${PREV_DATABASE_SUBNET_IDS_CSV:-}"
  DATABASE_LAMBDA_SG_ID="${PREV_DATABASE_LAMBDA_SG_ID:-}"
  DATABASE_PORT="${PREV_DATABASE_PORT:-}"
  DATABASE_CREATE_APP_USER="${PREV_DATABASE_CREATE_APP_USER:-true}"
  DATABASE_CREATE_SCHEMA="${PREV_DATABASE_CREATE_SCHEMA:-true}"
  DATABASE_USERNAME_PREFIX="${PREV_DATABASE_USERNAME_PREFIX:-}"
  DATABASE_APP_USERNAME="${PREV_DATABASE_APP_USERNAME:-}"
  [[ -z "$DATABASE_CREATE_APP_USER" ]] && DATABASE_CREATE_APP_USER="true"
  [[ -z "$DATABASE_CREATE_SCHEMA" ]] && DATABASE_CREATE_SCHEMA="true"
  SLACK_SIGNING_SECRET="${SLACK_SIGNING_SECRET:-}"
  SLACK_CLIENT_SECRET="${SLACK_CLIENT_SECRET:-}"
  SLACK_CLIENT_ID="${SLACK_CLIENT_ID:-}"
fi

SYNCBOT_API_URL="$(output_value "$APP_OUTPUTS" "SyncBotApiUrl")"
SYNCBOT_INSTALL_URL="$(output_value "$APP_OUTPUTS" "SyncBotInstallUrl")"

echo
echo "=== Post-Deploy ==="
if [[ "$TASK_BUILD_DEPLOY" == "true" ]]; then
  echo "Deploy complete."
fi

if [[ "$TASK_SLACK_API" == "true" || "$TASK_BUILD_DEPLOY" == "true" ]]; then
  generate_stage_slack_manifest "$STAGE" "$SYNCBOT_API_URL" "$SYNCBOT_INSTALL_URL"
fi

if [[ "$TASK_SLACK_API" == "true" ]] && [[ -n "${SLACK_MANIFEST_GENERATED_PATH:-}" ]]; then
  slack_api_configure_from_manifest "$SLACK_MANIFEST_GENERATED_PATH" "$SYNCBOT_INSTALL_URL"
fi

if [[ "$TASK_CICD" == "true" ]]; then
  configure_github_actions_aws \
    "$BOOTSTRAP_OUTPUTS" \
    "$BOOTSTRAP_STACK" \
    "$REGION" \
    "$STACK_NAME" \
    "$STAGE" \
    "$DATABASE_SCHEMA" \
    "$DB_MODE" \
    "$DATABASE_HOST" \
    "$DATABASE_ADMIN_USER" \
    "$DATABASE_ADMIN_PASSWORD" \
    "$DATABASE_NETWORK_MODE" \
    "$DATABASE_SUBNET_IDS_CSV" \
    "$DATABASE_LAMBDA_SG_ID" \
    "$DATABASE_ENGINE" \
    "${DATABASE_PORT:-}" \
    "${DATABASE_CREATE_APP_USER:-true}" \
    "${DATABASE_CREATE_SCHEMA:-true}" \
    "${DATABASE_USERNAME_PREFIX:-}" \
    "${DATABASE_APP_USERNAME:-}"
fi

# --- Save config to env file ---
echo
if prompt_yes_no "Save config to .env.deploy.${STAGE} for future deploys?" "y"; then
  ENV_SAVE_FILE="$REPO_ROOT/.env.deploy.${STAGE}"
  {
    echo "# Generated by deploy.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "CLOUD_PROVIDER=aws"
    echo "AWS_REGION=$REGION"
    echo "STACK_NAME=$STACK_NAME"
    echo "BOOTSTRAP_STACK_NAME=$BOOTSTRAP_STACK"
    echo ""
    echo "SLACK_SIGNING_SECRET=$SLACK_SIGNING_SECRET"
    echo "SLACK_CLIENT_SECRET=$SLACK_CLIENT_SECRET"
    echo "SLACK_CLIENT_ID=$SLACK_CLIENT_ID"
    echo ""
    echo "DATA_ENCRYPTION_KEY=$DATA_ENCRYPTION_KEY"
    echo ""
    echo "DATABASE_HOST=${DATABASE_HOST:-}"
    [[ -n "${DB_EFFECTIVE_PORT:-}" ]] && echo "DATABASE_PORT=$DB_EFFECTIVE_PORT"
    echo "DATABASE_USER=${DATABASE_USER:-}"
    echo "DATABASE_PASSWORD=$DATABASE_PASSWORD"
    echo "DATABASE_SCHEMA=$DATABASE_SCHEMA"
    echo "DATABASE_ENGINE=$DATABASE_ENGINE"
    [[ -n "${DATABASE_TLS_ENABLED:-}" ]] && echo "DATABASE_TLS_ENABLED=$DATABASE_TLS_ENABLED"
    if [[ "$DB_MODE" == "2" ]]; then
      echo ""
      echo "DATABASE_ADMIN_USER=$DATABASE_ADMIN_USER"
      [[ -n "$DATABASE_ADMIN_PASSWORD" ]] && echo "DATABASE_ADMIN_PASSWORD=$DATABASE_ADMIN_PASSWORD"
      [[ -n "${DATABASE_USERNAME_PREFIX:-}" ]] && echo "DATABASE_USERNAME_PREFIX=$DATABASE_USERNAME_PREFIX"
      [[ -n "${DATABASE_APP_USERNAME:-}" ]] && echo "DATABASE_APP_USERNAME=$DATABASE_APP_USERNAME"
      echo "DATABASE_CREATE_APP_USER=${DATABASE_CREATE_APP_USER:-true}"
      echo "DATABASE_CREATE_SCHEMA=${DATABASE_CREATE_SCHEMA:-true}"
    fi
  } > "$ENV_SAVE_FILE"
  chmod 600 "$ENV_SAVE_FILE"
  echo "Saved to $ENV_SAVE_FILE"
  echo "Next time: ./deploy.sh --env $STAGE aws"
fi

# --- Push to GitHub (if --setup-github and TASK_CICD was not already run) ---
if [[ "${SETUP_GITHUB:-}" == "true" && "$TASK_CICD" != "true" ]]; then
  echo
  echo "=== Push to GitHub Environment ==="
  prereqs_require_cmd gh prereqs_hint_gh_cli
  if ! gh auth status >/dev/null 2>&1; then
    echo "Error: gh CLI not authenticated. Run 'gh auth login' first." >&2
    exit 1
  fi
  REPO="$(prompt_github_repo_for_actions "$REPO_ROOT")"
  ENV_NAME="$STAGE"
  ROLE_ARN="${AWS_ROLE_ARN:-$(output_value "$BOOTSTRAP_OUTPUTS" "GitHubDeployRoleArn")}"

  gh api -X PUT "repos/$REPO/environments/$ENV_NAME" >/dev/null
  [[ -n "$ROLE_ARN" ]] && gh variable set AWS_ROLE_TO_ASSUME --body "$ROLE_ARN" -R "$REPO"
  [[ -n "$S3_BUCKET" ]] && gh variable set AWS_S3_BUCKET --body "$S3_BUCKET" -R "$REPO"
  gh variable set AWS_REGION --body "$REGION" -R "$REPO"
  gh_variable_set_env AWS_STACK_NAME "$ENV_NAME" "$REPO" "$STACK_NAME"
  gh_variable_set_env STAGE_NAME "$ENV_NAME" "$REPO" "$STAGE"
  gh_variable_set_env DATABASE_SCHEMA "$ENV_NAME" "$REPO" "$DATABASE_SCHEMA"
  gh_variable_set_env DATABASE_ENGINE "$ENV_NAME" "$REPO" "$DATABASE_ENGINE"
  gh_variable_set_env SLACK_CLIENT_ID "$ENV_NAME" "$REPO" "$SLACK_CLIENT_ID"
  if [[ -n "$DATABASE_HOST" ]]; then
    gh_variable_set_env DATABASE_HOST "$ENV_NAME" "$REPO" "$DATABASE_HOST"
    gh_variable_set_env DATABASE_ADMIN_USER "$ENV_NAME" "$REPO" "${DATABASE_ADMIN_USER:-}"
    gh_variable_set_env DATABASE_NETWORK_MODE "$ENV_NAME" "$REPO" "${DATABASE_NETWORK_MODE:-public}"
    if [[ "${DATABASE_NETWORK_MODE:-public}" == "private" ]]; then
      gh_variable_set_env DATABASE_SUBNET_IDS_CSV "$ENV_NAME" "$REPO" "${DATABASE_SUBNET_IDS_CSV:-}"
      gh_variable_set_env DATABASE_LAMBDA_SECURITY_GROUP_ID "$ENV_NAME" "$REPO" "${DATABASE_LAMBDA_SG_ID:-${DATABASE_LAMBDA_SECURITY_GROUP_ID:-}}"
    else
      gh_variable_set_env DATABASE_SUBNET_IDS_CSV "$ENV_NAME" "$REPO" ""
      gh_variable_set_env DATABASE_LAMBDA_SECURITY_GROUP_ID "$ENV_NAME" "$REPO" ""
    fi
    gh_variable_set_env DATABASE_PORT "$ENV_NAME" "$REPO" "${DATABASE_PORT:-}"
    gh_variable_set_env DATABASE_CREATE_APP_USER "$ENV_NAME" "$REPO" "${DATABASE_CREATE_APP_USER:-true}"
    gh_variable_set_env DATABASE_CREATE_SCHEMA "$ENV_NAME" "$REPO" "${DATABASE_CREATE_SCHEMA:-true}"
    gh_variable_set_env DATABASE_USERNAME_PREFIX "$ENV_NAME" "$REPO" "${DATABASE_USERNAME_PREFIX:-}"
    gh_variable_set_env DATABASE_APP_USERNAME "$ENV_NAME" "$REPO" "${DATABASE_APP_USERNAME:-}"
    gh_variable_set_env DATABASE_USER "$ENV_NAME" "$REPO" "${DATABASE_USER:-}"
  else
    gh_variable_set_env DATABASE_HOST "$ENV_NAME" "$REPO" ""
    gh_variable_set_env DATABASE_ADMIN_USER "$ENV_NAME" "$REPO" ""
    gh_variable_set_env DATABASE_NETWORK_MODE "$ENV_NAME" "$REPO" "public"
    gh_variable_set_env DATABASE_SUBNET_IDS_CSV "$ENV_NAME" "$REPO" ""
    gh_variable_set_env DATABASE_LAMBDA_SECURITY_GROUP_ID "$ENV_NAME" "$REPO" ""
    gh_variable_set_env DATABASE_PORT "$ENV_NAME" "$REPO" ""
    gh_variable_set_env DATABASE_CREATE_APP_USER "$ENV_NAME" "$REPO" "true"
    gh_variable_set_env DATABASE_CREATE_SCHEMA "$ENV_NAME" "$REPO" "true"
    gh_variable_set_env DATABASE_USERNAME_PREFIX "$ENV_NAME" "$REPO" ""
    gh_variable_set_env DATABASE_APP_USERNAME "$ENV_NAME" "$REPO" ""
    gh_variable_set_env DATABASE_USER "$ENV_NAME" "$REPO" ""
  fi
  echo "Setting GitHub environment secrets for '$ENV_NAME' (Slack, DATA_ENCRYPTION_KEY, DATABASE_PASSWORD, ...)..."
  gh secret set SLACK_SIGNING_SECRET --env "$ENV_NAME" --body "$SLACK_SIGNING_SECRET" -R "$REPO"
  gh secret set SLACK_CLIENT_SECRET --env "$ENV_NAME" --body "$SLACK_CLIENT_SECRET" -R "$REPO"
  gh secret set DATA_ENCRYPTION_KEY --env "$ENV_NAME" --body "$DATA_ENCRYPTION_KEY" -R "$REPO"
  gh secret set DATABASE_PASSWORD --env "$ENV_NAME" --body "$DATABASE_PASSWORD" -R "$REPO"
  [[ -n "${DATABASE_ADMIN_PASSWORD:-}" ]] && gh secret set DATABASE_ADMIN_PASSWORD --env "$ENV_NAME" --body "$DATABASE_ADMIN_PASSWORD" -R "$REPO"
  echo "GitHub environment '$ENV_NAME' updated for repo $REPO."
fi

echo
echo "=== Deploy Receipt ==="
write_deploy_receipt

echo
echo "=== Deploy Complete ==="
echo "Stack:       $STACK_NAME"
echo "Region:      $REGION"
echo "API URL:     ${SYNCBOT_API_URL:-n/a}"
echo "Install URL: ${SYNCBOT_INSTALL_URL:-n/a}"
if [[ -n "${SYNCBOT_API_URL:-}" ]]; then
  echo "OAuth URL:   ${SYNCBOT_API_URL%/slack/events}/slack/oauth_redirect"
fi
