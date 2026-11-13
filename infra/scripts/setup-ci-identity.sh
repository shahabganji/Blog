#!/usr/bin/env bash
# Setup of the identities GitHub Actions uses to run Pulumi against the blog resource group. Safe to re-run.
# Both are user-assigned managed identities with GitHub OIDC federated credentials (no secrets, no app registrations),
# kept in their own resource group (IDENTITY_RG) on which CI has no rights, so CI can never add credentials to them.
#   - Deploy identity (DEPLOY_IDENTITY): Contributor on the "blog" resource group. Its federated credential trusts
#     ONLY jobs in the protected "prod" environment, and its client id is a "prod" environment variable.
#   - Preview identity (PREVIEW_IDENTITY): Reader on the "blog" resource group, trusted for pull requests and
#     pushes to the deploy branch. PR code runs in the preview job, so that job must not be able to write to Azure.
# It also configures the GitHub repo:
#   - "prod" environment: REVIEWER must approve every deployment; only release/v* tags may deploy.
#   - ruleset on the deploy branch: no merge while the Copilot review runs or conversations are unresolved.
#   - AZURE_* variables and (when PULUMI_ACCESS_TOKEN is set) the PULUMI_ACCESS_TOKEN secret.
#
# Prerequisites: az (logged in to the target subscription, Owner or User Access Administrator), gh (authenticated).
# Optionally a Pulumi access token in PULUMI_ACCESS_TOKEN (https://app.pulumi.com/account/tokens) to (re)set the repo secret.
set -euo pipefail

REPO="${REPO:-shahabganji/Blog}"
RESOURCE_GROUP="${RESOURCE_GROUP:-blog}"
IDENTITY_RG="${IDENTITY_RG:-github-ci}"
LOCATION="${LOCATION:-westeurope}"
DEPLOY_IDENTITY="${DEPLOY_IDENTITY:-id-github-blog-infra}"
PREVIEW_IDENTITY="${PREVIEW_IDENTITY:-id-github-blog-infra-preview}"
GH_ENVIRONMENT="${GH_ENVIRONMENT:-prod}"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-shahab}"
RELEASE_TAG_PATTERN="${RELEASE_TAG_PATTERN:-release/v*}"
REVIEWER="${REVIEWER:-$(gh api user -q .login)}"

SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
TENANT_ID="$(az account show --query tenantId -o tsv)"
RG_ID="$(az group show -n "$RESOURCE_GROUP" --query id -o tsv)"
az group create -n "$IDENTITY_RG" -l "$LOCATION" --tags Purpose=github-ci Owner=Shahab >/dev/null

ensure_identity() {
  az identity show -g "$IDENTITY_RG" -n "$1" >/dev/null 2>&1 || az identity create -g "$IDENTITY_RG" -n "$1" -l "$LOCATION" >/dev/null
}

add_federated_credential() {
  local identity="$1" name="$2" subject="$3"
  if ! az identity federated-credential show -g "$IDENTITY_RG" --identity-name "$identity" -n "$name" >/dev/null 2>&1; then
    az identity federated-credential create -g "$IDENTITY_RG" --identity-name "$identity" -n "$name" \
      --issuer "https://token.actions.githubusercontent.com" --subject "$subject" \
      --audiences "api://AzureADTokenExchange" >/dev/null
  fi
}

assign_role() {
  local identity="$1" role="$2" principal_id
  principal_id="$(az identity show -g "$IDENTITY_RG" -n "$identity" --query principalId -o tsv)"
  az role assignment create --assignee-object-id "$principal_id" --assignee-principal-type ServicePrincipal \
    --role "$role" --scope "$RG_ID" >/dev/null
}

# Deploy identity. Contributor deliberately lacks Microsoft.Authorization/locks/* : the CanNotDelete lock on the
# resource group is manual-only and must never be modifiable by CI (it is not part of the Pulumi program either).
ensure_identity "$DEPLOY_IDENTITY"
add_federated_credential "$DEPLOY_IDENTITY" "github-env-${GH_ENVIRONMENT}" "repo:${REPO}:environment:${GH_ENVIRONMENT}"
assign_role "$DEPLOY_IDENTITY" Contributor
DEPLOY_CLIENT_ID="$(az identity show -g "$IDENTITY_RG" -n "$DEPLOY_IDENTITY" --query clientId -o tsv)"

# Preview identity (read-only).
ensure_identity "$PREVIEW_IDENTITY"
add_federated_credential "$PREVIEW_IDENTITY" "github-pull-request" "repo:${REPO}:pull_request"
add_federated_credential "$PREVIEW_IDENTITY" "github-branch-${DEPLOY_BRANCH}" "repo:${REPO}:ref:refs/heads/${DEPLOY_BRANCH}"
assign_role "$PREVIEW_IDENTITY" Reader
PREVIEW_CLIENT_ID="$(az identity show -g "$IDENTITY_RG" -n "$PREVIEW_IDENTITY" --query clientId -o tsv)"

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
gh variable set AZURE_CLIENT_ID --repo "$REPO" --env "$GH_ENVIRONMENT" --body "$DEPLOY_CLIENT_ID"
gh variable delete AZURE_CLIENT_ID --repo "$REPO" >/dev/null 2>&1 || true
gh variable set AZURE_PREVIEW_CLIENT_ID --repo "$REPO" --body "$PREVIEW_CLIENT_ID"
gh variable set AZURE_TENANT_ID --repo "$REPO" --body "$TENANT_ID"
gh variable set AZURE_SUBSCRIPTION_ID --repo "$REPO" --body "$SUBSCRIPTION_ID"
if [[ -n "${PULUMI_ACCESS_TOKEN:-}" ]]; then
  gh secret set PULUMI_ACCESS_TOKEN --repo "$REPO" --body "$PULUMI_ACCESS_TOKEN"
fi

# PRs into the deploy branch cannot be merged while the Copilot review is still running or while any review
# conversation is unresolved. Copilot reviews every push automatically. The required check is the
# copilot-review-gate workflow, because Copilot's own check is never reported on the PR.
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
        "required_status_checks": [ { "context": "copilot-review-gate", "integration_id": ${GITHUB_ACTIONS_APP_ID} } ] } },
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

echo "Done. Deploy client id: $DEPLOY_CLIENT_ID, preview client id: $PREVIEW_CLIENT_ID"
