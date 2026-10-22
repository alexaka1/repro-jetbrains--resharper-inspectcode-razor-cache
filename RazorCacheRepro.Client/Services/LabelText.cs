using RazorCacheRepro.Widgets;

namespace RazorCacheRepro.Client.Services;

public static class LabelText
{
    public static string Normalize(string value) => TextFormatter.Trim(value);
}
