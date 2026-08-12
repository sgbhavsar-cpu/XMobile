import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/enums.dart';
import '../../core/state/providers.dart';
import '../../core/ui/common.dart';

class CustomersScreen extends ConsumerStatefulWidget {
  const CustomersScreen({super.key});

  @override
  ConsumerState<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends ConsumerState<CustomersScreen> {
  final _search = TextEditingController();
  String? _query;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final customers = ref.watch(customersProvider(_query));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Customers'),
        actions: [
          IconButton(
            icon: const Icon(Icons.trending_up),
            tooltip: 'Opportunities',
            onPressed: () => context.push('/opportunities'),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(58),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: TextField(
              controller: _search,
              onChanged: (value) => setState(() => _query = value.trim().isEmpty ? null : value),
              decoration: InputDecoration(
                hintText: 'Search customers',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                filled: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                suffixIcon: _query == null
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _search.clear();
                          setState(() => _query = null);
                        },
                      ),
              ),
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/customers/new'),
        icon: const Icon(Icons.add_business),
        label: const Text('New prospect'),
      ),
      body: RefreshIndicator(
        onRefresh: () async => bumpRefreshFrom(ref),
        child: AsyncBody(
          value: customers,
          onRetry: () => bumpRefreshFrom(ref),
          builder: (list) => list.isEmpty
              ? EmptyState(
                  icon: Icons.store,
                  title: _query == null ? 'No customers assigned' : 'Nothing matched',
                  message: _query == null
                      ? 'Customers come from XInfo. You can also propose a new prospect.'
                      : 'Try a different search.',
                  action: FilledButton.tonal(
                    onPressed: () => context.push('/customers/new'),
                    child: const Text('Propose a prospect'),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: list.length,
                  itemBuilder: (context, index) {
                    final customer = list[index];
                    final site = customer.primarySite;

                    return Card(
                      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                      child: ListTile(
                        leading: CircleAvatar(
                          child: Text(customer.name.substring(0, 1).toUpperCase()),
                        ),
                        title: Text(customer.name),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (site != null) Text(site.addressSummary),
                            Row(
                              children: [
                                if (customer.category != null)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 6, top: 4),
                                    child: StatusChip(label: 'Class ${customer.category}'),
                                  ),
                                if (customer.lifecycleStatus != AccountLifecycle.active)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: StatusChip.forLifecycle(customer.lifecycleStatus),
                                  ),
                              ],
                            ),
                          ],
                        ),
                        isThreeLine: true,
                        onTap: () => context.push('/customers/${customer.id}'),
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }
}
