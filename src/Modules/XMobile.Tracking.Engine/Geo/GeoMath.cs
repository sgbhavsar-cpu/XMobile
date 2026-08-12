using XMobile.Tracking.Engine.Models;

namespace XMobile.Tracking.Engine.Geo;

/// <summary>Spherical geometry helpers. Metres throughout, to match PostGIS geography.</summary>
public static class GeoMath
{
    private const double EarthRadiusM = 6_371_008.8;   // IUGG mean radius

    public static double DistanceM(GeoPoint a, GeoPoint b)
    {
        // Haversine. Accurate to ~0.5% versus the ellipsoid, which is far below GPS noise
        // at the distances that matter here.
        var lat1 = ToRadians(a.Lat);
        var lat2 = ToRadians(b.Lat);
        var dLat = lat2 - lat1;
        var dLon = ToRadians(b.Lon - a.Lon);

        var h = Math.Sin(dLat / 2) * Math.Sin(dLat / 2)
              + Math.Cos(lat1) * Math.Cos(lat2) * Math.Sin(dLon / 2) * Math.Sin(dLon / 2);

        return 2 * EarthRadiusM * Math.Asin(Math.Min(1.0, Math.Sqrt(h)));
    }

    public static double BearingDeg(GeoPoint from, GeoPoint to)
    {
        var lat1 = ToRadians(from.Lat);
        var lat2 = ToRadians(to.Lat);
        var dLon = ToRadians(to.Lon - from.Lon);

        var y = Math.Sin(dLon) * Math.Cos(lat2);
        var x = Math.Cos(lat1) * Math.Sin(lat2) - Math.Sin(lat1) * Math.Cos(lat2) * Math.Cos(dLon);

        return (ToDegrees(Math.Atan2(y, x)) + 360) % 360;
    }

    /// <summary>Implied speed between two fixes, in km/h. Used for teleport detection.</summary>
    public static double ImpliedSpeedKmph(GeoPoint a, DateTimeOffset ta, GeoPoint b, DateTimeOffset tb)
    {
        var seconds = Math.Abs((tb - ta).TotalSeconds);
        if (seconds < 1) return 0;
        return DistanceM(a, b) / seconds * 3.6;
    }

    /// <summary>
    /// Path length, ignoring movements below the jitter threshold. A phone sitting on a desk
    /// generates hundreds of metres of fictional travel over an hour if you sum every fix.
    /// </summary>
    public static long PathLengthM(IReadOnlyList<GeoPoint> points, double jitterThresholdM)
    {
        double total = 0;
        for (var i = 1; i < points.Count; i++)
        {
            var step = DistanceM(points[i - 1], points[i]);
            if (step >= jitterThresholdM) total += step;
        }
        return (long)Math.Round(total);
    }

    /// <summary>Ramer-Douglas-Peucker simplification, so stored paths stay small but shaped.</summary>
    public static IReadOnlyList<GeoPoint> Simplify(IReadOnlyList<GeoPoint> points, double toleranceM)
    {
        if (points.Count <= 2) return points;

        var keep = new bool[points.Count];
        keep[0] = keep[^1] = true;
        SimplifySegment(points, 0, points.Count - 1, toleranceM, keep);

        var result = new List<GeoPoint>(points.Count);
        for (var i = 0; i < points.Count; i++)
            if (keep[i]) result.Add(points[i]);

        return result;
    }

    private static void SimplifySegment(
        IReadOnlyList<GeoPoint> points, int first, int last, double toleranceM, bool[] keep)
    {
        if (last <= first + 1) return;

        var maxDistance = 0.0;
        var maxIndex = first;

        for (var i = first + 1; i < last; i++)
        {
            var d = PerpendicularDistanceM(points[i], points[first], points[last]);
            if (d > maxDistance) { maxDistance = d; maxIndex = i; }
        }

        if (maxDistance <= toleranceM) return;

        keep[maxIndex] = true;
        SimplifySegment(points, first, maxIndex, toleranceM, keep);
        SimplifySegment(points, maxIndex, last, toleranceM, keep);
    }

    private static double PerpendicularDistanceM(GeoPoint point, GeoPoint lineStart, GeoPoint lineEnd)
    {
        // Local flat-earth projection: valid at the scale of a single simplification window.
        var latRad = ToRadians(lineStart.Lat);
        var mPerDegLat = 111_132.0;
        var mPerDegLon = 111_320.0 * Math.Cos(latRad);

        var px = (point.Lon - lineStart.Lon) * mPerDegLon;
        var py = (point.Lat - lineStart.Lat) * mPerDegLat;
        var ex = (lineEnd.Lon - lineStart.Lon) * mPerDegLon;
        var ey = (lineEnd.Lat - lineStart.Lat) * mPerDegLat;

        var lengthSquared = ex * ex + ey * ey;
        if (lengthSquared < 1e-9) return Math.Sqrt(px * px + py * py);

        var t = Math.Clamp((px * ex + py * ey) / lengthSquared, 0, 1);
        var dx = px - t * ex;
        var dy = py - t * ey;

        return Math.Sqrt(dx * dx + dy * dy);
    }

    /// <summary>Spread of a cluster: the largest distance from its centroid.</summary>
    public static double SpreadM(IReadOnlyList<GeoPoint> points)
    {
        if (points.Count < 2) return 0;

        var centroid = new GeoPoint(points.Average(p => p.Lat), points.Average(p => p.Lon));
        return points.Max(p => DistanceM(centroid, p));
    }

    private static double ToRadians(double degrees) => degrees * Math.PI / 180.0;
    private static double ToDegrees(double radians) => radians * 180.0 / Math.PI;
}
