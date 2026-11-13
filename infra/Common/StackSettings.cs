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
        AppInsightsWorkspaceResourceId = config.Require("appInsightsWorkspaceResourceId");
    }

    public string SubscriptionId { get; }

    public string Location { get; }

    public string ResourceGroupName { get; }

    /// <summary>
    /// When true, resources are adopted from Azure via their resource id instead of being created.
    /// Only needed when (re)building the Pulumi state for already existing infrastructure.
    /// </summary>
    public bool ImportExisting { get; }

    /// <summary>
    /// Log Analytics workspace App Insights is linked to. Kept verbatim as Azure reports it: the workspace
    /// has since been moved to the "default" resource group, so this id is stale (see infra/README.md).
    /// </summary>
    public string AppInsightsWorkspaceResourceId { get; }

    public string ResourceGroupId => $"/subscriptions/{SubscriptionId}/resourceGroups/{ResourceGroupName}";
}
