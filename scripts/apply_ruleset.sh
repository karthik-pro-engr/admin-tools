#!/usr/bin/env bash
# scripts/apply_ruleset.sh
# Debuggable ruleset creation script for admin-tools
#
# Usage:
#   export GITHUB_TOKEN="ghp_xxx"   # OR ensure `gh auth login` has admin rights
#   ./apply_ruleset.sh <owner> <repo> "<status_check_name>"
#
# Example:
#   ./apply_ruleset.sh karthik-pro-engr architecting-state "Build · Unit tests · Lint"

set -euo pipefail

LOG_PREFIX="[apply_ruleset]"
timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { printf "%s %s %s\n" "$(timestamp)" "${LOG_PREFIX}" "$*"; }

section() { log "---- $* ----"; }

usage() {
  cat <<EOF
Usage:
  GITHUB_TOKEN must be set in env (preferred) OR gh must be authenticated.
  ./apply_ruleset.sh <owner> <repo> "<status_check_name>"

Examples:
  ./apply_ruleset.sh karthik-pro-engr architecting-state "Build · Unit tests · Lint"
EOF
  exit 2
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

section "Start"
log "Script invoked. PID $$"
if ! has_cmd curl; then
  log "ERROR: curl not found in PATH. Install curl."
  exit 10
fi
if ! has_cmd jq; then
  log "ERROR: jq not found in PATH. Install jq (used for pretty JSON output)."
  exit 11
fi
if ! has_cmd date; then
  log "ERROR: date not found in PATH."
  exit 12
fi

OWNER="${1-}"
REPO="${2-}"
STATUS_CHECK_NAME="${3-}"

if [ -z "$OWNER" ] || [ -z "$REPO" ]; then
  log "ERROR: Missing required arguments."
  usage
fi

section "Environment summary"
if [ -n "${GITHUB_TOKEN-}" ]; then
  log "GITHUB_TOKEN: present (value suppressed)"
else
  log "GITHUB_TOKEN: not present"
fi

if has_cmd gh; then
  GH_VERSION=$(gh --version | head -n1 || true)
  log "gh CLI: available - ${GH_VERSION}"
else
  log "gh CLI: not available"
fi

log "curl: $(curl --version | head -n1 | tr -s ' ' ' ' )"
log "jq: $(jq --version 2>/dev/null || true)"
log "Owner: ${OWNER}"
log "Repo: ${REPO}"
if [ -n "$STATUS_CHECK_NAME" ]; then
  log "Status check name provided: '${STATUS_CHECK_NAME}'"
else
  log "Status check name: (none) — ruleset will be created with empty required checks"
fi

section "Auth checks"
if [ -n "${GITHUB_TOKEN-}" ]; then
  log "Testing token: calling GET /user (token will not be printed)"
  HTTP_USER_STATUS=$(curl -s -o /tmp/_gh_user_resp -w "%{http_code}" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    https://api.github.com/user || true)
  log "GET /user HTTP status: ${HTTP_USER_STATUS}"
  if [ "${HTTP_USER_STATUS}" -ge 200 ] && [ "${HTTP_USER_STATUS}" -lt 300 ]; then
    log "Token test succeeded. Authenticated as:"
    jq -r '{login: .login, id: .id, name: .name} | @json' /tmp/_gh_user_resp 2>/dev/null || cat /tmp/_gh_user_resp
  else
    log "WARNING: token test failed (status ${HTTP_USER_STATUS}). Response body:"
    cat /tmp/_gh_user_resp || true
    log "If you're running in Actions, ensure the secret was set and mapped into env (e.g., GITHUB_TOKEN: \${{ secrets.ADMIN_PAT }}) and that token owner has admin rights to target repo."
  fi
  rm -f /tmp/_gh_user_resp || true
else
  log "No GITHUB_TOKEN set — will attempt to use 'gh' CLI if authenticated."
  if has_cmd gh; then
    if gh auth status >/dev/null 2>&1; then
      log "gh is authenticated; will use gh api fallback."
      gh auth status || true
    else
      log "ERROR: gh is not authenticated. Run 'gh auth login' or set GITHUB_TOKEN."
      exit 3
    fi
  else
    log "ERROR: Neither GITHUB_TOKEN nor gh auth available. Cannot proceed."
    exit 4
  fi
fi

section "Build ruleset payload"
CHECKS_JSON="[]"
if [ -n "$STATUS_CHECK_NAME" ]; then
  esc=$(printf '%s' "$STATUS_CHECK_NAME" | sed 's/"/\\"/g')
  CHECKS_JSON="[ { \"name\": \"${esc}\" } ]"
fi

PAYLOAD=$(cat <<EOF
{
  "name": "protect-main",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "ref_name": { "include": ["refs/heads/main"] }
  },
  "bypass_actors": [],
  "rules": [
    {
      "type": "pull_request_reviews",
      "parameters": {
        "required_approving_review_count": 0
      }
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "contexts": ["Build · Unit tests · Lint"],
        "strict": true
      }
    },
    {
      "type": "required_approving_review_count",
      "parameters": {
        "count": 1,
        "dismiss_stale_reviews": true,
        "require_code_owner_reviews": true
      }
    },
    {
      "type": "enforce_admins",
      "parameters": { "enabled": true }
    },
    {
      "type": "block_force_pushes",
      "parameters": { "enabled": true }
    },
    {
      "type": "prevent_deletions",
      "parameters": { "enabled": true }
    }
  ]
}

EOF
)

