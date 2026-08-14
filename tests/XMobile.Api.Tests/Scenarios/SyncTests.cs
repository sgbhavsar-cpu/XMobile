using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using XMobile.Api.Tests.Support;

namespace XMobile.Api.Tests.Scenarios;

/// <summary>
/// The offline protocol (docs/04-offline-sync.md): a delta pull scoped to the caller, a push
/// batch that can create a row purely from its payload (the "created entirely offline" case),
/// and the conflict record/resolve round-trip. Same Testcontainers Postgres as CoreFlowTests.
/// </summary>
[Collection("api")]
public sealed class SyncTests(ApiTestContext context)
{
    [Fact]
    public async Task Pull_is_scoped_to_the_owning_rep()
    {
        var factory = context.Factory;
        var (ownerClient, ownerId) = await AuthHelper.LoginAsync(factory, "E-SYNC-1A");
        await TestData.SeedHomeLocationAsync(factory, ownerId);
        var (otherClient, _) = await AuthHelper.LoginAsync(factory, "E-SYNC-1B");

        var today = DateOnly.FromDateTime(DateTime.UtcNow);
        var tourId = Guid.NewGuid();
        var createResponse = await ownerClient.PostAsJsonAsync("/v1/tours",
            new { id = tourId, title = "Sync scope tour", plannedStartDate = today, plannedEndDate = today });
        Assert.Equal(HttpStatusCode.Created, createResponse.StatusCode);

        var ownerPull = await ownerClient.GetAsync("/v1/sync/pull?entities=planning.tour");
        Assert.Equal(HttpStatusCode.OK, ownerPull.StatusCode);
        Assert.True(ContainsEntityId(await ParseAsync(ownerPull), tourId));

        var otherPull = await otherClient.GetAsync("/v1/sync/pull?entities=planning.tour");
        Assert.Equal(HttpStatusCode.OK, otherPull.StatusCode);
        Assert.False(ContainsEntityId(await ParseAsync(otherPull), tourId));
    }

    [Fact]
    public async Task Push_creates_a_visit_plan_purely_from_its_payload()
    {
        var factory = context.Factory;
        var (client, userId) = await AuthHelper.LoginAsync(factory, "E-SYNC-2");
        await TestData.SeedHomeLocationAsync(factory, userId);
        var (customerId, siteId) = await TestData.SeedCustomerWithSiteAsync(factory, userId);
        var deviceId = await RegisterDeviceAsync(client);

        var today = DateOnly.FromDateTime(DateTime.UtcNow);
        var tourId = Guid.NewGuid();
        await client.PostAsJsonAsync("/v1/tours",
            new { id = tourId, title = "Push tour", plannedStartDate = today, plannedEndDate = today });

        Guid dayId;
        using (var detail = await ParseAsync(await client.GetAsync($"/v1/tours/{tourId}")))
        {
            dayId = detail.RootElement.GetProperty("days")[0].GetProperty("id").GetGuid();
        }

        var planId = Guid.NewGuid();
        var pushResponse = await client.PostAsJsonAsync("/v1/sync/push", new
        {
            deviceId,
            mutations = new[]
            {
                new
                {
                    clientMutationId = Guid.NewGuid(),
                    entity = "planning.visit_plan",
                    id = planId,
                    op = "INSERT",
                    data = new
                    {
                        tourId, tourDayId = dayId, customerId, siteId,
                        visitTypeCode = "SALES_CALL", plannedDate = today,
                    },
                },
            },
        });
        Assert.Equal(HttpStatusCode.OK, pushResponse.StatusCode);
        using (var push = await ParseAsync(pushResponse))
        {
            Assert.Equal("APPLIED", push.RootElement.GetProperty("results")[0].GetProperty("status").GetString());
        }

        using var tourDetail = await ParseAsync(await client.GetAsync($"/v1/tours/{tourId}"));
        var plans = tourDetail.RootElement.GetProperty("plans");
        Assert.Equal(1, plans.GetArrayLength());
        Assert.Equal(planId, plans[0].GetProperty("id").GetGuid());
    }

