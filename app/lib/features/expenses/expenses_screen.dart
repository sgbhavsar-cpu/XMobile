import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/enums.dart';
import '../../core/state/providers.dart';
import '../../core/ui/common.dart';
import '../../core/ui/form_fields.dart';

class ExpensesScreen extends ConsumerWidget {
  const ExpensesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final expenses = ref.watch(expensesProvider((from: null, to: null)));
    final inbox = ref.watch(shareInboxProvider);
    final categories = ref.watch(expenseCategoriesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Expenses'),
        actions: [
          IconButton(
            icon: Badge(
              isLabelVisible: (inbox.valueOrNull?.isNotEmpty ?? false),
              label: Text('${inbox.valueOrNull?.length ?? 0}'),
              child: const Icon(Icons.inbox),
            ),
            tooltip: 'Shared receipts',
            onPressed: () => context.push('/share-inbox'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/expenses/new'),
        icon: const Icon(Icons.add),
        label: const Text('Add expense'),
      ),
      body: RefreshIndicator(
        onRefresh: () async => bumpRefreshFrom(ref),
        child: AsyncBody(
          value: expenses,
          onRetry: () => bumpRefreshFrom(ref),
          builder: (list) {
            final pendingInbox = inbox.valueOrNull ?? const [];

            if (list.isEmpty && pendingInbox.isEmpty) {
              return EmptyState(
                icon: Icons.receipt_long,
                title: 'No expenses yet',
                message: 'Add one here, or share a payment screenshot into XMobile from '
                    'your UPI app and it will be waiting for you.',
                action: FilledButton.tonal(
                  onPressed: () => context.push('/expenses/new'),
                  child: const Text('Add an expense'),
                ),
              );
            }

            final total = list
                .where((e) => e.status != ExpenseStatus.voided)
                .fold<double>(0, (sum, e) => sum + e.amount);

            return ListView(
              padding: const EdgeInsets.only(bottom: 88),
              children: [
                if (pendingInbox.isNotEmpty)
                  Card(
                    margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                    color: Theme.of(context).colorScheme.primaryContainer,
                    child: ListTile(
                      leading: const Icon(Icons.inbox),
                      title: Text('${pendingInbox.length} shared receipt'
                          '${pendingInbox.length == 1 ? '' : 's'} waiting'),
                      subtitle: const Text('Tap to turn them into expenses'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => context.push('/share-inbox'),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text('${list.length} entries · ${currencyFormat.format(total)}',
                      style: Theme.of(context).textTheme.titleSmall),
                ),
                for (final expense in list)
                  Card(
                    margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                    child: ListTile(
                      leading: CircleAvatar(
                        child: Icon(_iconFor(expense.categoryCode), size: 20),
                      ),
                      title: Text(
                        categories.valueOrNull
                                ?.where((c) => c.code == expense.categoryCode)
                                .firstOrNull
                                ?.name ??
                            expense.categoryCode,
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${dateFormat.format(expense.expenseDate)}'
                              '${expense.merchantName != null ? ' · ${expense.merchantName}' : ''}'),
                          if (expense.captureSource == CaptureSource.shareIntent)
                            Text('From a shared receipt',
                                style: Theme.of(context).textTheme.bodySmall),
                          if (expense.xinfoStatus != null)
                            Text('XInfo: ${expense.xinfoStatus}',
                                style: Theme.of(context).textTheme.bodySmall),
                        ],
                      ),
                      isThreeLine: expense.xinfoStatus != null ||
                          expense.captureSource == CaptureSource.shareIntent,
                      trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(currencyFormat.format(expense.amount),
                              style: Theme.of(context).textTheme.titleSmall),
                          const SizedBox(height: 4),
                          StatusChip.forExpense(expense.status),
                        ],
                      ),
                      onTap: () => context.push('/expenses/${expense.id}'),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  IconData _iconFor(String categoryCode) => switch (categoryCode) {
        'TRAVEL_AIR' => Icons.flight,
        'TRAVEL_RAIL' => Icons.train,
        'TRAVEL_BUS' => Icons.directions_bus,
        'TRAVEL_TAXI' => Icons.local_taxi,
        'TRAVEL_OWN_VEHICLE' => Icons.two_wheeler,
        'FUEL' => Icons.local_gas_station,
        'TOLL_PARKING' => Icons.toll,
        'LODGING' => Icons.hotel,
        'MEALS' => Icons.restaurant,
        'DAILY_ALLOWANCE' => Icons.payments,
        'COMMUNICATION' => Icons.phone_android,
        'COURIER' => Icons.local_shipping,
        _ => Icons.receipt,
      };
}
