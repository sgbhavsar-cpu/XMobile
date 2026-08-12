import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/enums.dart';
import '../../core/models/models.dart';
import '../../core/state/providers.dart';
import '../../core/ui/common.dart';
import '../../core/ui/form_fields.dart';

/// The rep's own journey timeline.
///
/// Two deliberate choices here. Gaps are drawn, not hidden — showing them builds trust
/// and hiding them destroys it. And anything the system is unsure about is offered for
/// confirmation rather than presented as fact.
class JourneyScreen extends ConsumerStatefulWidget {
  const JourneyScreen({super.key});

  @override
  ConsumerState<JourneyScreen> createState() => _JourneyScreenState();
}

class _JourneyScreenState extends ConsumerState<JourneyScreen> {
  DateTime _date = DateTime.now();

  DateTime get _from => DateTime(_date.year, _date.month, _date.day);
  DateTime get _to => _from.add(const Duration(days: 1));

  @override
  Widget build(BuildContext context) {
    final events = ref.watch(journeyEventsProvider((from: _from, to: _to)));
    final segments = ref.watch(journeySegmentsProvider((from: _from, to: _to)));

    return Scaffold(
      appBar: AppBar(
        title: const Text('My journey'),
        actions: [
          IconButton(
            icon: const Icon(Icons.calendar_today),
            tooltip: 'Change day',
            onPressed: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: _date,
                firstDate: DateTime.now().subtract(const Duration(days: 90)),
                lastDate: DateTime.now(),
              );
              if (picked != null) setState(() => _date = picked);
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/journey/manual'),
        icon: const Icon(Icons.add),
        label: const Text('Add missing'),
      ),
      body: RefreshIndicator(
        onRefresh: () async => bumpRefreshFrom(ref),
        child: ListView(
          padding: const EdgeInsets.only(bottom: 96),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.chevron_left),
                    onPressed: () =>
                        setState(() => _date = _date.subtract(const Duration(days: 1))),
                  ),
                  Expanded(
                    child: Text(
                      dateFormat.format(_date),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.chevron_right),
                    onPressed: _isToday(_date)
                        ? null
                        : () => setState(() => _date = _date.add(const Duration(days: 1))),
                  ),
                ],
              ),
            ),
            segments.when(
              loading: () => const SizedBox.shrink(),
              error: (_, __) => const SizedBox.shrink(),
              data: (list) => _DaySummaryCard(segments: list),
            ),
            events.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => Padding(padding: const EdgeInsets.all(16), child: Text('$e')),
              data: (list) => list.isEmpty
                  ? EmptyState(
                      icon: Icons.timeline,
                      title: 'Nothing recorded for this day',
                      message: 'If you travelled, you can add what happened by hand.',
                      action: FilledButton.tonal(
                        onPressed: () => context.push('/journey/manual'),
                        child: const Text('Add an event'),
                      ),
                    )
                  : Column(
                      children: [
                        for (var i = 0; i < list.length; i++)
                          _EventTile(
                            event: list[i],
                            isLast: i == list.length - 1,
                            gapToNext: i < list.length - 1
                                ? list[i + 1].occurredAt.difference(list[i].occurredAt)
                                : null,
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  bool _isToday(DateTime date) {
    final now = DateTime.now();
    return date.year == now.year && date.month == now.month && date.day == now.day;
  }
}

class _DaySummaryCard extends StatelessWidget {
  const _DaySummaryCard({required this.segments});

  final List<JourneySegment> segments;

  @override
  Widget build(BuildContext context) {
    if (segments.isEmpty) return const SizedBox.shrink();

    final distanceM = segments.fold<int>(0, (sum, s) => sum + s.distanceM);
    final estimatedM =
        segments.where((s) => s.isEstimated).fold<int>(0, (sum, s) => sum + s.distanceM);
    final travelSeconds = segments
        .where((s) => s.isTravel)
        .fold<int>(0, (sum, s) => sum + (s.duration?.inSeconds ?? 0));

    return FormSectionCard(
      title: 'The day in numbers',
      children: [
        DetailRow(
          label: 'Distance',
          value: '${(distanceM / 1000).toStringAsFixed(1)} km',
          icon: Icons.straighten,
          emphasise: true,
        ),
        if (estimatedM > 0)
          DetailRow(
            label: 'Of which estimated',
            value: '${(estimatedM / 1000).toStringAsFixed(1)} km across gaps in tracking',
            icon: Icons.help_outline,
          ),
        DetailRow(
          label: 'Time travelling',
          value: '${(travelSeconds / 3600).toStringAsFixed(1)} hours',
          icon: Icons.schedule,
        ),
        const SizedBox(height: 8),
        for (final segment in segments)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                Icon(_iconFor(segment.travelMode), size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${_label(segment.type)} · '
                    '${(segment.distanceM / 1000).toStringAsFixed(0)} km by '
                    '${segment.travelMode.label.toLowerCase()}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                if (segment.isEstimated)
                  const StatusChip(label: 'Estimated', color: Colors.orange),
                if (segment.isProvisional)
                  const StatusChip(label: 'Unconfirmed', color: Colors.grey),
              ],
            ),
          ),
      ],
    );
  }

  String _label(String type) => switch (type) {
        'OUTBOUND_TRAVEL' => 'Outbound',
        'RETURN_TRAVEL' => 'Return',
        'INTER_TRAVEL' => 'Between customers',
        _ => type,
      };

  IconData _iconFor(TravelMode mode) => switch (mode) {
        TravelMode.rail => Icons.train,
        TravelMode.air => Icons.flight,
        TravelMode.car => Icons.directions_car,
        TravelMode.twoWheeler => Icons.two_wheeler,
        TravelMode.bus => Icons.directions_bus,
        TravelMode.walk => Icons.directions_walk,
        _ => Icons.help_outline,
      };
}

class _EventTile extends ConsumerWidget {
  const _EventTile({required this.event, required this.isLast, this.gapToNext});

