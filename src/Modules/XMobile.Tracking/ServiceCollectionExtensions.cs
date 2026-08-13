using Microsoft.Extensions.DependencyInjection;
using XMobile.Persistence;
using XMobile.Tracking.Infrastructure;

namespace XMobile.Tracking;

/// <summary>Marker type whose assembly XMobile.Persistence scans for entity configurations.</summary>
public sealed class TrackingModuleMarker;

public static class ServiceCollectionExtensions
{
    public static IServiceCollection AddTrackingModule(this IServiceCollection services)
    {
        services.AddScoped<InferenceRunner>();
        services.AddHostedService<NightlyReinferenceWorker>();
        services.AddPersistenceModule<TrackingModuleMarker>();
        return services;
    }
}
