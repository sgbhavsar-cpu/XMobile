using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;

namespace XMobile.Api.Tests.Support;

internal static class AuthHelper
{
    /// <summary>Dev-login (not in api/openapi.yaml — see XMobile.Identity.Contracts.DevLoginRequest)
    /// then attaches the returned bearer token to a fresh client's default headers.</summary>
    public static async Task<(HttpClient Client, Guid UserId)> LoginAsync(ApiFactory factory, string employeeCode)
    {
        var client = factory.CreateClient();
        var response = await client.PostAsJsonAsync(
            "/v1/auth/dev/login", new { employeeCode, fullName = employeeCode });
        response.EnsureSuccessStatusCode();

        using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        var token = doc.RootElement.GetProperty("accessToken").GetString()!;
        var userId = doc.RootElement.GetProperty("userId").GetGuid();

        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        return (client, userId);
    }
}
