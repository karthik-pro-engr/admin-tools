#!/usr/bin/env bash
# scripts/apply_classic_protection.sh
# Apply classic branch protection to a single branch (main by default)
#
# Usage:
#   export GITHUB_TOKEN="ghp_xxx"   # PAT with repo admin rights, or use gh auth
#   ./scripts/apply_classic_protection.sh <owner> <repo> [branch] "<status_check_name>"
#
# Example:
#   ./scripts/apply_classic_protection.sh karthik-pro-engr architecting-state main "Build · Unit tests · Lint"

set -euo pipefail

LOG_PREFIX="[apply_classic_protection]"
timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { printf "%s %s %s\n" "$(timestamp)" "${LOG_PREFIX}" "$*"; }

usage(){
  cat <<EOF
Usage:
  GITHUB_TOKEN must be set (preferred) OR gh must be authenticated.
  ./apply_classic_protection.sh <owner> <repo> [branch] "<status_check_name>"

Examples:
  ./scripts/apply_classic_protection.sh karthik-pro-engr architecting-state main "Build · Unit tests · Lint"
EOF
  exit 2
}

has_cmd(){ command -v "$1" >/dev/null 2>&1; }

log "Start"
if ! has_cmd curl; then log "ERROR: curl required"; exit 10; fi
if ! has_cmd jq; then log "ERROR: jq required"; exit 11; fi

OWNER="${1-}"
REPO="${2-}"
BRANCH="${3-main}"
STATUS_CHECK_NAME="${4-}"

if [ -z "$OWNER" ] || [ -z "$REPO" ]; then
  log "ERROR: missing args"
  usage
fi

log "Owner: ${OWNER}"
log "Repo : ${REPO}"
log "Branch: ${BRANCH}"
if [ -n "$STATUS_CHECK_NAME" ]; then
  log "Status check: '${STATUS_CHECK_NAME}'"
else
  log "Status check: (none) — contexts will be empty array"
fi

# auth check
if [ -n "${GITHUB_TOKEN-}" ]; then
  log "Using GITHUB_TOKEN (value suppressed) to test access..."
  HTTP_U=$(curl -s -o /tmp/_uresp -w "%{http_code}" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    https://api.github.com/user || true)
  log "GET /user HTTP status: ${HTTP_U}"
  if [ "${HTTP_U}" -ge 200 ] && [ "${HTTP_U}" -lt 300 ]; then
    log "Token OK; authenticated as: $(jq -r '.login' /tmp/_uresp || cat /tmp/_uresp)"
  else
    log "ERROR: token test failed (status ${HTTP_U}). Response:"
    cat /tmp/_uresp || true
    rm -f /tmp/_uresp
    exit 1
  fi
  rm -f /tmp/_uresp
else
  if has_cmd gh && gh auth status >/dev/null 2>&1; then
    log "No GITHUB_TOKEN but gh CLI authenticated; we'll use gh if needed."
  else
    log "ERROR: Neither GITHUB_TOKEN set nor gh authenticated."
    usage
  fi
fi

# Construct JSON payload safely with jq (handles quotes properly).
# required_status_checks must always include both strict and contexts properties (contexts can be empty array).
if [ -n "$STATUS_CHECK_NAME" ]; then
  CONTEXTS_JSON=$(jq -nc --arg ctx "$STATUS_CHECK_NAME" '[$ctx]')
else
  CONTEXTS_JSON='[]'
fi

# Build the payload using jq so it's valid JSON
PAYLOAD=$(jq -n \
  --argjson contexts "$CONTEXTS_JSON" \
  '{
    required_status_checks: { strict: true, contexts: $contexts },
    enforce_admins: true,
    required_pull_request_reviews: {
      dismiss_stale_reviews: true,
      require_code_owner_reviews: true,
      required_approving_review_count: 1
    },
    restrictions: null
  }'
)

log "Payload (pretty):"
printf "%s\n" "$PAYLOAD" | jq .

API="https://api.github.com/repos/${OWNER}/${REPO}/branches/${BRANCH}/protection"

TMP_RESP="$(mktemp)"
log "Calling API: PUT ${API}"
if [ -n "${GITHUB_TOKEN-}" ]; then
  HTTP_STATUS=$(curl -sS -o "${TMP_RESP}" -w "%{http_code}" -X PUT \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    --data "${PAYLOAD}" \
    "${API}" || true)
else
  # fallback to gh
  printf "%s" "$PAYLOAD" > "${TMP_RESP}.payload"
  if gh api "${API}" -X PUT -f @"${TMP_RESP}.payload" > "${TMP_RESP}" 2>/tmp/gh_err; then
    HTTP_STATUS=200
  else
    HTTP_STATUS=$(sed -n '1p' /tmp/gh_err || echo "0")
  fi
  rm -f "${TMP_RESP}.payload" /tmp/gh_err || true
fi

log "HTTP status: ${HTTP_STATUS}"
log "Response body:"
cat "${TMP_RESP}" || true

# Accept 200 (updated), 201 (created) or 204 (no content)
if [ "${HTTP_STATUS}" = "200" ] || [ "${HTTP_STATUS}" = "201" ] || [ "${HTTP_STATUS}" = "204" ]; then
  log "SUCCESS: branch protection applied for ${OWNER}/${REPO}@${BRANCH}"
  rm -f "${TMP_RESP}"
  exit 0
fi

log "ERROR: API returned ${HTTP_STATUS}. Try the response above to see details."
if [ -s "${TMP_RESP}" ]; then
  printf "\nPretty JSON (if any):\n"
  if jq -e . >/dev/null 2>&1 < "${TMP_RESP}"; then
    jq . "${TMP_RESP}" || true
  fi
fi

rm -f "${TMP_RESP}" || true
exit 5
