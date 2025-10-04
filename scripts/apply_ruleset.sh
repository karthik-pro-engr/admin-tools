#!/usr/bin/env bash
# scripts/apply_ruleset.sh
# Create / upsert a repository ruleset that protects main with required fields.
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

trap 'log "ERROR: script failed at line ${LINENO} (last cmd: ${BASH_COMMAND:-unknown}). Exiting."; exit 1' ERR

has_cmd(){ command -v "$1" >/dev/null 2>&1; }
for c in curl jq date; do
  if ! has_cmd "$c"; then
    echo "${LOG_PREFIX} ERROR: required command '$c' not found. Install it." >&2
    exit 10
  fi
done

OWNER="${1-}"
REPO="${2-}"
STATUS_CHECK_NAME="${3-:-}"

if [ -z "$OWNER" ] || [ -z "$REPO" ]; then
  cat <<USAGE
Usage: $0 <owner> <repo> "<status_check_name (optional)>"
Example: $0 karthik-pro-engr architecting-state "Build · Unit tests · Lint"
USAGE
  exit 2
fi

section(){ log "---- $* ----"; }

section "Start"
log "Owner: ${OWNER}"
log "Repo: ${REPO}"
if [ -n "$STATUS_CHECK_NAME" ]; then
  log "Status check: '${STATUS_CHECK_NAME}'"
else
  log "Status check: (none)"
fi
log "GITHUB_TOKEN: ${GITHUB_TOKEN:+present (suppressed) }"
if has_cmd gh; then log "gh: $(gh --version | head -n1)"; fi

# prepare escaped status check JSON item
if [ -n "$STATUS_CHECK_NAME" ]; then
  esc=$(printf '%s' "$STATUS_CHECK_NAME" | sed 's/"/\\"/g')
  STATUS_CHECK_JSON="{ \"context\": \"${esc}\" }"
else
  STATUS_CHECK_JSON=""
fi

# Build canonical payload that satisfies the Rulesets API required fields.
# Note: the pull_request.parameters object must include all required keys per docs.
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
        "allowed_merge_methods": ["merge", "squash", "rebase"],
        "automatic_copilot_code_review_enabled": false,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": true,
        "require_last_push_approval": false,
        "required_approving_review_count": 1,
        "required_review_thread_resolution": false,
        "required_status_checks": {
          "do_not_enforce_on_create": false,
          "required_status_checks": [],
          "strict_required_status_checks_policy": false
        }
      }
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "do_not_enforce_on_create": false,
        "required_status_checks": [
          $( [ -n "$STATUS_CHECK_JSON" ] && printf '%s' "${STATUS_CHECK_JSON}" || printf '' )
        ],
        "strict_required_status_checks_policy": true
      }
    },
    { "type": "non_fast_forward", "parameters": {} },
    { "type": "deletion", "parameters": {} }
  ]
}
EOF
)

section "Payload"
# Show raw and pretty if possible
log "Payload (raw):"
printf "%s\n" "$PAYLOAD"
if printf "%s\n" "$PAYLOAD" | jq . >/dev/null 2>&1; then
  log "Payload (pretty):"
  printf "%s\n" "$PAYLOAD" | jq .
fi

API_URL="https://api.github.com/repos/${OWNER}/${REPO}/rulesets"
section "Call API"
log "POST ${API_URL}"

TMPRESP="$(mktemp)"
# prefer GITHUB_TOKEN (set it in Actions as secrets.ADMIN_PAT -> env GITHUB_TOKEN)
if [ -n "${GITHUB_TOKEN-}" ]; then
  STATUS=$(curl -sS -w "%{http_code}" -o "${TMPRESP}" \
    -X POST "${API_URL}" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    --data-binary "${PAYLOAD}" || true)
else
  # fallback to gh
  printf "%s" "${PAYLOAD}" > /tmp/_payload_rules.json
  if gh api "repos/${OWNER}/${REPO}/rulesets" -X POST -f /tmp/_payload_rules.json > "${TMPRESP}" 2>/tmp/_gh_err; then
    STATUS=201
  else
    STATUS=0
    cat /tmp/_gh_err > "${TMPRESP}" || true
  fi
  rm -f /tmp/_payload_rules.json /tmp/_gh_err || true
fi

log "HTTP status: ${STATUS}"
log "Response (raw):"
cat "${TMPRESP}" || true
if jq -e . >/dev/null 2>&1 < "${TMPRESP}"; then
  log "Response (pretty):"
  jq . "${TMPRESP}" || true
fi

if [ "${STATUS}" -ge 200 ] && [ "${STATUS}" -lt 300 ]; then
  log "SUCCESS: ruleset created/updated (status ${STATUS})."
  rm -f "${TMPRESP}" || true
  exit 0
fi

# decode common failures
if [ "${STATUS}" = "422" ]; then
  log "ERROR 422: Validation failed. See response above. Typical causes:"
  log " - Missing a required parameter for a rule (pull_request parameters are strict)."
  log " - A field value has invalid type or name."
  exit 6
elif [ "${STATUS}" = "401" ]; then
  log "ERROR 401: Unauthorized — token invalid or revoked."
  exit 4
elif [ "${STATUS}" = "403" ]; then
  log "ERROR 403: Forbidden — token lacks required repo admin perms or token owner is not admin."
  exit 5
fi

log "Unhandled HTTP status ${STATUS}. See response above."
exit 7
