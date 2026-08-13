using Microsoft.EntityFrameworkCore;
using XMobile.Customers.Domain;
using XMobile.Persistence;
using XMobile.Shared;

namespace XMobile.Customers.Infrastructure;

/// <summary>Implements the port XMobile.Tracking uses to build the journey engine's Home/Sites
/// Place list and to resolve an inbound geofence_event.geofence_id — see
/// XMobile.Shared.IGeofenceLookup.</summary>
public sealed class GeofenceLookupService(XMobileDbContext db) : IGeofenceLookup
{
    public async Task<GeofenceInfo?> GetByIdAsync(Guid geofenceId, CancellationToken ct)
    {
        var g = await db.Set<Geofence>().FirstOrDefaultAsync(x => x.Id == geofenceId && x.IsActive, ct);
        return g is null ? null : ToInfo(g);
    }

    public async Task<IReadOnlyList<GeofenceInfo>> GetByRefsAsync(
        IReadOnlyList<(string RefType, Guid RefId)> refs, CancellationToken ct)
    {
        if (refs.Count == 0)
        {
            return [];
        }

        var refTypes = refs.Select(r => r.RefType).Distinct().ToList();
        var refIds = refs.Select(r => r.RefId).ToList();

        // Filtered again in memory: EF can't translate "pair in a list of tuples" directly, and
        // this set is always small (home + a handful of a tour's planned sites).
        var candidates = await db.Set<Geofence>()
            .Where(g => g.IsActive && refTypes.Contains(g.RefType) && refIds.Contains(g.RefId))
            .ToListAsync(ct);

        var refSet = refs.ToHashSet();
        return candidates.Where(g => refSet.Contains((g.RefType, g.RefId))).Select(ToInfo).ToList();
    }

    private static GeofenceInfo ToInfo(Geofence g) => new(g.Id, g.RefType, g.RefId, g.Name, g.Geog.ToGeoPoint(), g.RadiusM);
}
