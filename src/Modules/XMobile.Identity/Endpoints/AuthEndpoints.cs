using System.Text.Json;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;
using Microsoft.EntityFrameworkCore;
using XMobile.Identity.Domain;
using XMobile.Identity.Infrastructure;
using XMobile.Persistence;
using XMobile.Persistence.Enums;
using XMobile.Shared;

namespace XMobile.Identity.Endpoints;

public static class AuthEndpoints
{
    public static IEndpointRouteBuilder MapAuthEndpoints(this IEndpointRouteBuilder app)
    {
        var auth = app.MapGroup("/v1/auth").WithTags("Auth").RequireAuthorization();

        // Dev-only bootstrap — see Contracts.cs DevLoginRequest. Not part of api/openapi.yaml.
        auth.MapPost("/dev/login", DevLoginAsync).AllowAnonymous();

        auth.MapPost("/device", RegisterDeviceAsync);
        auth.MapGet("/me", GetMeAsync);
        auth.MapPost("/consent", RecordConsentAsync);

        return app;
    }

    private static async Task<IResult> DevLoginAsync(
        DevLoginRequest request, XMobileDbContext db, IDevTokenIssuer issuer, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(request.EmployeeCode))
        {
            throw new DomainValidationException("employeeCode is required");
        }

        var user = await db.Set<AppUser>().FirstOrDefaultAsync(u => u.EmployeeCode == request.EmployeeCode, ct);
        if (user is null)
        {
            user = new AppUser
            {
                EmployeeCode = request.EmployeeCode,
                FullName = string.IsNullOrWhiteSpace(request.FullName) ? request.EmployeeCode : request.FullName,
            };
            db.Add(user);
            // Flush now: the role row below needs the DB-generated Id.
            await db.SaveChangesAsync(ct);
            db.Add(new UserRole { UserId = user.Id, RoleCode = "SALES_REP", GrantedAt = DateTimeOffset.UtcNow });
            await db.SaveChangesAsync(ct);
        }

        var roles = await db.Set<UserRole>()
            .Where(r => r.UserId == user.Id).Select(r => r.RoleCode).ToListAsync(ct);
        var token = issuer.IssueToken(user, roles);

        return Results.Ok(new DevLoginResult(token, user.Id, user.EmployeeCode, roles));
    }

    private static async Task<IResult> RegisterDeviceAsync(
        DeviceRegistration request, XMobileDbContext db, ICurrentUser currentUser, IClock clock, CancellationToken ct)
    {
        var device = await db.Set<Device>().FirstOrDefaultAsync(d => d.Id == request.DeviceId, ct);
        var isNew = device is null;
        if (isNew)
        {
            device = new Device { Id = request.DeviceId, RegisteredAt = clock.UtcNow };
            db.Add(device);
        }

        device!.UserId = currentUser.UserId;
        device.Platform = Enum.Parse<DevicePlatform>(request.Platform);
        device.Model = request.Model;
        device.Manufacturer = request.Manufacturer;
        device.OsVersion = request.OsVersion;
        device.AppVersion = request.AppVersion;
        device.InstallId = request.InstallId;
        device.PushToken = request.PushToken;
        device.PushProvider = request.PushToken is null ? null : (request.Platform == "IOS" ? "APNS" : "FCM");
        device.IsCompanyOwned = request.IsCompanyOwned ?? device.IsCompanyOwned;
        device.LastSeenAt = clock.UtcNow;

        if (request.Health is { } health)
        {
            device.LocationPermission = health.LocationPermission;
            device.BatteryOptimised = health.BatteryOptimised;
            device.NotificationsAllowed = health.NotificationsAllowed;
            device.ActivityPermission = health.ActivityPermission;
            device.MockLocationAllowed = health.MockLocationAllowed;
            device.TrackingHealthScore = health.Score is { } score ? (short)score : null;
            device.HealthDetails = JsonSerializer.Serialize(health);
        }

        await db.SaveChangesAsync(ct);

        // Sync policy is served once the sync module lands (deferred — see the implementation
        // plan); a device still binds successfully and gets its working policyVersion=1 today.
        return Results.Ok(new DeviceRegistrationResult(
            device.Id, [], 1, new Dictionary<string, object?>(), clock.UtcNow));
    }

    private static async Task<IResult> GetMeAsync(XMobileDbContext db, ICurrentUser currentUser, CancellationToken ct)
    {
        var user = await db.Set<AppUser>().FirstOrDefaultAsync(u => u.Id == currentUser.UserId, ct)
                   ?? throw new NotFoundException("User not found");

        var roles = await db.Set<UserRole>()
            .Where(r => r.UserId == user.Id).Select(r => r.RoleCode).ToListAsync(ct);

        var home = await db.Set<UserHomeLocation>()
            .Where(h => h.UserId == user.Id && h.EffectiveTo == null)
            .FirstOrDefaultAsync(ct);

        Dictionary<string, object?>? orgUnit = null;
        if (user.OrgUnitId is { } orgUnitId)
        {
            var ou = await db.Set<OrgUnit>().FirstOrDefaultAsync(o => o.Id == orgUnitId, ct);
            if (ou is not null)
            {
                orgUnit = new Dictionary<string, object?> { ["id"] = ou.Id, ["code"] = ou.Code, ["name"] = ou.Name };
            }
        }

        var hasConsent = await db.Set<ConsentRecord>()
            .AnyAsync(c => c.UserId == user.Id && c.Granted && c.RevokedAt == null, ct);

        return Results.Ok(new MeResult(
            user.Id,
            user.EmployeeCode,
            user.FullName,
            roles,
            user.ManagerId,
            orgUnit,
            home is null ? null : new HomeLocationDto(home.Id, home.Label, home.Geog.ToGeoPoint(), home.GeofenceRadiusM, home.City),
            user.ShiftStart.ToString("HH:mm"),
            user.ShiftEnd.ToString("HH:mm"),
            user.WorkingDays,
            !hasConsent));
    }

    private static async Task<IResult> RecordConsentAsync(
        ConsentRequest request, XMobileDbContext db, ICurrentUser currentUser, IClock clock, CancellationToken ct)
    {
        db.Add(new ConsentRecord
        {
            UserId = currentUser.UserId,
            PolicyCode = request.PolicyCode,
            PolicyVersion = request.PolicyVersion,
            Granted = request.Granted,
            GrantedAt = clock.UtcNow,
        });
        await db.SaveChangesAsync(ct);
        return Results.NoContent();
    }
}
