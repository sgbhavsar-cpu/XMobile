using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using NetTopologySuite.Geometries;
using XMobile.Api.Tests.Support;
using XMobile.Persistence;
using XMobile.Persistence.Enums;
using XMobile.Tracking.Domain;
using XMobile.Tracking.Infrastructure;

namespace XMobile.Api.Tests.Scenarios;

/// <summary>
/// The first real caller of src/Modules/XMobile.Tracking.Engine (docs/08 §4's "imperative
/// shell"): a device evidence batch over real HTTP, through real Postgres, into the pure engine,
/// and back — proving the whole ingest → inference → persistence pipeline actually works, not
/// just that it compiles. Coordinates mirror XMobile.Tracking.Engine.Tests.Support.Places so the
/// trip is physically sensible (Pune home ↔ Pune customer, ~1.75 km).
/// </summary>
[Collection("api")]
public sealed class TrackingTests(ApiTestContext context)
{
    private static readonly (double Lat, double Lon) Home = (18.5204, 73.8567);
    private static readonly (double Lat, double Lon) Customer = (18.5314, 73.8446);
    private static readonly TimeSpan LocalOffset = TimeSpan.FromHours(5.5);

    [Fact]
    public async Task Batch_evidence_produces_a_full_depart_arrive_journey()
    {
        var factory = context.Factory;
        var (client, userId) = await AuthHelper.LoginAsync(factory, "E-TRACK-1");
        await TestData.SeedHomeLocationAsync(factory, userId, Home.Lat, Home.Lon);
        var (customerId, siteId) = await TestData.SeedCustomerWithSiteAsync(factory, userId, Customer.Lat, Customer.Lon);
        var deviceId = await RegisterDeviceAsync(client);
        // InferenceRunner.Sites is only the active tour's planned sites (see the plan's scope
        // decision) — without a tour+plan covering the site, the engine has no Place to match the
        // customer pings against, so they never form a presence run at all.
        var today = DateOnly.FromDateTime((DateTimeOffset.UtcNow + LocalOffset).DateTime);
        await SeedTourWithPlanAsync(client, customerId, siteId, today, today, today);

        // Anchored just before "now" and kept short (36 minutes total) so the trip always lands
        // inside today's local (IST) window regardless of what time of day the suite runs — the
        // one edge case this doesn't cover is the suite running within ~40 minutes of local
        // midnight, where the trip's start could fall on the previous calendar day.
        var tripEnd = DateTimeOffset.UtcNow.AddMinutes(-1);
        var tripStart = tripEnd.AddMinutes(-48);

        // The pre-departure stay must clear config.HomeArrivalDwell (10 min) too — a shorter
        // initial stay leaves the first presence run's dwell unsatisfied, which suppresses not
        // just its (uninteresting) arrival candidate but its departure candidate as well, since
        // JourneyEngine generates both from the same run in one pass (see FromPresenceRuns).
        var pings = new List<object>();
        AppendStay(pings, Home, tripStart, TimeSpan.FromMinutes(12));
        var departHomeAt = tripStart.AddMinutes(12);
        AppendTravel(pings, Home, Customer, departHomeAt, TimeSpan.FromMinutes(6));
        var arriveCustomerAt = departHomeAt.AddMinutes(6);
        AppendStay(pings, Customer, arriveCustomerAt, TimeSpan.FromMinutes(6));
        var departCustomerAt = arriveCustomerAt.AddMinutes(6);
        AppendTravel(pings, Customer, Home, departCustomerAt, TimeSpan.FromMinutes(6));
        var arriveHomeAt = departCustomerAt.AddMinutes(6);
        AppendStay(pings, Home, arriveHomeAt, TimeSpan.FromMinutes(12));

        var batchResponse = await client.PostAsJsonAsync("/v1/tracking/batch", new { deviceId, pings });
        Assert.True(HttpStatusCode.OK == batchResponse.StatusCode, await batchResponse.Content.ReadAsStringAsync());
        using (var batch = await ParseAsync(batchResponse))
        {
            Assert.Equal(pings.Count, batch.RootElement.GetProperty("acceptedPings").GetInt32());
            Assert.Equal(0, batch.RootElement.GetProperty("duplicatePings").GetInt32());
        }

        using var journey = await GetJourneyAsync(client, tripStart.AddMinutes(-5), tripEnd.AddMinutes(5));
        var eventTypes = journey.RootElement.GetProperty("events").EnumerateArray()
            .Select(e => e.GetProperty("type").GetString()).ToList();
        Assert.Contains("DEPART_HOME", eventTypes);
        Assert.Contains("ARRIVE_CUSTOMER", eventTypes);
        Assert.Contains("DEPART_CUSTOMER", eventTypes);
        Assert.Contains("ARRIVE_HOME", eventTypes);

        var segmentTypes = journey.RootElement.GetProperty("segments").EnumerateArray()
            .Select(s => s.GetProperty("type").GetString()).ToList();
        Assert.Contains("AT_CUSTOMER", segmentTypes);
    }

