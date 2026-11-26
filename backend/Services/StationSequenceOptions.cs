namespace Backend.Services;

public sealed record StationSequenceOptions(string Id, string SourcePuesto)
{
    public bool Enabled => Id.Length > 0;
    public SemaphoreSlim ValidationGate { get; } = new(1, 1);

    public static StationSequenceOptions FromConfiguration(IConfiguration configuration)
    {
        var id = configuration["StationSequence:Id"]?.Trim() ?? "";
        var source = configuration["StationSequence:SourcePuesto"]?.Trim() ?? "";
        if ((id.Length == 0) != (source.Length == 0) ||
            id.Length > 20 || source.Length > 20 ||
            (id.Length > 0 && string.Equals(id, source, StringComparison.OrdinalIgnoreCase)))
        {
            throw new InvalidOperationException(
                "StationSequence requiere Id y SourcePuesto distintos de hasta 20 caracteres.");
        }
        return new StationSequenceOptions(id, source);
    }
}
