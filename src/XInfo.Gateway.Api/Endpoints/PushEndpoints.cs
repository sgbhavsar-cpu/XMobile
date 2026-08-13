using XInfo.Gateway.Api.Infrastructure;
using XInfo.Gateway.Contracts;
using XInfo.Gateway.Data.Repositories;

namespace XInfo.Gateway.Api.Endpoints;

/// <summary>
/// What XMobile owns and writes into XInfo.
///
/// Every call carries an idempotency key and every one is safe to repeat. That is not
/// defensive decoration: the caller is an outbox that retries on any failure it cannot
/// classify, and a duplicated delivery that created a second expense would be paid twice.
/// </summary>
public static class PushEndpoints
{
    public static IEndpointRouteBuilder MapPushEndpoints(this IEndpointRouteBuilder app)
    {
        var push = app.MapGroup("/v1/xinfo").WithTags("Push")
            .RequireAuthorization();

        push.MapPost("/customers/propose", (
            PushEnvelope<ProposeCustomerCommand> message,
            IPushRepository repo, CancellationToken ct) =>
        {
            Validate(message);
            GatewayValidationException.Require(
                !string.IsNullOrWhiteSpace(message.Payload.Name), "Customer name is required");

            // XInfo decides whether this becomes a customer. Our id travels with it so the
            // visits already recorded against the prospect can be matched on approval.
            return repo.ProposeCustomerAsync(message, ct);
        });

        push.MapPost("/sites", (
            PushEnvelope<AddSiteCommand> message, IPushRepository repo, CancellationToken ct) =>
        {
            Validate(message);
            GatewayValidationException.Require(
                !string.IsNullOrWhiteSpace(message.Payload.CustomerXinfoId),
                "A site needs the XInfo customer it belongs to");

            return repo.AddSiteAsync(message, ct);
        });

        push.MapPost("/contacts", (
            PushEnvelope<AddContactCommand> message, IPushRepository repo, CancellationToken ct) =>
        {
            Validate(message);
            GatewayValidationException.Require(
                !string.IsNullOrWhiteSpace(message.Payload.FullName), "Contact name is required");

            return repo.AddContactAsync(message, ct);
        });

        push.MapPost("/sites/capture-geo", (
            PushEnvelope<CaptureGeoCommand> message, IPushRepository repo, CancellationToken ct) =>
        {
            Validate(message);
            var geo = message.Payload;
            GatewayValidationException.Require(
                geo.Lat is >= -90 and <= 90, "Latitude is out of range");
            GatewayValidationException.Require(
                geo.Lon is >= -180 and <= 180, "Longitude is out of range");

            // A coordinate a rep captured standing at the site, replacing whatever XInfo
            // derived from the address.
            return repo.CaptureGeoAsync(message, ct);
        });

        push.MapPost("/opportunities", (
            PushEnvelope<UpsertOpportunityCommand> message,
            IPushRepository repo, CancellationToken ct) =>
        {
            Validate(message);
            var opportunity = message.Payload;
            GatewayValidationException.Require(
                !string.IsNullOrWhiteSpace(opportunity.Title), "Opportunity title is required");
            GatewayValidationException.Require(
                !string.IsNullOrWhiteSpace(opportunity.StageCode), "Stage is required");
            GatewayValidationException.Require(
                opportunity.RepFieldsUpdatedAt != default,
                "RepFieldsUpdatedAt is required so XInfo can reject a stale update");

            return repo.UpsertOpportunityAsync(message, ct);
        });

        push.MapPost("/visits", (
            PushEnvelope<VisitCompletedCommand> message,
            IPushRepository repo, CancellationToken ct) =>
        {
            Validate(message);
            GatewayValidationException.Require(
                !string.IsNullOrWhiteSpace(message.Payload.CustomerXinfoId),
                "A visit needs the XInfo customer it was against");

            return repo.PushVisitAsync(message, ct);
        });

        push.MapPost("/tours", (
            PushEnvelope<TourCompletedCommand> message, IPushRepository repo, CancellationToken ct) =>
        {
            Validate(message);
            return repo.PushTourAsync(message, ct);
        });

        push.MapPost("/expenses", (
            PushEnvelope<ExpenseCapturedCommand> message,
            IPushRepository repo, CancellationToken ct) =>
        {
            Validate(message);
            var expense = message.Payload;
            GatewayValidationException.Require(expense.Amount > 0, "Expense amount must be positive");
            GatewayValidationException.Require(
                !string.IsNullOrWhiteSpace(expense.CategoryCode), "Expense category is required");

            // The one push where a lost message is money a rep does not get back, which is
            // why the nightly reconciliation below exists.
            return repo.PushExpenseAsync(message, ct);
        });

        push.MapPost("/journey-summaries", (
            PushEnvelope<JourneyDailySummaryCommand> message,
            IPushRepository repo, CancellationToken ct) =>
        {
            Validate(message);
            return repo.PushJourneySummaryAsync(message, ct);
        });

        // ---------------------------------------------------------------- reconciliation
        push.MapGet("/reconciliation", async (
            string entity, DateTimeOffset from, DateTimeOffset to, string? employeeCode,
            IPushRepository repo, CancellationToken ct) =>
        {
            GatewayValidationException.Require(
                !string.IsNullOrWhiteSpace(entity), "Which entity to reconcile");
            GatewayValidationException.Require(to >= from, "The end date is before the start date");
            GatewayValidationException.Require(
                (to - from).TotalDays <= 92, "Reconcile at most three months at a time");

            // What XInfo believes it holds, so our nightly job can compare counts and sums
            // and re-push anything that never arrived.
            var summary = await repo.GetReconciliationAsync(entity, from, to, employeeCode, ct);
            return summary is null ? Results.NoContent() : Results.Ok(summary);
        });

        return app;
    }

    private static void Validate<T>(PushEnvelope<T> message)
    {
        GatewayValidationException.Require(
            message.MessageId != Guid.Empty, "MessageId is required");
        GatewayValidationException.Require(
            !string.IsNullOrWhiteSpace(message.IdempotencyKey),
            "IdempotencyKey is required; without it a retry would duplicate the record");
        GatewayValidationException.Require(
            !string.IsNullOrWhiteSpace(message.EmployeeCode),
            "EmployeeCode is required so XInfo can attribute the record");
    }
}
