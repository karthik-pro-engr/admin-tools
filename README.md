DESCRIPTION

Automates applying branch protection rulesets to newly created repositories — bootstraps secure defaults (require PRs, CI status checks, block force-pushes, prevent deletions).

---

# Admin Tools — Ruleset Automation

This repository contains admin tooling and a GitHub Action to automate creation and application of branch protection rulesets for newly created repositories. It bootstraps repos with a secure default posture so teams can ship safely and consistently.

> Purpose: make new repositories safe by default (require PRs, require CI checks, block destructive pushes) — a small but high-impact step toward production-grade engineering.

## Features

- **Protect the `main` branch**
    - Applies to `refs/heads/main`.
    - Prevents accidental force pushes and branch deletion.

- **Require a pull request before merging**
    - At least one approving review required.
    - **Dismiss stale pull request approvals** when new commits are pushed.
    - **Require review from Code Owners** (if `.github/CODEOWNERS` is defined).
    - Block direct pushes; enforce merges via PR only.

- **Require status checks to pass before merging**
    - Optionally specify one or more required CI checks (e.g., `Android CI / Build · Unit tests · Lint`).
    - Strict mode: branch must be up-to-date with `main` before merging.

- **Enforce for administrators**
    - Admins are not exempt from rules (no silent bypass).

- **Security hardening**
    - Block force-pushes (`git push --force`) to preserve history.
    - Prevent deletion of the protected branch.

- **Automation options**
    - Run locally with a GitHub personal access token (PAT) or `gh auth`.
    - Run automatically from a secure admin GitHub Action (`workflow_dispatch`).

## Repository layout

```
repo-root/
├─ .github/
│  └─ workflows/
│     └─ apply-ruleset.yml         # admin workflow (workflow_dispatch)
├─ scripts/
│  └─ apply_ruleset.sh            # script that calls GitHub API to create ruleset
├─ README.md                      # this file
```

## Quick start — Local run

1. Generate a **fine-grained** Personal Access Token (PAT) with minimal permissions (see next section). Copy it now.
2. Save `apply_ruleset.sh` locally and make it executable:

```bash
chmod +x scripts/apply_classic_protection_ruleset.sh
```

3. Export the PAT into your shell session (temporary):

```bash
export ADMIN_PAT="ghp_xxx..." # paste your fine-grained token here
export GITHUB_TOKEN="$ADMIN_PAT"  # script expects GITHUB_TOKEN variable
```

4. Run the script with parameters: `OWNER` `REPO` and the exact status check name (copy from PR checks UI):

```bash
./scripts/apply_classic_protection_ruleset.sh karthik-pro-engr architecting-state "Android CI / Build · Unit tests · Lint"
```

5. When finished, unset the token from your shell:

```bash
unset GITHUB_TOKEN
unset ADMIN_PAT
```

## Quick start — Run from GitHub (Admin repo)

1. Create this admin repo (private recommended) and add `scripts/apply_ruleset.sh` and `.github/workflows/apply-ruleset.yml`.
2. Generate a fine-grained PAT and add it to the admin repo secrets as `ADMIN_PAT`.
3. In the Actions tab, select **Apply Branch Ruleset (Admin)** → **Run workflow** and provide:
   - `owner`: repository owner (user or org)
   - `repo`: repository name
   - `status_check`: exact status check name (optional; can be added later)

The workflow will run the script using the secret token and apply the ruleset.

## Fine-grained PAT: minimal permission checklist

When creating the token, follow these minimal permissions for safety:
- Resource owner: your user/org
- Repository access: **Only select repositories** → add the target repo(s)
- Permissions:
  - **Repository → Administration**: Read & write (needed to create rulesets)
  - **Checks**: Read & write (if the script will reference checks)
  - (Optional) **Contents → Read** if script needs to inspect repo files
- Set a reasonable expiration; rotate tokens regularly.

> If possible for long-term automation, prefer a GitHub App (installable) instead of a PAT.

## How the script behaves

- If you provide a `status_check` string it will be placed into `required_status_checks` for the ruleset.
- If you omit `status_check` the script creates the ruleset with an empty checks array — update it later after the CI check has run once and you know the exact name.
- The script will enable: pull request requirement, required status checks (strict), require 1 approving review, enforce admins, block force pushes, and prevent branch deletions. Customize in `scripts/apply_ruleset.sh` as needed.

## Security & operational notes

- Keep this repo **private** or strictly limit who can run workflows.
- Protect branches in this admin repo (require PRs, reviews) so its workflows/secrets aren’t abused.
- Use least privilege for tokens; rotate tokens periodically.
- Test the flow in a sandbox repo before running in production.

## Example: Update ruleset after CI shows check names

1. Create or update a PR in the target repo so CI runs at least once.
2. Copy the exact check title shown on the PR checks UI.
3. Re-run the script (local or admin workflow) supplying that check title to make it required.

## Troubleshooting

- **403 / Permission denied**: token lacks repo administration rights or is not scoped to the target repo. Recreate token with correct permissions and re-run.
- **Status check not selectable**: the check must have run at least once on the repo/PR before you can require it in the ruleset. Run CI first and then update ruleset.

## License & contribution

This admin-tooling is provided "as-is". If you plan to share or use in an organization, consider adding a LICENSE and internal documentation for token rotation and audit procedures.

---


