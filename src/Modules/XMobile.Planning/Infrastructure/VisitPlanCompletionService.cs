using Microsoft.EntityFrameworkCore;
using XMobile.Persistence;
using XMobile.Persistence.Enums;
using XMobile.Planning.Domain;
using XMobile.Shared;

namespace XMobile.Planning.Infrastructure;

/// <summary>Implements the port Visits calls after a successful check-in against a plan — see
/// XMobile.Shared.IVisitPlanCompletion for why this is an interface rather than a project
/// reference from Visits into Planning.</summary>
public sealed class VisitPlanCompletionService(XMobileDbContext db) : IVisitPlanCompletion
{
    public async Task MarkCompletedAsync(Guid visitPlanId, CancellationToken ct)
    {
        var plan = await db.Set<VisitPlan>().FirstOrDefaultAsync(p => p.Id == visitPlanId, ct);
        if (plan is null || plan.Status != PlanStatus.PLANNED)
        {
            return; // Already resolved (or unknown) — checking in twice must stay idempotent.
        }

        plan.Status = PlanStatus.COMPLETED;
        await db.SaveChangesAsync(ct);
    }
}
