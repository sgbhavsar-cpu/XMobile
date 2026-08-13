using System.Text.Json;

namespace XMobile.Shared;

/// <summary>
/// `SyncMutationContext.Data` is a schema-free JSON bag (api/openapi.yaml: `additionalProperties:
/// true`) — every `ISyncEntityHandler.ApplyAsync` needs to pull typed fields out of it. Centralised
/// here so each handler doesn't re-write the same `TryGetProperty`/`ValueKind` checks.
/// </summary>
public static class SyncJson
{
    public static string? GetString(JsonElement data, string property)
        => data.TryGetProperty(property, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    public static Guid? GetGuid(JsonElement data, string property)
        => GetString(data, property) is { } s && Guid.TryParse(s, out var guid) ? guid : null;

    public static DateOnly? GetDateOnly(JsonElement data, string property)
        => GetString(data, property) is { } s && DateOnly.TryParse(s, out var date) ? date : null;

    public static TimeOnly? GetTimeOnly(JsonElement data, string property)
        => GetString(data, property) is { } s && TimeOnly.TryParse(s, out var time) ? time : null;

    public static DateTimeOffset? GetDateTimeOffset(JsonElement data, string property)
        => GetString(data, property) is { } s && DateTimeOffset.TryParse(s, out var dto) ? dto : null;

    public static bool? GetBool(JsonElement data, string property)
        => data.TryGetProperty(property, out var value) &&
           (value.ValueKind is JsonValueKind.True or JsonValueKind.False)
            ? value.GetBoolean()
            : null;

    public static short? GetInt16(JsonElement data, string property)
        => data.TryGetProperty(property, out var value) && value.ValueKind == JsonValueKind.Number
            ? value.GetInt16()
            : null;

    public static decimal? GetDecimal(JsonElement data, string property)
        => data.TryGetProperty(property, out var value) && value.ValueKind == JsonValueKind.Number
            ? value.GetDecimal()
            : null;

    public static GeoPoint? GetGeoPoint(JsonElement data, string property)
    {
        if (!data.TryGetProperty(property, out var point) || point.ValueKind != JsonValueKind.Object)
        {
            return null;
        }

        if (!point.TryGetProperty("lat", out var lat) || !point.TryGetProperty("lon", out var lon))
        {
            return null;
        }

        var accuracy = point.TryGetProperty("accuracyM", out var acc) && acc.ValueKind == JsonValueKind.Number
            ? acc.GetDouble() : (double?)null;
        return new GeoPoint(lat.GetDouble(), lon.GetDouble(), accuracy);
    }
}
