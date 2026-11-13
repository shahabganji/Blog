#!/usr/bin/env bash
# Setup of the identities GitHub Actions uses to run Pulumi against the blog resource group. Safe to re-run.
#   - Deploy identity (APP_NAME): Contributor on the "blog" resource group. Its OIDC federated credential
#     trusts ONLY jobs in the protected "prod" environment, and its client id is a "prod" environment variable.
#   - Preview identity (PREVIEW_APP_NAME): Reader on the "blog" resource group, trusted for pull requests and
#     pushes to the deploy branch. PR code runs in the preview job, so that job must not be able to write to Azure.
# It also configures the GitHub repo:
#   - "prod" environment: REVIEWER must approve every deployment; only release/v* tags may deploy.
#   - ruleset on the deploy branch: no merge while the Copilot review runs or conversations are unresolved.
#   - AZURE_* variables and (when PULUMI_ACCESS_TOKEN is set) the PULUMI_ACCESS_TOKEN secret.
#
# Prerequisites: az (logged in to the target subscription), gh (authenticated). Optionally a Pulumi access
# token in PULUMI_ACCESS_TOKEN (https://app.pulumi.com/account/tokens) to (re)set the repo secret.
set -euo pipefail

REPO="${REPO:-shahabganji/Blog}"
RESOURCE_GROUP="${RESOURCE_GROUP:-blog}"
APP_NAME="${APP_NAME:-github-blog-infra}"
PREVIEW_APP_NAME="${PREVIEW_APP_NAME:-github-blog-infra-preview}"
GH_ENVIRONMENT="${GH_ENVIRONMENT:-prod}"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-shahab}"
RELEASE_TAG_PATTERN="${RELEASE_TAG_PATTERN:-release/v*}"
REVIEWER="${REVIEWER:-$(gh api user -q .login)}"

SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
TENANT_ID="$(az account show --query tenantId -o tsv)"
RG_ID="$(az group show -n "$RESOURCE_GROUP" --query id -o tsv)"

ensure_app() {
  local name="$1" app_id
  app_id="$(az ad app list --display-name "$name" --query '[0].appId' -o tsv)"
  if [[ -z "$app_id" ]]; then
    app_id="$(az ad app create --display-name "$name" --query appId -o tsv)"
  fi
  az ad sp show --id "$app_id" >/dev/null 2>&1 || az ad sp create --id "$app_id" >/dev/null
  echo "$app_id"
}

add_federated_credential() {
  local app_id="$1" name="$2" subject="$3"
  if ! az ad app federated-credential list --id "$app_id" --query "[?name=='$name']" -o tsv | grep -q .; then
    az ad app federated-credential create --id "$app_id" --parameters "{
      \"name\": \"$name\",
      \"issuer\": \"https://token.actions.githubusercontent.com\",
      \"subject\": \"$subject\",
      \"audiences\": [\"api://AzureADTokenExchange\"]
    }" >/dev/null
  fi
}

remove_federated_credential() {
  local app_id="$1" name="$2"
  if az ad app federated-credential list --id "$app_id" --query "[?name=='$name']" -o tsv | grep -q .; then
    az ad app federated-credential delete --id "$app_id" --federated-credential-id "$name" >/dev/null
  fi
}

assign_role() {
  local app_id="$1" role="$2" object_id
  object_id="$(az ad sp show --id "$app_id" --query id -o tsv)"
  az role assignment create --assignee-object-id "$object_id" --assignee-principal-type ServicePrincipal \
    --role "$role" --scope "$RG_ID" >/dev/null
}

# Deploy identity. Contributor deliberately lacks Microsoft.Authorization/locks/* : the CanNotDelete lock on the
# resource group is manual-only and must never be modifiable by CI (it is not part of the Pulumi program either).
APP_ID="$(ensure_app "$APP_NAME")"
add_federated_credential "$APP_ID" "github-env-${GH_ENVIRONMENT}" "repo:${REPO}:environment:${GH_ENVIRONMENT}"
remove_federated_credential "$APP_ID" "github-pull-request"
remove_federated_credential "$APP_ID" "github-branch-${DEPLOY_BRANCH}"
assign_role "$APP_ID" Contributor

# Preview identity (read-only).
PREVIEW_APP_ID="$(ensure_app "$PREVIEW_APP_NAME")"
add_federated_credential "$PREVIEW_APP_ID" "github-pull-request" "repo:${REPO}:pull_request"
add_federated_credential "$PREVIEW_APP_ID" "github-branch-${DEPLOY_BRANCH}" "repo:${REPO}:ref:refs/heads/${DEPLOY_BRANCH}"
assign_role "$PREVIEW_APP_ID" Reader

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

# The deploy client id lives only in the "prod" environment; jobs outside it get the read-only preview identity.
gh variable set AZURE_CLIENT_ID --repo "$REPO" --env "$GH_ENVIRONMENT" --body "$APP_ID"
gh variable delete AZURE_CLIENT_ID --repo "$REPO" >/dev/null 2>&1 || true
gh variable set AZURE_PREVIEW_CLIENT_ID --repo "$REPO" --body "$PREVIEW_APP_ID"
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

echo "Done. Deploy app (client) id: $APP_ID, preview app (client) id: $PREVIEW_APP_ID"
