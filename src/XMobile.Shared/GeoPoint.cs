namespace XMobile.Shared;

/// <summary>Wire shape for `#/components/schemas/GeoPoint` in api/openapi.yaml.</summary>
public sealed record GeoPoint(double Lat, double Lon, double? AccuracyM = null);

/// <summary>
/// Great-circle distance for the one thing every module doing geofence math needs — deliberately
/// not a dependency on src/Modules/XMobile.Tracking.Engine, which is kept dependency-free by
/// design (see its .csproj) for CI trace-replay determinism.
/// </summary>
public static class GeoMath
{
    private const double EarthRadiusM = 6_371_000;

    public static double DistanceMeters(GeoPoint a, GeoPoint b)
    {
        var lat1 = DegToRad(a.Lat);
        var lat2 = DegToRad(b.Lat);
        var dLat = DegToRad(b.Lat - a.Lat);
        var dLon = DegToRad(b.Lon - a.Lon);

        var h = Math.Sin(dLat / 2) * Math.Sin(dLat / 2)
                + Math.Cos(lat1) * Math.Cos(lat2) * Math.Sin(dLon / 2) * Math.Sin(dLon / 2);
        return 2 * EarthRadiusM * Math.Asin(Math.Min(1, Math.Sqrt(h)));
    }

    private static double DegToRad(double deg) => deg * Math.PI / 180.0;
}
