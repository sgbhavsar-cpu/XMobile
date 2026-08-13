using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;
using XMobile.Persistence;
using XMobile.Planning.Domain;

namespace XMobile.Planning.Infrastructure;

public sealed class TourConfig : IEntityTypeConfiguration<Tour>
{
    public void Configure(EntityTypeBuilder<Tour> builder)
    {
        builder.ToTable("tour", "planning");
        builder.HasKey(e => e.Id);
        builder.HasClientGeneratedKey();
        builder.ConfigureSyncable();
        builder.ConfigureSoftDelete();
        // DB-computed (`GENERATED ALWAYS AS ... STORED`) — never written, always read back.
        builder.Property(e => e.IsSingleDay).ValueGeneratedOnAddOrUpdate();
    }
}

public sealed class TourDayConfig : IEntityTypeConfiguration<TourDay>
{
    public void Configure(EntityTypeBuilder<TourDay> builder)
    {
        builder.ToTable("tour_day", "planning");
        builder.HasKey(e => e.Id);
        builder.Property(e => e.Id).HasDefaultValueSql("gen_random_uuid()");
        builder.ConfigureSyncable();
        builder.ConfigureSoftDelete();
    }
}

public sealed class VisitPlanConfig : IEntityTypeConfiguration<VisitPlan>
{
    public void Configure(EntityTypeBuilder<VisitPlan> builder)
    {
        builder.ToTable("visit_plan", "planning");
        builder.HasKey(e => e.Id);
        builder.HasClientGeneratedKey();
        builder.ConfigureSyncable();
        builder.ConfigureSoftDelete();
    }
}
