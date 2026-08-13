using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using XMobile.Api.Tests.Support;

namespace XMobile.Api.Tests.Scenarios;

/// <summary>
/// `PUT /v1/auth/home` is not in api/openapi.yaml (see AuthEndpoints.cs) — added because
/// `POST /v1/tours` hard-requires a home location and nothing else could ever set one. Unlike
/// CoreFlowTests, this one deliberately does NOT call TestData.SeedHomeLocationAsync — the whole
/// point is proving a tour can be planned without seeding straight into the database.
/// </summary>
[Collection("api")]
public sealed class HomeLocationTests(ApiTestContext context)
{
    [Fact]
    public async Task Setting_a_home_location_unblocks_tour_creation()
    {
        var factory = context.Factory;
        var (client, _) = await AuthHelper.LoginAsync(factory, "E-HOME-1");

        var today = DateOnly.FromDateTime(DateTime.UtcNow);
        var beforeHome = await client.PostAsJsonAsync("/v1/tours",
            new { id = Guid.NewGuid(), title = "Too early", plannedStartDate = today, plannedEndDate = today });
        Assert.Equal(HttpStatusCode.BadRequest, beforeHome.StatusCode);

        var homeResponse = await client.PutAsJsonAsync("/v1/auth/home", new
        {
            label = "Home", point = new { lat = 18.52, lon = 73.85 }, geofenceRadiusM = 200, city = "Pune",
        });
        Assert.Equal(HttpStatusCode.OK, homeResponse.StatusCode);
        using (var home = await ParseAsync(homeResponse))
        {
            Assert.Equal("Pune", home.RootElement.GetProperty("city").GetString());
        }

        var tourId = Guid.NewGuid();
        var afterHome = await client.PostAsJsonAsync("/v1/tours",
            new { id = tourId, title = "Now possible", plannedStartDate = today, plannedEndDate = today });
        Assert.Equal(HttpStatusCode.Created, afterHome.StatusCode);

        // Calling it again (rep relocates) updates in place rather than erroring or duplicating.
        var secondHomeResponse = await client.PutAsJsonAsync("/v1/auth/home", new
        {
            label = "Home", point = new { lat = 19.0, lon = 72.8 }, geofenceRadiusM = 250, city = "Mumbai",
        });
        Assert.Equal(HttpStatusCode.OK, secondHomeResponse.StatusCode);
        using (var home = await ParseAsync(secondHomeResponse))
        {
            Assert.Equal("Mumbai", home.RootElement.GetProperty("city").GetString());
        }

        using var me = await ParseAsync(await client.GetAsync("/v1/auth/me"));
        Assert.Equal("Mumbai", me.RootElement.GetProperty("homeLocation").GetProperty("city").GetString());
    }

    private static async Task<JsonDocument> ParseAsync(HttpResponseMessage response)
        => JsonDocument.Parse(await response.Content.ReadAsStringAsync());
}
