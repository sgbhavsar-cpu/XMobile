namespace XMobile.Identity;

// Wire DTOs mirror api/openapi.yaml component schemas (Auth section) — property names use
// camelCase via System.Text.Json's default policy configured in XMobile.Api.

/// <summary>
/// Dev-only bootstrap, not in api/openapi.yaml: mints the bearer token that a real deployment
/// gets from Keycloak's PKCE flow. Looks up-or-creates the app_user by employee code (stands in
/// for AD/LDAP provisioning) and returns a token whose claims `/v1/auth/device` and every other
/// endpoint validate exactly the way they will once Keycloak is real — only the issuer changes.
/// </summary>
public sealed record DevLoginRequest(string EmployeeCode, string? FullName);

public sealed record DevLoginResult(string AccessToken, Guid UserId, string EmployeeCode, IReadOnlyList<string> Roles);

public sealed record TrackingHealthDto(
    string? LocationPermission,
    bool? BatteryOptimised,
    bool? NotificationsAllowed,
    bool? ActivityPermission,
    bool? MockLocationAllowed,
    bool? IsPowerSaving,
    int? Score,
    IReadOnlyList<string>? Issues);

public sealed record DeviceRegistration(
    Guid DeviceId,
    string Platform,
    string? Model,
    string? Manufacturer,
    string? OsVersion,
    string? AppVersion,
    string? InstallId,
    string? PushToken,
    bool? IsCompanyOwned,
    TrackingHealthDto? Health);

public sealed record DeviceRegistrationResult(
    Guid DeviceId,
    IReadOnlyList<object> SyncPolicy,
    int PolicyVersion,
    IReadOnlyDictionary<string, object?> Settings,
    DateTimeOffset ServerTime);

public sealed record HomeLocationDto(
    Guid Id, string Label, XMobile.Shared.GeoPoint Point, int GeofenceRadiusM, string? City);

public sealed record MeResult(
    Guid UserId,
    string EmployeeCode,
    string FullName,
    IReadOnlyList<string> Roles,
    Guid? ManagerId,
    IReadOnlyDictionary<string, object?>? OrgUnit,
    HomeLocationDto? HomeLocation,
    string ShiftStart,
    string ShiftEnd,
    IReadOnlyList<short> WorkingDays,
    bool ConsentRequired);

public sealed record ConsentRequest(string PolicyCode, string PolicyVersion, bool Granted);

/// <summary>Not in api/openapi.yaml — see `PUT /v1/auth/home` in AuthEndpoints.cs.</summary>
public sealed record UpdateHomeLocationRequest(
    string? Label, XMobile.Shared.GeoPoint Point, int? GeofenceRadiusM, string? City);
