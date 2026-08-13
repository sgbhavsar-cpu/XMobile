using Microsoft.EntityFrameworkCore;
using XMobile.Identity.Domain;
using XMobile.Persistence;
using XMobile.Shared;

namespace XMobile.Identity.Infrastructure;

/// <summary>
/// The repository-level scope predicate that is the second enforcement layer behind
/// `[Authorize]` (docs/06-security-identity.md §2) — a rep only ever sees `[self]`; a manager
/// sees self plus every subordinate via `identity.user_hierarchy_closure`. Other modules call
/// this to build `WHERE user_id IN (...)` filters rather than trusting the endpoint policy alone.
/// </summary>
public interface IUserScopeService
{
    Task<IReadOnlyCollection<Guid>> GetVisibleUserIdsAsync(CancellationToken ct = default);
}

public sealed class UserScopeService(XMobileDbContext db, ICurrentUser currentUser) : IUserScopeService
{
    public async Task<IReadOnlyCollection<Guid>> GetVisibleUserIdsAsync(CancellationToken ct = default)
    {
        if (!currentUser.IsInRole("MANAGER"))
        {
            return [currentUser.UserId];
        }

        var subordinateIds = await db.Set<UserHierarchyClosure>()
            .Where(h => h.AncestorId == currentUser.UserId)
            .Select(h => h.DescendantId)
            .ToListAsync(ct);

        return [currentUser.UserId, .. subordinateIds];
    }
}
