using XMobile.Shared;

namespace XMobile.Visits;

// Wire DTOs mirror api/openapi.yaml component schemas (Visits/Reports section). Visit responses
// use XMobile.Shared.VisitSummary directly — its fields already match the openapi `Visit`
// schema field-for-field (it doubles as the cross-module read port other modules consume).

public sealed record CheckInRequestDto(
    Guid VisitId, Guid? VisitPlanId, Guid? TourId, Guid SiteId, Guid? ContactId, string? VisitTypeCode,
    DateTimeOffset CheckInAt, GeoPoint Point, string Method, string? OutOfFenceReasonCode,
    string? OutOfFenceRemark, Guid? SelfieAttachmentId, string? DeviceTz);

public sealed record CheckOutRequestDto(
    DateTimeOffset CheckOutAt, GeoPoint? Point, Guid? SignatureAttachmentId, long? BaseVersion);

public sealed record VisitReportDto(
    Guid VisitId, string? TemplateCode, int? TemplateVersion, string? OutcomeCode, string? Summary,
    string? DiscussionPoints, string? NextAction, DateOnly? FollowUpDate, bool? OrderIntent,
    decimal? OrderValueEst, bool CompetitorSeen, string? CompetitorNotes, short? CustomerSentiment,
    Guid? ContactMetId, string? ContactMetName, Dictionary<string, object?> Answers, bool IsDraft,
    DateTimeOffset? SubmittedAt, long RowVersion);

public sealed record VisitReportUpsertRequest(
    string? TemplateCode, int? TemplateVersion, string? OutcomeCode, string? Summary,
    string? DiscussionPoints, string? NextAction, DateOnly? FollowUpDate, bool? OrderIntent,
    decimal? OrderValueEst, bool CompetitorSeen, string? CompetitorNotes, short? CustomerSentiment,
    Guid? ContactMetId, string? ContactMetName, Dictionary<string, object?>? Answers, bool Submit,
    long? BaseVersion);

public sealed record AmendReportRequest(string Reason, VisitReportUpsertRequest Report);

public sealed record FormTemplateDto(
    Guid Id, string Code, int Version, string Name, string? VisitTypeCode, string Status,
    DateOnly? EffectiveFrom, Dictionary<string, object?> Schema);
