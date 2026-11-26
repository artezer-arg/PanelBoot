namespace Backend.Services;

internal static class NoOrnamentPrinting
{
    public const string ConfigKey = "Auto_Print_No_Ornament";

    public static bool IsAutomatic(string? value) =>
        !string.Equals(value?.Trim(), "false", StringComparison.OrdinalIgnoreCase);
}
