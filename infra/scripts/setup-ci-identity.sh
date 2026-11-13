#!/usr/bin/env bash
# One-time setup of the identity GitHub Actions uses to run Pulumi against the blog resource group.
# Creates (or reuses) an Entra app + service principal with GitHub OIDC federated credentials,
# grants it Contributor on the "blog" resource group only, and configures the GitHub repo:
#   - "prod" environment: REVIEWER must approve every deployment; only release/v* tags may deploy.
#   - ruleset on the deploy branch: no merge while the Copilot review runs or conversations are unresolved.
#   - AZURE_* variables and (when PULUMI_ACCESS_TOKEN is set) the PULUMI_ACCESS_TOKEN secret.
# Safe to re-run.
#
# Prerequisites: az (logged in to the target subscription), gh (authenticated). Optionally a Pulumi access
# token in PULUMI_ACCESS_TOKEN (https://app.pulumi.com/account/tokens) to (re)set the repo secret.
set -euo pipefail

REPO="${REPO:-shahabganji/Blog}"
RESOURCE_GROUP="${RESOURCE_GROUP:-blog}"
APP_NAME="${APP_NAME:-github-blog-infra}"
GH_ENVIRONMENT="${GH_ENVIRONMENT:-prod}"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-shahab}"
RELEASE_TAG_PATTERN="${RELEASE_TAG_PATTERN:-release/v*}"
REVIEWER="${REVIEWER:-$(gh api user -q .login)}"

SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
TENANT_ID="$(az account show --query tenantId -o tsv)"
RG_ID="$(az group show -n "$RESOURCE_GROUP" --query id -o tsv)"

APP_ID="$(az ad app list --display-name "$APP_NAME" --query '[0].appId' -o tsv)"
if [[ -z "$APP_ID" ]]; then
  APP_ID="$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)"
fi
az ad sp show --id "$APP_ID" >/dev/null 2>&1 || az ad sp create --id "$APP_ID" >/dev/null

add_federated_credential() {
  local name="$1" subject="$2"
  if ! az ad app federated-credential list --id "$APP_ID" --query "[?name=='$name']" -o tsv | grep -q .; then
    az ad app federated-credential create --id "$APP_ID" --parameters "{
      \"name\": \"$name\",
      \"issuer\": \"https://token.actions.githubusercontent.com\",
      \"subject\": \"$subject\",
      \"audiences\": [\"api://AzureADTokenExchange\"]
    }" >/dev/null
  fi
}
add_federated_credential "github-pull-request" "repo:${REPO}:pull_request"
add_federated_credential "github-branch-${DEPLOY_BRANCH}" "repo:${REPO}:ref:refs/heads/${DEPLOY_BRANCH}"
add_federated_credential "github-env-${GH_ENVIRONMENT}" "repo:${REPO}:environment:${GH_ENVIRONMENT}"

# Contributor deliberately lacks Microsoft.Authorization/locks/* : the CanNotDelete lock on the resource group
# is manual-only and must never be modifiable by CI (it is not part of the Pulumi program either).
SP_OBJECT_ID="$(az ad sp show --id "$APP_ID" --query id -o tsv)"
az role assignment create --assignee-object-id "$SP_OBJECT_ID" --assignee-principal-type ServicePrincipal \
  --role Contributor --scope "$RG_ID" >/dev/null

# prevent_self_review must stay false: the reviewer is also the one pushing the release tags.
REVIEWER_ID="$(gh api "users/${REVIEWER}" -q .id)"
gh api --method PUT "repos/${REPO}/environments/${GH_ENVIRONMENT}" --input - >/dev/null <<JSON
{
  "reviewers": [{ "type": "User", "id": ${REVIEWER_ID} }],
  "prevent_self_review": false,
  "deployment_branch_policy": { "protected_branches": false, "custom_branch_policies": true }
}
JSON
if ! gh api "repos/${REPO}/environments/${GH_ENVIRONMENT}/deployment-branch-policies" \
    -q ".branch_policies[] | select(.type == \"tag\" and .name == \"${RELEASE_TAG_PATTERN}\") | .id" | grep -q .; then
  gh api --method POST "repos/${REPO}/environments/${GH_ENVIRONMENT}/deployment-branch-policies" \
    -f name="$RELEASE_TAG_PATTERN" -f type=tag >/dev/null
fi

gh variable set AZURE_CLIENT_ID --repo "$REPO" --body "$APP_ID"
gh variable set AZURE_TENANT_ID --repo "$REPO" --body "$TENANT_ID"
gh variable set AZURE_SUBSCRIPTION_ID --repo "$REPO" --body "$SUBSCRIPTION_ID"
if [[ -n "${PULUMI_ACCESS_TOKEN:-}" ]]; then
  gh secret set PULUMI_ACCESS_TOKEN --repo "$REPO" --body "$PULUMI_ACCESS_TOKEN"
fi

# PRs into the deploy branch cannot be merged while the Copilot review is still running (its check is required)
# or while any review conversation is unresolved. Copilot reviews every push automatically.
# Repo admins may bypass (direct pushes such as upstream syncs); on PRs that needs an explicit "bypass rules" tick.
RULESET_NAME="${DEPLOY_BRANCH}: review before merge"
GITHUB_ACTIONS_APP_ID=15368
RULESET_JSON="$(cat <<JSON
{
  "name": "${RULESET_NAME}",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["refs/heads/${DEPLOY_BRANCH}"], "exclude": [] } },
  "bypass_actors": [ { "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always" } ],
  "rules": [
    { "type": "pull_request", "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": true,
        "allowed_merge_methods": ["merge", "squash", "rebase"] } },
    { "type": "required_status_checks", "parameters": {
        "strict_required_status_checks_policy": false,
        "do_not_enforce_on_create": false,
        "required_status_checks": [ { "context": "copilot-pull-request-reviewer", "integration_id": ${GITHUB_ACTIONS_APP_ID} } ] } },
    { "type": "copilot_code_review", "parameters": { "review_on_push": true, "review_draft_pull_requests": false } }
  ]
}
JSON
)"
RULESET_ID="$(gh api "repos/${REPO}/rulesets" -q ".[] | select(.name == \"${RULESET_NAME}\") | .id")"
if [[ -n "$RULESET_ID" ]]; then
  gh api --method PUT "repos/${REPO}/rulesets/${RULESET_ID}" --input - >/dev/null <<<"$RULESET_JSON"
else
  gh api --method POST "repos/${REPO}/rulesets" --input - >/dev/null <<<"$RULESET_JSON"
fi

echo "Done. App (client) id: $APP_ID"