    [Fact]
    public async Task Duplicate_ping_ids_are_reported_not_reinserted()
    {
        var factory = context.Factory;
        var (client, userId) = await AuthHelper.LoginAsync(factory, "E-TRACK-2");
        await TestData.SeedHomeLocationAsync(factory, userId, Home.Lat, Home.Lon);
        var deviceId = await RegisterDeviceAsync(client);

        var at = DateTimeOffset.UtcNow.AddMinutes(-10);
        var pings = new List<object>();
        AppendStay(pings, Home, at, TimeSpan.FromMinutes(4));

        var firstResponse = await client.PostAsJsonAsync("/v1/tracking/batch", new { deviceId, pings });
        Assert.Equal(HttpStatusCode.OK, firstResponse.StatusCode);
        using (var first = await ParseAsync(firstResponse))
        {
            Assert.Equal(pings.Count, first.RootElement.GetProperty("acceptedPings").GetInt32());
            Assert.Equal(0, first.RootElement.GetProperty("duplicatePings").GetInt32());
        }

        var freshPing = new List<object>();
        AppendStay(freshPing, Home, at.AddMinutes(10), TimeSpan.Zero);
        var secondBatch = pings.Concat(freshPing).ToList();

        var secondResponse = await client.PostAsJsonAsync("/v1/tracking/batch", new { deviceId, pings = secondBatch });
        Assert.Equal(HttpStatusCode.OK, secondResponse.StatusCode);
        using (var second = await ParseAsync(secondResponse))
        {
            Assert.Equal(1, second.RootElement.GetProperty("acceptedPings").GetInt32());
            Assert.Equal(pings.Count, second.RootElement.GetProperty("duplicatePings").GetInt32());
        }
    }

    [Fact]
    public async Task Override_on_a_detected_event_reruns_inference_and_the_correction_survives()
    {
        var factory = context.Factory;
        var (client, userId) = await AuthHelper.LoginAsync(factory, "E-TRACK-3");
        await TestData.SeedHomeLocationAsync(factory, userId, Home.Lat, Home.Lon);
        var (customerId, siteId) = await TestData.SeedCustomerWithSiteAsync(factory, userId, Customer.Lat, Customer.Lon);
        var deviceId = await RegisterDeviceAsync(client);
        var today = DateOnly.FromDateTime((DateTimeOffset.UtcNow + LocalOffset).DateTime);
        await SeedTourWithPlanAsync(client, customerId, siteId, today, today, today);

        var tripEnd = DateTimeOffset.UtcNow.AddMinutes(-1);
        var tripStart = tripEnd.AddMinutes(-30);
        var pings = new List<object>();
        AppendStay(pings, Home, tripStart, TimeSpan.FromMinutes(10));
        var departHomeAt = tripStart.AddMinutes(10);
        AppendTravel(pings, Home, Customer, departHomeAt, TimeSpan.FromMinutes(6));
        var arriveCustomerAt = departHomeAt.AddMinutes(6);
        AppendStay(pings, Customer, arriveCustomerAt, TimeSpan.FromMinutes(6));

        var batchResponse = await client.PostAsJsonAsync("/v1/tracking/batch", new { deviceId, pings });
        Assert.True(HttpStatusCode.OK == batchResponse.StatusCode, await batchResponse.Content.ReadAsStringAsync());

        Guid arrivalEventId;
        using (var journey = await GetJourneyAsync(client, tripStart.AddMinutes(-5), tripEnd.AddMinutes(5)))
        {
            var arrival = journey.RootElement.GetProperty("events").EnumerateArray()
                .Single(e => e.GetProperty("type").GetString() == "ARRIVE_CUSTOMER");
            arrivalEventId = arrival.GetProperty("id").GetGuid();
        }

        var correctedAt = arriveCustomerAt.AddMinutes(-2);
        var overrideResponse = await client.PostAsJsonAsync($"/v1/tracking/events/{arrivalEventId}/override",
            new { occurredAt = correctedAt, reason = "GPS lag — I actually arrived earlier" });
        Assert.Equal(HttpStatusCode.OK, overrideResponse.StatusCode);
        using (var overridden = await ParseAsync(overrideResponse))
        {
            Assert.Equal("CONFIRMED", overridden.RootElement.GetProperty("status").GetString());
        }

        // The rebuild that override triggers must not silently drop the correction.
        using var journeyAfter = await GetJourneyAsync(client, tripStart.AddMinutes(-5), tripEnd.AddMinutes(5));
        var arrivalAfter = journeyAfter.RootElement.GetProperty("events").EnumerateArray()
            .Single(e => e.GetProperty("id").GetGuid() == arrivalEventId);
        Assert.Equal("CONFIRMED", arrivalAfter.GetProperty("status").GetString());
        // Postgres timestamptz stores microsecond precision; .NET DateTimeOffset ticks are 100ns —
        // a sub-microsecond difference after the round trip is expected, not a correctness issue.
        var persistedOccurredAt = arrivalAfter.GetProperty("occurredAt").GetDateTimeOffset();
        Assert.True((persistedOccurredAt - correctedAt).Duration() < TimeSpan.FromMilliseconds(1),
            $"expected ~{correctedAt:O}, got {persistedOccurredAt:O}");
    }

