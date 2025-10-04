#!/usr/bin/env bash
# scripts/apply_ruleset.sh
# Robust, debuggable ruleset creation/upsert script for admin-tools
#
# Usage:
#   export GITHUB_TOKEN="ghp_xxx"   # preferred (fine-grained PAT with repo admin)
#   ./apply_ruleset.sh <owner> <repo> "<status_check_name>"
#
# Example:
#   ./apply_ruleset.sh karthik-pro-engr architecting-state "Build · Unit tests · Lint"

set -euo pipefail
set -o errtrace

LOG_PREFIX="[apply_ruleset]"
timestamp(){ date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log(){ printf "%s %s %s\n" "$(timestamp)" "${LOG_PREFIX}" "$*"; }

# error trap to print context (no secrets)
on_error(){
  local exit_code=$?
  local last_cmd="${BASH_COMMAND:-unknown}"
  local caller_info
  caller_info=$(caller 0 2>/dev/null || true)
  log "ERROR: script failed with exit code ${exit_code}"
  log "ERROR: last command: ${last_cmd}"
  [ -n "${caller_info}" ] && log "ERROR: caller info: ${caller_info}"
  log "Dumping environment summary (sensitive values suppressed):"
  env | grep -E '^(USER=|HOME=|GITHUB_ACTIONS=|GITHUB_RUN_ID=|GITHUB_REPOSITORY=)' || true
  log "Exiting with ${exit_code}."
  exit "${exit_code}"
}
trap 'on_error' ERR

TMP_FILES=()
cleanup() {
  for f in "${TMP_FILES[@]:-}"; do
    [ -f "$f" ] && rm -f "$f" || true
  done
}
trap cleanup EXIT

has_cmd(){ command -v "$1" >/dev/null 2>&1; }

for cmd in curl jq date; do
  if ! has_cmd "$cmd"; then
    log "ERROR: required command '$cmd' not found. Install it."
    exit 10
  fi
done

OWNER="${1-}"
REPO="${2-}"
STATUS_CHECK_NAME="${3-:-}"

if [ -z "$OWNER" ] || [ -z "$REPO" ]; then
  log "ERROR: Missing arguments."
  printf "Usage: %s <owner> <repo> \"<status_check_name>\"\n" "$(basename "$0")"
  exit 2
fi

section(){ log "---- $* ----"; }

section "Start"
log "PID $$"
log "Owner: ${OWNER}"
log "Repo: ${REPO}"
if [ -n "$STATUS_CHECK_NAME" ]; then
  log "Status check: '${STATUS_CHECK_NAME}'"
else
  log "Status check: (none)"
fi

if [ -n "${GITHUB_TOKEN-}" ]; then
  log "GITHUB_TOKEN: present (value suppressed)"
else
  log "GITHUB_TOKEN: not present"
fi

if has_cmd gh; then
  log "gh CLI: $(gh --version | head -n1 || true)"
else
  log "gh CLI: not available"
fi

section "Build payload"

# Build the required_status_checks JSON fragment safely
if [ -n "$STATUS_CHECK_NAME" ]; then
  # escape any double quotes inside the name
  esc=$(printf '%s' "$STATUS_CHECK_NAME" | sed 's/"/\\"/g')
  req_checks_json="[ { \"context\": \"${esc}\" } ]"
else
  req_checks_json="[]"
fi

# Use a cat-heredoc assignment (robust in CI) instead of read -d ''
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
      "type": "pull_request",
      "parameters": {
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": true,
        "required_approving_review_count": 1
      }
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": true,
        "required_status_checks": ${req_checks_json}
      }
    },
    {
      "type": "non_fast_forward",
      "parameters": {}
    },
    {
      "type": "deletion",
      "parameters": {}
    }
  ]
}
EOF
)

log "Payload (raw):"
printf "%s\n" "$PAYLOAD"

# Pretty print if possible (don't fail if jq can't parse)
if printf "%s\n" "$PAYLOAD" | jq . >/dev/null 2>&1; then
  log "Payload (pretty):"
  printf "%s\n" "$PAYLOAD" | jq .
else
  log "Payload not valid JSON for pretty-print (will still send raw payload)."
fi

API_URL="https://api.github.com/repos/${OWNER}/${REPO}/rulesets"
section "POST ruleset (primary attempt)"
log "API URL: ${API_URL}"

# post payload using curl or gh fallback
post_with_curl() {
  local payload="$1"
  local respfile
  respfile=$(mktemp)
  TMP_FILES+=("$respfile")
  local status
  status=$(curl -sS -w "%{http_code}" -o "${respfile}" \
    -X POST "${API_URL}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    --data-binary "${payload}" || true)
  echo "${status}|${respfile}"
}

post_with_gh() {
  local payload="$1"
  local respfile
  respfile=$(mktemp)
  TMP_FILES+=("$respfile")
  printf "%s" "${payload}" > /tmp/_payload.json
  TMP_FILES+=("/tmp/_payload.json")
  if gh api "repos/${OWNER}/${REPO}/rulesets" -X POST -f /tmp/_payload.json > "${respfile}" 2>/tmp/_gh_err; then
    echo "201|${respfile}"
  else
    cat /tmp/_gh_err > "${respfile}" 2>/dev/null || true
    TMP_FILES+=("/tmp/_gh_err")
    echo "0|${respfile}"
  fi
}

if [ -n "${GITHUB_TOKEN-}" ]; then
  call_result=$(post_with_curl "$PAYLOAD")
else
  if has_cmd gh; then
    call_result=$(post_with_gh "$PAYLOAD")
  else
    log "ERROR: No GITHUB_TOKEN and no gh available; cannot call API."
    exit 3
  fi
fi

HTTP_STATUS=${call_result%%|*}
RESP_FILE=${call_result#*|}

log "HTTP status: ${HTTP_STATUS}"
log "Response (raw):"
[ -f "${RESP_FILE}" ] && sed -n '1,400p' "${RESP_FILE}" || true

if [ -f "${RESP_FILE}" ] && jq -e . >/dev/null 2>&1 < "${RESP_FILE}"; then
  log "Response (pretty):"
  jq . "${RESP_FILE}" || true
fi

if [[ "${HTTP_STATUS}" =~ ^2[0-9]{2}$ ]]; then
  log "SUCCESS: ruleset created/updated (status ${HTTP_STATUS})."
  exit 0
fi

if [ "${HTTP_STATUS}" = "422" ]; then
  log "ERROR 422: Validation failed. Response printed above."
  if [ -f "${RESP_FILE}" ] && jq -r '.message // empty' "${RESP_FILE}" >/dev/null 2>&1; then
    log "API message: $(jq -r '.message // empty' "${RESP_FILE}")"
  fi
  if [ -f "${RESP_FILE}" ] && jq -r '.errors // empty' "${RESP_FILE}" >/dev/null 2>&1; then
    log "API errors:"
    jq -r '.errors' "${RESP_FILE}" || true
  fi
  exit 6
fi

if [[ "${HTTP_STATUS}" =~ ^4|5 ]]; then
  log "ERROR: API returned HTTP ${HTTP_STATUS}. Response printed above."
  if [ "${HTTP_STATUS}" = "401" ]; then
    log "401 Unauthorized: token invalid or revoked."
  elif [ "${HTTP_STATUS}" = "403" ]; then
    log "403 Forbidden: token lacks permissions or token owner isn't an admin on the target repo."
  elif [ "${HTTP_STATUS}" = "404" ]; then
    log "404 Not Found: repo may be misspelled or token lacks access."
  fi
  exit 7
fi

log "Unexpected API response (status: ${HTTP_STATUS}). See response above."
exit 8
