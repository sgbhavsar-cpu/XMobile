using NetTopologySuite.Geometries;
using XMobile.Persistence;
using XMobile.Persistence.Enums;

namespace XMobile.Tracking.Domain;

// Raw evidence tables (db/schema/04_tracking.sql) — all client-generated ids, append-only,
// none registered with config.fn_make_syncable (they're evidence, not synced working-set data).

public sealed class TrackingSession : IHasGuidKey
{
    public Guid Id { get; set; }
    public Guid UserId { get; set; }
    public Guid DeviceId { get; set; }
    public Guid? TourId { get; set; }
    public DateTimeOffset StartedAt { get; set; }
    public DateTimeOffset? EndedAt { get; set; }
    public required string StartReason { get; set; }
    public string? EndReason { get; set; }
    public SessionStatus Status { get; set; } = SessionStatus.ACTIVE;
    public string? AppVersion { get; set; }
    public string? OsVersion { get; set; }
    public int PingCount { get; set; }
    public long RowVersion { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
}

public sealed class TrackingPause : IHasGuidKey
{
    public Guid Id { get; set; }
    public Guid SessionId { get; set; }
    public Guid UserId { get; set; }
    public DateTimeOffset PausedAt { get; set; }
    public DateTimeOffset? ResumedAt { get; set; }
    public required string ReasonCode { get; set; }
    public string? ReasonText { get; set; }
    public bool AutoResumed { get; set; }
    public string? ResumedBy { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
}

/// <summary>Monthly range-partitioned on `recorded_at` — see
/// `tracking.fn_ensure_ping_partition`, called before every insert by the ingest handler.</summary>
public sealed class LocationPing : IHasGuidKey
{
    public Guid Id { get; set; }
    public Guid UserId { get; set; }
    public Guid DeviceId { get; set; }
    public Guid? SessionId { get; set; }
    public DateTimeOffset RecordedAt { get; set; }
    public DateTimeOffset ReceivedAt { get; set; }
    public DateTimeOffset? CorrectedAt { get; set; }
    public required Point Geog { get; set; }
    public float? AccuracyM { get; set; }
    public float? AltitudeM { get; set; }
    public float? SpeedMps { get; set; }
    public float? SpeedAccuracy { get; set; }
    public float? HeadingDeg { get; set; }
    public string? ActivityType { get; set; }
    public short? ActivityConf { get; set; }
    public bool? IsMoving { get; set; }
    public short? BatteryPct { get; set; }
    public bool? IsCharging { get; set; }
    public string? Provider { get; set; }
    public bool IsMock { get; set; }
    public PingSource Source { get; set; } = PingSource.FG_SERVICE;
    public bool IsOffWindow { get; set; }
    public long? Seq { get; set; }
    public string? DeviceTz { get; set; }
    public short? TzOffsetMin { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
}

public sealed class GeofenceEvent : IHasGuidKey
{
    public Guid Id { get; set; }
    public Guid UserId { get; set; }
    public Guid DeviceId { get; set; }
    public Guid? SessionId { get; set; }
    public Guid GeofenceId { get; set; }
    public required string EventType { get; set; }
    public DateTimeOffset OccurredAt { get; set; }
    public DateTimeOffset ReceivedAt { get; set; }
    public Point? Geog { get; set; }
    public float? AccuracyM { get; set; }
    public int? DwellSec { get; set; }
    public short? OsConfidence { get; set; }
    public bool IsMock { get; set; }
    public DateTimeOffset? ProcessedAt { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
}

public sealed class StayDetection : IHasGuidKey
{
    public Guid Id { get; set; }
    public Guid UserId { get; set; }
    public Guid DeviceId { get; set; }
    public DateTimeOffset ArrivedAt { get; set; }
    public DateTimeOffset? DepartedAt { get; set; }
    public required Point Geog { get; set; }
    public float? HorizontalAccuracyM { get; set; }
    public required string Source { get; set; }
    public string? MatchedRefType { get; set; }
    public Guid? MatchedRefId { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
}

public sealed class DeviceHeartbeat : IHasGuidKey
{
    public Guid Id { get; set; }
    public Guid DeviceId { get; set; }
    public Guid UserId { get; set; }
    public DateTimeOffset ReportedAt { get; set; }
    public DateTimeOffset ReceivedAt { get; set; }
    public short? BatteryPct { get; set; }
    public bool? IsPowerSaving { get; set; }
    public bool? LocationEnabled { get; set; }
    public string? PermissionLevel { get; set; }
    public bool? ServiceRunning { get; set; }
    public int? QueuedPings { get; set; }
    public int? QueuedMutations { get; set; }
    public string? NetworkType { get; set; }
    public string? AppVersion { get; set; }
    public int? ClockSkewSec { get; set; }
    public string Details { get; set; } = "{}";
}

// Inference output (server-generated ids) — journey_event/journey_segment/tracking_anomaly are
// syncable (the app's journey timeline is part of the offline working set); inference_run and
// user_journey_state are server-internal bookkeeping.

public sealed class JourneyEvent : ISyncableEntity
{
    public Guid Id { get; set; }
    public Guid UserId { get; set; }
    public Guid? TourId { get; set; }
    public JourneyEventType EventType { get; set; }
    public DateTimeOffset OccurredAt { get; set; }
    public DateTimeOffset DetectedAt { get; set; }
    public DateOnly LocalDate { get; set; }
    public string? DeviceTz { get; set; }
    public Point? Geog { get; set; }
    public string? RefType { get; set; }
    public Guid? RefId { get; set; }
    public Guid? SiteId { get; set; }
    public DetectionMethod DetectionMethod { get; set; }
    public decimal Confidence { get; set; }
    public EventStatus Status { get; set; } = EventStatus.DETECTED;
    public bool IsEstimated { get; set; }
    public string Evidence { get; set; } = "{}";
    public DateTimeOffset? OriginalOccurredAt { get; set; }
    public Guid? OverriddenBy { get; set; }
    public DateTimeOffset? OverriddenAt { get; set; }
    public string? OverrideReason { get; set; }
    public Guid? InferenceRunId { get; set; }
    public Guid? SupersededById { get; set; }
    public long RowVersion { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
}

public sealed class JourneySegment : ISyncableEntity
{
    public Guid Id { get; set; }
    public Guid UserId { get; set; }
    public Guid? TourId { get; set; }
    public SegmentType SegmentType { get; set; }
    public Guid? FromEventId { get; set; }
    public Guid? ToEventId { get; set; }
    public DateTimeOffset StartedAt { get; set; }
    public DateTimeOffset? EndedAt { get; set; }
    public int? DurationS { get; set; }
    public DateOnly LocalDate { get; set; }
    public string? RefType { get; set; }
    public Guid? RefId { get; set; }
    public Guid? SiteId { get; set; }
    public long? DistanceM { get; set; }
    public long? StraightLineM { get; set; }
    public TravelMode TravelMode { get; set; } = TravelMode.UNKNOWN;
    public decimal? ModeConfidence { get; set; }
    public Guid? ModeOverriddenBy { get; set; }
    public LineString? Path { get; set; }
    public int PingCount { get; set; }
    public bool IsEstimated { get; set; }
    public bool IsProvisional { get; set; }
    public Guid? InferenceRunId { get; set; }
    public Guid? SupersededById { get; set; }
    public long RowVersion { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
}

public sealed class TrackingAnomaly : ISyncableEntity
{
    public Guid Id { get; set; }
    public Guid UserId { get; set; }
    public Guid? DeviceId { get; set; }
    public Guid? TourId { get; set; }
    public required string AnomalyType { get; set; }
    public string Severity { get; set; } = "MEDIUM";
    public DateTimeOffset WindowStart { get; set; }
    public DateTimeOffset? WindowEnd { get; set; }
    public DateOnly LocalDate { get; set; }
    public int? DurationS { get; set; }
    public string Details { get; set; } = "{}";
    public DateTimeOffset DetectedAt { get; set; }
    public Guid? AcknowledgedBy { get; set; }
    public DateTimeOffset? AcknowledgedAt { get; set; }
    public string? RepExplanation { get; set; }
    public string? ManagerNote { get; set; }
    public DateTimeOffset? ResolvedAt { get; set; }
    public long RowVersion { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
}

/// <summary>Audit row per `InferenceRunner.RunAsync` call — window, trigger, engine version and
/// the `EngineConfig` snapshot used, so a disputed journey can be explained months later.</summary>
public sealed class InferenceRun
{
    public Guid Id { get; set; }
    public Guid UserId { get; set; }
    public DateTimeOffset WindowFrom { get; set; }
    public DateTimeOffset WindowTo { get; set; }
    public required string TriggerReason { get; set; }
    public DateTimeOffset StartedAt { get; set; }
    public DateTimeOffset? FinishedAt { get; set; }
    public int EventsCreated { get; set; }
    public int EventsSuperseded { get; set; }
    public int SegmentsCreated { get; set; }
    public required string EngineVersion { get; set; }
    public string ConfigSnapshot { get; set; } = "{}";
    public string Status { get; set; } = "RUNNING";
    public string? Error { get; set; }
}

/// <summary>PK is `user_id` — one row per user, the live cache `EntryState` is read from on the
/// next inference run and the manager "who's where" dashboard will read from later.</summary>
public sealed class UserJourneyState
{
    public Guid UserId { get; set; }
    public JourneyState State { get; set; } = JourneyState.UNKNOWN;
    public Guid? TourId { get; set; }
    public string? RefType { get; set; }
    public Guid? RefId { get; set; }
    public Guid? SiteId { get; set; }
    public DateTimeOffset? Since { get; set; }
    public DateTimeOffset? LastPingAt { get; set; }
    public Point? LastPingGeog { get; set; }
    public DateTimeOffset? LastEvaluatedAt { get; set; }
    public bool TrackingActive { get; set; }
    public short? HealthScore { get; set; }
    public long RowVersion { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
}
