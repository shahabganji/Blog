using Pulumi;

namespace Blog.Infra.Common;

internal static class BlogResourceOptions
{
    /// <summary>
    /// Every blog resource is protected against accidental deletion and can be adopted from Azure
    /// (<paramref name="azureResourceId"/>) when <see cref="StackSettings.ImportExisting"/> is set.
    /// </summary>
    public static CustomResourceOptions For(
        StackSettings settings,
        string azureResourceId,
        IEnumerable<string>? ignoreChanges = null,
        IEnumerable<Resource>? dependsOn = null)
    {
        var options = new CustomResourceOptions
        {
            Protect = true,
            ImportId = settings.ImportExisting ? azureResourceId : null,
        };

        if (ignoreChanges is not null)
        {
            options.IgnoreChanges.AddRange(ignoreChanges);
        }

        if (dependsOn is not null)
        {
            options.DependsOn = dependsOn.ToArray();
        }

        return options;
    }
}
