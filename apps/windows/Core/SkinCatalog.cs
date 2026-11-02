using System;
using System.Collections.Generic;
using System.IO;

namespace Miucs.Windows;

public static class SkinCatalog
{
    public const long MaximumPreviewBytes = 20_000_000;
    public static bool IsRetired(string id) => id is "staff-note" or "pencil-flight";
    public static IEnumerable<string> PreviewCandidates(string directory)
    {
        foreach (string extension in new[] { "gif", "png", "webp", "jpg", "jpeg" })
        {
            string candidate = Path.Combine(directory, "preview." + extension);
            bool valid;
            try
            {
                var file = new FileInfo(candidate);
                valid = file.Exists && file.Length is > 0 and <= MaximumPreviewBytes &&
                    (file.Attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) == 0;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { valid = false; }
            if (valid) yield return candidate;
        }
    }
}