    [Fact]
    public async Task Nightly_batch_reinferes_a_user_with_stale_evidence_directly()
    {
        var factory = context.Factory;
        var (client, userId) = await AuthHelper.LoginAsync(factory, "E-TRACK-4");
        await TestData.SeedHomeLocationAsync(factory, userId, Home.Lat, Home.Lon);
        var (customerId, siteId) = await TestData.SeedCustomerWithSiteAsync(factory, userId, Customer.Lat, Customer.Lon);
        var deviceId = await RegisterDeviceAsync(client);

        var nowLocal = DateTimeOffset.UtcNow + LocalOffset;
        var todayLocalDate = DateOnly.FromDateTime(nowLocal.DateTime);
        var yesterdayLocalDate = todayLocalDate.AddDays(-1);
        await SeedTourWithPlanAsync(client, customerId, siteId, yesterdayLocalDate, todayLocalDate, yesterdayLocalDate);

        // Npgsql only accepts UTC-offset DateTimeOffset values for timestamptz columns.
        var yesterday10Am = new DateTimeOffset(yesterdayLocalDate.ToDateTime(new TimeOnly(10, 0)), LocalOffset)
            .ToUniversalTime();

        using (var scope = factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<XMobileDbContext>();
            void AddPing(DateTimeOffset at, double lat, double lon) => db.Add(new LocationPing
            {
                Id = Guid.NewGuid(),
                UserId = userId,
                DeviceId = deviceId,
                RecordedAt = at,
                ReceivedAt = at,
                Geog = new Point(lon, lat) { SRID = 4326 },
                AccuracyM = 15,
                IsMoving = false,
                Source = PingSource.FG_SERVICE,
            });

            AddPing(yesterday10Am, Home.Lat, Home.Lon);
            AddPing(yesterday10Am.AddMinutes(4), Home.Lat, Home.Lon);
            AddPing(yesterday10Am.AddMinutes(10), Customer.Lat, Customer.Lon);
            AddPing(yesterday10Am.AddMinutes(15), Customer.Lat, Customer.Lon);
            await db.SaveChangesAsync();
        }

        var worker = factory.Services.GetServices<IHostedService>().OfType<NightlyReinferenceWorker>().Single();
        await worker.RunNightlyBatchAsync(CancellationToken.None);

        using (var scope = factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<XMobileDbContext>();
            var runs = await db.Set<InferenceRun>()
                .Where(r => r.UserId == userId && r.TriggerReason == "NIGHTLY")
                .ToListAsync();
            Assert.Contains(runs, r => r.Status == "SUCCESS");
        }
    }