    [Fact]
    public async Task Stale_push_conflicts_and_KEEP_CLIENT_resolves_it()
    {
        var factory = context.Factory;
        var (client, userId) = await AuthHelper.LoginAsync(factory, "E-SYNC-3");
        await TestData.SeedHomeLocationAsync(factory, userId);
        var deviceId = await RegisterDeviceAsync(client);

        var today = DateOnly.FromDateTime(DateTime.UtcNow);
        var tourId = Guid.NewGuid();
        await client.PostAsJsonAsync("/v1/tours",
            new { id = tourId, title = "Original title", plannedStartDate = today, plannedEndDate = today });

        var pushResponse = await client.PostAsJsonAsync("/v1/sync/push", new
        {
            deviceId,
            mutations = new[]
            {
                new
                {
                    clientMutationId = Guid.NewGuid(),
                    entity = "planning.tour",
                    id = tourId,
                    op = "UPDATE",
                    baseVersion = 999L, // deliberately stale — a freshly created tour is at rowVersion 0
                    data = new { title = "Changed offline" },
                },
            },
        });
        Assert.Equal(HttpStatusCode.OK, pushResponse.StatusCode);

        Guid conflictId;
        using (var push = await ParseAsync(pushResponse))
        {
            var result = push.RootElement.GetProperty("results")[0];
            Assert.Equal("CONFLICT", result.GetProperty("status").GetString());
            conflictId = result.GetProperty("conflictId").GetGuid();
        }

        using (var conflicts = await ParseAsync(await client.GetAsync("/v1/sync/conflicts")))
        {
            Assert.Contains(
                conflicts.RootElement.EnumerateArray(),
                c => c.GetProperty("id").GetGuid() == conflictId);
        }

        var resolveResponse = await client.PostAsJsonAsync(
            $"/v1/sync/conflicts/{conflictId}/resolve", new { choice = "KEEP_CLIENT" });
        Assert.Equal(HttpStatusCode.NoContent, resolveResponse.StatusCode);

        using (var conflicts = await ParseAsync(await client.GetAsync("/v1/sync/conflicts")))
        {
            Assert.DoesNotContain(
                conflicts.RootElement.EnumerateArray(),
                c => c.GetProperty("id").GetGuid() == conflictId);
        }

        using var tour = await ParseAsync(await client.GetAsync($"/v1/tours/{tourId}"));
        Assert.Equal("Changed offline", tour.RootElement.GetProperty("title").GetString());
    }

    /// <summary>Regression test for the Npgsql "Cannot write DateTimeOffset with Offset=X..."
    /// bug (docs/10-roadmap.md §6) — `sync.client_mutation.occurred_at` is written from every
    /// pushed mutation's `occurredAt`, and every other test in this file omits it or uses
    /// DateTimeOffset.UtcNow (offset always zero), which never exercised this. A real device
    /// reports its own local offset.</summary>
    [Fact]
    public async Task Push_accepts_a_mutation_with_a_non_utc_offset_occurredAt()
    {
        var factory = context.Factory;
        var (client, userId) = await AuthHelper.LoginAsync(factory, "E-SYNC-4");
        await TestData.SeedHomeLocationAsync(factory, userId);
        var deviceId = await RegisterDeviceAsync(client);

        var today = DateOnly.FromDateTime(DateTime.UtcNow);
        var tourId = Guid.NewGuid();
        var pushResponse = await client.PostAsJsonAsync("/v1/sync/push", new
        {
            deviceId,
            mutations = new[]
            {
                new
                {
                    clientMutationId = Guid.NewGuid(),
                    entity = "planning.tour",
                    id = tourId,
                    op = "INSERT",
                    occurredAt = DateTimeOffset.UtcNow.ToOffset(TimeSpan.FromHours(5.5)),
                    data = new { title = "Pushed offline", plannedStartDate = today, plannedEndDate = today },
                },
            },
        });

        Assert.Equal(HttpStatusCode.OK, pushResponse.StatusCode);
        using var push = await ParseAsync(pushResponse);
        Assert.Equal("APPLIED", push.RootElement.GetProperty("results")[0].GetProperty("status").GetString());
    }

    /// <summary>`sync.client_mutation.device_id` has a real FK to `identity.device` — push
    /// needs a registered device, exactly as a real client would already have from onboarding.</summary>
    private static async Task<Guid> RegisterDeviceAsync(HttpClient client)
    {
        var deviceId = Guid.NewGuid();
        var response = await client.PostAsJsonAsync(
            "/v1/auth/device", new { deviceId, platform = "ANDROID", model = "Pixel", appVersion = "1.0.0" });
        response.EnsureSuccessStatusCode();
        return deviceId;
    }

    private static bool ContainsEntityId(JsonDocument pullResponse, Guid entityId)
        => pullResponse.RootElement.GetProperty("changes").EnumerateArray()
            .Any(c => c.GetProperty("id").GetString() == entityId.ToString());

    private static async Task<JsonDocument> ParseAsync(HttpResponseMessage response)
        => JsonDocument.Parse(await response.Content.ReadAsStringAsync());
}
