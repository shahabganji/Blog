using Blog.Infra.Common;
using Blog.Infra.Components;
using Pulumi;

namespace Blog.Infra;

internal sealed class BlogInfrastructure : Stack
{
    public BlogInfrastructure()
    {
        var settings = new StackSettings();

        var resourceGroup = new ResourceGroupResources(settings);
        var resourceGroupName = resourceGroup.ResourceGroup.Name;

        var monitoring = new MonitoringResources(settings, resourceGroupName);
        var database = new DatabaseResources(settings, resourceGroupName);
        var storage = new StorageResources(settings, resourceGroupName);
        var webApp = new WebAppResources(settings, resourceGroupName, monitoring.AppInsights);

        WebAppDefaultHostName = webApp.Site.DefaultHostName;
        CustomDomains = Output.Create<IReadOnlyList<string>>(WebAppResources.CustomDomains);
        SqlServerFqdn = database.Server.FullyQualifiedDomainName;
        BlobEndpoint = storage.Account.PrimaryEndpoints.Apply(e => e.Blob);
        StaticWebsiteEndpoint = storage.Account.PrimaryEndpoints.Apply(e => e.Web);
    }

    [Output]
    public Output<string> WebAppDefaultHostName { get; set; }

    [Output]
    public Output<IReadOnlyList<string>> CustomDomains { get; set; }

    [Output]
    public Output<string> SqlServerFqdn { get; set; }

    [Output]
    public Output<string> BlobEndpoint { get; set; }

    [Output]
    public Output<string> StaticWebsiteEndpoint { get; set; }
}
