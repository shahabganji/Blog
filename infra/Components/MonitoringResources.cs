using Blog.Infra.Common;
using Pulumi;
using Pulumi.AzureNative.ApplicationInsights;
using Pulumi.AzureNative.Monitor;

namespace Blog.Infra.Components;

internal sealed class MonitoringResources
{
    private const string SmartDetectionActionGroupName = "Application Insights Smart Detection";

    public MonitoringResources(StackSettings settings, Output<string> resourceGroupName)
    {
        AppInsights = new Component("codechef", new ComponentArgs
        {
            ResourceGroupName = resourceGroupName,
            ResourceName = "codechef",
            Location = settings.Location,
            Kind = "web",
            ApplicationType = ApplicationType.Web,
            FlowType = "Redfield",
            RequestSource = "IbizaWebAppExtensionCreate",
            RetentionInDays = 90,
            WorkspaceResourceId = settings.AppInsightsWorkspaceResourceId,
            PublicNetworkAccessForIngestion = PublicNetworkAccessType.Enabled,
            PublicNetworkAccessForQuery = PublicNetworkAccessType.Enabled,
            Tags = Tags.Default,
        }, BlogResourceOptions.For(
            settings,
            $"{settings.ResourceGroupId}/providers/microsoft.insights/components/codechef",
            // Azure reports "Disabled" (classic ingestion off) for workspace-based components; not a settable value.
            ignoreChanges: ["ingestionMode"]));

        SmartDetectionActionGroup = new ActionGroup("application-insights-smart-detection", new ActionGroupArgs
        {
            ResourceGroupName = resourceGroupName,
            ActionGroupName = SmartDetectionActionGroupName,
            Location = "Global",
            GroupShortName = "SmartDetect",
            Enabled = true,
            ArmRoleReceivers =
            {
                new Pulumi.AzureNative.Monitor.Inputs.ArmRoleReceiverArgs
                {
                    Name = "Monitoring Contributor",
                    RoleId = "749f88d5-cbae-40b8-bcfc-e573ddc772fa",
                    UseCommonAlertSchema = true,
                },
                new Pulumi.AzureNative.Monitor.Inputs.ArmRoleReceiverArgs
                {
                    Name = "Monitoring Reader",
                    RoleId = "43d0d8ad-25c7-4714-9337-8ba259a9fe05",
                    UseCommonAlertSchema = true,
                },
            },
        }, BlogResourceOptions.For(settings, $"{settings.ResourceGroupId}/providers/microsoft.insights/actionGroups/{SmartDetectionActionGroupName}"));
    }

    public Component AppInsights { get; }

    public ActionGroup SmartDetectionActionGroup { get; }
}