    [Fact]
    public async Task Device_health_round_trips_through_GET_and_PUT()
    {
        var factory = context.Factory;
        var (client, _) = await AuthHelper.LoginAsync(factory, "E-TRACK-5");
        await RegisterDeviceAsync(client);

        using (var health = await ParseAsync(await client.GetAsync("/v1/tracking/health")))
        {
            // Registered without a Health sub-object, so everything reads back at its default.
            Assert.Equal("UNKNOWN", health.RootElement.GetProperty("locationPermission").GetString());
            Assert.False(health.RootElement.GetProperty("autostartConfigured").GetBoolean());
        }

        var putResponse = await client.PutAsJsonAsync("/v1/tracking/health", new
        {
            locationPermission = "ALWAYS",
            batteryOptimised = false,
            notificationsAllowed = true,
            activityPermission = true,
            autostartConfigured = true,
            isPowerSaving = false,
            queuedPings = 3,
        });
        Assert.Equal(HttpStatusCode.OK, putResponse.StatusCode);
        using (var updated = await ParseAsync(putResponse))
        {
            Assert.Equal("ALWAYS", updated.RootElement.GetProperty("locationPermission").GetString());
            Assert.True(updated.RootElement.GetProperty("autostartConfigured").GetBoolean());
            Assert.Equal(3, updated.RootElement.GetProperty("queuedPings").GetInt32());
            Assert.NotEqual(JsonValueKind.Null, updated.RootElement.GetProperty("lastUploadAt").ValueKind);
        }

        using var reread = await ParseAsync(await client.GetAsync("/v1/tracking/health"));
        Assert.Equal("ALWAYS", reread.RootElement.GetProperty("locationPermission").GetString());
    }

    [Fact]
    public async Task Getting_health_without_a_registered_device_is_404()
    {
        var factory = context.Factory;
        var (client, _) = await AuthHelper.LoginAsync(factory, "E-TRACK-6");

        var response = await client.GetAsync("/v1/tracking/health");

        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
    }

    [Fact]
    public async Task Tracking_status_reflects_session_pause_and_resume()
    {
        var factory = context.Factory;
        var (client, _) = await AuthHelper.LoginAsync(factory, "E-TRACK-7");
        var deviceId = await RegisterDeviceAsync(client);

        using (var before = await ParseAsync(await client.GetAsync("/v1/tracking/status")))
        {
            Assert.False(before.RootElement.GetProperty("active").GetBoolean());
        }

        var startResponse = await client.PostAsJsonAsync("/v1/tracking/session", new
        {
            sessionId = Guid.NewGuid(), deviceId, startedAt = DateTimeOffset.UtcNow, startReason = "MANUAL",
        });
        Assert.Equal(HttpStatusCode.Created, startResponse.StatusCode);

        using (var afterStart = await ParseAsync(await client.GetAsync("/v1/tracking/status")))
        {
            Assert.True(afterStart.RootElement.GetProperty("active").GetBoolean());
        }

        var pauseResponse = await client.PostAsJsonAsync(
            "/v1/tracking/status", new { active = false, pauseReasonCode = "PERSONAL_BREAK" });
        Assert.Equal(HttpStatusCode.OK, pauseResponse.StatusCode);
        using (var paused = await ParseAsync(pauseResponse))
        {
            Assert.False(paused.RootElement.GetProperty("active").GetBoolean());
        }

        var resumeResponse = await client.PostAsJsonAsync("/v1/tracking/status", new { active = true });
        Assert.Equal(HttpStatusCode.OK, resumeResponse.StatusCode);
        using var resumed = await ParseAsync(resumeResponse);
        Assert.True(resumed.RootElement.GetProperty("active").GetBoolean());
    }

    [Fact]
    public async Task Pausing_without_a_reason_is_rejected()
    {
        var factory = context.Factory;
        var (client, _) = await AuthHelper.LoginAsync(factory, "E-TRACK-8");
        var deviceId = await RegisterDeviceAsync(client);
        await client.PostAsJsonAsync("/v1/tracking/session", new
        {
            sessionId = Guid.NewGuid(), deviceId, startedAt = DateTimeOffset.UtcNow, startReason = "MANUAL",
        });

        var response = await client.PostAsJsonAsync("/v1/tracking/status", new { active = false });

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }

