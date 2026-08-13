using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;
using XMobile.Shared;

namespace XMobile.Persistence;

/// <summary>
/// One physical DbContext for the whole backend (matches "under 100 reps, single API" scale —
/// docs/10-roadmap.md). Modules own their entity configurations; see
/// <see cref="PersistenceModelOptions"/> for how those get discovered without a circular project
/// reference. `SaveChangesAsync` sets `xmobile.actor_id` on the write transaction so the
/// change-feed/audit triggers can attribute the write (db/README.md "Actor for audit").
/// </summary>
public sealed class XMobileDbContext(
    DbContextOptions<XMobileDbContext> options,
    IOptions<PersistenceModelOptions> modelOptions,
    ICurrentUser currentUser) : DbContext(options)
{
    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        base.OnModelCreating(modelBuilder);

        XMobilePostgres.RegisterEnumTypes(modelBuilder);

        foreach (var assembly in modelOptions.Value.ModuleAssemblies)
        {
            modelBuilder.ApplyConfigurationsFromAssembly(assembly);
        }
    }

    public override async Task<int> SaveChangesAsync(CancellationToken cancellationToken = default)
    {
        // Guid.Empty is the anonymous-caller sentinel (see ICurrentUser) — e.g. the dev-login
        // bootstrap write that happens before any user is authenticated. Leave actor_id NULL then;
        // the schema allows it (`sync.change_log.changed_by uuid`, nullable).
        if (currentUser.UserId == Guid.Empty || !ChangeTracker.HasChanges())
        {
            return await base.SaveChangesAsync(cancellationToken);
        }

        var ownsTransaction = Database.CurrentTransaction is null;
        var transaction = Database.CurrentTransaction
                           ?? await Database.BeginTransactionAsync(cancellationToken);
        try
        {
            // SET LOCAL does not accept bind parameters over the Postgres wire protocol, so this
            // must be inlined — safe here because the value is a Guid formatted with "D"
            // (fixed hex-and-dash shape, no characters SQL would ever interpret specially).
            var setActorSql = "SET LOCAL xmobile.actor_id = '" + currentUser.UserId.ToString("D") + "'";
            await Database.ExecuteSqlRawAsync(setActorSql, cancellationToken);

            var result = await base.SaveChangesAsync(cancellationToken);

            if (ownsTransaction)
            {
                await transaction.CommitAsync(cancellationToken);
            }

            return result;
        }
        catch
        {
            if (ownsTransaction)
            {
                await transaction.RollbackAsync(cancellationToken);
            }

            throw;
        }
        finally
        {
            if (ownsTransaction)
            {
                await transaction.DisposeAsync();
            }
        }
    }
}
