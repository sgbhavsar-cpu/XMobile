using Microsoft.Extensions.DependencyInjection;
using NetTopologySuite.Geometries;
using XMobile.Customers.Domain;
using XMobile.Identity.Domain;
using XMobile.Persistence;

namespace XMobile.Api.Tests.Support;

/// <summary>
/// Seeds rows with no endpoint of their own in this increment — home-location capture and
/// customer/site data both come from paths not built yet (a home-location endpoint isn't in
/// api/openapi.yaml at all; customers come from the XInfo import job, Phase 3). Writing directly
/// via XMobileDbContext outside a request resolves ICurrentUser to the Guid.Empty sentinel (see
/// XMobileDbContext.SaveChangesAsync), so these seed writes correctly leave actor_id NULL.
/// </summary>
internal static class TestData
{
    public static async Task<Guid> SeedHomeLocationAsync(
        ApiFactory factory, Guid userId, double lat = 18.52, double lon = 73.85, int radiusM = 200)
    {
        using var scope = factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<XMobileDbContext>();

        var home = new UserHomeLocation
        {
            UserId = userId,
            Label = "Home",
            City = "Pune",
            Geog = new Point(lon, lat) { SRID = 4326 },
            GeofenceRadiusM = radiusM,
            EffectiveFrom = DateOnly.FromDateTime(DateTime.UtcNow),
        };
        db.Add(home);
        await db.SaveChangesAsync();
        return home.Id;
    }

    public static async Task<(Guid CustomerId, Guid SiteId)> SeedCustomerWithSiteAsync(
        ApiFactory factory, Guid assignedUserId, double lat = 18.52, double lon = 73.85)
    {
        using var scope = factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<XMobileDbContext>();

        var customer = new CustomerAccount { Name = "Test Distributors", AccountType = "DISTRIBUTOR" };
        db.Add(customer);
        await db.SaveChangesAsync();

        var site = new CustomerSite
        {
            CustomerId = customer.Id,
            Name = "HQ",
            Geog = new Point(lon, lat) { SRID = 4326 },
            GeofenceRadiusM = 150,
        };
        db.Add(site);
        db.Add(new CustomerAssignment
        {
            CustomerId = customer.Id,
            UserId = assignedUserId,
            ValidFrom = DateOnly.FromDateTime(DateTime.UtcNow),
        });
        await db.SaveChangesAsync();

        return (customer.Id, site.Id);
    }
}
