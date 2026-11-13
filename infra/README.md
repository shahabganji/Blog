# Blog infrastructure (Pulumi, C#)

Pulumi project that manages the Azure resources of the blog (subscription `prod-shahab-the-guy-blog`,
resource group `blog`). State lives in Pulumi Cloud: `shahabganji/blog-infra/prod`.

## Managed resources

| Area | Resources |
|---|---|
| Resource group (`Components/ResourceGroupResources.cs`) | `blog` |
| Monitoring (`Components/MonitoringResources.cs`) | App Insights `codechef`, action group `Application Insights Smart Detection` |
| Database (`Components/DatabaseResources.cs`) | SQL server `codechef`, Entra admin `SQL-DBA`, firewall rules, database `code_chef_blog` |
| Storage (`Components/StorageResources.cs`) | storage account `codechef` (custom domain `images.shahab-the-guy.dev`), blob service settings, container `blog`, lifecycle policy, static website |
| Web (`Components/WebAppResources.cs`) | App Service plan `codechef` (B1 Linux), web app `codechef`, app settings, custom domain bindings, SCM/FTP basic auth policies |

Every resource is `protect`ed, so Pulumi refuses to delete or replace it. The resource group also has an Azure `CanNotDelete` lock,
`del-lock-my-blog`. It is deliberately **not** managed by Pulumi and is maintained manually only: neither Pulumi nor the CI identity can change or remove it.

Not managed: App Service managed certificates (Azure renews them, so binding `sslState`/`thumbprint` changes are ignored), the
`shahab-the-guy.dev` DNS zone, Key Vault and the Log Analytics workspace (all in RG `default`), and the system `master` database.

## Usage

```bash
cd infra
pulumi login                 # Pulumi Cloud
az login                     # azure-native uses the az CLI credentials locally
pulumi stack select prod
pulumi preview --diff
pulumi up
```

### Configuration (`Pulumi.prod.yaml`)

| Key | Description |
|---|---|
| `azure-native:subscriptionId` / `azure-native:location` | Target subscription / default region |
| `appInsightsWorkspaceResourceId` | Log Analytics workspace App Insights is linked to (see follow-ups) |
| `sqlAdminPassword` (secret) | SQL admin password. Only sent when the server is created; changes are ignored |
| `sqlFirewallIps.<RULE>` (secret) | IPs for the `HOME_IP` / `SHQUER_HOME_IP` SQL firewall rules |
| `storageAllowedIps[n]` (secret) | IP rules of the storage firewall |
| `importExisting` (default `false`) | Adopt resources from Azure (`ImportId`) instead of creating them |

The IPs are secrets because this repository is public, for example `pulumi config set --secret --path sqlFirewallIps.HOME_IP 1.2.3.4`.

### How the resources were adopted

The code was written by hand from the live configuration (`az` CLI). Each resource passes its Azure id as `ImportId`
when `importExisting=true`:

```bash
pulumi preview --diff --config importExisting=true   # must show only "import" steps, no update/replace
pulumi up --config importExisting=true
pulumi config rm importExisting                      # `--config` is saved to Pulumi.<stack>.yaml; never commit it as true
pulumi preview --expect-no-changes                   # afterwards: everything unchanged
```

To rebuild the state (for example a new stack or backend), run the same commands again. Remove `importExisting` afterwards, otherwise
resources added later would try to import an Azure id that doesn't exist.
`ignoreChanges` is used only for values Azure computes or that don't apply to this Linux site. Ignoring them also keeps their current values on future updates.

## CI/CD

`master` only mirrors the upstream fork (linkdotnet/Blog) and is never deployed. `shahab` is the working branch.

| Workflow | Trigger | What it does |
|---|---|---|
| `infra.yml` (infra-preview) | PR into `shahab`, or push to `shahab` (only when `infra/**` changes) | `pulumi preview`, posted as a PR comment and on the run's summary page. **Never deploys.** |
| `infra-deploy.yml` (infra-deploy) | Push of a `release/v*` tag | `pulumi up` in the `prod` GitHub environment |

The preview report (`scripts/preview_report.py`) is a single PR comment, updated on every push. It shows:

- a coloured status box (no changes, changes, or replace/delete/failure);
- badges with the number of resources per operation;
- a table of the changed resources and their properties;
- the highlighted diff, with links to Pulumi Cloud, the run and the commit.

Merging into `shahab` is blocked by a repository ruleset while:

- the Copilot review is still running (its `copilot-pull-request-reviewer` check is required); or
- any review conversation is unresolved.

Copilot reviews every push automatically. Repo admins can still push directly, for example for upstream syncs. On a PR, an admin has to tick "bypass rules" explicitly to merge early.

Production deploys are guarded three ways:

- The `prod` environment requires approval from **@shahabganji** on every run.
- The environment only accepts `release/v*` tags, so branches cannot deploy.
- The job fails if the tagged commit is not on `shahab`.

Upstream uses plain `v*` tags, which is why the release tags have their own prefix.

```bash
git tag release/v1.0.0 && git push origin release/v1.0.0   # then approve the run in GitHub Actions
```

Azure authentication uses GitHub OIDC, so no client secret is stored. The setup is idempotent and can be re-run at any time:

```bash
infra/scripts/setup-ci-identity.sh                                  # identity, environment protection, branch ruleset, repo variables
PULUMI_ACCESS_TOKEN=<token> infra/scripts/setup-ci-identity.sh      # ...and also (re)set the Pulumi token secret
```

The script does the following:

- Creates two Entra apps:

  | App | Role on RG `blog` | Trusted for (OIDC subject) | Client id |
  |---|---|---|---|
  | `github-blog-infra` (deploy) | **Contributor** | the `prod` environment **only** | `prod` environment variable `AZURE_CLIENT_ID` |
  | `github-blog-infra-preview` | **Reader** | PRs and pushes to `shahab` | repo variable `AZURE_PREVIEW_CLIENT_ID` |

  Code from a PR runs in the preview job, so that job only gets read access. Write access requires the approved,
  tag-only `prod` environment. Neither app can modify or remove the delete lock (that needs `Microsoft.Authorization/locks/*`).
- Configures the `prod` environment and the `shahab` ruleset as described above.
- Sets the `AZURE_*` variables.

`PULUMI_ACCESS_TOKEN` is a repo secret because previews need it to read the state, so any same-repo branch can use it. Forks
can't, and Copilot agent PRs need your approval before workflows run. The token cannot write to Azure (the preview identity is
read-only), but it can read the stack's decrypted config. Only give write access to the repo to people you trust with that.

## Known follow-ups (intentionally not changed)

- **App Insights points at a stale workspace id.** It is linked to `DefaultResourceGroup-WEU/.../DefaultWorkspace-...-WEU`,
  but that resource group no longer exists. The workspace now lives in RG `default`. Check that telemetry still arrives,
  then update `appInsightsWorkspaceResourceId` and run `pulumi up`.
- The resource group and storage account are tagged `"Purpose "`, with a trailing space. To fix it, update `Tags.LegacyPurposeKey`.
- The storage account allows public blob access and shared-key auth. The app uses a connection string from the git-ignored
  `appsettings.Production.json`. Consider managed identity plus app settings or Key Vault references.
- The SQL server still allows SQL authentication (`azureADOnlyAuthentication: false`).
