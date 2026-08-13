using NetTopologySuite.Geometries;
using XMobile.Persistence;
using XMobile.Persistence.Enums;

namespace XMobile.Visits.Domain;

public sealed class Visit : ISyncableEntity, ISoftDeletable, IHasGuidKey
{
    public Guid Id { get; set; }
    public Guid? VisitPlanId { get; set; }
    public Guid? TourId { get; set; }
    public Guid? TourDayId { get; set; }
    public Guid UserId { get; set; }
    public Guid CustomerId { get; set; }
    public Guid SiteId { get; set; }
    public Guid? ContactId { get; set; }
    public required string VisitTypeCode { get; set; }
    public DateOnly LocalDate { get; set; }

    public DateTimeOffset CheckInAt { get; set; }
    public Point? CheckInGeog { get; set; }
    public float? CheckInAccuracyM { get; set; }
    public int? CheckInDistanceM { get; set; }
    public CheckinMethod CheckInMethod { get; set; } = CheckinMethod.MANUAL;
    public Guid? CheckInDeviceId { get; set; }
    public bool IsOutOfGeofence { get; set; }
    public string? OutOfFenceReasonCode { get; set; }
    public string? OutOfFenceRemark { get; set; }

    public DateTimeOffset? CheckOutAt { get; set; }
    public Point? CheckOutGeog { get; set; }
    public float? CheckOutAccuracyM { get; set; }
    public CheckinMethod? CheckOutMethod { get; set; }
    public bool AutoClosed { get; set; }
    public int? DurationMin { get; set; }

    public Guid? SelfieAttachmentId { get; set; }
    public Guid? SignatureAttachmentId { get; set; }
    public short PhotoCount { get; set; }

    public bool IsUnplanned { get; set; }
    public VisitStatus Status { get; set; } = VisitStatus.CHECKED_IN;
    public string? VoidReason { get; set; }
    public Guid? ArriveEventId { get; set; }
    public Guid? DepartEventId { get; set; }

    public string? DeviceTz { get; set; }
    public long RowVersion { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
    public DateTimeOffset? DeletedAt { get; set; }
}

public sealed class FormTemplate : ISyncableEntity
{
    public Guid Id { get; set; }
    public required string Code { get; set; }
    public int Version { get; set; }
    public required string Name { get; set; }
    public string? Description { get; set; }
    public string? VisitTypeCode { get; set; }
    public string? CustomerCategory { get; set; }
    public Guid? OrgUnitId { get; set; }
    public required string Schema { get; set; }
    public TemplateStatus Status { get; set; } = TemplateStatus.DRAFT;
    public DateOnly? EffectiveFrom { get; set; }
    public DateOnly? EffectiveTo { get; set; }
    public DateTimeOffset? PublishedAt { get; set; }
    public Guid? PublishedBy { get; set; }
    public long RowVersion { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
}

/// <summary>PK is `visit_id` — one report per visit.</summary>
public sealed class VisitReport : ISyncableEntity
{
    public Guid VisitId { get; set; }
    public Guid UserId { get; set; }
    public Guid? TemplateId { get; set; }
    public string? TemplateCode { get; set; }
    public int? TemplateVersion { get; set; }

    public string? OutcomeCode { get; set; }
    public string? Summary { get; set; }
    public string? DiscussionPoints { get; set; }
    public string? NextAction { get; set; }
    public DateOnly? FollowUpDate { get; set; }
    public bool? OrderIntent { get; set; }
    public decimal? OrderValueEst { get; set; }
    public string Currency { get; set; } = "INR";
    public bool CompetitorSeen { get; set; }
    public string? CompetitorNotes { get; set; }
    public short? CustomerSentiment { get; set; }
    public string? IssuesRaised { get; set; }
    public Guid? ContactMetId { get; set; }
    public string? ContactMetName { get; set; }

    public string Answers { get; set; } = "{}";

    public Guid? VoiceNoteAttachmentId { get; set; }
    public bool IsDraft { get; set; } = true;
    public DateTimeOffset? SubmittedAt { get; set; }
    public long RowVersion { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
}

/// <summary>Append-only: reports are immutable once submitted (docs/02 §2.4).</summary>
public sealed class VisitReportAmendment
{
    public Guid Id { get; set; }
    public Guid VisitId { get; set; }
    public Guid AmendedBy { get; set; }
    public DateTimeOffset AmendedAt { get; set; }
    public required string Reason { get; set; }
    public required string BeforeJson { get; set; }
    public required string AfterJson { get; set; }
    public long RowVersion { get; set; }
}
