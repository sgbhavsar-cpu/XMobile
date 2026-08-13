using XMobile.Shared;

namespace XMobile.Planning;

// Wire DTOs mirror api/openapi.yaml component schemas (Tours section).

public sealed record TourDayDto(
    Guid Id, DateOnly PlanDate, short DaySeq, string ActivityType, string? FromCity, string? ToCity,
    string? PlannedTravelMode, string? OvernightCity, string? Notes);

public sealed record TourDayUpsert(
    Guid? Id, DateOnly PlanDate, short DaySeq, string ActivityType, string? FromCity, string? ToCity,
    string? PlannedTravelMode, string? OvernightCity, string? Notes);

public sealed record TourDto(
    Guid Id, Guid UserId, string Title, string? Purpose, DateOnly PlannedStartDate, DateOnly PlannedEndDate,
    DateTimeOffset? ActualStartAt, DateTimeOffset? ActualEndAt, string Status, string? DestinationCity,
    long? TotalDistanceM, int TotalVisits, decimal? TotalExpenseAmount, long RowVersion);

public sealed record VisitPlanDto(
    Guid Id, Guid? TourId, Guid? TourDayId, Guid CustomerId, string? CustomerName, Guid SiteId,
    string? SiteName, string VisitTypeCode, DateOnly PlannedDate, TimeOnly? PlannedStartTime, short Seq,
    string? Objective, string Status, bool IsBaseline, long RowVersion);

public sealed record TourDetailDto(
    Guid Id, Guid UserId, string Title, string? Purpose, DateOnly PlannedStartDate, DateOnly PlannedEndDate,
    DateTimeOffset? ActualStartAt, DateTimeOffset? ActualEndAt, string Status, string? DestinationCity,
    long? TotalDistanceM, int TotalVisits, decimal? TotalExpenseAmount, long RowVersion,
    IReadOnlyList<TourDayDto> Days, IReadOnlyList<VisitPlanDto> Plans, IReadOnlyList<VisitSummary> Visits)
{
    public static TourDetailDto From(TourDto t, IReadOnlyList<TourDayDto> days, IReadOnlyList<VisitPlanDto> plans,
        IReadOnlyList<VisitSummary> visits)
        => new(t.Id, t.UserId, t.Title, t.Purpose, t.PlannedStartDate, t.PlannedEndDate, t.ActualStartAt,
            t.ActualEndAt, t.Status, t.DestinationCity, t.TotalDistanceM, t.TotalVisits, t.TotalExpenseAmount,
            t.RowVersion, days, plans, visits);
}

public sealed record TourUpsertRequest(
    Guid Id, string Title, DateOnly PlannedStartDate, DateOnly PlannedEndDate, string? Purpose,
    string? DestinationCity, long? BaseVersion, IReadOnlyList<TourDayUpsert>? Days);

public sealed record VisitPlanUpsertRequest(
    Guid Id, Guid SiteId, string VisitTypeCode, DateOnly PlannedDate, Guid? CustomerId, Guid? ContactId,
    TimeOnly? PlannedStartTime, short? Seq, string? Objective, long? BaseVersion);

public sealed record PlanSkipRequest(string ReasonCode, string? Remark);
