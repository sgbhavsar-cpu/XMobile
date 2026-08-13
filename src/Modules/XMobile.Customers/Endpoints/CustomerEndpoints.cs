using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;
using Microsoft.EntityFrameworkCore;
using XMobile.Customers.Domain;
using XMobile.Identity.Infrastructure;
using XMobile.Persistence;
using XMobile.Shared;

namespace XMobile.Customers.Endpoints;

public static class CustomerEndpoints
{
    public static IEndpointRouteBuilder MapCustomerEndpoints(this IEndpointRouteBuilder app)
    {
        var customers = app.MapGroup("/v1/customers").WithTags("Customers").RequireAuthorization();

        customers.MapGet("", GetCustomersAsync);
        customers.MapGet("/{id:guid}", GetCustomerAsync);
        customers.MapGet("/{id:guid}/sites", GetCustomerSitesAsync);
        customers.MapGet("/{id:guid}/summary", GetCustomerSummaryAsync);
        customers.MapGet("/{id:guid}/history", GetCustomerHistoryAsync);

        return app;
    }

    private static async Task<IResult> GetCustomersAsync(
        string? q, double? nearLat, double? nearLon, int? radiusM,
        XMobileDbContext db, IUserScopeService scope, CancellationToken ct)
    {
        // nearLat/nearLon/radiusM (proximity ranking) is deferred — needs a geography distance
        // query over each customer's sites; the assigned-customer list is the load-bearing part
        // of this endpoint for Phase 1.
        _ = nearLat;
        _ = nearLon;
        _ = radiusM;

        var visibleUserIds = (await scope.GetVisibleUserIdsAsync(ct)).ToList();

        var query = db.Set<CustomerAccount>().Where(c => db.Set<CustomerAssignment>()
            .Any(a => a.CustomerId == c.Id && a.ValidTo == null && visibleUserIds.Contains(a.UserId)));

        if (!string.IsNullOrWhiteSpace(q))
        {
            query = query.Where(c => EF.Functions.ILike(c.Name, $"%{q}%"));
        }

        var customerList = await query.OrderBy(c => c.Name).ToListAsync(ct);
        var sitesByCustomer = await LoadSitesAsync(db, customerList.Select(c => c.Id), ct);

        // lastVisitAt is populated on the single-customer detail endpoint only, to avoid an
        // extra cross-module call per row here — it is nullable in the wire schema either way.
        var result = customerList.Select(c => ToCustomerDto(c, sitesByCustomer, lastVisitAt: null));
        return Results.Ok(result);
    }

    private static async Task<IResult> GetCustomerAsync(
        Guid id, XMobileDbContext db, IUserScopeService scope, IVisitLookup visits, CancellationToken ct)
    {
        var customer = await LoadVisibleCustomerAsync(db, scope, id, ct);
        var sitesByCustomer = await LoadSitesAsync(db, [id], ct);
        var customerVisits = await visits.GetByCustomerIdAsync(id, since: null, ct);
        var lastVisitAt = customerVisits.Select(v => v.CheckInAt).DefaultIfEmpty().Max();

        return Results.Ok(ToCustomerDto(customer, sitesByCustomer, lastVisitAt == default ? null : lastVisitAt));
    }

    private static async Task<IResult> GetCustomerSitesAsync(
        Guid id, XMobileDbContext db, IUserScopeService scope, CancellationToken ct)
    {
        await LoadVisibleCustomerAsync(db, scope, id, ct);
        var sites = await db.Set<CustomerSite>()
            .Where(s => s.CustomerId == id).OrderBy(s => s.Name).ToListAsync(ct);
        return Results.Ok(sites.Select(ToSiteDto));
    }

