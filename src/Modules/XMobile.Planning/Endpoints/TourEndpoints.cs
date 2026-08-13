using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;
using Microsoft.EntityFrameworkCore;
using XMobile.Identity.Domain;
using XMobile.Identity.Infrastructure;
using XMobile.Persistence;
using XMobile.Persistence.Enums;
using XMobile.Planning.Domain;
using XMobile.Shared;

namespace XMobile.Planning.Endpoints;

public static class TourEndpoints
{
    public static IEndpointRouteBuilder MapTourEndpoints(this IEndpointRouteBuilder app)
    {
        var tours = app.MapGroup("/v1/tours").WithTags("Tours").RequireAuthorization();
        tours.MapGet("", ListToursAsync);
        tours.MapPost("", CreateTourAsync);
        tours.MapGet("/{id:guid}", GetTourAsync);
        tours.MapPatch("/{id:guid}", UpdateTourAsync);
        tours.MapPost("/{id:guid}/start", StartTourAsync);
        tours.MapPost("/{id:guid}/complete", CompleteTourAsync);
        tours.MapPost("/{id:guid}/days/{dayId:guid}/plans", AddVisitPlanAsync);

        var plans = app.MapGroup("/v1/plans").WithTags("Tours").RequireAuthorization();
        plans.MapGet("", ListPlansAsync);
        // Not in api/openapi.yaml — added so HttpApiClient.skipVisitPlan (which only takes a
        // planId, no date range to search /v1/plans with) has something to return.
        plans.MapGet("/{id:guid}", GetPlanAsync);
        plans.MapPost("/{id:guid}/skip", SkipPlanAsync);

        return app;
    }

    // ---------------------------------------------------------------- Tours

    private static async Task<IResult> ListToursAsync(
        DateOnly? from, DateOnly? to, string? status, Guid? userId,
        XMobileDbContext db, ICurrentUser currentUser, IUserScopeService scope, CancellationToken ct)
    {
        var effectiveUserId = await ResolveScopedUserIdAsync(userId, currentUser, scope, ct);

        var query = db.Set<Tour>().Where(t => t.UserId == effectiveUserId);
        if (from is { } f)
        {
            query = query.Where(t => t.PlannedEndDate >= f);
        }

        if (to is { } t2)
        {
            query = query.Where(t => t.PlannedStartDate <= t2);
        }

        if (!string.IsNullOrWhiteSpace(status) && Enum.TryParse<TourStatus>(status, out var statusValue))
        {
            query = query.Where(t => t.Status == statusValue);
        }

        var results = await query.OrderByDescending(t => t.PlannedStartDate).ToListAsync(ct);
        return Results.Ok(results.Select(ToDto));
    }

    private static async Task<IResult> CreateTourAsync(
        TourUpsertRequest request, XMobileDbContext db, ICurrentUser currentUser, IClock clock, CancellationToken ct)
    {
        if (request.PlannedEndDate < request.PlannedStartDate)
        {
            throw new DomainValidationException("plannedEndDate must not be before plannedStartDate");
        }

        var home = await db.Set<UserHomeLocation>()
            .FirstOrDefaultAsync(h => h.UserId == currentUser.UserId && h.EffectiveTo == null, ct)
            ?? throw new DomainValidationException(
                "No home location is set for this user; capture one before planning a tour.");

        var tour = new Tour
        {
            Id = request.Id,
            UserId = currentUser.UserId,
            Title = request.Title,
            Purpose = request.Purpose,
            HomeLocationId = home.Id,
            PlannedStartDate = request.PlannedStartDate,
            PlannedEndDate = request.PlannedEndDate,
            DestinationCity = request.DestinationCity,
            Status = TourStatus.PLANNED,
            CreatedBy = currentUser.UserId,
        };
        db.Add(tour);

        var suppliedByDate = (request.Days ?? []).ToDictionary(d => d.PlanDate, d => d);
        short seq = 1;
        for (var date = request.PlannedStartDate; date <= request.PlannedEndDate; date = date.AddDays(1), seq++)
        {
            suppliedByDate.TryGetValue(date, out var supplied);
            db.Add(new TourDay
            {
                TourId = tour.Id,
                UserId = currentUser.UserId,
                PlanDate = date,
                DaySeq = seq,
                ActivityType = supplied?.ActivityType is { } a && Enum.TryParse<DayActivity>(a, out var parsed)
                    ? parsed : DayActivity.VISITS,
                FromCity = supplied?.FromCity,
                ToCity = supplied?.ToCity,
                OvernightCity = supplied?.OvernightCity,
                Notes = supplied?.Notes,
            });
        }

        await db.SaveChangesAsync(ct);
        return Results.Created($"/v1/tours/{tour.Id}", ToDto(tour));
    }

