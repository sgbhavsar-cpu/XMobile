using Microsoft.Extensions.Options;
using XInfo.Gateway.Api.Infrastructure;
using XInfo.Gateway.Data.Repositories;

namespace XInfo.Gateway.Api.Endpoints;

/// <summary>
/// What XInfo owns and XMobile reads: master data, hierarchy, sales history, opportunity
/// state and expense outcomes.
///
/// Every one of these is delta-first. A full pull of a live CRM is something you do once, on
/// the night of a rollout — after that, asking for everything nightly is how a gateway ends
/// up throttled by the DBA.
/// </summary>
public static class PullEndpoints
{
    public static IEndpointRouteBuilder MapPullEndpoints(this IEndpointRouteBuilder app)
    {
        var pull = app.MapGroup("/v1/xinfo").WithTags("Pull")
            .RequireAuthorization();

        pull.MapGet("/customers", (
                DateTimeOffset? modifiedSince, string? cursor, int? pageSize,
                IPullRepository repo, IOptions<GatewayOptions> options, CancellationToken ct)
            => repo.GetCustomersAsync(modifiedSince, cursor, Size(pageSize, options), ct));

        pull.MapPost("/customers/by-ids", (
            string[] xinfoIds, IPullRepository repo, CancellationToken ct) =>
        {
            GatewayValidationException.Require(
                xinfoIds.Length <= 500, "Ask for at most 500 ids at a time");

            // Targeted refresh for the ids a webhook named — far cheaper than re-sweeping the
            // whole modified-since range because one customer changed.
            return repo.GetCustomersByIdsAsync(xinfoIds, ct);
        });

        pull.MapGet("/sites", (
                DateTimeOffset? modifiedSince, string? cursor, int? pageSize,
                IPullRepository repo, IOptions<GatewayOptions> options, CancellationToken ct)
            => repo.GetSitesAsync(modifiedSince, cursor, Size(pageSize, options), ct));

        pull.MapGet("/contacts", (
                DateTimeOffset? modifiedSince, string? cursor, int? pageSize,
                IPullRepository repo, IOptions<GatewayOptions> options, CancellationToken ct)
            => repo.GetContactsAsync(modifiedSince, cursor, Size(pageSize, options), ct));

        pull.MapGet("/assignments", (
                DateTimeOffset? modifiedSince, string? cursor, int? pageSize,
                IPullRepository repo, IOptions<GatewayOptions> options, CancellationToken ct)
            => repo.GetAssignmentsAsync(modifiedSince, cursor, Size(pageSize, options), ct));

        pull.MapGet("/users", (
                DateTimeOffset? modifiedSince, string? cursor, int? pageSize,
                IPullRepository repo, IOptions<GatewayOptions> options, CancellationToken ct)
            => repo.GetUsersAsync(modifiedSince, cursor, Size(pageSize, options), ct));

        pull.MapGet("/org-units", (
                DateTimeOffset? modifiedSince, string? cursor, int? pageSize,
                IPullRepository repo, IOptions<GatewayOptions> options, CancellationToken ct)
            => repo.GetOrgUnitsAsync(modifiedSince, cursor, Size(pageSize, options), ct));

        pull.MapGet("/sales-history", (
                DateTimeOffset? modifiedSince, string? customerXinfoId, string? cursor,
                int? pageSize, IPullRepository repo, IOptions<GatewayOptions> options,
                CancellationToken ct)
            => repo.GetSalesHistoryAsync(
                modifiedSince, customerXinfoId, cursor, Size(pageSize, options), ct));

        pull.MapGet("/opportunities", (
                DateTimeOffset? modifiedSince, string? cursor, int? pageSize,
                IPullRepository repo, IOptions<GatewayOptions> options, CancellationToken ct)
            => repo.GetOpportunitiesAsync(modifiedSince, cursor, Size(pageSize, options), ct));

        pull.MapGet("/expense-status", (
                DateTimeOffset? modifiedSince, string? cursor, int? pageSize,
                IPullRepository repo, IOptions<GatewayOptions> options, CancellationToken ct)
            // Approval and settlement outcomes flowing back. XMobile displays them and acts
            // on nothing: XInfo owns that workflow.
            => repo.GetExpenseStatusesAsync(modifiedSince, cursor, Size(pageSize, options), ct));

        pull.MapGet("/reference", (
                string? domain, IPullRepository repo, CancellationToken ct)
            => repo.GetReferenceItemsAsync(domain, ct));

        pull.MapGet("/rates", (
                DateTimeOffset? asOf, IPullRepository repo, CancellationToken ct)
            // Mileage and per-diem rates, so the app can show an indicative amount offline.
            // XInfo still recomputes and decides the figure that gets paid.
            => repo.GetRatesAsync(asOf ?? DateTimeOffset.UtcNow, ct));

        return app;
    }

    private static int Size(int? requested, IOptions<GatewayOptions> options)
        => requested is > 0 ? requested.Value : options.Value.DefaultPageSize;
}