    private static async Task<IResult> GetCustomerSummaryAsync(
        Guid id, XMobileDbContext db, IUserScopeService scope, IVisitLookup visits, CancellationToken ct)
    {
        var customer = await LoadVisibleCustomerAsync(db, scope, id, ct);
        var since90 = DateOnly.FromDateTime(DateTime.UtcNow.AddDays(-90));
        var since365 = DateOnly.FromDateTime(DateTime.UtcNow.AddDays(-365));

        var siteCount = await db.Set<CustomerSite>().CountAsync(s => s.CustomerId == id, ct);
        var customerVisits = await visits.GetByCustomerIdAsync(id, since: since90, ct);
        var lastVisitAt = customerVisits.Select(v => v.CheckInAt).DefaultIfEmpty().Max();

        var salesLast12Months = await db.Set<SalesHistory>()
            .Where(s => s.CustomerId == id && s.DocumentType == "ORDER" && s.DocumentDate >= since365)
            .SumAsync(s => (decimal?)s.Amount, ct) ?? 0m;
        var lastOrderDate = await db.Set<SalesHistory>()
            .Where(s => s.CustomerId == id && s.DocumentType == "ORDER")
            .OrderByDescending(s => s.DocumentDate).Select(s => (DateOnly?)s.DocumentDate)
            .FirstOrDefaultAsync(ct);

        // Opportunities are out of this increment's scope (Phase 3b — customer intelligence);
        // the pipeline fields report zero until that module lands.
        return Results.Ok(new Customer360Dto(
            customer.Id, customer.Name, customer.LifecycleStatus.ToString(), customer.Category,
            siteCount, lastVisitAt == default ? null : lastVisitAt, customerVisits.Count,
            salesLast12Months, lastOrderDate, 0, 0m, DateTimeOffset.UtcNow));
    }

    private static async Task<IResult> GetCustomerHistoryAsync(
        Guid id, DateOnly? since, XMobileDbContext db, IUserScopeService scope, IVisitLookup visitLookup,
        CancellationToken ct)
    {
        await LoadVisibleCustomerAsync(db, scope, id, ct);

        var salesQuery = db.Set<SalesHistory>().Where(s => s.CustomerId == id);
        if (since is { } cutoff)
        {
            salesQuery = salesQuery.Where(s => s.DocumentDate >= cutoff);
        }

        var sales = await salesQuery.OrderByDescending(s => s.DocumentDate).Take(200).ToListAsync(ct);
        var visits = await visitLookup.GetByCustomerIdAsync(id, since, ct);

        var salesDtos = sales.Select(s => new SalesHistoryItemDto(
            s.Id, s.DocumentType, s.DocumentNo, s.DocumentDate, s.Amount, s.Currency, s.Status, s.Summary));

        return Results.Ok(new CustomerHistoryResult(
            salesDtos.ToList(), visits.Select(VisitDto.From).ToList(), DateTimeOffset.UtcNow));
    }

    /// <summary>404s rather than 403s on an out-of-scope customer — matches docs/06 §5's "a rep
    /// must never be able to read another rep's rows" without confirming the id even exists.</summary>
    private static async Task<CustomerAccount> LoadVisibleCustomerAsync(
        XMobileDbContext db, IUserScopeService scope, Guid customerId, CancellationToken ct)
    {
        var visibleUserIds = (await scope.GetVisibleUserIdsAsync(ct)).ToList();
        var customer = await db.Set<CustomerAccount>().FirstOrDefaultAsync(c => c.Id == customerId, ct)
                       ?? throw new NotFoundException("Customer not found");

        var isAssigned = await db.Set<CustomerAssignment>().AnyAsync(
            a => a.CustomerId == customerId && a.ValidTo == null && visibleUserIds.Contains(a.UserId), ct);
        if (!isAssigned)
        {
            throw new NotFoundException("Customer not found");
        }

        return customer;
    }

    private static async Task<Dictionary<Guid, List<CustomerSiteDto>>> LoadSitesAsync(
        XMobileDbContext db, IEnumerable<Guid> customerIds, CancellationToken ct)
    {
        var ids = customerIds.ToList();
        var sites = await db.Set<CustomerSite>().Where(s => ids.Contains(s.CustomerId)).ToListAsync(ct);
        return sites.GroupBy(s => s.CustomerId).ToDictionary(g => g.Key, g => g.Select(ToSiteDto).ToList());
    }

    private static CustomerDto ToCustomerDto(
        CustomerAccount c, Dictionary<Guid, List<CustomerSiteDto>> sitesByCustomer, DateTimeOffset? lastVisitAt)
        => new(c.Id, c.XinfoId, c.Name, c.AccountType, c.Category, c.Phone,
            sitesByCustomer.TryGetValue(c.Id, out var sites) ? sites : [], lastVisitAt, c.RowVersion);

    private static CustomerSiteDto ToSiteDto(CustomerSite s) => new(
        s.Id, s.Name, s.IsPrimary, s.AddressLine1, s.City,
        s.Geog?.ToGeoPoint(s.GeoAccuracyM), s.GeoSource.ToString(), s.GeofenceRadiusM, s.GeoVerifiedAt, s.RowVersion);
}
