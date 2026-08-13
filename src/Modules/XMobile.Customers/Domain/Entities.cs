using NetTopologySuite.Geometries;
using XMobile.Persistence;
using XMobile.Persistence.Enums;

namespace XMobile.Customers.Domain;

public sealed class CustomerAccount : ISyncableEntity, ISoftDeletable
{
    public Guid Id { get; set; }
    public string? XinfoId { get; set; }
    public string? Code { get; set; }
    public required string Name { get; set; }
    public string? LegalName { get; set; }
    public string? AccountType { get; set; }
    public string? Category { get; set; }
    public string? Industry { get; set; }
    public Guid? ParentId { get; set; }
    public Guid? OwnerUserId { get; set; }
    public Guid? OrgUnitId { get; set; }
    public string? CreditStatus { get; set; }
    public string? GstNumber { get; set; }
    public string? Phone { get; set; }
    public string? Email { get; set; }
    public bool IsActive { get; set; } = true;
    public AccountLifecycle LifecycleStatus { get; set; } = AccountLifecycle.ACTIVE;
    public bool IsFieldCreated { get; set; }
    public Guid? CreatedByUserId { get; set; }
    public DateTimeOffset? ProposedAt { get; set; }
    public DateTimeOffset? ApprovedAt { get; set; }
    public DateTimeOffset? RejectedAt { get; set; }
    public string? RejectionReason { get; set; }
    public DateTimeOffset? XinfoSyncedAt { get; set; }
    public string? XinfoHash { get; set; }
    public long RowVersion { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
    public DateTimeOffset? DeletedAt { get; set; }
}

public sealed class CustomerSite : ISyncableEntity, ISoftDeletable
{
    public Guid Id { get; set; }
    public Guid CustomerId { get; set; }
    public string? XinfoId { get; set; }
    public string? SiteCode { get; set; }
    public required string Name { get; set; }
    public string? SiteType { get; set; }
    public bool IsPrimary { get; set; }
    public string? AddressLine1 { get; set; }
    public string? AddressLine2 { get; set; }
    public string? Landmark { get; set; }
    public string? City { get; set; }
    public string? District { get; set; }
    public string? State { get; set; }
    public string? PostalCode { get; set; }
    public string CountryCode { get; set; } = "IN";
    public Point? Geog { get; set; }
    public GeoSource GeoSource { get; set; } = GeoSource.NONE;
    public double? GeoAccuracyM { get; set; }
    public int GeofenceRadiusM { get; set; } = 150;
    public Guid? GeoCapturedBy { get; set; }
    public DateTimeOffset? GeoCapturedAt { get; set; }
    public Guid? GeoVerifiedBy { get; set; }
    public DateTimeOffset? GeoVerifiedAt { get; set; }
    public int? SuggestedRadiusM { get; set; }
    public string Timezone { get; set; } = "Asia/Kolkata";
    public bool IsActive { get; set; } = true;
    public long RowVersion { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
    public DateTimeOffset? DeletedAt { get; set; }
}

public sealed class CustomerContact : ISyncableEntity, ISoftDeletable
{
    public Guid Id { get; set; }
    public Guid CustomerId { get; set; }
    public Guid? SiteId { get; set; }
    public string? XinfoId { get; set; }
    public required string FullName { get; set; }
    public string? Designation { get; set; }
    public string? Department { get; set; }
    public string? Phone { get; set; }
    public string? Email { get; set; }
    public bool IsPrimary { get; set; }
    public bool IsActive { get; set; } = true;
    public long RowVersion { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
    public DateTimeOffset? DeletedAt { get; set; }
}

public sealed class CustomerAssignment : ISyncableEntity, ISoftDeletable
{
    public Guid Id { get; set; }
    public Guid CustomerId { get; set; }
    public Guid UserId { get; set; }
    public string Role { get; set; } = "PRIMARY";
    public DateOnly ValidFrom { get; set; }
    public DateOnly? ValidTo { get; set; }
    public string? XinfoId { get; set; }
    public long RowVersion { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
    public DateTimeOffset? DeletedAt { get; set; }
}

public sealed class SalesHistory : ISyncableEntity, ISoftDeletable
{
    public Guid Id { get; set; }
    public Guid CustomerId { get; set; }
    public string? XinfoId { get; set; }
    public string DocumentType { get; set; } = "ORDER";
    public string? DocumentNo { get; set; }
    public DateOnly DocumentDate { get; set; }
    public decimal Amount { get; set; }
    public string Currency { get; set; } = "INR";
    public decimal? Quantity { get; set; }
    public string? Uom { get; set; }
    public string? Status { get; set; }
    public string? Summary { get; set; }
    public DateTimeOffset SyncedAt { get; set; }
    public long RowVersion { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
    public DateTimeOffset? DeletedAt { get; set; }
}
