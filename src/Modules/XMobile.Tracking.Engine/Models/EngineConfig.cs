namespace XMobile.Tracking.Engine.Models;

/// <summary>
/// Every threshold the engine uses. Loaded from <c>config.app_setting</c> and snapshotted into
/// <c>tracking.inference_run.config_snapshot</c>, so a journey inferred last March can be
/// explained with the thresholds that were actually in force at the time.
/// </summary>
public sealed record EngineConfig
{
    public const string EngineVersion = "1.0.0";

    // --- geofencing -------------------------------------------------------
    public double HomeRadiusM { get; init; } = 200;
    public double DefaultSiteRadiusM { get; init; } = 150;

    /// <summary>Fixes worse than this cannot drive a transition (they remain evidence of presence).</summary>
    public double AccuracyRejectM { get; init; } = 100;

    // --- arrival / departure ---------------------------------------------
    public TimeSpan MinDwellForArrival { get; init; } = TimeSpan.FromMinutes(4);
    public double DepartDisplacementM { get; init; } = 500;
    public TimeSpan DepartDisplacementWindow { get; init; } = TimeSpan.FromMinutes(15);
    public TimeSpan HomeArrivalDwell { get; init; } = TimeSpan.FromMinutes(10);

    // --- gaps and overnight ----------------------------------------------
    public TimeSpan GapThreshold { get; init; } = TimeSpan.FromMinutes(45);
    public TimeSpan OvernightStationary { get; init; } = TimeSpan.FromHours(4);
    public TimeOnly OvernightWindowStart { get; init; } = new(21, 0);
    public TimeOnly OvernightWindowEnd { get; init; } = new(7, 0);
    public double OvernightSpreadM { get; init; } = 250;

    // --- confidence -------------------------------------------------------
    public double AutoConfirmConfidence { get; init; } = 0.75;
    public double ReviewConfidenceFloor { get; init; } = 0.45;

    /// <summary>Penalty applied when the matched site's coordinates are merely geocoded.</summary>
    public double UntrustedLocationPenalty { get; init; } = 0.20;

    // --- distance ---------------------------------------------------------
    public double RoadDistanceFactor { get; init; } = 1.25;

    /// <summary>Movements below this between consecutive fixes are GPS jitter, not travel.</summary>
    public double JitterThresholdM { get; init; } = 15;

    public double PathSimplifyToleranceM { get; init; } = 20;

    // --- anomaly ----------------------------------------------------------
    public double TeleportSpeedKmph { get; init; } = 900;
    public double AirPlausibleSpeedKmph { get; init; } = 250;
    public TimeSpan ClockSkewTolerance { get; init; } = TimeSpan.FromMinutes(5);
    public TimeSpan LongPauseThreshold { get; init; } = TimeSpan.FromMinutes(60);

    // --- return-leg scoring (docs/03 §4) ----------------------------------
    public double ReturnScoreNoRemainingVisits { get; init; } = 0.40;
    public double ReturnScoreApproachingHome { get; init; } = 0.30;
    public double ReturnScoreLeavingAllSites { get; init; } = 0.20;
    public double ReturnScoreLastTourDay { get; init; } = 0.15;

    /// <summary>Fraction of distance-to-home that must be closed to count as "approaching".</summary>
    public double ReturnApproachFraction { get; init; } = 0.15;

    public int ReturnMinConsecutiveFixes { get; init; } = 3;

    /// <summary>Auto candidates this close to an anchor of the same type are suppressed.</summary>
    public TimeSpan AnchorSuppressionWindow { get; init; } = TimeSpan.FromMinutes(30);

    public static EngineConfig Default { get; } = new();
}
