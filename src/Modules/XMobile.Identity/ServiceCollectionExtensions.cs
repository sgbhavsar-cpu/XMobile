using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using XMobile.Identity.Infrastructure;
using XMobile.Persistence;
using XMobile.Shared;

namespace XMobile.Identity;

/// <summary>Marker type whose assembly XMobile.Persistence scans for entity configurations.</summary>
public sealed class IdentityModuleMarker;

public static class ServiceCollectionExtensions
{
    public static IServiceCollection AddIdentityModule(this IServiceCollection services, IConfiguration configuration)
    {
        services.Configure<DevJwtOptions>(configuration.GetSection(DevJwtOptions.SectionName));
        services.AddHttpContextAccessor();
        services.AddScoped<ICurrentUser, HttpCurrentUser>();
        services.AddScoped<IDevTokenIssuer, DevTokenIssuer>();
        services.AddScoped<IUserScopeService, UserScopeService>();
        services.AddPersistenceModule<IdentityModuleMarker>();
        return services;
    }
}
