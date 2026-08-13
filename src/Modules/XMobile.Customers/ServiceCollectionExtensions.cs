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
        services.AddScoped<ICustomerScopeService, CustomerScopeService>();
        services.AddScoped<IGeofenceLookup, GeofenceLookupService>();
        services.AddScoped<ISyncEntityHandler, CustomerAccountSyncHandler>();
        services.AddScoped<ISyncEntityHandler, CustomerSiteSyncHandler>();
        services.AddPersistenceModule<CustomersModuleMarker>();
        return services;
    }
}