    private static async Task<IResult> GetTourAsync(
        Guid id, XMobileDbContext db, ICurrentUser currentUser, IUserScopeService scope, IVisitLookup visits,
        CancellationToken ct)
    {
        var tour = await LoadVisibleTourAsync(db, scope, id, ct);
        var days = await db.Set<TourDay>().Where(d => d.TourId == id).OrderBy(d => d.DaySeq).ToListAsync(ct);
        var plans = await db.Set<VisitPlan>().Where(p => p.TourId == id).OrderBy(p => p.PlannedDate)
            .ThenBy(p => p.Seq).ToListAsync(ct);
        var tourVisits = await visits.GetByTourIdAsync(id, ct);

        return Results.Ok(TourDetailDto.From(
            ToDto(tour), days.Select(ToDayDto).ToList(), plans.Select(ToPlanDto).ToList(), tourVisits));
    }

    private static async Task<IResult> UpdateTourAsync(
        Guid id, TourUpsertRequest request, XMobileDbContext db, ICurrentUser currentUser, CancellationToken ct)
    {
        var tour = await LoadOwnTourAsync(db, currentUser, id, ct);

        if (request.BaseVersion is { } baseVersion)
        {
            db.Entry(tour).Property(t => t.RowVersion).OriginalValue = baseVersion;
        }

        tour.Title = request.Title;
        tour.Purpose = request.Purpose;
        tour.PlannedStartDate = request.PlannedStartDate;
        tour.PlannedEndDate = request.PlannedEndDate;
        tour.DestinationCity = request.DestinationCity;

        await SaveOrConflictAsync(db, ct);
        return Results.Ok(ToDto(tour));
    }

    private static async Task<IResult> StartTourAsync(
        Guid id, XMobileDbContext db, ICurrentUser currentUser, IClock clock, CancellationToken ct)
    {
        var tour = await LoadOwnTourAsync(db, currentUser, id, ct);
        tour.Status = TourStatus.IN_PROGRESS;
        tour.ActualStartAt = clock.UtcNow;
        await SaveOrConflictAsync(db, ct);
        return Results.NoContent();
    }

    private static async Task<IResult> CompleteTourAsync(
        Guid id, XMobileDbContext db, ICurrentUser currentUser, IClock clock, CancellationToken ct)
    {
        var tour = await LoadOwnTourAsync(db, currentUser, id, ct);
        tour.Status = TourStatus.COMPLETED;
        tour.ActualEndAt = clock.UtcNow;
        await SaveOrConflictAsync(db, ct);
        return Results.NoContent();
    }

    private static async Task<IResult> AddVisitPlanAsync(
        Guid id, Guid dayId, VisitPlanUpsertRequest request, XMobileDbContext db, ICurrentUser currentUser,
        ISiteLookup siteLookup, CancellationToken ct)
    {
        var tour = await LoadOwnTourAsync(db, currentUser, id, ct);
        var day = await db.Set<TourDay>().FirstOrDefaultAsync(d => d.Id == dayId && d.TourId == id, ct)
                 ?? throw new NotFoundException("Tour day not found");

        var customerId = request.CustomerId
            ?? (await siteLookup.GetByIdAsync(request.SiteId, ct))?.CustomerId
            ?? throw new DomainValidationException("siteId does not resolve to a known customer");

        var plan = new VisitPlan
        {
            Id = request.Id,
            TourId = tour.Id,
            TourDayId = day.Id,
            UserId = currentUser.UserId,
            CustomerId = customerId,
            SiteId = request.SiteId,
            ContactId = request.ContactId,
            VisitTypeCode = request.VisitTypeCode,
            PlannedDate = request.PlannedDate,
            PlannedStartTime = request.PlannedStartTime,
            Seq = request.Seq ?? 1,
            Objective = request.Objective,
            IsBaseline = tour.BaselineLockedAt is null,
            CreatedBy = currentUser.UserId,
        };
        db.Add(plan);
        await db.SaveChangesAsync(ct);

        return Results.Created($"/v1/plans/{plan.Id}", ToPlanDto(plan));
    }

    // ---------------------------------------------------------------- Plans

