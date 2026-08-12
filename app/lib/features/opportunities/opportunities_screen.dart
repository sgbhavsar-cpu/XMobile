import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/state/providers.dart';
import '../../core/ui/common.dart';
import '../../core/ui/form_fields.dart';

/// The rep's pipeline. Opportunities are the one thing both sides edit, so the list
/// shows who created what and flags anything past its close date.
class OpportunitiesScreen extends ConsumerStatefulWidget {
  const OpportunitiesScreen({super.key, this.customerId});

  final String? customerId;

  @override
  ConsumerState<OpportunitiesScreen> createState() => _OpportunitiesScreenState();
}

class _OpportunitiesScreenState extends ConsumerState<OpportunitiesScreen> {
  bool _openOnly = true;

  @override
  Widget build(BuildContext context) {
    final opportunities = ref.watch(
        opportunitiesProvider((customerId: widget.customerId, openOnly: _openOnly)));
    final stages = ref.watch(opportunityStagesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Opportunities'),
        actions: [
          IconButton(
            icon: Icon(_openOnly ? Icons.filter_alt : Icons.filter_alt_off),
            tooltip: _openOnly ? 'Showing open only' : 'Showing all',
            onPressed: () => setState(() => _openOnly = !_openOnly),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push(
            '/opportunities/new${widget.customerId != null ? '?customerId=${widget.customerId}' : ''}'),
        icon: const Icon(Icons.add),
        label: const Text('New'),
      ),
      body: RefreshIndicator(
        onRefresh: () async => bumpRefreshFrom(ref),
        child: AsyncBody(
          value: opportunities,
          onRetry: () => bumpRefreshFrom(ref),
          builder: (list) {
            if (list.isEmpty) {
              return EmptyState(
                icon: Icons.trending_up,
                title: _openOnly ? 'No open opportunities' : 'No opportunities',
                message: 'Record a requirement the moment a customer mentions it — '
                    'that is what keeps the pipeline honest.',
                action: FilledButton.tonal(
                  onPressed: () => context.push('/opportunities/new'),
                  child: const Text('Create one'),
                ),
              );
            }

            final total = list.fold<double>(0, (sum, o) => sum + (o.estimatedValue ?? 0));

            return ListView(
              padding: const EdgeInsets.only(bottom: 88),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    '${list.length} opportunit${list.length == 1 ? 'y' : 'ies'} · '
                    '${currencyFormat.format(total)} in play',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                for (final opportunity in list)
                  Card(
                    margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                    child: ListTile(
                      title: Text(opportunity.title),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(opportunity.customerName),
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              StatusChip(
                                label: stages.valueOrNull
                                        ?.where((s) => s.code == opportunity.stageCode)
                                        .firstOrNull
                                        ?.name ??
                                    opportunity.stageCode,
                              ),
                              if (opportunity.estimatedValue != null)
                                StatusChip(
                                  label: currencyFormat.format(opportunity.estimatedValue),
                                  color: Colors.teal,
                                ),
                              if (opportunity.isOverdue)
                                const StatusChip(label: 'Overdue', color: Colors.red),
                              if (opportunity.isFieldCreated)
                                const StatusChip(label: 'Yours', color: Colors.purple),
                            ],
                          ),
                        ],
                      ),
                      isThreeLine: true,
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => context.push('/opportunities/${opportunity.id}'),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
