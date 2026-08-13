using Microsoft.Extensions.DependencyInjection;
using XMobile.Customers.Infrastructure;
using XMobile.Persistence;
using XMobile.Shared;

namespace XMobile.Customers;

/// <summary>Marker type whose assembly XMobile.Persistence scans for entity configurations.</summary>
public sealed class CustomersModuleMarker;

public static class ServiceCollectionExtensions
{
    public static IServiceCollection AddCustomersModule(this IServiceCollection services)
    {
        services.AddScoped<ISiteLookup, SiteLookupService>();
        services.AddPersistenceModule<CustomersModuleMarker>();
        return services;
    }
}
