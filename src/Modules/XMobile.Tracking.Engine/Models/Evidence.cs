namespace XMobile.Tracking.Engine.Models;

/// <summary>A geographic point. Degrees, WGS84.</summary>
public readonly record struct GeoPoint(double Lat, double Lon)
{
    public bool IsValid => Lat is >= -90 and <= 90 && Lon is >= -180 and <= 180;
}

public enum PingSource { FgService, Geofence, SignificantChange, IosVisit, Motion, Manual, Heartbeat }

public enum ActivityType { Unknown, Still, Walking, Running, OnBicycle, InVehicle }

/// <summary>A single location fix reported by the device.</summary>
public sealed record Ping
{
    public required Guid Id { get; init; }

    /// <summary>Device clock. May be wrong; see <see cref="EffectiveAt"/>.</summary>
    public required DateTimeOffset RecordedAt { get; init; }

    /// <summary>
    /// <see cref="RecordedAt"/> corrected for the device's estimated clock skew.
    /// The engine orders and reasons on this, never on the raw device clock.
    /// </summary>
    public DateTimeOffset? CorrectedAt { get; init; }

    public DateTimeOffset EffectiveAt => CorrectedAt ?? RecordedAt;

    public required GeoPoint Point { get; init; }
    public double? AccuracyM { get; init; }
    public double? SpeedMps { get; init; }
    public double? HeadingDeg { get; init; }
    public ActivityType Activity { get; init; } = ActivityType.Unknown;
    public int? ActivityConfidence { get; init; }
    public bool? IsMoving { get; init; }
    public int? BatteryPct { get; init; }
    public bool IsMock { get; init; }
    public PingSource Source { get; init; } = PingSource.FgService;
    public string? DeviceTimeZone { get; init; }

    /// <summary>
    /// Whether this fix is precise enough to drive a state transition. Imprecise fixes are
    /// still evidence of being in an area — they just cannot, on their own, move the machine.
    /// </summary>
    public bool IsDecisionGrade(EngineConfig config)
        => !IsMock && Point.IsValid && (AccuracyM is null || AccuracyM <= config.AccuracyRejectM);
}

public enum GeofenceTransition { Enter, Exit, Dwell }

public enum PlaceKind { None, Home, CustomerSite, Stay }

/// <summary>An OS-reported geofence crossing — the highest-value single piece of evidence.</summary>
public sealed record GeofenceEvent
{
    public required Guid Id { get; init; }
    public required Guid GeofenceId { get; init; }
    public required PlaceKind PlaceKind { get; init; }
    public required Guid PlaceId { get; init; }
    public required GeofenceTransition Transition { get; init; }
    public required DateTimeOffset OccurredAt { get; init; }
    public GeoPoint? Point { get; init; }
    public double? AccuracyM { get; init; }
    public int? DwellSeconds { get; init; }
    public bool IsMock { get; init; }
}

/// <summary>
/// A stationary period detected by the OS (iOS <c>CLVisit</c>, Android stationary detection).
/// Strong corroboration for dwell on platforms that suppress continuous updates.
/// </summary>
public sealed record StayDetection
{
    public required Guid Id { get; init; }
    public required DateTimeOffset ArrivedAt { get; init; }
    public DateTimeOffset? DepartedAt { get; init; }
    public required GeoPoint Point { get; init; }
    public double? AccuracyM { get; init; }
    public string Source { get; init; } = "IOS_VISIT";
}

/// <summary>A period the rep explicitly paused tracking. Not an anomaly — a known blind spot.</summary>
public sealed record PauseWindow
{
    public required Guid Id { get; init; }
    public required DateTimeOffset PausedAt { get; init; }
    public DateTimeOffset? ResumedAt { get; init; }
    public string ReasonCode { get; init; } = "UNSPECIFIED";
    public bool AutoResumed { get; init; }

    public bool Covers(DateTimeOffset at) => at >= PausedAt && (ResumedAt is null || at <= ResumedAt);
}

/// <summary>Device health sample, used to explain gaps rather than leave them mysterious.</summary>
public sealed record HealthSample
{
    public required DateTimeOffset ReportedAt { get; init; }
    public int? BatteryPct { get; init; }
    public bool? IsPowerSaving { get; init; }
    public bool? LocationEnabled { get; init; }
    public bool? ServiceRunning { get; init; }
    public string? PermissionLevel { get; init; }
    public bool? WasRebooted { get; init; }
    public bool? WasAppRestarted { get; init; }
    public int? QueuedPings { get; init; }
}
