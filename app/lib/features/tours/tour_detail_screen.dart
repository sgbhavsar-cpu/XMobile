import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/enums.dart';
import '../../core/models/models.dart';
import '../../core/state/providers.dart';
import '../../core/ui/common.dart';
import '../../core/ui/form_fields.dart';

/// A tour, day by day, with its plans and what actually happened.
class TourDetailScreen extends ConsumerWidget {
  const TourDetailScreen({super.key, required this.tourId});

  final String tourId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tour = ref.watch(tourProvider(tourId));
    final plans = ref.watch(visitPlansProvider((from: null, to: null, tourId: tourId)));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tour'),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit),
            tooltip: 'Edit',
            onPressed: () => context.push('/tours/$tourId/edit'),
          ),
        ],
      ),
      body: AsyncBody(
        value: tour,
        onRetry: () => bumpRefreshFrom(ref),
        builder: (t) => ListView(
          children: [
            _Header(tour: t),
            _Actions(tour: t),
            plans.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => Padding(padding: const EdgeInsets.all(16), child: Text('$e')),
              data: (allPlans) => Column(
                children: [
                  for (final day in t.days)
                    _DayCard(
                      tour: t,
                      day: day,
                      plans: allPlans.where((p) => p.tourDayId == day.id).toList(),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.tour});

  final Tour tour;

  @override
  Widget build(BuildContext context) => FormSectionCard(
        title: tour.title,
        subtitle: tour.purpose,
        trailing: StatusChip.forTour(tour.status),
        children: [
          DetailRow(
            label: 'Planned',
            value: tour.isSingleDay
                ? dateFormat.format(tour.plannedStartDate)
                : '${dateFormat.format(tour.plannedStartDate)} – ${dateFormat.format(tour.plannedEndDate)}',
            icon: Icons.calendar_month,
          ),
          if (tour.destinationCity != null)
            DetailRow(label: 'Destination', value: tour.destinationCity!, icon: Icons.place),
          if (tour.actualStartAt != null)
            DetailRow(
              label: 'Actually left',
              value: dateTimeFormat.format(tour.actualStartAt!),
              icon: Icons.logout,
            ),
          if (tour.actualEndAt != null)
            DetailRow(
              label: 'Actually returned',
              value: dateTimeFormat.format(tour.actualEndAt!),
              icon: Icons.home,
            ),
        ],
      );
}

class _Actions extends ConsumerStatefulWidget {
  const _Actions({required this.tour});

  final Tour tour;

  @override
  ConsumerState<_Actions> createState() => _ActionsState();
}

class _ActionsState extends ConsumerState<_Actions> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action, String success) async {
    setState(() => _busy = true);
    try {
      await action();
      bumpRefreshFrom(ref);
      if (mounted) showSuccess(context, success);
    } catch (e) {
      if (mounted) showApiError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tour = widget.tour;
    final api = ref.read(apiClientProvider);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          if (tour.status == TourStatus.planned || tour.status == TourStatus.draft)
            Expanded(
              child: FilledButton.icon(
                onPressed: _busy
                    ? null
                    : () => _run(() => api.startTour(tour.id).then((_) {}),
                        'Tour started — tracking is on'),
                icon: const Icon(Icons.play_arrow),
                label: const Text('Start tour'),
              ),
            ),
          if (tour.status == TourStatus.inProgress) ...[
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => context.push('/journey'),
                icon: const Icon(Icons.timeline),
                label: const Text('Journey'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: _busy
                    ? null
                    : () async {
                        final ok = await confirm(
                          context,
                          title: 'Finish this tour?',
                          message: 'Mark the tour complete. You can still add expenses against it.',
                          confirmLabel: 'Finish',
                        );
                        if (!ok) return;
                        await _run(
                            () => api.completeTour(tour.id).then((_) {}), 'Tour completed');
                      },
                icon: const Icon(Icons.flag),
                label: const Text('Finish'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _DayCard extends ConsumerWidget {
  const _DayCard({required this.tour, required this.day, required this.plans});

  final Tour tour;
  final TourDay day;
  final List<VisitPlan> plans;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isToday = _sameDay(day.planDate, DateTime.now());
    final isTravelDay = day.activityType == DayActivity.travel;

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      color: isToday ? theme.colorScheme.primaryContainer.withOpacity(0.35) : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Day ${day.daySeq} · ${dateFormat.format(day.planDate)}'
                    '${isToday ? ' · Today' : ''}',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                StatusChip(label: day.activityType.label),
              ],
            ),
            if (day.fromCity != null || day.toCity != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '${day.fromCity ?? '?'} → ${day.toCity ?? '?'}'
                  '${day.plannedTravelMode != null && day.plannedTravelMode != TravelMode.unknown ? ' by ${day.plannedTravelMode!.label.toLowerCase()}' : ''}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            if (day.overnightCity != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('Overnight: ${day.overnightCity}', style: theme.textTheme.bodySmall),
              ),
            if (day.notes != null && day.notes!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(day.notes!, style: theme.textTheme.bodySmall),
              ),
            const Divider(height: 20),
            if (plans.isEmpty)
              Text(
                isTravelDay
                    ? 'Travel day — no visits expected.'
                    : 'No visits planned for this day yet.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              )
            else
              for (final plan in plans)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: CircleAvatar(radius: 14, child: Text('${plan.seq}')),
                  title: Text(plan.customerName),
                  subtitle: Text('${plan.siteName}'
                      '${plan.plannedStartTime != null ? ' · ${plan.plannedStartTime}' : ''}'),
                  trailing: plan.status == PlanStatus.planned
                      ? TextButton(
                          onPressed: () => context.push('/check-in?planId=${plan.id}'),
                          child: const Text('Check in'),
                        )
                      : StatusChip.forPlan(plan.status),
                ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => context.push(
                    '/plans/new?tourId=${tour.id}&date=${_isoDate(day.planDate)}'),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add visit to this day'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

String _isoDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';
