namespace Blog.Infra.Common;

internal static class Tags
{
    public static Dictionary<string, string> Default => new(StringComparer.Ordinal)
    {
        ["Env"] = "Prod",
        ["Owner"] = "Shahab",
        ["Purpose"] = "blog",
    };

    /// <summary>
    /// The resource group and the storage account were tagged with a trailing space in the
    /// "Purpose " key. Kept verbatim so Pulumi reflects the real state; fix in Azure and here together.
    /// </summary>
    public static Dictionary<string, string> LegacyPurposeKey => new(StringComparer.Ordinal)
    {
        ["Env"] = "Prod",
        ["Owner"] = "Shahab",
        ["Purpose "] = "blog",
    };
}
