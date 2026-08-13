using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.Configuration;

namespace XMobile.Api.Tests.Support;

public sealed class ApiFactory(string connectionString) : WebApplicationFactory<Program>
{
    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.ConfigureAppConfiguration((_, config) =>
        {
            config.AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["ConnectionStrings:XMobile"] = connectionString,
                // 32+ bytes, required for HS256 — see XMobile.Identity.Infrastructure.DevJwtOptions.
                ["DevJwt:SigningKey"] = "test-only-signing-key-do-not-use-elsewhere-32bytes+",
            });
        });
    }
}

/// <summary>Shares one container + host across every test in the "api" collection — starting a
/// Postgres container per test class would make the suite minutes slower for no benefit.</summary>
public sealed class ApiTestContext : IAsyncLifetime
{
    private readonly PostgresFixture _postgres = new();

    public ApiFactory Factory { get; private set; } = null!;

    public async Task InitializeAsync()
    {
        await _postgres.InitializeAsync();
        Factory = new ApiFactory(_postgres.ConnectionString);
    }

    public async Task DisposeAsync()
    {
        await Factory.DisposeAsync();
        await _postgres.DisposeAsync();
    }
}

[CollectionDefinition("api")]
public sealed class ApiCollection : ICollectionFixture<ApiTestContext>;
