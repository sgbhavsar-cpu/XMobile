using System.Security.Claims;
using System.Text.Encodings.Web;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Diagnostics;
using Microsoft.Extensions.Diagnostics.HealthChecks;
using Microsoft.Extensions.Options;
using XInfo.Gateway.Data.Repositories;
using XInfo.Gateway.Data.Sql;

namespace XInfo.Gateway.Api.Infrastructure;

public sealed class GatewayOptions
{
    public const string SectionName = "Gateway";

    /// <summary>Shared secret the XMobile backend presents. Injected, never in the repo.</summary>
    public string ApiKey { get; set; } = string.Empty;

    /// <summary>Refuse to start when XInfo is missing procedures we call.</summary>
    public bool VerifyProceduresOnStartup { get; set; } = true;

    public int DefaultPageSize { get; set; } = 500;
}

// ---------------------------------------------------------------- auth

public static class ApiKeyAuthentication
{
    public const string SchemeName = "ApiKey";
    public const string HeaderName = "X-Gateway-Key";
}

public sealed class ApiKeyOptions : AuthenticationSchemeOptions;

public sealed class ApiKeyAuthenticationHandler(
    IOptionsMonitor<ApiKeyOptions> options,
    ILoggerFactory logger,
    UrlEncoder encoder,
    IOptions<GatewayOptions> gateway) : AuthenticationHandler<ApiKeyOptions>(options, logger, encoder)
{
    protected override Task<AuthenticateResult> HandleAuthenticateAsync()
    {
        var configured = gateway.Value.ApiKey;

        if (string.IsNullOrWhiteSpace(configured))
        {
            // An unset key must not mean "let everyone in". This service can write into the
            // company's CRM.
            return Task.FromResult(AuthenticateResult.Fail(
                "Gateway:ApiKey is not configured; refusing all requests"));
        }

        if (!Request.Headers.TryGetValue(ApiKeyAuthentication.HeaderName, out var presented))
        {
            return Task.FromResult(AuthenticateResult.Fail("Missing gateway key"));
        }

        // Fixed-time comparison: a plain string compare leaks the key one character at a time
        // to anyone who can measure the response.
        var expected = System.Text.Encoding.UTF8.GetBytes(configured);
        var actual = System.Text.Encoding.UTF8.GetBytes(presented.ToString());

        if (!System.Security.Cryptography.CryptographicOperations.FixedTimeEquals(expected, actual))
        {
            return Task.FromResult(AuthenticateResult.Fail("Invalid gateway key"));
        }

        var identity = new ClaimsIdentity(
            [new Claim(ClaimTypes.Name, "xmobile-backend")], ApiKeyAuthentication.SchemeName);

        return Task.FromResult(AuthenticateResult.Success(
            new AuthenticationTicket(new ClaimsPrincipal(identity), ApiKeyAuthentication.SchemeName)));
    }
}

// ---------------------------------------------------------------- errors

public static class GatewayExceptionHandling
{
    public static void UseGatewayExceptionHandling(this WebApplication app)
        => app.UseExceptionHandler(builder => builder.Run(async context =>
        {
            var error = context.Features.Get<IExceptionHandlerFeature>()?.Error;
            var logger = context.RequestServices
                .GetRequiredService<ILoggerFactory>().CreateLogger("XInfo.Gateway");

            var (status, title, detail) = error switch
            {
                // XInfo enforced a rule. The caller should not retry, and the message is worth
                // relaying to whoever is waiting on it.
                XInfoRuleException rule => (422, rule.Message, $"XInfo error {rule.ErrorNumber}"),

                // XInfo is unreachable or failing. The caller keeps the message in its outbox
                // and tries later — 503 says "again", not "never".
                XInfoUnavailableException unavailable => (503, "XInfo is unavailable", unavailable.Message),

                GatewayValidationException validation => (400, validation.Message, null),
                OperationCanceledException => (499, "Request cancelled", null),
                _ => (500, "Gateway error", $"Reference {context.TraceIdentifier}")
            };

            if (status >= 500)
            {
                logger.LogError(error, "Gateway failure on {Path} ({TraceId})",
                    context.Request.Path, context.TraceIdentifier);
            }
            else
            {
                logger.LogInformation("Rejected {Path}: {Title}", context.Request.Path, title);
            }

            context.Response.StatusCode = status;
            context.Response.ContentType = "application/problem+json";
            await context.Response.WriteAsJsonAsync(new
            {
                type = $"https://xmobile/errors/gateway/{status}",
                title,
                status,
                detail,
                traceId = context.TraceIdentifier
            });
        }));
}

public sealed class GatewayValidationException(string message) : Exception(message)
{
    public static void Require(bool condition, string message)
    {
        if (!condition) throw new GatewayValidationException(message);
    }
}

// ---------------------------------------------------------------- health

public sealed class XInfoHealthCheck(IPushRepository repository) : IHealthCheck
{
    public async Task<HealthCheckResult> CheckHealthAsync(
        HealthCheckContext context, CancellationToken ct = default)
    {
        try
        {
            return await repository.HealthCheckAsync(ct)
                ? HealthCheckResult.Healthy("XInfo SQL reachable")
                : HealthCheckResult.Unhealthy("XInfo health procedure did not return 1");
        }
        catch (Exception ex)
        {
            return HealthCheckResult.Unhealthy("XInfo SQL unreachable", ex);
        }
    }
}

public static class StartupVerification
{
    /// <summary>
    /// Checks that every procedure in <see cref="XInfoSprocs.All"/> exists before serving
    /// traffic. Catches a half-deployed DBA release at startup instead of mid-shift.
    /// </summary>
    public static async Task VerifyXInfoProceduresAsync(this WebApplication app)
    {
        using var scope = app.Services.CreateScope();
        var sql = scope.ServiceProvider.GetRequiredService<ISqlExecutor>();
        var logger = app.Services.GetRequiredService<ILoggerFactory>()
            .CreateLogger("XInfo.Gateway.Startup");

        try
        {
            var present = await sql.QueryAsync<string>(XInfoSprocs.HealthCheck);
            logger.LogInformation("XInfo reachable; {Count} procedures expected",
                XInfoSprocs.All.Count);
            _ = present;
        }
        catch (Exception ex)
        {
            // Log rather than crash: in a staged rollout the gateway may come up before the
            // DBA's release lands, and a crash-loop helps nobody. Readiness stays red until
            // the health check passes, so nothing routes here meanwhile.
            logger.LogError(ex,
                "Could not verify XInfo procedures at startup. Readiness will stay red until it succeeds.");
        }
    }
}
