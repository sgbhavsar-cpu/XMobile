using Microsoft.Extensions.DependencyInjection;
using XMobile.Persistence;
using XMobile.Planning.Infrastructure;
using XMobile.Shared;

namespace XMobile.Planning;

/// <summary>Marker type whose assembly XMobile.Persistence scans for entity configurations.</summary>
public sealed class PlanningModuleMarker;

public static class ServiceCollectionExtensions
{
    public static IServiceCollection AddPlanningModule(this IServiceCollection services)
    {
        services.AddScoped<IVisitPlanCompletion, VisitPlanCompletionService>();
        services.AddScoped<ISyncEntityHandler, TourSyncHandler>();
        services.AddScoped<ISyncEntityHandler, TourDaySyncHandler>();
        services.AddScoped<ISyncEntityHandler, VisitPlanSyncHandler>();
        services.AddPersistenceModule<PlanningModuleMarker>();
        return services;
    }
}
