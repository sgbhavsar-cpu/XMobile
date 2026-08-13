using Microsoft.EntityFrameworkCore;
using XMobile.Customers.Domain;
using XMobile.Persistence;
using XMobile.Shared;

namespace XMobile.Customers.Infrastructure;

/// <summary>Implements the port Planning and Visits use to resolve a site's customer and
/// geofence — see XMobile.Shared.ISiteLookup.</summary>
public sealed class SiteLookupService(XMobileDbContext db) : ISiteLookup
{
    public async Task<SiteInfo?> GetByIdAsync(Guid siteId, CancellationToken ct)
    {
        var site = await db.Set<CustomerSite>().FirstOrDefaultAsync(s => s.Id == siteId, ct);
        if (site is null)
        {
            return null;
        }

        var customerName = await db.Set<CustomerAccount>()
            .Where(c => c.Id == site.CustomerId).Select(c => c.Name).FirstOrDefaultAsync(ct);

        return new SiteInfo(
            site.Id, site.CustomerId, site.Name, customerName, site.GeofenceRadiusM,
            site.Geog?.ToGeoPoint(site.GeoAccuracyM));
    }
}
