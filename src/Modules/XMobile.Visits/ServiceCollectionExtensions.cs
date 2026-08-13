using Microsoft.Extensions.DependencyInjection;
using XMobile.Persistence;
using XMobile.Shared;
using XMobile.Visits.Infrastructure;

namespace XMobile.Visits;

/// <summary>Marker type whose assembly XMobile.Persistence scans for entity configurations.</summary>
public sealed class VisitsModuleMarker;

public static class ServiceCollectionExtensions
{
    public static IServiceCollection AddVisitsModule(this IServiceCollection services)
    {
        services.AddScoped<IVisitLookup, VisitLookupService>();
        services.AddPersistenceModule<VisitsModuleMarker>();
        return services;
    }
}
