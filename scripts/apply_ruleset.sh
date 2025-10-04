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

# Error handler prints helpful debug info (no secrets)
on_error(){
  local exit_code=$?
  # BASH_COMMAND is the last executed command, LINENO is line of trap definition; we want the line from caller
  local last_cmd="${BASH_COMMAND:-unknown}"
  # Try to get line number via caller
  local caller_info
  caller_info=$(caller 0 2>/dev/null || true)
  log "ERROR: script failed with exit code ${exit_code}"
  log "ERROR: last command: ${last_cmd}"
  if [ -n "${caller_info}" ]; then
    log "ERROR: caller info: ${caller_info}"
  fi
  log "Dumping environment summary (sensitive values suppressed):"
  # Show a few env vars but avoid printing tokens
  env | grep -E '^(USER=|HOME=|GITHUB_ACTIONS=|GITHUB_RUN_ID=|GITHUB_REPOSITORY=)' || true
  log "Exiting with ${exit_code}."
  exit "${exit_code}"
}
trap 'on_error' ERR

# ensure cleanup of temp files
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
# Escape status check safely
if [ -n "$STATUS_CHECK_NAME" ]; then
  esc=$(printf '%s' "$STATUS_CHECK_NAME" | sed 's/"/\\"/g')
  req_checks_json="[ { \"context\": \"${esc}\" } ]"
else
  req_checks_json="[]"
fi

# Canonical payload expected by Rulesets API
read -r -d '' PAYLOAD <<'PAYLOAD_EOF'
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
        "required_status_checks": REPLACE_REQUIRED_CHECKS
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
PAYLOAD_EOF

# Insert required_status_checks array
PAYLOAD="${PAYLOAD//REPLACE_REQUIRED_CHECKS/${req_checks_json}}"

log "Payload (raw):"
printf "%s\n" "$PAYLOAD"

# Try pretty print but don't fail if jq has trouble
if printf "%s\n" "$PAYLOAD" | jq . >/dev/null 2>&1; then
  log "Payload (pretty):"
  printf "%s\n" "$PAYLOAD" | jq .
else
  log "Payload not valid JSON for pretty-print (will still send raw payload)."
fi

API_URL="https://api.github.com/repos/${OWNER}/${REPO}/rulesets"
section "POST ruleset (primary attempt)"
log "API URL: ${API_URL}"

# helpers for API calls (curl) - will capture response and status
post_with_curl() {
  local payload="$1"
  local resp
  local status
  local respfile
  respfile=$(mktemp)
  TMP_FILES+=("$respfile")
  # Use --fail? no, we capture status ourselves
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
    # capture gh err output
    cat /tmp/_gh_err > "${respfile}" 2>/dev/null || true
    TMP_FILES+=("/tmp/_gh_err")
    echo "0|${respfile}"
  fi
}

# Choose transport
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
[ -f "${RESP_FILE}" ] && sed -n '1,200p' "${RESP_FILE}" || true

# Pretty print response when JSON
if [ -f "${RESP_FILE}" ] && jq -e . >/dev/null 2>&1 < "${RESP_FILE}"; then
  log "Response (pretty):"
  jq . "${RESP_FILE}" || true
fi

# If success
if [[ "${HTTP_STATUS}" =~ ^2[0-9]{2}$ ]]; then
  log "SUCCESS: ruleset created/updated (status ${HTTP_STATUS})."
  exit 0
fi

# If client error 422 show message and exit (but give detailed hint)
if [ "${HTTP_STATUS}" = "422" ]; then
  log "ERROR 422: Validation failed. Response printed above. The 'message' and 'errors' fields give the exact reason."
  # Try to surface 'message' and 'errors' if available
  if [ -f "${RESP_FILE}" ] && jq -r '.message // empty' "${RESP_FILE}" >/dev/null 2>&1; then
    log "API message: $(jq -r '.message // empty' "${RESP_FILE}")"
  fi
  if [ -f "${RESP_FILE}" ] && jq -r '.errors // empty' "${RESP_FILE}" >/dev/null 2>&1; then
    log "API errors:"
    jq -r '.errors' "${RESP_FILE}" || true
  fi
  exit 6
fi

# For other 4xx/5xx statuses, print helpful note
if [[ "${HTTP_STATUS}" =~ ^4|5 ]]; then
  log "ERROR: API returned HTTP ${HTTP_STATUS}. Response printed above."
  # If 401/403 provide guidance
  if [ "${HTTP_STATUS}" = "401" ]; then
    log "401 Unauthorized: token invalid or revoked."
  elif [ "${HTTP_STATUS}" = "403" ]; then
    log "403 Forbidden: token lacks permissions or token owner isn't an admin on the target repo."
  elif [ "${HTTP_STATUS}" = "404" ]; then
    log "404 Not Found: repo may be misspelled or token lacks access."
  fi
  exit 7
fi

# fallback
log "Unexpected API response (status: ${HTTP_STATUS}). See response above."
exit 8
