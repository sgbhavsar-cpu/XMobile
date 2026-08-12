namespace XMobile.Tracking.Engine.Models;

public enum JourneyState
{
    AtHome,
    OutboundTransit,
    AtCustomer,
    InterTransit,
    OvernightStop,
    ReturnTransit,
    Paused,
    Unknown
}

public enum JourneyEventType
{
    DepartHome,
    ArriveCustomer,
    DepartCustomer,
    StartReturn,
    ArriveHome,
    OvernightStopStart,
    OvernightStopEnd,
    TransitStart,
    TransitEnd,
    PauseStart,
    PauseEnd,
    GapStart,
    GapEnd
}

public enum SegmentType
{
    OutboundTravel,
    InterTravel,
    ReturnTravel,
    AtCustomer,
    AtHome,
    OvernightStop,
    Gap,
    Paused
}

public enum DetectionMethod
{
    Geofence,
    Dwell,
    PingCluster,
    IosVisit,
    Activity,
    Manual,
    InferredFromGap,
    CheckIn,
    System
}

public enum EventStatus { Detected, NeedsReview, Confirmed, Rejected, Superseded }

public enum TravelMode { Unknown, Walk, TwoWheeler, Car, Bus, Rail, Air, Boat }

/// <summary>A detected transition. Carries its evidence so a disputed journey can be explained.</summary>
public sealed record JourneyEvent
{
    public required JourneyEventType Type { get; init; }
    public required DateTimeOffset OccurredAt { get; init; }
    public required DateOnly LocalDate { get; init; }
    public GeoPoint? Point { get; init; }
    public PlaceKind PlaceKind { get; init; } = PlaceKind.None;
    public Guid? PlaceId { get; init; }
    public Guid? CustomerId { get; init; }
    public required DetectionMethod Method { get; init; }
    public required double Confidence { get; init; }
    public EventStatus Status { get; init; } = EventStatus.Detected;
    public bool IsEstimated { get; init; }

    /// <summary>Rule scores and source ids. Serialised to <c>journey_event.evidence</c>.</summary>
    public IReadOnlyDictionary<string, object> Evidence { get; init; } =
        new Dictionary<string, object>();

    /// <summary>True for anchors: manual corrections and confirmed events, which are never recomputed.</summary>
    public bool IsAnchor { get; init; }

    public Guid? SourceEventId { get; init; }
}

/// <summary>The interval between two events.</summary>
public sealed record JourneySegment
{
    public required SegmentType Type { get; init; }
    public required DateTimeOffset StartedAt { get; init; }
    public DateTimeOffset? EndedAt { get; init; }
    public required DateOnly LocalDate { get; init; }
    public PlaceKind PlaceKind { get; init; } = PlaceKind.None;
    public Guid? PlaceId { get; init; }
    public Guid? CustomerId { get; init; }
    public long DistanceM { get; init; }
    public long StraightLineM { get; init; }
    public TravelMode TravelMode { get; init; } = TravelMode.Unknown;
    public double? ModeConfidence { get; init; }
    public int PingCount { get; init; }

    /// <summary>Reconstructed across an evidence gap. Never silently used for reimbursement.</summary>
    public bool IsEstimated { get; init; }

    /// <summary>Return leg recorded before confirmation; reclassified if the rep visits another customer.</summary>
    public bool IsProvisional { get; init; }

    public IReadOnlyList<GeoPoint> Path { get; init; } = [];

    public int? DurationSeconds => EndedAt is null
        ? null
        : (int)(EndedAt.Value - StartedAt).TotalSeconds;
}

public enum AnomalySeverity { Low, Medium, High, Critical }

/// <summary>
/// Something worth a human's attention. Anomalies flag, they never block: refusing a rep in
/// the field on a false positive costs a selling day (docs/03 §6).
/// </summary>
public sealed record Anomaly
{
    public required string Type { get; init; }
    public required AnomalySeverity Severity { get; init; }
    public required DateTimeOffset WindowStart { get; init; }
    public DateTimeOffset? WindowEnd { get; init; }
    public required DateOnly LocalDate { get; init; }
    public int? DurationSeconds => WindowEnd is null
        ? null
        : (int)(WindowEnd.Value - WindowStart).TotalSeconds;

    public IReadOnlyDictionary<string, object> Details { get; init; } =
        new Dictionary<string, object>();
}

public static class AnomalyTypes
{
    public const string GapUnexplained = "GAP_UNEXPLAINED";
    public const string AppKilled = "APP_KILLED";
    public const string PermissionRevoked = "PERMISSION_REVOKED";
    public const string LocationOff = "LOCATION_OFF";
    public const string PowerSave = "POWER_SAVE";
    public const string DeviceOff = "DEVICE_OFF";
    public const string NoSignal = "NO_SIGNAL";
    public const string MockLocation = "MOCK_LOCATION";
    public const string Teleport = "TELEPORT";
    public const string ClockSkew = "CLOCK_SKEW";
    public const string LongPause = "LONG_PAUSE";
    public const string LowBatterySampling = "LOW_BATTERY_SAMPLING";
}
