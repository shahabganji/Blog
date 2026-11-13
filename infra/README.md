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
pulumi preview --expect-no-changes                   # afterwards: everything unchanged
```

To rebuild the state (for example a new stack or backend), run the same commands again.
`ignoreChanges` is used only for values Azure computes or that don't apply to this Linux site. Ignoring them also keeps their current values on future updates.

## CI/CD

`master` only mirrors the upstream fork (linkdotnet/Blog) and is never deployed. `shahab` is the working branch.

| Workflow | Trigger | What it does |
|---|---|---|
| `infra.yml` (infra-preview) | PR into `shahab`, or push to `shahab` (only when `infra/**` changes) | `pulumi preview` (posted as a PR comment). **Never deploys.** |
| `infra-deploy.yml` (infra-deploy) | Push of a `release/v*` tag | `pulumi up` in the `prod` GitHub environment |

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
infra/scripts/setup-ci-identity.sh                                  # identity, environment protection, repo variables
PULUMI_ACCESS_TOKEN=<token> infra/scripts/setup-ci-identity.sh      # ...and also (re)set the Pulumi token secret
```

The script does the following:

- Creates the Entra app `github-blog-infra`, with federated credentials for PRs, the `shahab` branch and the `prod` environment.
- Grants it **Contributor on RG `blog` only**, which cannot modify or remove the delete lock (that requires `Microsoft.Authorization/locks/*`).
- Configures the `prod` environment as described above.
- Sets the `AZURE_*` repo variables.

## Known follow-ups (intentionally not changed)

- **App Insights points at a stale workspace id.** It is linked to `DefaultResourceGroup-WEU/.../DefaultWorkspace-...-WEU`,
  but that resource group no longer exists. The workspace now lives in RG `default`. Check that telemetry still arrives,
  then update `appInsightsWorkspaceResourceId` and run `pulumi up`.
- The resource group and storage account are tagged `"Purpose "`, with a trailing space. To fix it, update `Tags.LegacyPurposeKey`.
- The storage account allows public blob access and shared-key auth. The app uses a connection string from the git-ignored
  `appsettings.Production.json`. Consider managed identity plus app settings or Key Vault references.
- The SQL server still allows SQL authentication (`azureADOnlyAuthentication: false`).