    [Fact]
    public async Task Pausing_with_nothing_active_is_a_conflict()
    {
        var factory = context.Factory;
        var (client, _) = await AuthHelper.LoginAsync(factory, "E-TRACK-9");

        var response = await client.PostAsJsonAsync(
            "/v1/tracking/status", new { active = false, pauseReasonCode = "PERSONAL_BREAK" });

        Assert.Equal(HttpStatusCode.Conflict, response.StatusCode);
    }

    [Fact]
    public async Task Resuming_with_nothing_paused_is_rejected()
    {
        var factory = context.Factory;
        var (client, _) = await AuthHelper.LoginAsync(factory, "E-TRACK-10");

        var response = await client.PostAsJsonAsync("/v1/tracking/status", new { active = true });

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }

    // ---------------------------------------------------------------- helpers

    private static void AppendStay(List<object> pings, (double Lat, double Lon) point, DateTimeOffset from, TimeSpan duration)
    {
        var to = from + duration;
        for (var t = from; t <= to; t += TimeSpan.FromMinutes(2))
        {
            pings.Add(new
            {
                id = Guid.NewGuid(),
                recordedAt = t,
                point = new { lat = point.Lat, lon = point.Lon },
                accuracyM = 15.0,
                speedMps = 0.0,
                isMoving = false,
                isMock = false,
                source = "FG_SERVICE",
            });
        }
    }

    private static void AppendTravel(
        List<object> pings, (double Lat, double Lon) from, (double Lat, double Lon) to,
        DateTimeOffset departAt, TimeSpan duration)
    {
        var step = TimeSpan.FromMinutes(2);
        var totalSeconds = duration.TotalSeconds;
        for (var elapsed = 0.0; elapsed <= totalSeconds; elapsed += step.TotalSeconds)
        {
            var fraction = elapsed / totalSeconds;
            pings.Add(new
            {
                id = Guid.NewGuid(),
                recordedAt = departAt.AddSeconds(elapsed),
                point = new
                {
                    lat = from.Lat + (to.Lat - from.Lat) * fraction,
                    lon = from.Lon + (to.Lon - from.Lon) * fraction,
                },
                accuracyM = 20.0,
                speedMps = 5.0,
                isMoving = true,
                isMock = false,
                source = "FG_SERVICE",
            });
        }
    }

    private static async Task<JsonDocument> GetJourneyAsync(HttpClient client, DateTimeOffset from, DateTimeOffset to)
    {
        var url = $"/v1/tracking/journey?from={Uri.EscapeDataString(from.ToString("O"))}" +
                   $"&to={Uri.EscapeDataString(to.ToString("O"))}";
        var response = await client.GetAsync(url);
        response.EnsureSuccessStatusCode();
        return await ParseAsync(response);
    }

    private static async Task<Guid> SeedTourWithPlanAsync(
        HttpClient client, Guid customerId, Guid siteId, DateOnly start, DateOnly end, DateOnly planDate)
    {
        var tourId = Guid.NewGuid();
        var tourResponse = await client.PostAsJsonAsync("/v1/tours",
            new { id = tourId, title = "Tracking test tour", plannedStartDate = start, plannedEndDate = end });
        tourResponse.EnsureSuccessStatusCode();

        Guid dayId;
        using (var detail = await ParseAsync(await client.GetAsync($"/v1/tours/{tourId}")))
        {
            dayId = detail.RootElement.GetProperty("days").EnumerateArray()
                .Single(d => DateOnly.Parse(d.GetProperty("planDate").GetString()!) == planDate)
                .GetProperty("id").GetGuid();
        }

        var planResponse = await client.PostAsJsonAsync($"/v1/tours/{tourId}/days/{dayId}/plans", new
        {
            id = Guid.NewGuid(), customerId, siteId, visitTypeCode = "SALES_CALL", plannedDate = planDate,
        });
        planResponse.EnsureSuccessStatusCode();

        return tourId;
    }

    private static async Task<Guid> RegisterDeviceAsync(HttpClient client)
    {
        var deviceId = Guid.NewGuid();
        var response = await client.PostAsJsonAsync(
            "/v1/auth/device", new { deviceId, platform = "ANDROID", model = "Pixel", appVersion = "1.0.0" });
        response.EnsureSuccessStatusCode();
        return deviceId;
    }

    private static async Task<JsonDocument> ParseAsync(HttpResponseMessage response)
        => JsonDocument.Parse(await response.Content.ReadAsStringAsync());
}
