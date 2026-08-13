using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Npgsql;

namespace XMobile.Persistence;

public static class ServiceCollectionExtensions
{
    /// <summary>
    /// Registers <see cref="XMobileDbContext"/> against a single <see cref="NpgsqlDataSource"/>
    /// built with every schema-first enum mapped (see <see cref="XMobilePostgres"/>). Call once
    /// from the host; each module's `Add{Module}()` then adds its assembly to
    /// <see cref="PersistenceModelOptions"/> so its entity configurations are picked up.
    /// </summary>
    /// <remarks>
    /// The connection string is read from <see cref="IConfiguration"/> lazily, inside the
    /// singleton factory, rather than once up front in Program.cs — <c>WebApplicationFactory</c>
    /// (used by XMobile.Api.Tests) overrides configuration at host-build time, after Program.cs's
    /// top-level statements have already started running; reading it eagerly would capture the
    /// real (unconfigured) connection string instead of the test container's.
    /// </remarks>
    public static IServiceCollection AddXMobilePersistence(this IServiceCollection services)
    {
        services.AddSingleton(sp =>
        {
            var connectionString = sp.GetRequiredService<IConfiguration>().GetConnectionString("XMobile")
                ?? throw new InvalidOperationException("ConnectionStrings:XMobile is not configured");
            return XMobilePostgres.BuildDataSource(connectionString);
        });

        services.AddDbContext<XMobileDbContext>((sp, options) =>
            options.UseNpgsql(sp.GetRequiredService<NpgsqlDataSource>(),
                    npgsql => npgsql.UseNetTopologySuite())
                .UseSnakeCaseNamingConvention());

        return services;
    }

    /// <summary>Called by each module's `Add{Module}()` to register its entity configurations.</summary>
    public static IServiceCollection AddPersistenceModule<TMarker>(this IServiceCollection services)
    {
        services.Configure<PersistenceModelOptions>(o => o.ModuleAssemblies.Add(typeof(TMarker).Assembly));
        return services;
    }
}
