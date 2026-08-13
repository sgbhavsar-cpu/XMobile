using XInfo.Gateway.Data.Sql;

namespace XInfo.Gateway.Api.Endpoints;

/// <summary>
/// Endpoints for the people running this thing, not for the application.
///
/// The procedure list is deliberately public and unauthenticated: it is the answer to "which
/// procedures does the gateway need?", which is the first question the DBA asks and the first
/// thing to check when a deployment half-lands. It exposes names only — no data, no schema.
/// </summary>
public static class OperationsEndpoints
{
    public static IEndpointRouteBuilder MapOperationsEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapGet("/v1/ops/procedures", () => Results.Ok(new
        {
            count = XInfoSprocs.All.Count,
            schema = "xm",
            procedures = XInfoSprocs.All
        })).WithTags("Operations").AllowAnonymous();

        return app;
    }
}
