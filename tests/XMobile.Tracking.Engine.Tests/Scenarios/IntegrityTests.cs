using XMobile.Tracking.Engine.Models;
using XMobile.Tracking.Engine.Tests.Support;
using Xunit;

namespace XMobile.Tracking.Engine.Tests.Scenarios;

/// <summary>
/// Anti-tamper signals. Every one of these raises a flag for a human and none of them stops the
/// rep working: on a BYOD fleet with no MDM, false positives are certain, and blocking someone
/// in the field on one costs a selling day.
/// </summary>
public class IntegrityTests
{
    private static readonly TimeSpan Ist = TimeSpan.FromHours(5.5);
    private static DateTimeOffset At(int hour, int minute = 0) => new(2026, 8, 11, hour, minute, 0, Ist);

    private static readonly Guid YardId = new("66666666-6666-6666-6666-666666666666");

    private static (Place Home, Place Site) Setup() =>
        (Places.Home(), Places.Site(YardId.ToString(), Places.PuneCustomer, "Main Yard"));

    [Fact]
    public void MockLocationIsFlaggedAsCritical()
    {
        var (home, site) = Setup();

        var input = new TraceBuilder()
            .StayAt(Places.PuneHome, At(7), TimeSpan.FromHours(1))
            .MockPing(Places.PuneCustomer, At(9, 0))
            .MockPing(Places.PuneCustomer, At(9, 30))
            .Build(home, [site], At(6), At(12));

        var result = new JourneyEngine().Infer(input);
        var anomaly = result.Anomalies.First(a => a.Type == AnomalyTypes.MockLocation);

        Assert.Equal(AnomalySeverity.Critical, anomaly.Severity);
        Assert.Equal(2, anomaly.Details["ping_count"]);
    }

    [Fact]
    public void MockedFixesNeverManufactureAVisit()
    {
        // The flag is not enough on its own: a faked position must not also produce a visit
        // record that looks identical to a real one.
        var (home, site) = Setup();

        var input = new TraceBuilder()
            .StayAt(Places.PuneHome, At(7), TimeSpan.FromHours(1))
            .MockPing(Places.PuneCustomer, At(9, 0))
            .MockPing(Places.PuneCustomer, At(9, 20))
            .MockPing(Places.PuneCustomer, At(9, 40))
            .MockPing(Places.PuneCustomer, At(10, 0))
            .Build(home, [site], At(6), At(12));

        var result = new JourneyEngine().Infer(input);

        Assert.DoesNotContain(result.Events, e => e.Type == JourneyEventType.ArriveCustomer);
    }

    [Fact]
    public void PhysicallyImpossibleJumpsAreFlaggedAsTeleports()
    {
        var (home, site) = Setup();

        var input = new TraceBuilder()
            .StayAt(Places.PuneHome, At(7), TimeSpan.FromMinutes(20))
            .StayAt(Places.NagpurYard, At(7, 25), TimeSpan.FromMinutes(20))   // 620 km in 5 minutes
            .Build(home, [site], At(6), At(12));

        var anomaly = new JourneyEngine().Infer(input).Anomalies
            .First(a => a.Type == AnomalyTypes.Teleport);

        Assert.Equal(AnomalySeverity.Critical, anomaly.Severity);
    }

    [Fact]
    public void AFastJumpAcrossALongGapIsTreatedAsAFlightNotATeleport()
    {
        // Someone who actually flew produces a fast jump. Flagging it as fraud would train
        // managers to ignore the signal.
        var (home, site) = Setup();

        var input = new TraceBuilder()
            .StayAt(Places.PuneHome, At(6), TimeSpan.FromMinutes(20))
            .StayAt(Places.NagpurYard, At(8, 30), TimeSpan.FromMinutes(20))   // 620 km in ~2 hours
            .Build(home, [site], At(5), At(12));

        var anomalies = new JourneyEngine().Infer(input).Anomalies;

        Assert.DoesNotContain(anomalies,
            a => a.Type == AnomalyTypes.Teleport && a.Severity == AnomalySeverity.Critical);
    }

    [Fact]
    public void ClockManipulationIsFlagged()
    {
        var (home, site) = Setup();
        var basePing = At(9, 0);

        var input = new JourneyInput
        {
            UserId = Guid.NewGuid(),
            WindowFrom = At(6),
            WindowTo = At(12),
            Home = home,
            Sites = [site],
            Pings =
            [
                new Ping
                {
                    Id = new Guid("00000000-0000-0000-0000-000000000001"),
                    RecordedAt = basePing,
                    CorrectedAt = basePing.AddMinutes(25),   // device clock 25 minutes out
                    Point = Places.PuneHome,
                    AccuracyM = 10
                }
            ]
        };

        var anomaly = new JourneyEngine().Infer(input).Anomalies
            .First(a => a.Type == AnomalyTypes.ClockSkew);

        Assert.Equal(AnomalySeverity.Medium, anomaly.Severity);
    }

    [Fact]
    public void NoAnomalyIsSevereEnoughToRemoveTheJourney()
    {
        // Flags annotate; they never delete. Even a day full of integrity problems still
        // produces the journey, because the manager needs to see what was recorded.
        var (home, site) = Setup();

        var input = new TraceBuilder()
            .StayAt(Places.PuneHome, At(7), TimeSpan.FromHours(1))
            .TravelFromTo(Places.PuneHome, Places.PuneCustomer, At(8), TimeSpan.FromMinutes(20),
                TimeSpan.FromMinutes(2))
            .StayAt(Places.PuneCustomer, At(8, 20), TimeSpan.FromHours(1))
            .MockPing(Places.NagpurYard, At(9, 30))
            .Build(home, [site], At(6), At(12));

        var result = new JourneyEngine().Infer(input);

        Assert.NotEmpty(result.Anomalies);
        Assert.Contains(result.Events, e => e.Type == JourneyEventType.ArriveCustomer);
        Assert.Contains(result.Events, e => e.Type == JourneyEventType.DepartHome);
    }
}
