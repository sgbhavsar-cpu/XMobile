using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using XMobile.Api.Tests.Support;

namespace XMobile.Api.Tests.Scenarios;

/// <summary>
/// The Phase 1 exit criterion, end to end through real HTTP against a real (Testcontainers)
/// Postgres: sign in, plan a day, check in and out of a visit, submit its report — proving the
/// schema-first EF mappings, the actor-id write path, and the Planning/Visits cross-module
/// completion port all actually work together, not just compile.
/// </summary>
[Collection("api")]
public sealed class CoreFlowTests(ApiTestContext context)
{
    [Fact]
    public async Task Rep_can_plan_a_day_and_complete_a_visit_end_to_end()
    {
        var factory = context.Factory;
        var (client, userId) = await AuthHelper.LoginAsync(factory, "E-CORE-1");
        await TestData.SeedHomeLocationAsync(factory, userId);
        var (customerId, siteId) = await TestData.SeedCustomerWithSiteAsync(factory, userId);

        var deviceResponse = await client.PostAsJsonAsync("/v1/auth/device", new
        {
            deviceId = Guid.NewGuid(), platform = "ANDROID", model = "Pixel", appVersion = "1.0.0",
        });
        Assert.Equal(HttpStatusCode.OK, deviceResponse.StatusCode);

        var meResponse = await client.GetAsync("/v1/auth/me");
        Assert.Equal(HttpStatusCode.OK, meResponse.StatusCode);
        using (var me = await ParseAsync(meResponse))
        {
            Assert.True(me.RootElement.GetProperty("consentRequired").GetBoolean());
        }

        var consentResponse = await client.PostAsJsonAsync(
            "/v1/auth/consent", new { policyCode = "LOCATION_TRACKING", policyVersion = "1", granted = true });
        Assert.Equal(HttpStatusCode.NoContent, consentResponse.StatusCode);

        var today = DateOnly.FromDateTime(DateTime.UtcNow);
        var tourId = Guid.NewGuid();
        var tourResponse = await client.PostAsJsonAsync("/v1/tours", new
        {
            id = tourId, title = "Pune day", plannedStartDate = today, plannedEndDate = today,
        });
        Assert.Equal(HttpStatusCode.Created, tourResponse.StatusCode);
        using (var tour = await ParseAsync(tourResponse))
        {
            Assert.Equal("PLANNED", tour.RootElement.GetProperty("status").GetString());
        }

        Guid dayId;
        var tourDetailResponse = await client.GetAsync($"/v1/tours/{tourId}");
        Assert.Equal(HttpStatusCode.OK, tourDetailResponse.StatusCode);
        using (var detail = await ParseAsync(tourDetailResponse))
        {
            var days = detail.RootElement.GetProperty("days");
            Assert.Equal(1, days.GetArrayLength());
            dayId = days[0].GetProperty("id").GetGuid();
        }

        var planId = Guid.NewGuid();
        var planResponse = await client.PostAsJsonAsync($"/v1/tours/{tourId}/days/{dayId}/plans", new
        {
            id = planId, customerId, siteId, visitTypeCode = "SALES_CALL", plannedDate = today,
        });
        Assert.Equal(HttpStatusCode.Created, planResponse.StatusCode);

        var visitId = Guid.NewGuid();
        var checkInResponse = await client.PostAsJsonAsync("/v1/visits/check-in", new
        {
            visitId,
            visitPlanId = planId,
            tourId,
            siteId,
            checkInAt = DateTimeOffset.UtcNow,
            point = new { lat = 18.52, lon = 73.85 },
            method = "MANUAL",
        });
        Assert.Equal(HttpStatusCode.Created, checkInResponse.StatusCode);
        using (var visit = await ParseAsync(checkInResponse))
        {
            Assert.Equal("CHECKED_IN", visit.RootElement.GetProperty("status").GetString());
            Assert.False(visit.RootElement.GetProperty("isOutOfGeofence").GetBoolean());
        }

        // Checking in against a plan must complete it — the Visits -> Planning cross-module port.
        var tourAfterCheckIn = await client.GetAsync($"/v1/tours/{tourId}");
        using (var detail = await ParseAsync(tourAfterCheckIn))
        {
            var plan = detail.RootElement.GetProperty("plans")[0];
            Assert.Equal("COMPLETED", plan.GetProperty("status").GetString());
            var tourVisits = detail.RootElement.GetProperty("visits");
            Assert.Equal(1, tourVisits.GetArrayLength());
        }

        var checkOutResponse = await client.PostAsJsonAsync(
            $"/v1/visits/{visitId}/check-out", new { checkOutAt = DateTimeOffset.UtcNow.AddMinutes(20) });
        Assert.Equal(HttpStatusCode.OK, checkOutResponse.StatusCode);
        using (var visit = await ParseAsync(checkOutResponse))
        {
            Assert.Equal("CHECKED_OUT", visit.RootElement.GetProperty("status").GetString());
        }

        var reportResponse = await client.PutAsJsonAsync($"/v1/visits/{visitId}/report", new
        {
            outcomeCode = "ORDER_BOOKED",
            summary = "Good visit",
            submit = true,
            answers = new Dictionary<string, object> { ["stock_checked"] = true },
        });
        Assert.Equal(HttpStatusCode.OK, reportResponse.StatusCode);
        using (var report = await ParseAsync(reportResponse))
        {
            Assert.False(report.RootElement.GetProperty("isDraft").GetBoolean());
        }

        var customerResponse = await client.GetAsync($"/v1/customers/{customerId}");
        Assert.Equal(HttpStatusCode.OK, customerResponse.StatusCode);

        var summaryResponse = await client.GetAsync($"/v1/customers/{customerId}/summary");
        Assert.Equal(HttpStatusCode.OK, summaryResponse.StatusCode);
        using (var summary = await ParseAsync(summaryResponse))
        {
            Assert.Equal(1, summary.RootElement.GetProperty("visits90d").GetInt32());
        }

        var historyResponse = await client.GetAsync($"/v1/customers/{customerId}/history");
        Assert.Equal(HttpStatusCode.OK, historyResponse.StatusCode);

        var templatesResponse = await client.GetAsync("/v1/form-templates?visitTypeCode=SALES_CALL");
        Assert.Equal(HttpStatusCode.OK, templatesResponse.StatusCode);
        using (var templates = await ParseAsync(templatesResponse))
        {
            // Seeded by db/schema/10_seed.sql (STD_SALES_CALL).
            Assert.True(templates.RootElement.GetArrayLength() >= 1);
        }
    }

