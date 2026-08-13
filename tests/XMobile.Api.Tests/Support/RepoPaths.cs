using System.Runtime.CompilerServices;

namespace XMobile.Api.Tests.Support;

internal static class RepoPaths
{
    /// <summary>Walks up from this source file to find the repo root (marked by XMobile.sln),
    /// so the schema loader works regardless of the test output directory.</summary>
    public static string SchemaDirectory([CallerFilePath] string here = "")
    {
        var dir = new DirectoryInfo(Path.GetDirectoryName(here)!);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "XMobile.sln")))
        {
            dir = dir.Parent;
        }

        if (dir is null)
        {
            throw new InvalidOperationException($"Could not locate repo root (XMobile.sln) above {here}");
        }

        return Path.Combine(dir.FullName, "db", "schema");
    }
}
