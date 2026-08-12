namespace XMobile.Tracking.Engine.Models;

/// <summary>
/// Everything the engine is allowed to see. If it is not in here, the engine cannot use it —
/// which is what keeps <see cref="IJourneyEngine.Infer"/> pure and replayable.
/// </summary>
public sealed record JourneyInput
{
    public required Guid UserId { get; init; }
    public required DateTimeOffset WindowFrom { get; init; }
    public required DateTimeOffset WindowTo { get; init; }

    public IReadOnlyList<Ping> Pings { get; init; } = [];
    public IReadOnlyList<GeofenceEvent> GeofenceEvents { get; init; } = [];
    public IReadOnlyList<StayDetection> Stays { get; init; } = [];
    public IReadOnlyList<PauseWindow> Pauses { get; init; } = [];
    public IReadOnlyList<HealthSample> HealthSamples { get; init; } = [];

    /// <summary>
    /// Manual corrections and confirmed events. Treated as fixed truth: a rebuild never
    /// overwrites them, because a rep who cannot correct a wrong detection stops trusting
    /// the system, and a correction that erases the detection destroys the audit trail.
    /// </summary>
    public IReadOnlyList<JourneyEvent> Anchors { get; init; } = [];

    public required Place Home { get; init; }
    public IReadOnlyList<Place> Sites { get; init; } = [];
    public TourContext? Tour { get; init; }

    /// <summary>State the user was in when the window opened.</summary>
    public JourneyState EntryState { get; init; } = JourneyState.Unknown;

    /// <summary>Device-local offset, used for business dates and the overnight window.</summary>
    public TimeSpan LocalOffset { get; init; } = TimeSpan.FromHours(5.5);

    public EngineConfig Config { get; init; } = EngineConfig.Default;
}

/// <summary>The inferred journey. Deterministic for a given input.</summary>
public sealed record JourneyResult
{
    public IReadOnlyList<JourneyEvent> Events { get; init; } = [];
    public IReadOnlyList<JourneySegment> Segments { get; init; } = [];
    public IReadOnlyList<Anomaly> Anomalies { get; init; } = [];
    public JourneyState EndState { get; init; } = JourneyState.Unknown;
    public string EngineVersion { get; init; } = EngineConfig.EngineVersion;

    public long TotalDistanceM => Segments.Sum(s => s.DistanceM);
    public long EstimatedDistanceM => Segments.Where(s => s.IsEstimated).Sum(s => s.DistanceM);
}

public interface IJourneyEngine
{
    /// <summary>
    /// Pure: no I/O, no clock, no randomness. Same evidence in, same journey out — which is
    /// what makes late-arriving offline data safe to replay (docs/03 §1).
    /// </summary>
    JourneyResult Infer(JourneyInput input);
}