log "Payload to be sent (pretty-printed):"
printf "%s\n" "${PAYLOAD}" | jq .

API_URL="https://api.github.com/repos/${OWNER}/${REPO}/rulesets"
section "Calling GitHub API to create ruleset"
log "API endpoint: ${API_URL}"

TMP_RESP="$(mktemp)"
if [ -n "${GITHUB_TOKEN-}" ]; then
  log "Using GITHUB_TOKEN for API request (value suppressed)."
  HTTP_STATUS=$(curl -sS -w "%{http_code}" -o "${TMP_RESP}" \
    -X POST "${API_URL}" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    --data-binary "${PAYLOAD}" || true)
else
  log "Using gh api fallback (gh must be authenticated and authorized)."
  TMP_PAYLOAD="$(mktemp)"
  printf "%s" "${PAYLOAD}" > "${TMP_PAYLOAD}"
  if gh api "${API_URL}" -X POST -f @"${TMP_PAYLOAD}" > "${TMP_RESP}" 2>/tmp/gh_err; then
    HTTP_STATUS=200
  else
    HTTP_STATUS=$(cat /tmp/gh_err | sed -n '1p' | sed -n '1,1p' || echo "0")
  fi
  rm -f "${TMP_PAYLOAD}" /tmp/gh_err || true
fi

log "API HTTP status: ${HTTP_STATUS}"
log "Response body (raw):"
cat "${TMP_RESP}" || true

if jq -e . >/dev/null 2>&1 < "${TMP_RESP}"; then
  log "Response body (pretty JSON):"
  jq . "${TMP_RESP}" || true
else
  log "Response not valid JSON or empty. See raw above."
fi

if [ "${HTTP_STATUS}" -ge 200 ] && [ "${HTTP_STATUS}" -lt 300 ]; then
  log "SUCCESS: ruleset created or updated."
  rm -f "${TMP_RESP}"
  exit 0
fi

case "${HTTP_STATUS}" in
  401)
    log "ERROR 401: Unauthorized. Token invalid or revoked. Confirm PAT is correct and not expired."
    ;;
  403)
    log "ERROR 403: Forbidden. Token may lack required scopes or token owner may not have admin rights on target repo."
    log "Ensure token has 'Repository administration: read & write' (fine-grained) or 'repo' (classic) and the token owner is a repo admin."
    ;;
  404)
    log "ERROR 404: Not Found. Possible causes:"
    log " - The repository owner/repo is misspelled."
    log " - The token does not have access to the repository (fine-grained tokens must include this repo)."
    ;;
  422)
    log "ERROR 422: Validation failed. The payload may be invalid or a ruleset with the same name/target already exists with incompatible settings."
    ;;
  *)
    log "ERROR ${HTTP_STATUS}: Unexpected response. Inspect the response JSON above for details."
    ;;
esac

log "Cleanup tmp files and exit with failure (exit code 6)."
rm -f "${TMP_RESP}" || true
exit 6
