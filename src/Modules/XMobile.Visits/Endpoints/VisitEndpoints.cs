using System.Text.Json;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;
using Microsoft.EntityFrameworkCore;
using XMobile.Identity.Infrastructure;
using XMobile.Persistence;
using XMobile.Persistence.Enums;
using XMobile.Shared;
using XMobile.Visits.Domain;

namespace XMobile.Visits.Endpoints;

public static class VisitEndpoints
{
    private static readonly JsonSerializerOptions AnswersJsonOptions = new() { PropertyNamingPolicy = null };

    public static IEndpointRouteBuilder MapVisitEndpoints(this IEndpointRouteBuilder app)
    {
        var visits = app.MapGroup("/v1/visits").WithTags("Visits").RequireAuthorization();
        visits.MapPost("/check-in", CheckInAsync);
        visits.MapPost("/{id:guid}/check-out", CheckOutAsync);
        visits.MapGet("", ListVisitsAsync);
        visits.MapGet("/{id:guid}/report", GetReportAsync);
        visits.MapPut("/{id:guid}/report", SaveReportAsync);
        visits.MapPost("/{id:guid}/report/amend", AmendReportAsync);

        app.MapGet("/v1/form-templates", ListFormTemplatesAsync).WithTags("Reports").RequireAuthorization();

        return app;
    }

    // ---------------------------------------------------------------- Visits

    private static async Task<IResult> CheckInAsync(
        CheckInRequestDto request, XMobileDbContext db, ICurrentUser currentUser, ISiteLookup siteLookup,
        IVisitPlanCompletion planCompletion, CancellationToken ct)
    {
        var site = await siteLookup.GetByIdAsync(request.SiteId, ct)
                  ?? throw new DomainValidationException("siteId does not resolve to a known site");

        int? distanceM = null;
        var isOutOfGeofence = false;
        if (site.Point is { } center)
        {
            distanceM = (int)Math.Round(GeoMath.DistanceMeters(center, request.Point));
            isOutOfGeofence = distanceM > site.GeofenceRadiusM;
        }

        if (isOutOfGeofence && string.IsNullOrWhiteSpace(request.OutOfFenceReasonCode))
        {
            throw new DomainValidationException(
                "outOfFenceReasonCode is required when checking in outside the geofence",
                new Dictionary<string, string[]> { ["outOfFenceReasonCode"] = ["required outside the geofence"] });
        }

        var visit = new Visit
        {
            Id = request.VisitId,
            VisitPlanId = request.VisitPlanId,
            TourId = request.TourId,
            UserId = currentUser.UserId,
            CustomerId = site.CustomerId,
            SiteId = request.SiteId,
            ContactId = request.ContactId,
            // Not required by CheckInRequest — defaults to the base sales-call type when the
            // caller (e.g. an unplanned visit) doesn't have one to hand.
            VisitTypeCode = string.IsNullOrWhiteSpace(request.VisitTypeCode) ? "SALES_CALL" : request.VisitTypeCode,
            LocalDate = DateOnly.FromDateTime(request.CheckInAt.UtcDateTime),
            CheckInAt = request.CheckInAt,
            CheckInGeog = request.Point.ToNtsPoint(),
            CheckInAccuracyM = (float?)request.Point.AccuracyM,
            CheckInDistanceM = distanceM,
            CheckInMethod = Enum.Parse<CheckinMethod>(request.Method),
            IsOutOfGeofence = isOutOfGeofence,
            OutOfFenceReasonCode = request.OutOfFenceReasonCode,
            OutOfFenceRemark = request.OutOfFenceRemark,
            SelfieAttachmentId = request.SelfieAttachmentId,
            IsUnplanned = request.VisitPlanId is null,
            DeviceTz = request.DeviceTz,
        };
        db.Add(visit);
        await db.SaveChangesAsync(ct);

        if (request.VisitPlanId is { } planId)
        {
            await planCompletion.MarkCompletedAsync(planId, ct);
        }

        return Results.Created($"/v1/visits/{visit.Id}", ToSummary(visit));
    }