    [Fact]
    public async Task Starting_a_second_tour_while_one_is_in_progress_is_rejected()
    {
        var factory = context.Factory;
        var (client, userId) = await AuthHelper.LoginAsync(factory, "E-CORE-2");
        await TestData.SeedHomeLocationAsync(factory, userId);
        var today = DateOnly.FromDateTime(DateTime.UtcNow);

        var firstId = Guid.NewGuid();
        await client.PostAsJsonAsync("/v1/tours",
            new { id = firstId, title = "First", plannedStartDate = today, plannedEndDate = today });
        var firstStart = await client.PostAsync($"/v1/tours/{firstId}/start", content: null);
        Assert.Equal(HttpStatusCode.NoContent, firstStart.StatusCode);

        var secondId = Guid.NewGuid();
        await client.PostAsJsonAsync("/v1/tours",
            new { id = secondId, title = "Second", plannedStartDate = today, plannedEndDate = today });
        var secondStart = await client.PostAsync($"/v1/tours/{secondId}/start", content: null);

        Assert.Equal(HttpStatusCode.Conflict, secondStart.StatusCode);
    }

    [Fact]
    public async Task A_rep_cannot_read_another_reps_tour()
    {
        var factory = context.Factory;
        var (ownerClient, ownerId) = await AuthHelper.LoginAsync(factory, "E-CORE-3A");
        await TestData.SeedHomeLocationAsync(factory, ownerId);
        var (_, otherId) = await AuthHelper.LoginAsync(factory, "E-CORE-3B");

        var today = DateOnly.FromDateTime(DateTime.UtcNow);
        var tourId = Guid.NewGuid();
        var createResponse = await ownerClient.PostAsJsonAsync("/v1/tours",
            new { id = tourId, title = "Owner's tour", plannedStartDate = today, plannedEndDate = today });
        Assert.Equal(HttpStatusCode.Created, createResponse.StatusCode);

        var (otherClient, _) = await AuthHelper.LoginAsync(factory, "E-CORE-3B");
        _ = otherId;
        var response = await otherClient.GetAsync($"/v1/tours/{tourId}");

        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
    }

    [Fact]
    public async Task Check_in_outside_the_geofence_requires_a_reason()
    {
        var factory = context.Factory;
        var (client, userId) = await AuthHelper.LoginAsync(factory, "E-CORE-4");
        var (_, siteId) = await TestData.SeedCustomerWithSiteAsync(factory, userId, lat: 18.52, lon: 73.85);

        var response = await client.PostAsJsonAsync("/v1/visits/check-in", new
        {
            visitId = Guid.NewGuid(),
            siteId,
            // ~11km away — well outside the 150m geofence, no reason code supplied.
            checkInAt = DateTimeOffset.UtcNow,
            point = new { lat = 18.62, lon = 73.85 },
            method = "MANUAL",
        });

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }

    /// <summary>Regression test for the Npgsql "Cannot write DateTimeOffset with Offset=X..."
    /// bug (docs/10-roadmap.md §6) — every other test in this file submits DateTimeOffset.UtcNow
    /// (offset always zero), which never exercised this. A real device reports its own local
    /// offset.</summary>
    [Fact]
    public async Task Check_in_accepts_a_non_utc_offset_timestamp()
    {
        var factory = context.Factory;
        var (client, userId) = await AuthHelper.LoginAsync(factory, "E-CORE-5");
        var (_, siteId) = await TestData.SeedCustomerWithSiteAsync(factory, userId, lat: 18.52, lon: 73.85);

        var response = await client.PostAsJsonAsync("/v1/visits/check-in", new
        {
            visitId = Guid.NewGuid(),
            siteId,
            checkInAt = DateTimeOffset.UtcNow.ToOffset(TimeSpan.FromHours(5.5)),
            point = new { lat = 18.52, lon = 73.85 },
            method = "MANUAL",
        });

        Assert.Equal(HttpStatusCode.Created, response.StatusCode);
    }

    private static async Task<JsonDocument> ParseAsync(HttpResponseMessage response)
        => JsonDocument.Parse(await response.Content.ReadAsStringAsync());
}
