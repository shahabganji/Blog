#!/usr/bin/env bash
# One-time setup for the PR comprehension quiz gate. Idempotent; needs gh (repo admin) and openssl.
#
#   .github/pr-quiz/setup.sh              create the keypair (if missing), the pr-quiz environment and its secret
#   .github/pr-quiz/setup.sh --rotate     generate a new keypair (old quizzes can no longer be graded); commit public.pem
#   .github/pr-quiz/setup.sh --activate   also make shahab the default branch and require the pr-quiz check on PRs into it
#   .github/pr-quiz/setup.sh --solo       also let the PR author answer (repository variable PR_QUIZ_ALLOW_AUTHOR=true), for a
#                                         single maintainer whose PRs are opened with their own account
#
# Why the default branch: GitHub only lists and dispatches workflow_dispatch workflows (the quiz's publish and answer forms)
# that exist on the default branch.
set -euo pipefail

REPO="${REPO:-shahabganji/Blog}"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-shahab}"
ENVIRONMENT="pr-quiz"
SECRET_NAME="PR_QUIZ_PRIVATE_KEY"
GITHUB_ACTIONS_APP_ID=15368
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROTATE=false ACTIVATE=false SOLO=false
for arg in "$@"; do
  case "$arg" in
    --rotate) ROTATE=true ;;
    --activate) ACTIVATE=true ;;
    --solo) SOLO=true ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# Environment that only the deploy branch can use, so workflows on PR branches cannot read the private key.
gh api --method PUT "repos/$REPO/environments/$ENVIRONMENT" --input - >/dev/null <<JSON
{ "deployment_branch_policy": { "protected_branches": false, "custom_branch_policies": true } }
JSON
if ! gh api "repos/$REPO/environments/$ENVIRONMENT/deployment-branch-policies" \
  --jq ".branch_policies[] | select(.name == \"$DEPLOY_BRANCH\" and .type == \"branch\") | .id" | grep -q .; then
  gh api --method POST "repos/$REPO/environments/$ENVIRONMENT/deployment-branch-policies" \
    -f name="$DEPLOY_BRANCH" -f type=branch >/dev/null
fi

has_secret() { gh secret list --repo "$REPO" --env "$ENVIRONMENT" --json name --jq '.[].name' | grep -qx "$SECRET_NAME"; }
if $ROTATE || [[ ! -f "$DIR/public.pem" ]] || ! has_secret; then
  OPENSSL="$(command -v /opt/homebrew/opt/openssl@3/bin/openssl || command -v openssl)"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  (umask 077 && "$OPENSSL" genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$tmp/private.pem" 2>/dev/null)
  "$OPENSSL" pkey -in "$tmp/private.pem" -pubout -out "$DIR/public.pem"
  gh secret set "$SECRET_NAME" --repo "$REPO" --env "$ENVIRONMENT" <"$tmp/private.pem"
  echo "New keypair: commit .github/pr-quiz/public.pem. The private key exists only in the $ENVIRONMENT environment secret."
else
  echo "Keypair already set up."
fi

if $ACTIVATE; then
  gh api --method PATCH "repos/$REPO" -f default_branch="$DEPLOY_BRANCH" >/dev/null
  echo "Default branch is now $DEPLOY_BRANCH."

  # A separate ruleset, so infra/scripts/setup-ci-identity.sh (which replaces its own ruleset) never drops this check.
  RULESET_NAME="${DEPLOY_BRANCH}: PR quiz"
  RULESET_JSON="$(cat <<JSON
{
  "name": "${RULESET_NAME}",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["refs/heads/${DEPLOY_BRANCH}"], "exclude": [] } },
  "bypass_actors": [ { "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always" } ],
  "rules": [
    { "type": "required_status_checks", "parameters": {
        "strict_required_status_checks_policy": false,
        "do_not_enforce_on_create": false,
        "required_status_checks": [ { "context": "pr-quiz", "integration_id": ${GITHUB_ACTIONS_APP_ID} } ] } }
  ]
}
JSON
)"
  RULESET_ID="$(gh api "repos/$REPO/rulesets" --jq ".[] | select(.name == \"$RULESET_NAME\") | .id")"
  if [[ -n "$RULESET_ID" ]]; then
    gh api --method PUT "repos/$REPO/rulesets/$RULESET_ID" --input - >/dev/null <<<"$RULESET_JSON"
  else
    gh api --method POST "repos/$REPO/rulesets" --input - >/dev/null <<<"$RULESET_JSON"
  fi
  echo "Ruleset '$RULESET_NAME' requires the pr-quiz check on PRs into $DEPLOY_BRANCH."
fi

if $SOLO; then
  gh variable set PR_QUIZ_ALLOW_AUTHOR --repo "$REPO" --body true
  echo "Solo mode: a PR author who is a repository admin can answer the quiz too. Undo with: gh variable delete PR_QUIZ_ALLOW_AUTHOR --repo $REPO"
fi