    private static async Task<IResult> CheckOutAsync(
        Guid id, CheckOutRequestDto request, XMobileDbContext db, ICurrentUser currentUser, CancellationToken ct)
    {
        var visit = await LoadOwnVisitAsync(db, currentUser, id, ct);
        if (visit.Status != VisitStatus.CHECKED_IN)
        {
            throw new StateConflictException($"Visit is {visit.Status}, not CHECKED_IN");
        }

        if (request.BaseVersion is { } baseVersion)
        {
            db.Entry(visit).Property(v => v.RowVersion).OriginalValue = baseVersion;
        }

        visit.CheckOutAt = request.CheckOutAt;
        if (request.Point is { } point)
        {
            visit.CheckOutGeog = point.ToNtsPoint();
            visit.CheckOutAccuracyM = (float?)point.AccuracyM;
        }

        visit.CheckOutMethod = CheckinMethod.MANUAL;
        visit.SignatureAttachmentId = request.SignatureAttachmentId;
        visit.Status = VisitStatus.CHECKED_OUT;

        await SaveOrConflictAsync(db, ct);
        return Results.Ok(ToSummary(visit));
    }

    private static async Task<IResult> ListVisitsAsync(
        DateOnly? from, DateOnly? to, Guid? customerId, Guid? userId,
        XMobileDbContext db, ICurrentUser currentUser, IUserScopeService scope, CancellationToken ct)
    {
        var effectiveUserId = currentUser.UserId;
        if (userId is { } requested && requested != currentUser.UserId)
        {
            var visible = await scope.GetVisibleUserIdsAsync(ct);
            if (!visible.Contains(requested))
            {
                throw new ForbiddenException("Not permitted to view this user's visits");
            }

            effectiveUserId = requested;
        }

        var query = db.Set<Visit>().Where(v => v.UserId == effectiveUserId);
        if (from is { } f)
        {
            query = query.Where(v => v.LocalDate >= f);
        }

        if (to is { } t)
        {
            query = query.Where(v => v.LocalDate <= t);
        }

        if (customerId is { } cid)
        {
            query = query.Where(v => v.CustomerId == cid);
        }

        var results = await query.OrderByDescending(v => v.CheckInAt).ToListAsync(ct);
        return Results.Ok(results.Select(ToSummary));
    }

    // ---------------------------------------------------------------- Reports

    private static async Task<IResult> GetReportAsync(
        Guid id, XMobileDbContext db, ICurrentUser currentUser, CancellationToken ct)
    {
        await LoadOwnVisitAsync(db, currentUser, id, ct);
        var report = await db.Set<VisitReport>().FirstOrDefaultAsync(r => r.VisitId == id, ct)
                     ?? throw new NotFoundException("No report has been saved for this visit yet");
        return Results.Ok(ToReportDto(report));
    }

    private static async Task<IResult> SaveReportAsync(
        Guid id, VisitReportUpsertRequest request, XMobileDbContext db, ICurrentUser currentUser, IClock clock,
        CancellationToken ct)
    {
        var visit = await LoadOwnVisitAsync(db, currentUser, id, ct);
        var report = await db.Set<VisitReport>().FirstOrDefaultAsync(r => r.VisitId == id, ct);
        if (report is not null && !report.IsDraft)
        {
            throw new StateConflictException("Report is already submitted; use /report/amend to change it.");
        }

        var isNew = report is null;
        report ??= new VisitReport { VisitId = id, UserId = currentUser.UserId };

        if (!isNew && request.BaseVersion is { } baseVersion)
        {
            db.Entry(report).Property(r => r.RowVersion).OriginalValue = baseVersion;
        }

        ApplyUpsert(report, request);
        if (request.Submit)
        {
            report.IsDraft = false;
            report.SubmittedAt = clock.UtcNow;
        }

        if (isNew)
        {
            db.Add(report);
        }

        await SaveOrConflictAsync(db, ct);

        if (request.Submit)
        {
            visit.Status = VisitStatus.REPORT_SUBMITTED;
            await db.SaveChangesAsync(ct);
        }

        return Results.Ok(ToReportDto(report));
    }

