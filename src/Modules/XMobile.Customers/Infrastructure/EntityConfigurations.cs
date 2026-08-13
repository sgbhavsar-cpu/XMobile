using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;
using XMobile.Customers.Domain;
using XMobile.Persistence;

namespace XMobile.Customers.Infrastructure;

public sealed class CustomerAccountConfig : IEntityTypeConfiguration<CustomerAccount>
{
    public void Configure(EntityTypeBuilder<CustomerAccount> builder)
    {
        builder.ToTable("customer_account", "customer");
        builder.HasKey(e => e.Id);
        builder.Property(e => e.Id).HasDefaultValueSql("gen_random_uuid()");
        builder.ConfigureSyncable();
        builder.ConfigureSoftDelete();
    }
}

public sealed class CustomerSiteConfig : IEntityTypeConfiguration<CustomerSite>
{
    public void Configure(EntityTypeBuilder<CustomerSite> builder)
    {
        builder.ToTable("customer_site", "customer");
        builder.HasKey(e => e.Id);
        builder.Property(e => e.Id).HasDefaultValueSql("gen_random_uuid()");
        builder.ConfigureSyncable();
        builder.ConfigureSoftDelete();
        builder.Property(e => e.Geog).HasColumnType("geography(Point,4326)");
    }
}

public sealed class CustomerContactConfig : IEntityTypeConfiguration<CustomerContact>
{
    public void Configure(EntityTypeBuilder<CustomerContact> builder)
    {
        builder.ToTable("customer_contact", "customer");
        builder.HasKey(e => e.Id);
        builder.Property(e => e.Id).HasDefaultValueSql("gen_random_uuid()");
        builder.ConfigureSyncable();
        builder.ConfigureSoftDelete();
    }
}

public sealed class CustomerAssignmentConfig : IEntityTypeConfiguration<CustomerAssignment>
{
    public void Configure(EntityTypeBuilder<CustomerAssignment> builder)
    {
        builder.ToTable("customer_assignment", "customer");
        builder.HasKey(e => e.Id);
        builder.Property(e => e.Id).HasDefaultValueSql("gen_random_uuid()");
        builder.ConfigureSyncable();
        builder.ConfigureSoftDelete();
    }
}

public sealed class SalesHistoryConfig : IEntityTypeConfiguration<SalesHistory>
{
    public void Configure(EntityTypeBuilder<SalesHistory> builder)
    {
        builder.ToTable("sales_history", "customer");
        builder.HasKey(e => e.Id);
        builder.Property(e => e.Id).HasDefaultValueSql("gen_random_uuid()");
        builder.ConfigureSyncable();
        builder.ConfigureSoftDelete();
    }
}

public sealed class GeofenceConfig : IEntityTypeConfiguration<Geofence>
{
    public void Configure(EntityTypeBuilder<Geofence> builder)
    {
        builder.ToTable("geofence", "customer");
        builder.HasKey(e => e.Id);
        builder.Property(e => e.Id).HasDefaultValueSql("gen_random_uuid()");
        builder.ConfigureSyncable();
        builder.Property(e => e.Geog).HasColumnType("geography(Point,4326)");
    }
}
