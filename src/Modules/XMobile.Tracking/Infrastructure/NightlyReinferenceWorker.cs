using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using XMobile.Identity.Domain;
using XMobile.Persistence;
using XMobile.Persistence.Enums;
using XMobile.Shared;
using XMobile.Tracking.Domain;

namespace XMobile.Tracking.Infrastructure;

/// <summary>
/// Stands in for Quartz.NET (docs/08's eventual choice) — a PeriodicTimer loop that proves the
/// "worker" half of "ingest API + inference worker" without pulling in scheduling infrastructure
/// this pass doesn't need to justify. Reinferes the previous local day for every tracking-enabled
/// user who has recent evidence.
/// </summary>
public sealed class NightlyReinferenceWorker(
    IServiceScopeFactory scopeFactory, IClock clock, ILogger<NightlyReinferenceWorker> logger) : BackgroundService
{
    private static readonly TimeSpan LocalOffset = TimeSpan.FromHours(5.5);

    public TimeSpan Interval { get; init; } = TimeSpan.FromHours(24);

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(Interval);
        do
        {
            try
            {
                await RunNightlyBatchAsync(stoppingToken);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                logger.LogError(ex, "Nightly reinference batch failed");
            }
        } while (await timer.WaitForNextTickAsync(stoppingToken));
    }

    /// <summary>The testable core — called directly by integration tests so a real 24h timer tick
    /// is never needed to exercise this path.</summary>
    public async Task RunNightlyBatchAsync(CancellationToken ct)
    {
        var now = clock.UtcNow;
        var yesterdayLocal = DateOnly.FromDateTime((now + LocalOffset).DateTime).AddDays(-1);
        // Npgsql only accepts UTC-offset DateTimeOffset values for timestamptz columns (this
        // window is written to tracking.inference_run) — ToUniversalTime() re-expresses the same
        // instant with Offset=0 after building it in local wall-clock terms.
        var windowFrom = new DateTimeOffset(yesterdayLocal.ToDateTime(TimeOnly.MinValue), LocalOffset).ToUniversalTime();
        var windowTo = windowFrom.AddDays(1);

        List<Guid> userIds;
        using (var scope = scopeFactory.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<XMobileDbContext>();
            var evidenceCutoff = now.AddDays(-3);
            var activeUserIds = await db.Set<LocationPing>()
                .Where(p => p.RecordedAt >= evidenceCutoff)
                .Select(p => p.UserId)
                .Distinct()
                .ToListAsync(ct);

            userIds = activeUserIds.Count == 0
                ? []
                : await db.Set<AppUser>()
                    .Where(u => u.TrackingEnabled && u.Status == UserStatus.ACTIVE && activeUserIds.Contains(u.Id))
                    .Select(u => u.Id)
                    .ToListAsync(ct);
        }

        logger.LogInformation(
            "Nightly reinference: {Count} tracking-enabled users with evidence in the last 3 days", userIds.Count);

        foreach (var userId in userIds)
        {
            // A fresh scope per user keeps each DbContext's change tracker small and stops one
            // user's failure (caught below) from leaving a poisoned context for the next.
            using var userScope = scopeFactory.CreateScope();
            var runner = userScope.ServiceProvider.GetRequiredService<InferenceRunner>();
            try
            {
                await runner.RunAsync(userId, windowFrom, windowTo, "NIGHTLY", ct);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                logger.LogError(ex, "Nightly reinference failed for user {UserId}", userId);
            }
        }
    }
}
