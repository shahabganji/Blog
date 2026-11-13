using Blog.Infra.Common;
using Pulumi;
using Pulumi.AzureNative.Storage;
using Pulumi.AzureNative.Storage.Inputs;

namespace Blog.Infra.Components;

internal sealed class StorageResources
{
    private const string AccountName = "codechef";

    public StorageResources(StackSettings settings, Output<string> resourceGroupName)
    {
        var accountId = $"{settings.ResourceGroupId}/providers/Microsoft.Storage/storageAccounts/{AccountName}";

        Account = new StorageAccount(AccountName, new StorageAccountArgs
        {
            ResourceGroupName = resourceGroupName,
            AccountName = AccountName,
            Location = settings.Location,
            Kind = Kind.StorageV2,
            Sku = new SkuArgs { Name = SkuName.Standard_LRS },
            AccessTier = AccessTier.Hot,
            EnableHttpsTrafficOnly = true,
            MinimumTlsVersion = MinimumTlsVersion.TLS1_2,
            AllowBlobPublicAccess = true,
            AllowSharedKeyAccess = true,
            AllowCrossTenantReplication = false,
            DefaultToOAuthAuthentication = false,
            PublicNetworkAccess = PublicNetworkAccess.Enabled,
            LargeFileSharesState = LargeFileSharesState.Enabled,
            DnsEndpointType = DnsEndpointType.Standard,
            CustomDomain = new CustomDomainArgs { Name = "images.shahab-the-guy.dev" },
            NetworkRuleSet = new NetworkRuleSetArgs
            {
                DefaultAction = DefaultAction.Allow,
                Bypass = Bypass.AzureServices,
            },
            Encryption = new EncryptionArgs
            {
                KeySource = KeySource.Microsoft_Storage,
                RequireInfrastructureEncryption = false,
                Services = new EncryptionServicesArgs
                {
                    Blob = new EncryptionServiceArgs { Enabled = true, KeyType = KeyType.Account },
                    File = new EncryptionServiceArgs { Enabled = true, KeyType = KeyType.Account },
                },
            },
            Tags = Tags.LegacyPurposeKey,
        }, BlogResourceOptions.For(
            settings,
            accountId,
            // Personal client-IP allow rules are maintained manually and are not managed here.
            ignoreChanges: ["networkRuleSet.ipRules"]));

        BlobService = new BlobServiceProperties("codechef-blob-service", new BlobServicePropertiesArgs
        {
            ResourceGroupName = resourceGroupName,
            AccountName = Account.Name,
            BlobServicesName = "default",
            DeleteRetentionPolicy = new DeleteRetentionPolicyArgs { Enabled = true, Days = 7, AllowPermanentDelete = false },
            ContainerDeleteRetentionPolicy = new DeleteRetentionPolicyArgs { Enabled = true, Days = 7 },
        }, BlogResourceOptions.For(settings, $"{accountId}/blobServices/default"));

        BlogContainer = new BlobContainer("codechef-blog-container", new BlobContainerArgs
        {
            ResourceGroupName = resourceGroupName,
            AccountName = Account.Name,
            ContainerName = "blog",
            PublicAccess = PublicAccess.Blob,
            DefaultEncryptionScope = "$account-encryption-key",
            DenyEncryptionScopeOverride = false,
        }, BlogResourceOptions.For(settings, $"{accountId}/blobServices/default/containers/blog", dependsOn: [BlobService]));

        LifecyclePolicy = new ManagementPolicy("codechef-lifecycle", new ManagementPolicyArgs
        {
            ResourceGroupName = resourceGroupName,
            AccountName = Account.Name,
            ManagementPolicyName = "default",
            Policy = new ManagementPolicySchemaArgs
            {
                Rules =
                {
                    new ManagementPolicyRuleArgs
                    {
                        Name = "Cost_Control",
                        Enabled = true,
                        Type = RuleType.Lifecycle,
                        Definition = new ManagementPolicyDefinitionArgs
                        {
                            Filters = new ManagementPolicyFilterArgs { BlobTypes = { "blockBlob" } },
                            Actions = new ManagementPolicyActionArgs
                            {
                                BaseBlob = new ManagementPolicyBaseBlobArgs
                                {
                                    TierToCool = new DateAfterModificationArgs { DaysAfterModificationGreaterThan = 180 },
                                    TierToCold = new DateAfterModificationArgs { DaysAfterModificationGreaterThan = 360 },
                                },
                            },
                        },
                    },
                },
            },
        }, BlogResourceOptions.For(settings, $"{accountId}/managementPolicies/default"));

        StaticWebsite = new StorageAccountStaticWebsite("codechef-static-website", new StorageAccountStaticWebsiteArgs
        {
            ResourceGroupName = resourceGroupName,
            AccountName = Account.Name,
            IndexDocument = "index.html",
        }, BlogResourceOptions.For(settings, $"{accountId}/staticWebsite"));
    }

    public StorageAccount Account { get; }

    public StorageAccountStaticWebsite StaticWebsite { get; }

    public BlobServiceProperties BlobService { get; }

    public BlobContainer BlogContainer { get; }

    public ManagementPolicy LifecyclePolicy { get; }
}
