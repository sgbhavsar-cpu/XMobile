using Microsoft.EntityFrameworkCore;
using XMobile.Customers.Domain;
using XMobile.Persistence;
using XMobile.Shared;

namespace XMobile.Customers.Infrastructure;

/// <summary>Both customer.customer_account and customer.customer_site are server-owned (docs/04
/// §4: "Server wins, always — XInfo is master; client edits are proposals"). This increment
/// doesn't support field-created prospects (that's a separate, not-yet-built proposal flow), so
/// every push against either is simply rejected — there is nothing for the client to legitimately
/// change here yet.</summary>
public sealed class CustomerAccountSyncHandler(XMobileDbContext db) : ISyncEntityHandler
{
    public string Entity => "customer.customer_account";
    public bool IsGlobal => false;

    public async Task<object?> GetPayloadAsync(Guid id, CancellationToken ct)
    {
        var c = await db.Set<CustomerAccount>().FirstOrDefaultAsync(x => x.Id == id, ct);
        return c is null ? null : new
        {
            id = c.Id, xinfoId = c.XinfoId, name = c.Name, accountType = c.AccountType,
            category = c.Category, phone = c.Phone, lifecycleStatus = c.LifecycleStatus.ToString(),
            rowVersion = c.RowVersion,
        };
    }

    public Task<SyncApplyResult> ApplyAsync(SyncMutationContext ctx, CancellationToken ct)
        => Task.FromResult(new SyncApplyResult(
            SyncApplyOutcome.Rejected, Reason: "customer_account is server-owned; XInfo is the source of truth"));
}

public sealed class CustomerSiteSyncHandler(XMobileDbContext db) : ISyncEntityHandler
{
    public string Entity => "customer.customer_site";
    public bool IsGlobal => false;

    public async Task<object?> GetPayloadAsync(Guid id, CancellationToken ct)
    {
        var s = await db.Set<CustomerSite>().FirstOrDefaultAsync(x => x.Id == id, ct);
        return s is null ? null : new
        {
            id = s.Id, customerId = s.CustomerId, name = s.Name,
            point = s.Geog?.ToGeoPoint(s.GeoAccuracyM), geofenceRadiusM = s.GeofenceRadiusM,
            geoSource = s.GeoSource.ToString(), rowVersion = s.RowVersion,
        };
    }

    public Task<SyncApplyResult> ApplyAsync(SyncMutationContext ctx, CancellationToken ct)
        => Task.FromResult(new SyncApplyResult(
            SyncApplyOutcome.Rejected, Reason: "customer_site is server-owned; XInfo is the source of truth"));
}
