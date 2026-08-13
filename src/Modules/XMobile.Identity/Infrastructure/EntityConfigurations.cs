using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;
using XMobile.Identity.Domain;
using XMobile.Persistence;

namespace XMobile.Identity.Infrastructure;

public sealed class AppUserConfig : IEntityTypeConfiguration<AppUser>
{
    public void Configure(EntityTypeBuilder<AppUser> builder)
    {
        builder.ToTable("app_user", "identity");
        builder.HasKey(e => e.Id);
        builder.Property(e => e.Id).HasDefaultValueSql("gen_random_uuid()");
        builder.ConfigureSyncable();
        builder.ConfigureSoftDelete();
        builder.HasIndex(e => e.EmployeeCode).IsUnique();
    }
}

public sealed class UserRoleConfig : IEntityTypeConfiguration<UserRole>
{
    public void Configure(EntityTypeBuilder<UserRole> builder)
    {
        builder.ToTable("user_role", "identity");
        builder.HasKey(e => new { e.UserId, e.RoleCode });
    }
}

public sealed class DeviceConfig : IEntityTypeConfiguration<Device>
{
    public void Configure(EntityTypeBuilder<Device> builder)
    {
        builder.ToTable("device", "identity");
        builder.HasKey(e => e.Id);
        builder.HasClientGeneratedKey();
        builder.ConfigureSyncable();
        builder.Property(e => e.HealthDetails).HasColumnType("jsonb");
    }
}

public sealed class UserHomeLocationConfig : IEntityTypeConfiguration<UserHomeLocation>
{
    public void Configure(EntityTypeBuilder<UserHomeLocation> builder)
    {
        builder.ToTable("user_home_location", "identity");
        builder.HasKey(e => e.Id);
        builder.Property(e => e.Id).HasDefaultValueSql("gen_random_uuid()");
        builder.ConfigureSyncable();
        builder.ConfigureSoftDelete();
        builder.Property(e => e.Geog).HasColumnType("geography(Point,4326)");
    }
}

public sealed class OrgUnitConfig : IEntityTypeConfiguration<OrgUnit>
{
    public void Configure(EntityTypeBuilder<OrgUnit> builder)
    {
        builder.ToTable("org_unit", "identity");
        builder.HasKey(e => e.Id);
        builder.Property(e => e.Id).HasDefaultValueSql("gen_random_uuid()");
        builder.ConfigureSyncable();
        builder.ConfigureSoftDelete();
    }
}

public sealed class ConsentRecordConfig : IEntityTypeConfiguration<ConsentRecord>
{
    public void Configure(EntityTypeBuilder<ConsentRecord> builder)
    {
        builder.ToTable("consent_record", "identity");
        builder.HasKey(e => e.Id);
        builder.Property(e => e.Id).HasDefaultValueSql("gen_random_uuid()");
        builder.Property(e => e.Evidence).HasColumnType("jsonb");
    }
}

public sealed class UserHierarchyClosureConfig : IEntityTypeConfiguration<UserHierarchyClosure>
{
    public void Configure(EntityTypeBuilder<UserHierarchyClosure> builder)
    {
        builder.ToTable("user_hierarchy_closure", "identity");
        builder.HasKey(e => new { e.AncestorId, e.DescendantId });
    }
}
