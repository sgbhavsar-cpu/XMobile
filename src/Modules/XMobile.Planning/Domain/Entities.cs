using XMobile.Persistence;
using XMobile.Persistence.Enums;

namespace XMobile.Planning.Domain;

// Tour and VisitPlan carry a DB DEFAULT on `id` (see db/schema/03_planning.sql), but
// api/openapi.yaml's TourUpsert/VisitPlanUpsert require the client to supply `id` — a rep
// planning a tour or adding a visit needs a stable id while offline, before the row ever
// reaches the server (docs/04-offline-sync.md §1: "the client never invents server identity" —
// meaning the reverse is also true here, the *server* never overrides an id the client picked).
// These are therefore treated as client-generated keys at the application layer; the DB default
// only matters for rows inserted outside the API.
public sealed class Tour : ISyncableEntity, ISoftDeletable, IHasGuidKey
{
    public Guid Id { get; set; }
    public Guid UserId { get; set; }
    public string? Code { get; set; }
    public required string Title { get; set; }
    public string? Purpose { get; set; }
    public Guid HomeLocationId { get; set; }
    public DateOnly PlannedStartDate { get; set; }
    public DateOnly PlannedEndDate { get; set; }
    public string? DestinationCity { get; set; }
    public string? DestinationState { get; set; }
    public DateTimeOffset? ActualStartAt { get; set; }
    public DateTimeOffset? ActualEndAt { get; set; }
    public TourStatus Status { get; set; } = TourStatus.DRAFT;
    public bool IsSingleDay { get; set; }
    public DateTimeOffset? BaselineLockedAt { get; set; }
    public Guid? CreatedBy { get; set; }
    public string? CancelReason { get; set; }
    public string? Remark { get; set; }
    public long? TotalDistanceM { get; set; }
    public int TotalVisits { get; set; }
    public decimal? TotalExpenseAmount { get; set; }
    public long RowVersion { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
    public DateTimeOffset? DeletedAt { get; set; }
}

public sealed class TourDay : ISyncableEntity, ISoftDeletable
{
    public Guid Id { get; set; }
    public Guid TourId { get; set; }
    public Guid UserId { get; set; }
    public DateOnly PlanDate { get; set; }
    public short DaySeq { get; set; }
    public DayActivity ActivityType { get; set; } = DayActivity.VISITS;
    public string? FromCity { get; set; }
    public string? ToCity { get; set; }
    public TravelMode? PlannedTravelMode { get; set; }
    public string? OvernightCity { get; set; }
    public string? OvernightNote { get; set; }
    public string? Notes { get; set; }
    public int Revision { get; set; } = 1;
    public long RowVersion { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
    public DateTimeOffset? DeletedAt { get; set; }
}

public sealed class VisitPlan : ISyncableEntity, ISoftDeletable, IHasGuidKey
{
    public Guid Id { get; set; }
    public Guid? TourId { get; set; }
    public Guid? TourDayId { get; set; }
    public Guid UserId { get; set; }
    public Guid CustomerId { get; set; }
    public Guid SiteId { get; set; }
    public Guid? ContactId { get; set; }
    public required string VisitTypeCode { get; set; }
    public DateOnly PlannedDate { get; set; }
    public TimeOnly? PlannedStartTime { get; set; }
    public short PlannedDurationMin { get; set; } = 45;
    public short Seq { get; set; } = 1;
    public string? Objective { get; set; }
    public PlanStatus Status { get; set; } = PlanStatus.PLANNED;
    public string? SkipReasonCode { get; set; }
    public string? SkipRemark { get; set; }
    public Guid? RescheduledToId { get; set; }
    public bool IsBaseline { get; set; } = true;
    public Guid? CreatedBy { get; set; }
    public long RowVersion { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
    public DateTimeOffset? DeletedAt { get; set; }
}
