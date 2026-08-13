using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;
using XMobile.Persistence;
using XMobile.Visits.Domain;

namespace XMobile.Visits.Infrastructure;

public sealed class VisitConfig : IEntityTypeConfiguration<Visit>
{
    public void Configure(EntityTypeBuilder<Visit> builder)
    {
        builder.ToTable("visit", "visit");
        builder.HasKey(e => e.Id);
        builder.HasClientGeneratedKey();
        builder.ConfigureSyncable();
        builder.ConfigureSoftDelete();
        builder.Property(e => e.CheckInGeog).HasColumnType("geography(Point,4326)");
        builder.Property(e => e.CheckOutGeog).HasColumnType("geography(Point,4326)");
        // DB-computed (`GENERATED ALWAYS AS ... STORED`) from check_in_at/check_out_at.
        builder.Property(e => e.DurationMin).ValueGeneratedOnAddOrUpdate();
    }
}

public sealed class FormTemplateConfig : IEntityTypeConfiguration<FormTemplate>
{
    public void Configure(EntityTypeBuilder<FormTemplate> builder)
    {
        builder.ToTable("form_template", "visit");
        builder.HasKey(e => e.Id);
        builder.Property(e => e.Id).HasDefaultValueSql("gen_random_uuid()");
        builder.ConfigureSyncable();
        builder.Property(e => e.Schema).HasColumnType("jsonb");
    }
}

public sealed class VisitReportConfig : IEntityTypeConfiguration<VisitReport>
{
    public void Configure(EntityTypeBuilder<VisitReport> builder)
    {
        builder.ToTable("visit_report", "visit");
        builder.HasKey(e => e.VisitId);
        builder.Property(e => e.VisitId).ValueGeneratedNever();
        builder.ConfigureSyncable();
        builder.Property(e => e.Answers).HasColumnType("jsonb");
    }
}

public sealed class VisitReportAmendmentConfig : IEntityTypeConfiguration<VisitReportAmendment>
{
    public void Configure(EntityTypeBuilder<VisitReportAmendment> builder)
    {
        builder.ToTable("visit_report_amendment", "visit");
        builder.HasKey(e => e.Id);
        builder.Property(e => e.Id).HasDefaultValueSql("gen_random_uuid()");
        builder.Property(e => e.BeforeJson).HasColumnType("jsonb");
        builder.Property(e => e.AfterJson).HasColumnType("jsonb");
    }
}
