#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   GITHUB_TOKEN must be set as env var (or use gh auth)
#   ./apply_ruleset.sh <owner> <repo> "<status_check_name>"
#
# Example:
#   ./apply_ruleset.sh karthik-pro-engr architecting-state "Android CI / Build · Unit tests · Lint"

OWNER="$1"
REPO="$2"
STATUS_CHECK_NAME="${3-}"  # e.g. "Android CI / Build · Unit tests · Lint"
API="https://api.github.com/repos/${OWNER}/${REPO}/rulesets"

if [ -z "${GITHUB_TOKEN-}" ] && ! gh auth status >/dev/null 2>&1; then
  echo "ERROR: Set GITHUB_TOKEN environment variable or run 'gh auth login' first."
  exit 1
fi

echo "Creating branch ruleset 'protect-main' on ${OWNER}/${REPO} (target: refs/heads/main)"

# Compose checks array: if user supplied a name, include it. Otherwise leave empty (you can update later).
CHECKS_JSON="[]"
if [ -n "${STATUS_CHECK_NAME}" ]; then
  CHECKS_JSON="[ { \"name\": \"${STATUS_CHECK_NAME//\"/\\\"}\" } ]"
fi

# Note: this rule set will:
#  - require pull requests
#  - require the provided status check(s) (if provided)
#  - require 1 approving review
#  - dismiss stale approvals when new commits are pushed
#  - require code owner reviews (if a CODEOWNERS file exists)
#  - enforce admins, block force pushes and prevent deletions
#
# Important: For "Require review from Code Owners" to take effect, make sure a
# CODEOWNERS file exists on the base branch (usually main). If not present,
# the rule will still be created but code-owner reviews won't be enforced.

read -r -d '' PAYLOAD <<EOF
{
  "name":"protect-main",
  "target":"branch",
  "enforcement":"active",
  "conditions": {
    "ref_name": { "include": ["refs/heads/main"] }
  },
  "bypass_actors": [],
  "rules": [
    { "type": "pull_request_required", "parameters": {} },
    { "type": "required_status_checks", "parameters": { "checks": ${CHECKS_JSON}, "strict": true } },
    {
      "type": "require_approving_review_count",
      "parameters": {
        "count": 1,
        "dismiss_stale_reviews": true,
        "require_code_owner_reviews": true
      }
    },
    { "type": "enforce_admins", "parameters": { "enabled": true } },
    { "type": "block_force_pushes", "parameters": { "enabled": true } },
    { "type": "prevent_deletions", "parameters": { "enabled": true } }
  ]
}
EOF

# Use GITHUB_TOKEN if available, otherwise use gh api
if [ -n "${GITHUB_TOKEN-}" ]; then
  curl -sS -X POST \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${API}" -d "${PAYLOAD}" | jq .
else
  echo "${PAYLOAD}" > /tmp/payload.json
  gh api "${API}" -X POST -f /tmp/payload.json | jq .
fi

echo "Ruleset creation API called. If you included a status check name, ensure it matches exactly the check name shown on PRs."