    private static async Task<IResult> AmendReportAsync(
        Guid id, AmendReportRequest request, XMobileDbContext db, ICurrentUser currentUser, IClock clock,
        CancellationToken ct)
    {
        await LoadOwnVisitAsync(db, currentUser, id, ct);
        var report = await db.Set<VisitReport>().FirstOrDefaultAsync(r => r.VisitId == id, ct)
                     ?? throw new NotFoundException("No report has been saved for this visit yet");
        if (report.IsDraft)
        {
            throw new StateConflictException("Report is still a draft; save it directly instead of amending.");
        }

        var beforeJson = JsonSerializer.Serialize(ToReportDto(report));
        ApplyUpsert(report, request.Report);
        var afterJson = JsonSerializer.Serialize(ToReportDto(report));

        db.Add(new VisitReportAmendment
        {
            VisitId = id,
            AmendedBy = currentUser.UserId,
            AmendedAt = clock.UtcNow,
            Reason = request.Reason,
            BeforeJson = beforeJson,
            AfterJson = afterJson,
        });
        await db.SaveChangesAsync(ct);

        return Results.Ok(ToReportDto(report));
    }

    private static async Task<IResult> ListFormTemplatesAsync(
        string? visitTypeCode, XMobileDbContext db, CancellationToken ct)
    {
        var query = db.Set<FormTemplate>().Where(t => t.Status == TemplateStatus.PUBLISHED);
        if (!string.IsNullOrWhiteSpace(visitTypeCode))
        {
            query = query.Where(t => t.VisitTypeCode == visitTypeCode || t.VisitTypeCode == null);
        }

        var templates = await query.ToListAsync(ct);
        return Results.Ok(templates.Select(ToTemplateDto));
    }

    // ---------------------------------------------------------------- helpers

    private static async Task<Visit> LoadOwnVisitAsync(
        XMobileDbContext db, ICurrentUser currentUser, Guid visitId, CancellationToken ct)
        => await db.Set<Visit>().FirstOrDefaultAsync(v => v.Id == visitId && v.UserId == currentUser.UserId, ct)
           ?? throw new NotFoundException("Visit not found");

    private static async Task SaveOrConflictAsync(XMobileDbContext db, CancellationToken ct)
    {
        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch (DbUpdateConcurrencyException)
        {
            throw new StateConflictException("This was modified elsewhere; refresh and retry.");
        }
    }

    private static void ApplyUpsert(VisitReport report, VisitReportUpsertRequest request)
    {
        report.TemplateCode = request.TemplateCode;
        report.TemplateVersion = request.TemplateVersion;
        report.OutcomeCode = request.OutcomeCode;
        report.Summary = request.Summary;
        report.DiscussionPoints = request.DiscussionPoints;
        report.NextAction = request.NextAction;
        report.FollowUpDate = request.FollowUpDate;
        report.OrderIntent = request.OrderIntent;
        report.OrderValueEst = request.OrderValueEst;
        report.CompetitorSeen = request.CompetitorSeen;
        report.CompetitorNotes = request.CompetitorNotes;
        report.CustomerSentiment = request.CustomerSentiment;
        report.ContactMetId = request.ContactMetId;
        report.ContactMetName = request.ContactMetName;
        report.Answers = JsonSerializer.Serialize(request.Answers ?? new Dictionary<string, object?>());
    }

    private static VisitSummary ToSummary(Visit v) => new(
        v.Id, v.VisitPlanId, v.TourId, v.CustomerId, null, v.SiteId, null, v.VisitTypeCode, v.LocalDate,
        v.CheckInAt, v.CheckOutAt, v.DurationMin, v.CheckInDistanceM, v.IsOutOfGeofence, v.IsUnplanned,
        v.AutoClosed, v.Status.ToString(), v.RowVersion);

    private static VisitReportDto ToReportDto(VisitReport r) => new(
        r.VisitId, r.TemplateCode, r.TemplateVersion, r.OutcomeCode, r.Summary, r.DiscussionPoints,
        r.NextAction, r.FollowUpDate, r.OrderIntent, r.OrderValueEst, r.CompetitorSeen, r.CompetitorNotes,
        r.CustomerSentiment, r.ContactMetId, r.ContactMetName,
        JsonSerializer.Deserialize<Dictionary<string, object?>>(r.Answers, AnswersJsonOptions) ?? [],
        r.IsDraft, r.SubmittedAt, r.RowVersion);

    private static FormTemplateDto ToTemplateDto(FormTemplate t) => new(
        t.Id, t.Code, t.Version, t.Name, t.VisitTypeCode, t.Status.ToString(), t.EffectiveFrom,
        JsonSerializer.Deserialize<Dictionary<string, object?>>(t.Schema, AnswersJsonOptions) ?? []);
}
