using Blog.Infra.Common;
using Pulumi;
using Pulumi.AzureNative.Sql;
using Pulumi.AzureNative.Sql.Inputs;

namespace Blog.Infra.Components;

internal sealed class DatabaseResources
{
    private const string ServerName = "codechef";
    private const string DatabaseName = "code_chef_blog";

    public DatabaseResources(StackSettings settings, Output<string> resourceGroupName)
    {
        var serverId = $"{settings.ResourceGroupId}/providers/Microsoft.Sql/servers/{ServerName}";

        Server = new Server(ServerName, new ServerArgs
        {
            ResourceGroupName = resourceGroupName,
            ServerName = ServerName,
            Location = settings.Location,
            Version = "12.0",
            AdministratorLogin = "shahab",
            MinimalTlsVersion = "1.2",
            PublicNetworkAccess = ServerPublicNetworkAccessFlag.Enabled,
            RestrictOutboundNetworkAccess = ServerNetworkAccessFlag.Disabled,
            Tags = Tags.Default,
        }, BlogResourceOptions.For(
            settings,
            serverId,
            // The admin password is managed outside Pulumi (Azure never returns it).
            // Entra admins are managed by the dedicated ServerAzureADAdministrator resource below.
            ignoreChanges: ["administratorLoginPassword", "administrators"]));

        EntraAdministrator = new ServerAzureADAdministrator("codechef-entra-admin", new ServerAzureADAdministratorArgs
        {
            ResourceGroupName = resourceGroupName,
            ServerName = Server.Name,
            AdministratorName = "ActiveDirectory",
            AdministratorType = AdministratorType.ActiveDirectory,
            Login = "SQL-DBA",
            Sid = "beb5f430-1ded-41f7-a06d-88dcccfc65f7",
            TenantId = "0c05d0ea-d039-4300-9bb4-66ee8ceb4e7c",
        }, BlogResourceOptions.For(settings, $"{serverId}/administrators/ActiveDirectory"));

        // Personal client-IP rules (HOME_IP, SHQUER_HOME_IP) are maintained manually and are not managed here.
        AllowAzureServicesRule = new FirewallRule("codechef-fw-AllowAllWindowsAzureIps", new FirewallRuleArgs
        {
            ResourceGroupName = resourceGroupName,
            ServerName = Server.Name,
            FirewallRuleName = "AllowAllWindowsAzureIps",
            Name = "AllowAllWindowsAzureIps",
            StartIpAddress = "0.0.0.0",
            EndIpAddress = "0.0.0.0",
        }, BlogResourceOptions.For(settings, $"{serverId}/firewallRules/AllowAllWindowsAzureIps"));

        Database = new Database(DatabaseName, new DatabaseArgs
        {
            ResourceGroupName = resourceGroupName,
            ServerName = Server.Name,
            DatabaseName = DatabaseName,
            Location = settings.Location,
            Sku = new SkuArgs { Name = "Basic", Tier = "Basic", Capacity = 5 },
            MaxSizeBytes = 2_147_483_648,
            Collation = "SQL_Latin1_General_CP1_CI_AS",
            CatalogCollation = CatalogCollationType.SQL_Latin1_General_CP1_CI_AS,
            ZoneRedundant = false,
            IsLedgerOn = false,
            AvailabilityZone = AvailabilityZoneType.NoPreference,
            ReadScale = DatabaseReadScale.Disabled,
            RequestedBackupStorageRedundancy = BackupStorageRedundancy.Zone,
            MaintenanceConfigurationId = $"/subscriptions/{settings.SubscriptionId}/providers/Microsoft.Maintenance/publicMaintenanceConfigurations/SQL_Default",
            Tags = Tags.Default,
        }, BlogResourceOptions.For(settings, $"{serverId}/databases/{DatabaseName}"));
    }

    public Server Server { get; }

    public ServerAzureADAdministrator EntraAdministrator { get; }

    public FirewallRule AllowAzureServicesRule { get; }

    public Database Database { get; }
}
