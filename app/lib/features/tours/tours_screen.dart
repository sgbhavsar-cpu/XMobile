import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/enums.dart';
import '../../core/state/providers.dart';
import '../../core/ui/common.dart';
import '../../core/ui/form_fields.dart';

class ToursScreen extends ConsumerWidget {
  const ToursScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tours = ref.watch(toursProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Tours')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/tours/new'),
        icon: const Icon(Icons.add),
        label: const Text('New tour'),
      ),
      body: RefreshIndicator(
        onRefresh: () async => bumpRefreshFrom(ref),
        child: AsyncBody(
          value: tours,
          onRetry: () => bumpRefreshFrom(ref),
          builder: (list) => list.isEmpty
              ? EmptyState(
                  icon: Icons.route,
                  title: 'No tours yet',
                  message:
                      'A tour covers a working day or a multi-day trip. Planning is yours — '
                      'no approval needed.',
                  action: FilledButton(
                    onPressed: () => context.push('/tours/new'),
                    child: const Text('Plan a tour'),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: list.length,
                  itemBuilder: (context, index) {
                    final tour = list[index];
                    final subtitle = tour.isSingleDay
                        ? dateFormat.format(tour.plannedStartDate)
                        : '${dateFormat.format(tour.plannedStartDate)} – '
                            '${dateFormat.format(tour.plannedEndDate)} · ${tour.dayCount} days';

                    return Card(
                      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: tour.status == TourStatus.inProgress
                              ? Theme.of(context).colorScheme.primaryContainer
                              : null,
                          child: Icon(tour.isSingleDay ? Icons.today : Icons.route),
                        ),
                        title: Text(tour.title),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(subtitle),
                            if (tour.destinationCity != null)
                              Text(tour.destinationCity!,
                                  style: Theme.of(context).textTheme.bodySmall),
                          ],
                        ),
                        isThreeLine: tour.destinationCity != null,
                        trailing: StatusChip.forTour(tour.status),
                        onTap: () => context.push('/tours/${tour.id}'),
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }
}
