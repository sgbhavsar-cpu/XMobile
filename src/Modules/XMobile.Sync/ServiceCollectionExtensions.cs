using Microsoft.Extensions.DependencyInjection;
using XMobile.Persistence;

namespace XMobile.Sync;

/// <summary>Marker type whose assembly XMobile.Persistence scans for entity configurations.</summary>
public sealed class SyncModuleMarker;

public static class ServiceCollectionExtensions
{
    public static IServiceCollection AddSyncModule(this IServiceCollection services)
    {
        services.AddPersistenceModule<SyncModuleMarker>();
        return services;
    }
}
