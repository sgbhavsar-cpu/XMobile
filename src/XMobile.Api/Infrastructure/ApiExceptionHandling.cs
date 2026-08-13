using Microsoft.AspNetCore.Diagnostics;
using Microsoft.EntityFrameworkCore;
using Npgsql;
using XMobile.Shared;

namespace XMobile.Api.Infrastructure;

/// <summary>
/// RFC 9457 `application/problem+json` for every endpoint, modeled on
/// XInfo.Gateway.Api.Infrastructure.GatewayExceptionHandling — the exception types differ (these
/// come from XMobile.Shared, not the gateway's XInfo-specific ones) but the shape and the
/// log-level-by-status split are deliberately the same.
/// </summary>
public static class ApiExceptionHandling
{
    public static void UseApiExceptionHandling(this WebApplication app)
        => app.UseExceptionHandler(builder => builder.Run(async context =>
        {
            var error = context.Features.Get<IExceptionHandlerFeature>()?.Error;
            var logger = context.RequestServices
                .GetRequiredService<ILoggerFactory>().CreateLogger("XMobile.Api");

            var errors = (error as DomainValidationException)?.Errors;
            var (status, title, detail) = error switch
            {
                NotFoundException notFound => (404, notFound.Message, (string?)null),
                DomainValidationException validation => (400, validation.Message, (string?)null),
                ForbiddenException forbidden => (403, forbidden.Message, (string?)null),
                StateConflictException conflict => (409, conflict.Message, (string?)null),
                DbUpdateConcurrencyException =>
                    (409, "The resource was modified by someone else", (string?)null),
                // EF Core surfaces Postgres errors wrapped in a DbUpdateException, not the
                // PostgresException itself — match both shapes since a rethrow elsewhere could
                // plausibly propagate the unwrapped exception too.
                DbUpdateException { InnerException: PostgresException { SqlState: PostgresErrorCodes.UniqueViolation } }
                    or PostgresException { SqlState: PostgresErrorCodes.UniqueViolation } =>
                    (409, "This conflicts with an existing record", (string?)null),
                DbUpdateException { InnerException: PostgresException { SqlState: PostgresErrorCodes.ForeignKeyViolation } }
                    or PostgresException { SqlState: PostgresErrorCodes.ForeignKeyViolation } =>
                    (422, "Refers to something that does not exist", (string?)null),
                DbUpdateException { InnerException: PostgresException { SqlState: PostgresErrorCodes.CheckViolation } }
                    or PostgresException { SqlState: PostgresErrorCodes.CheckViolation } =>
                    (422, "Failed a data rule", (string?)null),
                OperationCanceledException => (499, "Request cancelled", (string?)null),
                _ => (500, "Internal error", $"Reference {context.TraceIdentifier}"),
            };

            if (status >= 500)
            {
                logger.LogError(error, "Unhandled failure on {Path} ({TraceId})",
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
                type = $"https://xmobile/errors/api/{status}",
                title,
                status,
                detail,
                instance = context.Request.Path.Value,
                errors,
                traceId = context.TraceIdentifier,
            });
        }));
}
