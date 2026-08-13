using Microsoft.EntityFrameworkCore;
using XMobile.Persistence;
using XMobile.Persistence.Enums;
using XMobile.Planning.Domain;
using XMobile.Shared;

namespace XMobile.Planning.Infrastructure;

/// <summary>Implements the port XMobile.Tracking uses to build the journey engine's
/// TourContext — see XMobile.Shared.ITourContextLookup.</summary>
public sealed class TourContextLookupService(XMobileDbContext db) : ITourContextLookup
{
    public async Task<TourContextInfo?> GetForUserAsync(Guid userId, DateOnly localDate, CancellationToken ct)
    {
        var tour = await db.Set<Tour>()
            .Where(t => t.UserId == userId && t.PlannedStartDate <= localDate && t.PlannedEndDate >= localDate
                && t.Status != TourStatus.CANCELLED)
            .OrderByDescending(t => t.Status == TourStatus.IN_PROGRESS)
            .FirstOrDefaultAsync(ct);
        if (tour is null)
        {
            return null;
        }

        var plans = await db.Set<VisitPlan>().Where(p => p.TourId == tour.Id).ToListAsync(ct);

        return new TourContextInfo(
            tour.Id,
            tour.PlannedStartDate,
            tour.PlannedEndDate,
            plans.Select(p => p.SiteId).Distinct().ToList(),
            plans.Where(p => p.Status == PlanStatus.PLANNED).Select(p => p.SiteId).Distinct().ToList());
    }
}
