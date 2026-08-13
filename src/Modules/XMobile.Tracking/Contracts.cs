using XMobile.Shared;

namespace XMobile.Tracking;

// Wire DTOs mirror api/openapi.yaml component schemas (Tracking section).

// ---------------------------------------------------------------- batch (inbound evidence)

public sealed record PingDto(
    Guid Id, DateTimeOffset RecordedAt, GeoPoint Point, double? AccuracyM, double? AltitudeM,
    double? SpeedMps, double? SpeedAccuracy, double? HeadingDeg, string? ActivityType, int? ActivityConfidence,
    bool? IsMoving, int? BatteryPct, bool? IsCharging, string? Provider, bool IsMock, string Source,
    long? Seq, string? DeviceTz, int? TzOffsetMin);

public sealed record GeofenceEventDto(
    Guid Id, Guid GeofenceId, string EventType, DateTimeOffset OccurredAt, GeoPoint? Point,
    double? AccuracyM, int? DwellSec, int? OsConfidence, bool IsMock);

public sealed record StayDetectionDto(
    Guid Id, DateTimeOffset ArrivedAt, DateTimeOffset? DepartedAt, GeoPoint Point, double? AccuracyM, string Source);

public sealed record HeartbeatDto(
    DateTimeOffset ReportedAt, int? BatteryPct, bool? IsPowerSaving, bool? LocationEnabled,
    string? PermissionLevel, bool? ServiceRunning, int? QueuedPings, int? QueuedMutations,
    string? NetworkType, string? AppVersion, int? ClockSkewSec);

public sealed record TrackingBatchRequest(
    Guid DeviceId, Guid? SessionId, IReadOnlyList<PingDto>? Pings,
    IReadOnlyList<GeofenceEventDto>? GeofenceEvents, IReadOnlyList<StayDetectionDto>? Stays, HeartbeatDto? Heartbeat);

public sealed record TrackingBatchResultDto(
    int AcceptedPings, int DuplicatePings, int AcceptedGeofenceEvents, int AcceptedStays,
    int NextUploadAfterSec, DateTimeOffset ServerTime);

// ---------------------------------------------------------------- sessions

public sealed record TrackingSessionStartRequest(
    Guid SessionId, Guid DeviceId, Guid? TourId, DateTimeOffset StartedAt, string StartReason,
    string? AppVersion, string? OsVersion);

public sealed record TrackingSessionDto(
    Guid Id, string Status, DateTimeOffset StartedAt, DateTimeOffset? EndedAt, string? EndReason, long RowVersion);

public sealed record SessionEndRequest(DateTimeOffset EndedAt, string? EndReason);

public sealed record SessionPauseRequest(Guid PauseId, DateTimeOffset PausedAt, string ReasonCode, string? ReasonText);

public sealed record SessionResumeRequest(DateTimeOffset ResumedAt);

// ---------------------------------------------------------------- journey (inference output)

public sealed record JourneyEventDto(
    Guid Id, string Type, DateTimeOffset OccurredAt, DateOnly LocalDate, GeoPoint? Point,
    string? RefType, Guid? RefId, Guid? SiteId, string DetectionMethod, decimal Confidence,
    string Status, bool IsEstimated, DateTimeOffset? OriginalOccurredAt, long RowVersion);

public sealed record JourneySegmentDto(
    Guid Id, string Type, DateTimeOffset StartedAt, DateTimeOffset? EndedAt, int? DurationS,
    DateOnly LocalDate, string? RefType, Guid? RefId, Guid? SiteId, long? DistanceM, string TravelMode,
    decimal? ModeConfidence, bool IsEstimated, bool IsProvisional, IReadOnlyList<GeoPoint>? Path, long RowVersion);

public sealed record TrackingAnomalyDto(
    Guid Id, string AnomalyType, string Severity, DateTimeOffset WindowStart, DateTimeOffset? WindowEnd,
    DateOnly LocalDate, int? DurationS, DateTimeOffset? AcknowledgedAt, DateTimeOffset? ResolvedAt);

/// <summary>Computed on the fly from the window's events/segments rather than read from a stored
/// rollup — see the plan's "daily_journey_summary is not written" scope decision. visitsPlanned/
/// visitsCompleted/trackingCoveragePct/attendanceStatus need Planning/Visits data this pass
/// doesn't cross-call for just a summary field, so they're left at 0/null.</summary>
public sealed record DailySummaryDto(
    DateOnly LocalDate, DateTimeOffset? FirstDepartureAt, DateTimeOffset? LastArrivalAt,
    long TotalDistanceM, int TravelTimeS, int CustomerTimeS, int GapTimeS);

public sealed record JourneyTimelineDto(
    Guid UserId, DateTimeOffset From, DateTimeOffset To, IReadOnlyList<JourneyEventDto> Events,
    IReadOnlyList<JourneySegmentDto> Segments, IReadOnlyList<TrackingAnomalyDto> Anomalies,
    IReadOnlyList<DailySummaryDto> Daily);

public sealed record OverrideEventRequest(DateTimeOffset OccurredAt, string Reason);

public sealed record HeadingHomeRequest(DateTimeOffset? OccurredAt, Guid? TourId);

public sealed record GeofenceDto(Guid Id, string RefType, Guid RefId, string Name, GeoPoint Point, int RadiusM);
