using Pulumi;

namespace Blog.Infra.Common;

/// <summary>
/// Strongly typed view over the stack configuration (see Pulumi.&lt;stack&gt;.yaml).
/// </summary>
internal sealed class StackSettings
{
    public StackSettings()
    {
        var azure = new Config("azure-native");
        var config = new Config();

        SubscriptionId = azure.Require("subscriptionId");
        Location = azure.Require("location");
        ResourceGroupName = config.Get("resourceGroupName") ?? "blog";
        ImportExisting = config.GetBoolean("importExisting") ?? false;
        SqlAdminPassword = config.RequireSecret("sqlAdminPassword");
        SqlFirewallIps = config.RequireSecretObject<Dictionary<string, string>>("sqlFirewallIps");
        AppInsightsWorkspaceResourceId = config.Require("appInsightsWorkspaceResourceId");
        StorageAllowedIps = config.RequireSecretObject<string[]>("storageAllowedIps");
    }

    public string SubscriptionId { get; }

    public string Location { get; }

    public string ResourceGroupName { get; }

    /// <summary>
    /// When true, resources are adopted from Azure via their resource id instead of being created.
    /// Only needed when (re)building the Pulumi state for already existing infrastructure.
    /// </summary>
    public bool ImportExisting { get; }

    public Output<string> SqlAdminPassword { get; }

    /// <summary>Firewall rule name → IPv4 address. Stored as a secret because the repository is public.</summary>
    public Output<Dictionary<string, string>> SqlFirewallIps { get; }

    /// <summary>
    /// Log Analytics workspace App Insights is linked to. Kept verbatim as Azure reports it: the workspace
    /// has since been moved to the "default" resource group, so this id is stale (see infra/README.md).
    /// </summary>
    public string AppInsightsWorkspaceResourceId { get; }

    /// <summary>IP rules on the storage firewall (inactive while the default action is Allow). Secret: public repo.</summary>
    public Output<string[]> StorageAllowedIps { get; }

    public string ResourceGroupId => $"/subscriptions/{SubscriptionId}/resourceGroups/{ResourceGroupName}";
}