  final JourneyEvent event;
  final bool isLast;
  final Duration? gapToNext;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final needsReview = event.status == EventStatus.needsReview;

    return Column(
      children: [
        Card(
          margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: needsReview
                  ? Colors.orange.withOpacity(0.2)
                  : theme.colorScheme.primaryContainer,
              child: Icon(_iconFor(event.type), size: 20),
            ),
            title: Text(event.type.label),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${timeFormat.format(event.occurredAt)}'
                    '${event.placeName != null ? ' · ${event.placeName}' : ''}'),
                if (event.originalOccurredAt != null)
                  Text(
                    'You corrected this from ${timeFormat.format(event.originalOccurredAt!)}',
                    style: theme.textTheme.bodySmall,
                  ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  children: [
                    if (event.isManual)
                      const StatusChip(label: 'Entered by you', color: Colors.blue),
                    if (event.isEstimated)
                      const StatusChip(label: 'Estimated', color: Colors.orange),
                    if (needsReview)
                      StatusChip(
                        label: 'Not sure (${(event.confidence * 100).round()}%)',
                        color: Colors.orange,
                      ),
                  ],
                ),
              ],
            ),
            isThreeLine: true,
            trailing: needsReview
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.check_circle_outline),
                        tooltip: 'Yes, that is right',
                        onPressed: () async {
                          await ref.read(apiClientProvider).confirmJourneyEvent(event.id);
                          bumpRefreshFrom(ref);
                          if (context.mounted) showSuccess(context, 'Confirmed');
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        tooltip: 'Correct the time',
                        onPressed: () => context.push('/journey/manual?eventId=${event.id}'),
                      ),
                    ],
                  )
                : IconButton(
                    icon: const Icon(Icons.edit_outlined),
                    tooltip: 'Correct the time',
                    onPressed: () => context.push('/journey/manual?eventId=${event.id}'),
                  ),
          ),
        ),

        // Gaps are drawn explicitly. Hiding them is how a tracking system loses trust.
        if (gapToNext != null && gapToNext! > const Duration(minutes: 45))
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.more_vert, size: 16, color: theme.colorScheme.outline),
                const SizedBox(width: 8),
                Text(
                  '${gapToNext!.inHours > 0 ? '${gapToNext!.inHours} h ' : ''}'
                  '${gapToNext!.inMinutes % 60} min with no record',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                ),
              ],
            ),
          ),
      ],
    );
  }

  IconData _iconFor(JourneyEventType type) => switch (type) {
        JourneyEventType.departHome => Icons.home_outlined,
        JourneyEventType.arriveHome => Icons.home,
        JourneyEventType.arriveCustomer => Icons.store,
        JourneyEventType.departCustomer => Icons.logout,
        JourneyEventType.startReturn => Icons.u_turn_left,
        JourneyEventType.overnightStopStart => Icons.hotel,
        JourneyEventType.overnightStopEnd => Icons.wb_sunny_outlined,
        _ => Icons.circle_outlined,
      };
}
