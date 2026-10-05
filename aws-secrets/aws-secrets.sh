#!/usr/bin/env bash
# See action.yml. Credentials stay inside this script: the role is assumed
# with the job's OIDC token and never exported to later steps.
set -euo pipefail
umask 077

ACCOUNT=907793002116
repo=${GITHUB_REPOSITORY#*/}
env_name=${INPUT_ENVIRONMENT:-}

if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]; then
  echo "::error::no OIDC token: add 'permissions: id-token: write' to the job"
  exit 1
fi

# Same naming as github-config terraform/ci_roles.tf and secrets/layout.py.
if [ -n "$env_name" ]; then
  role="github-ci/${repo}--$(printf '%s' "$env_name" | sed 's/[^A-Za-z0-9_+=,.@-]/_/g')"
  env_container="/github/${repo}/env/$(printf '%s' "$env_name" | sed 's/[^A-Za-z0-9_+=.@-]/_/g')"
  env_params="/github/${repo}/env/$(printf '%s' "$env_name" | sed 's/[^A-Za-z0-9_.-]/_/g')/"
else
  role="github-ci/${repo}"
  env_container=""
  env_params=""
fi

token=$(curl -sSf -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=sts.amazonaws.com" | jq -r .value)
echo "::add-mask::$token"
if ! creds=$(aws sts assume-role-with-web-identity --region "$AWS_REGION" \
    --role-arn "arn:aws:iam::${ACCOUNT}:role/${role}" \
    --role-session-name "gha-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT:-1}" \
    --web-identity-token "$token" --duration-seconds 900 \
    --query Credentials --output json 2>&1); then
  echo "::error::cannot assume ${role}: ${creds##*:}"
  echo "::error::the repo needs a secret or variable in zodl-inc/github-config, and an environment role needs the job to run in that environment"
  exit 1
fi
export AWS_ACCESS_KEY_ID=$(jq -r .AccessKeyId <<<"$creds")
export AWS_SECRET_ACCESS_KEY=$(jq -r .SecretAccessKey <<<"$creds")
export AWS_SESSION_TOKEN=$(jq -r .SessionToken <<<"$creds")
echo "::add-mask::$AWS_SECRET_ACCESS_KEY"
echo "::add-mask::$AWS_SESSION_TOKEN"
unset creds token

# JSON container -> {} when it is missing, empty, not JSON, or not readable.
read_container() {
  local v
  v=$(aws secretsmanager get-secret-value --region "$AWS_REGION" --secret-id "$1" \
    --query SecretString --output text 2>/dev/null) || v='{}'
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$v" && printf '%s' "$v" || echo '{}'
}

# Plain container (per-secret repos, org secrets) -> "" when missing.
read_plain() {
  aws secretsmanager get-secret-value --region "$AWS_REGION" --secret-id "$1" \
    --query SecretString --output text 2>/dev/null || true
}

export_value() {  # name value masked
  local delim
  delim="EOF_$(openssl rand -hex 16)"
  if [ "$3" = masked ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && echo "::add-mask::$line"
    done <<<"$2"
  fi
  printf '%s<<%s\n%s\n%s\n' "$1" "$delim" "$2" "$delim" >> "$GITHUB_ENV"
}

missing=()

if [ -n "${INPUT_SECRETS//[[:space:]]/}" ]; then
  repo_json=$(read_container "/github/${repo}/actions")
  env_json='{}'
  [ -n "$env_container" ] && env_json=$(read_container "$env_container")
  while IFS= read -r spec; do
    spec=$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<<"$spec")
    [ -z "$spec" ] && continue
    out=${spec%%=*}; name=${spec#*=}
    # environment JSON, environment per-secret, repo JSON, repo per-secret, org
    val=$(jq -r --arg k "$name" '.[$k] // empty' <<<"$env_json")
    [ -z "$val" ] && [ -n "$env_container" ] && val=$(read_plain "${env_container}/${name}")
    [ -z "$val" ] && val=$(jq -r --arg k "$name" '.[$k] // empty' <<<"$repo_json")
    [ -z "$val" ] && val=$(read_plain "/github/${repo}/${name}")
    [ -z "$val" ] && val=$(read_plain "/github/_org/${name}")
    if [ -z "$val" ]; then missing+=("secret $name"); continue; fi
    export_value "$out" "$val" masked
    echo "secret $out"
  done <<<"$INPUT_SECRETS"
  unset repo_json env_json val
fi

if [ -n "${INPUT_VARS//[[:space:]]/}" ]; then
  params='{}'
  for path in "/github/${repo}/" ${env_params:+"$env_params"}; do
    got=$(aws ssm get-parameters-by-path --region "$AWS_REGION" --path "$path" \
      --query 'Parameters[].{n:Name,v:Value}' --output json 2>/dev/null || echo '[]')
    params=$(jq --argjson got "$got" --arg p "$path" \
      '. + ($got | map({key: (.n | ltrimstr($p)), value: .v}) | from_entries)' <<<"$params")
  done
  while IFS= read -r spec; do
    spec=$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<<"$spec")
    [ -z "$spec" ] && continue
    out=${spec%%=*}; name=${spec#*=}
    val=$(jq -r --arg k "$name" '.[$k] // empty' <<<"$params")
    if [ -z "$val" ]; then
      val=$(aws ssm get-parameter --region "$AWS_REGION" --name "/github/_org/${name}" \
        --query Parameter.Value --output text 2>/dev/null || true)
    fi
    if [ -z "$val" ]; then missing+=("variable $name"); continue; fi
    export_value "$out" "$val" plain
    echo "variable $out"
  done <<<"$INPUT_VARS"
fi

if [ ${#missing[@]} -gt 0 ]; then
  printf '::error::not found or not readable: %s\n' "${missing[@]}"
  exit 1
fi
