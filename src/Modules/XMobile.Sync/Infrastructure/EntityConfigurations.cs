using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;
using XMobile.Sync.Domain;

namespace XMobile.Sync.Infrastructure;

public sealed class ChangeLogEntryConfig : IEntityTypeConfiguration<ChangeLogEntry>
{
    public void Configure(EntityTypeBuilder<ChangeLogEntry> builder)
    {
        builder.ToTable("change_log", "sync");
        builder.HasKey(e => e.Id);
        // Written only by config.fn_change_log triggers — never by application code.
        builder.Property(e => e.Id).ValueGeneratedOnAdd();
    }
}

public sealed class ClientMutationConfig : IEntityTypeConfiguration<ClientMutation>
{
    public void Configure(EntityTypeBuilder<ClientMutation> builder)
    {
        builder.ToTable("client_mutation", "sync");
        builder.HasKey(e => e.ClientMutationId);
        builder.Property(e => e.ClientMutationId).ValueGeneratedNever();
    }
}

public sealed class SyncConflictConfig : IEntityTypeConfiguration<SyncConflict>
{
    public void Configure(EntityTypeBuilder<SyncConflict> builder)
    {
        builder.ToTable("sync_conflict", "sync");
        builder.HasKey(e => e.Id);
        builder.Property(e => e.Id).HasDefaultValueSql("gen_random_uuid()");
        builder.Property(e => e.ClientPayload).HasColumnType("jsonb");
        builder.Property(e => e.ServerPayload).HasColumnType("jsonb");
        builder.Property(e => e.MergedPayload).HasColumnType("jsonb");
    }
}
