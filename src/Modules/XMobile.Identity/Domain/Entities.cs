using XMobile.Persistence;
using XMobile.Persistence.Enums;

namespace XMobile.Identity.Domain;

public sealed class AppUser : ISyncableEntity, ISoftDeletable
{
    public Guid Id { get; set; }
    public string? ExternalSubject { get; set; }
    public string? Upn { get; set; }
    public required string EmployeeCode { get; set; }
    public string? XinfoUserId { get; set; }
    public required string FullName { get; set; }
    public string? Email { get; set; }
    public string? Phone { get; set; }
    public string? Grade { get; set; }
    public string? Designation { get; set; }
    public Guid? OrgUnitId { get; set; }
    public Guid? ManagerId { get; set; }
    public string DefaultTimezone { get; set; } = "Asia/Kolkata";
    public TimeOnly ShiftStart { get; set; } = new(9, 0);
    public TimeOnly ShiftEnd { get; set; } = new(18, 0);
    public short[] WorkingDays { get; set; } = [1, 2, 3, 4, 5, 6];
    public bool TrackingEnabled { get; set; } = true;
    public UserStatus Status { get; set; } = UserStatus.ACTIVE;
    public DateOnly? JoinedOn { get; set; }
    public DateOnly? LeftOn { get; set; }
    public long RowVersion { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
    public DateTimeOffset? DeletedAt { get; set; }
}

public sealed class UserRole
{
    public Guid UserId { get; set; }
    public required string RoleCode { get; set; }
    public DateTimeOffset GrantedAt { get; set; }
    public Guid? GrantedBy { get; set; }
}

public sealed class Device : ISyncableEntity, IHasGuidKey
{
    public Guid Id { get; set; }
    public Guid UserId { get; set; }
    public DevicePlatform Platform { get; set; }
    public string? Model { get; set; }
    public string? Manufacturer { get; set; }
    public string? OsVersion { get; set; }
    public string? AppVersion { get; set; }
    public string? InstallId { get; set; }
    public string? Fingerprint { get; set; }
    public string? PushToken { get; set; }
    public string? PushProvider { get; set; }
    public bool IsCompanyOwned { get; set; }
    public string? LocationPermission { get; set; }
    public bool? BatteryOptimised { get; set; }
    public bool? NotificationsAllowed { get; set; }
    public bool? ActivityPermission { get; set; }
    public bool? MockLocationAllowed { get; set; }
    public short? TrackingHealthScore { get; set; }
    public string HealthDetails { get; set; } = "{}";
    public int ClockSkewSec { get; set; }
    public DateTimeOffset? LastSeenAt { get; set; }
    public DateTimeOffset? LastSyncAt { get; set; }
    public DateTimeOffset RegisteredAt { get; set; }
    public DateTimeOffset? RevokedAt { get; set; }
    public Guid? RevokedBy { get; set; }
    public string? RevokeReason { get; set; }
    public bool WipeRequested { get; set; }
    public long RowVersion { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
}

public sealed class UserHomeLocation : ISyncableEntity, ISoftDeletable
{
    public Guid Id { get; set; }
    public Guid UserId { get; set; }
    public string Label { get; set; } = "Home";
    public string? AddressLine1 { get; set; }
    public string? AddressLine2 { get; set; }
    public string? City { get; set; }
    public string? State { get; set; }
    public string? PostalCode { get; set; }
    public string CountryCode { get; set; } = "IN";
    public required NetTopologySuite.Geometries.Point Geog { get; set; }
    public int GeofenceRadiusM { get; set; } = 200;
    public GeoSource GeoSource { get; set; } = GeoSource.FIELD_CAPTURED;
    public double? AccuracyM { get; set; }
    public DateOnly EffectiveFrom { get; set; }
    public DateOnly? EffectiveTo { get; set; }
    public DateTimeOffset? VerifiedAt { get; set; }
    public Guid? VerifiedBy { get; set; }
    public long RowVersion { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
    public DateTimeOffset? DeletedAt { get; set; }
}

public sealed class OrgUnit : ISyncableEntity, ISoftDeletable
{
    public Guid Id { get; set; }
    public string? XinfoId { get; set; }
    public required string Code { get; set; }
    public required string Name { get; set; }
    public required string UnitType { get; set; }
    public Guid? ParentId { get; set; }
    public required string Path { get; set; }
    public bool IsActive { get; set; } = true;
    public long RowVersion { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
    public DateTimeOffset? DeletedAt { get; set; }
}

public sealed class ConsentRecord
{
    public Guid Id { get; set; }
    public Guid UserId { get; set; }
    public required string PolicyCode { get; set; }
    public required string PolicyVersion { get; set; }
    public bool Granted { get; set; }
    public DateTimeOffset GrantedAt { get; set; }
    public DateTimeOffset? RevokedAt { get; set; }
    public Guid? DeviceId { get; set; }
    public System.Net.IPAddress? IpAddress { get; set; }
    public string Evidence { get; set; } = "{}";
}

/// <summary>Flattened manager-&gt;subordinate closure, used for the MANAGER data-scope predicate.</summary>
public sealed class UserHierarchyClosure
{
    public Guid AncestorId { get; set; }
    public Guid DescendantId { get; set; }
    public short Depth { get; set; }
}
