using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace XMobile.Persistence;

/// <summary>
/// Every table registered with `config.fn_make_syncable` in db/schema carries these three
/// trigger-owned columns (see db/README.md "Conventions"): `row_version`/`updated_at` are bumped
/// by a BEFORE UPDATE trigger, `created_at` by a column DEFAULT. EF must never write them.
/// </summary>
public interface ISyncableEntity
{
    long RowVersion { get; set; }
    DateTimeOffset CreatedAt { get; set; }
    DateTimeOffset UpdatedAt { get; set; }
}

/// <summary>Tables with a nullable `deleted_at` (soft delete).</summary>
public interface ISoftDeletable
{
    DateTimeOffset? DeletedAt { get; set; }
}

/// <summary>
/// Tables the mobile app inserts into directly and that therefore have no DEFAULT on `id` — the
/// device supplies a UUIDv7 (db/README.md "Client-generated ids").
/// </summary>
public interface IHasGuidKey
{
    Guid Id { get; set; }
}

public static class EntityConventions
{
    /// <summary>
    /// Maps RowVersion as the EF concurrency token and tells EF that all three columns are
    /// database/trigger-generated on both insert and update, so they are never included in an
    /// INSERT/UPDATE column list and are always read back via RETURNING.
    /// </summary>
    public static EntityTypeBuilder<T> ConfigureSyncable<T>(this EntityTypeBuilder<T> builder)
        where T : class, ISyncableEntity
    {
        builder.Property(nameof(ISyncableEntity.RowVersion))
            .IsConcurrencyToken()
            .ValueGeneratedOnAddOrUpdate();
        builder.Property(nameof(ISyncableEntity.CreatedAt)).ValueGeneratedOnAdd();
        builder.Property(nameof(ISyncableEntity.UpdatedAt)).ValueGeneratedOnAddOrUpdate();
        return builder;
    }

    /// <summary>Excludes soft-deleted rows from every query by default.</summary>
    public static EntityTypeBuilder<T> ConfigureSoftDelete<T>(this EntityTypeBuilder<T> builder)
        where T : class, ISoftDeletable
    {
        builder.HasQueryFilter(e => EF.Property<DateTimeOffset?>(e, nameof(ISoftDeletable.DeletedAt)) == null);
        return builder;
    }

    public static EntityTypeBuilder<T> HasClientGeneratedKey<T>(this EntityTypeBuilder<T> builder)
        where T : class, IHasGuidKey
    {
        builder.Property(nameof(IHasGuidKey.Id)).ValueGeneratedNever();
        return builder;
    }
}
