using NetTopologySuite.Geometries;
using XMobile.Shared;

namespace XMobile.Persistence;

/// <summary>Converts between the wire-shape <see cref="GeoPoint"/> and the NTS <see cref="Point"/>
/// stored in every `geography(Point,4326)` column. NTS orders coordinates (X, Y) = (lon, lat).</summary>
public static class GeoPointExtensions
{
    public static Point ToNtsPoint(this GeoPoint point) => new(point.Lon, point.Lat) { SRID = 4326 };

    public static GeoPoint ToGeoPoint(this Point point, double? accuracyM = null) => new(point.Y, point.X, accuracyM);
}
