using Blog.Infra.Common;
using Pulumi.AzureNative.Resources;

namespace Blog.Infra.Components;

/// <remarks>
/// The CanNotDelete lock "del-lock-my-blog" on this resource group is intentionally NOT managed by Pulumi:
/// it is maintained manually only, so neither Pulumi nor the CI identity can ever change or remove it.
/// </remarks>
internal sealed class ResourceGroupResources
{
    public ResourceGroupResources(StackSettings settings)
    {
        ResourceGroup = new ResourceGroup("blog", new ResourceGroupArgs
        {
            ResourceGroupName = settings.ResourceGroupName,
            Location = settings.Location,
            Tags = Tags.LegacyPurposeKey,
        }, BlogResourceOptions.For(settings, settings.ResourceGroupId));
    }

    public ResourceGroup ResourceGroup { get; }
}
