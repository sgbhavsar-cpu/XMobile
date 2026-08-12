import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/enums.dart';
import '../../core/models/models.dart';
import '../../core/state/providers.dart';
import '../../core/ui/common.dart';
import '../../core/ui/form_fields.dart';

/// The screen a rep opens twenty times a day. It answers, in order: am I being tracked,
/// what am I doing next, and what is unfinished.
class TodayScreen extends ConsumerWidget {
  const TodayScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final today = DateTime.now();
    final dayStart = DateTime(today.year, today.month, today.day);

    final session = ref.watch(sessionProvider);
    final plans = ref.watch(visitPlansProvider((
      from: dayStart,
      to: dayStart,
      tourId: null,
    )));
    final openVisit = ref.watch(openVisitProvider);
    final activeTour = ref.watch(activeTourProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Today'),
        actions: [
          IconButton(
            tooltip: 'My journey',
            icon: const Icon(Icons.timeline),
            onPressed: () => context.push('/journey'),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => bumpRefreshFrom(ref),
        child: ListView(
          children: [
            _Greeting(name: session.user?.fullName ?? 'there', date: today),
            const _TrackingCard(),
            openVisit.when(
              data: (visit) => visit == null
                  ? const SizedBox.shrink()
                  : _OpenVisitCard(visit: visit),
              loading: () => const SizedBox.shrink(),
              error: (_, __) => const SizedBox.shrink(),
            ),
            activeTour.when(
              data: (tour) => tour == null ? const SizedBox.shrink() : _ActiveTourCard(tour: tour),
              loading: () => const SizedBox.shrink(),
              error: (_, __) => const SizedBox.shrink(),
            ),
            _PlanSection(plans: plans),
            const _QuickActions(),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

class _Greeting extends StatelessWidget {
  const _Greeting({required this.name, required this.date});

  final String name;
  final DateTime date;

  @override
  Widget build(BuildContext context) {
    final hour = DateTime.now().hour;
    final greeting = hour < 12 ? 'Good morning' : (hour < 17 ? 'Good afternoon' : 'Good evening');

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$greeting, ${name.split(' ').first}',
              style: Theme.of(context).textTheme.titleLarge),
          Text(dateFormat.format(date),
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

/// Tracking state is the first thing on the screen, always visible, never buried.
/// A rep should never have to wonder whether they are being tracked.
class _TrackingCard extends ConsumerWidget {
  const _TrackingCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(trackingActiveProvider);
    final health = ref.watch(trackingHealthProvider);

    return active.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (isActive) => health.when(
        loading: () => const SizedBox.shrink(),
        error: (_, __) => const SizedBox.shrink(),
        data: (h) {
          final theme = Theme.of(context);
          final healthy = h.score >= 80;
          final color = !isActive
              ? theme.colorScheme.outline
              : (healthy ? Colors.green : Colors.orange);

          return Card(
            margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
            child: InkWell(
              onTap: () => context.push('/tracking-health'),
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Icon(isActive ? Icons.location_on : Icons.location_off, color: color),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(isActive ? 'Tracking is on' : 'Tracking is paused',
                              style: theme.textTheme.titleSmall),
                          Text(
                            isActive
                                ? (healthy
                                    ? 'Everything is set up correctly'
                                    : '${h.issues.length} setting${h.issues.length == 1 ? '' : 's'} may stop tracking')
                                : 'Your location is not being recorded',
                            style: theme.textTheme.bodySmall?.copyWith(color: color),
                          ),
                        ],
                      ),
                    ),
                    if (!healthy && isActive)
                      TextButton(
                        onPressed: () => context.push('/tracking-health'),
                        child: const Text('Fix'),
                      )
                    else
                      const Icon(Icons.chevron_right),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _OpenVisitCard extends ConsumerWidget {
  const _OpenVisitCard({required this.visit});

  final Visit visit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final elapsed = DateTime.now().difference(visit.checkInAt);

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.play_circle_fill),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Checked in at ${visit.customerName}',
                      style: theme.textTheme.titleSmall),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${visit.siteName} · ${timeFormat.format(visit.checkInAt)} '
              '· ${elapsed.inMinutes} min so far',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => context.push('/visits/${visit.id}'),
                    icon: const Icon(Icons.logout, size: 18),
                    label: const Text('Check out'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ActiveTourCard extends StatelessWidget {
  const _ActiveTourCard({required this.tour});

  final Tour tour;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dayNumber = DateTime.now().difference(tour.plannedStartDate).inDays + 1;

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: ListTile(
        leading: const Icon(Icons.route),
        title: Text(tour.title),
        subtitle: Text(
          'Day $dayNumber of ${tour.dayCount} · '
          '${dateFormat.format(tour.plannedStartDate)} – ${dateFormat.format(tour.plannedEndDate)}',
          style: theme.textTheme.bodySmall,
        ),
        trailing: StatusChip.forTour(tour.status),
        onTap: () => context.push('/tours/${tour.id}'),
      ),
    );
  }
}

class _PlanSection extends ConsumerWidget {
  const _PlanSection({required this.plans});

  final AsyncValue<List<VisitPlan>> plans;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: Text("Today's plan", style: Theme.of(context).textTheme.titleMedium),
              ),
              TextButton.icon(
                onPressed: () => context.push('/plans/new?date=${_isoDate(DateTime.now())}'),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add visit'),
              ),
            ],
          ),
        ),
        plans.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (error, _) => Padding(
            padding: const EdgeInsets.all(16),
            child: Text('Could not load the plan: $error'),
          ),
          data: (list) => list.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
                  child: EmptyState(
                    icon: Icons.event_available,
                    title: 'Nothing planned today',
                    message: 'Add a visit, or record an unplanned one as you go.',
                    action: FilledButton.tonal(
                      onPressed: () => context.push('/plans/new?date=${_isoDate(DateTime.now())}'),
                      child: const Text('Plan a visit'),
                    ),
                  ),
                )
              : Column(children: [for (final plan in list) _PlanTile(plan: plan)]),
        ),
      ],
    );
  }
}

