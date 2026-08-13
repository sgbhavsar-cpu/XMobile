using Microsoft.EntityFrameworkCore;
using XMobile.Customers.Domain;
using XMobile.Persistence;
using XMobile.Shared;

namespace XMobile.Customers.Infrastructure;

/// <summary>Implements the port XMobile.Sync uses to scope `/v1/sync/pull` to a rep's assigned
/// customers — see XMobile.Shared.ICustomerScopeService.</summary>
public sealed class CustomerScopeService(XMobileDbContext db) : ICustomerScopeService
{
    public async Task<IReadOnlyList<Guid>> GetAssignedCustomerIdsAsync(Guid userId, CancellationToken ct)
        => await db.Set<CustomerAssignment>()
            .Where(a => a.UserId == userId && a.ValidTo == null)
            .Select(a => a.CustomerId)
            .ToListAsync(ct);
}