    private static async Task<IResult> ListPlansAsync(
        DateOnly from, DateOnly to, XMobileDbContext db, ICurrentUser currentUser, CancellationToken ct)
    {
        var results = await db.Set<VisitPlan>()
            .Where(p => p.UserId == currentUser.UserId && p.PlannedDate >= from && p.PlannedDate <= to)
            .OrderBy(p => p.PlannedDate).ThenBy(p => p.Seq)
            .ToListAsync(ct);
        return Results.Ok(results.Select(ToPlanDto));
    }

    private static async Task<IResult> GetPlanAsync(
        Guid id, XMobileDbContext db, ICurrentUser currentUser, CancellationToken ct)
    {
        var plan = await db.Set<VisitPlan>().FirstOrDefaultAsync(p => p.Id == id && p.UserId == currentUser.UserId, ct)
                  ?? throw new NotFoundException("Visit plan not found");
        return Results.Ok(ToPlanDto(plan));
    }

    private static async Task<IResult> SkipPlanAsync(
        Guid id, PlanSkipRequest request, XMobileDbContext db, ICurrentUser currentUser, CancellationToken ct)
    {
        var plan = await db.Set<VisitPlan>().FirstOrDefaultAsync(p => p.Id == id && p.UserId == currentUser.UserId, ct)
                  ?? throw new NotFoundException("Visit plan not found");

        if (plan.Status != PlanStatus.PLANNED)
        {
            throw new StateConflictException($"Plan is {plan.Status}, not PLANNED");
        }

        plan.Status = PlanStatus.SKIPPED;
        plan.SkipReasonCode = request.ReasonCode;
        plan.SkipRemark = request.Remark;
        await db.SaveChangesAsync(ct);
        return Results.NoContent();
    }

    // ---------------------------------------------------------------- helpers

    private static async Task<Guid> ResolveScopedUserIdAsync(
        Guid? requestedUserId, ICurrentUser currentUser, IUserScopeService scope, CancellationToken ct)
    {
        if (requestedUserId is not { } requested || requested == currentUser.UserId)
        {
            return currentUser.UserId;
        }

        var visible = await scope.GetVisibleUserIdsAsync(ct);
        if (!visible.Contains(requested))
        {
            throw new ForbiddenException("Not permitted to view this user's tours");
        }

        return requested;
    }

    private static async Task<Tour> LoadVisibleTourAsync(
        XMobileDbContext db, IUserScopeService scope, Guid tourId, CancellationToken ct)
    {
        var tour = await db.Set<Tour>().FirstOrDefaultAsync(t => t.Id == tourId, ct)
                  ?? throw new NotFoundException("Tour not found");
        var visible = await scope.GetVisibleUserIdsAsync(ct);
        if (!visible.Contains(tour.UserId))
        {
            throw new NotFoundException("Tour not found");
        }

        return tour;
    }

    private static async Task<Tour> LoadOwnTourAsync(
        XMobileDbContext db, ICurrentUser currentUser, Guid tourId, CancellationToken ct)
    {
        var tour = await db.Set<Tour>().FirstOrDefaultAsync(t => t.Id == tourId, ct)
                  ?? throw new NotFoundException("Tour not found");
        if (tour.UserId != currentUser.UserId)
        {
            throw new NotFoundException("Tour not found");
        }

        return tour;
    }

    private static async Task SaveOrConflictAsync(XMobileDbContext db, CancellationToken ct)
    {
        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch (DbUpdateConcurrencyException)
        {
            throw new StateConflictException("The tour was modified by someone else; refresh and retry.");
        }
    }

    private static TourDto ToDto(Tour t) => new(
        t.Id, t.UserId, t.Title, t.Purpose, t.PlannedStartDate, t.PlannedEndDate, t.ActualStartAt, t.ActualEndAt,
        t.Status.ToString(), t.DestinationCity, t.TotalDistanceM, t.TotalVisits, t.TotalExpenseAmount, t.RowVersion);

    private static TourDayDto ToDayDto(TourDay d) => new(
        d.Id, d.PlanDate, d.DaySeq, d.ActivityType.ToString(), d.FromCity, d.ToCity,
        d.PlannedTravelMode?.ToString(), d.OvernightCity, d.Notes);

    private static VisitPlanDto ToPlanDto(VisitPlan p) => new(
        p.Id, p.TourId, p.TourDayId, p.CustomerId, null, p.SiteId, null, p.VisitTypeCode, p.PlannedDate,
        p.PlannedStartTime, p.Seq, p.Objective, p.Status.ToString(), p.IsBaseline, p.RowVersion);
}