class _PlanTile extends ConsumerWidget {
  const _PlanTile({required this.plan});

  final VisitPlan plan;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final done = plan.status != PlanStatus.planned;

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: done
              ? theme.colorScheme.surfaceContainerHighest
              : theme.colorScheme.primaryContainer,
          child: Text('${plan.seq}'),
        ),
        title: Text(plan.customerName),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${plan.siteName}'
                '${plan.plannedStartTime != null ? ' · ${plan.plannedStartTime}' : ''}'),
            if (plan.objective != null)
              Text(plan.objective!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall),
            if (plan.status == PlanStatus.skipped && plan.skipRemark != null)
              Text('Skipped: ${plan.skipRemark}',
                  style: theme.textTheme.bodySmall?.copyWith(color: Colors.orange)),
          ],
        ),
        isThreeLine: plan.objective != null,
        trailing: done
            ? StatusChip.forPlan(plan.status)
            : FilledButton(
                onPressed: () => context.push('/check-in?planId=${plan.id}'),
                child: const Text('Check in'),
              ),
        onTap: done ? null : () => _showPlanActions(context, ref, plan),
      ),
    );
  }

  void _showPlanActions(BuildContext context, WidgetRef ref, VisitPlan plan) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.login),
              title: const Text('Check in'),
              onTap: () {
                Navigator.pop(sheetContext);
                context.push('/check-in?planId=${plan.id}');
              },
            ),
            ListTile(
              leading: const Icon(Icons.store),
              title: const Text('Open customer'),
              onTap: () {
                Navigator.pop(sheetContext);
                context.push('/customers/${plan.customerId}');
              },
            ),
            ListTile(
              leading: const Icon(Icons.event_busy),
              title: const Text('Skip this visit'),
              onTap: () {
                Navigator.pop(sheetContext);
                _showSkipDialog(context, ref, plan);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showSkipDialog(BuildContext context, WidgetRef ref, VisitPlan plan) async {
    final reasons = await ref.read(reasonCodesProvider('VISIT_SKIP').future);
    if (!context.mounted) return;

    String? selected;
    final remark = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) => AlertDialog(
          title: Text('Skip ${plan.customerName}?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppDropdown<ReasonCode>(
                label: 'Reason',
                required: true,
                items: reasons,
                value: reasons.where((r) => r.code == selected).firstOrNull,
                itemLabel: (r) => r.name,
                onChanged: (r) => setState(() => selected = r?.code),
              ),
              AppTextField(
                label: 'Remark',
                controller: remark,
                maxLines: 2,
                helper: 'Required for some reasons',
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Skip')),
          ],
        ),
      ),
    );

    if (confirmed != true || selected == null) return;
    if (!context.mounted) return;

    try {
      await ref.read(apiClientProvider).skipVisitPlan(plan.id, selected!, remark.text);
      bumpRefreshFrom(ref);
      if (context.mounted) showSuccess(context, 'Visit skipped');
    } catch (e) {
      if (context.mounted) showApiError(context, e);
    }
  }
}

class _QuickActions extends StatelessWidget {
  const _QuickActions();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Quick actions', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _QuickAction(
                  icon: Icons.add_location_alt,
                  label: 'Unplanned visit',
                  onTap: () => context.push('/check-in'),
                ),
                _QuickAction(
                  icon: Icons.receipt_long,
                  label: 'Add expense',
                  onTap: () => context.push('/expenses/new'),
                ),
                _QuickAction(
                  icon: Icons.timeline,
                  label: 'My journey',
                  onTap: () => context.push('/journey'),
                ),
                _QuickAction(
                  icon: Icons.trending_up,
                  label: 'Opportunities',
                  onTap: () => context.push('/opportunities'),
                ),
              ],
            ),
          ],
        ),
      );
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 160,
        child: OutlinedButton.icon(
          onPressed: onTap,
          icon: Icon(icon, size: 18),
          label: Text(label, overflow: TextOverflow.ellipsis),
        ),
      );
}

String _isoDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';
