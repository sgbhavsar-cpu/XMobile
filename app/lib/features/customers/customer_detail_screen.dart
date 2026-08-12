import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/enums.dart';
import '../../core/models/models.dart';
import '../../core/state/providers.dart';
import '../../core/ui/common.dart';
import '../../core/ui/form_fields.dart';

/// Customer 360 — what the rep wants in their hand walking in: recent orders, open
/// deals, and what was said last time.
class CustomerDetailScreen extends ConsumerWidget {
  const CustomerDetailScreen({super.key, required this.customerId});

  final String customerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final customer = ref.watch(customerProvider(customerId));
    final summary = ref.watch(customerSummaryProvider(customerId));

    return Scaffold(
      appBar: AppBar(title: const Text('Customer')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/check-in?customerId=$customerId'),
        icon: const Icon(Icons.login),
        label: const Text('Check in'),
      ),
      body: AsyncBody(
        value: customer,
        onRetry: () => bumpRefreshFrom(ref),
        builder: (c) => ListView(
          padding: const EdgeInsets.only(bottom: 96),
          children: [
            _Header(customer: c),
            summary.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(16),
                child: LinearProgressIndicator(),
              ),
              error: (_, __) => const SizedBox.shrink(),
              data: (s) => _SummaryCard(summary: s),
            ),
            _SitesCard(customer: c),
            _ContactsCard(customer: c),
            _OpportunitiesCard(customerId: customerId),
            _SalesHistoryCard(customerId: customerId),
            _VisitHistoryCard(customerId: customerId),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.customer});

  final Customer customer;

  @override
  Widget build(BuildContext context) => FormSectionCard(
        title: customer.name,
        subtitle: customer.accountType,
        trailing: customer.lifecycleStatus == AccountLifecycle.active
            ? null
            : StatusChip.forLifecycle(customer.lifecycleStatus),
        children: [
          if (customer.lifecycleStatus == AccountLifecycle.pendingApproval ||
              customer.lifecycleStatus == AccountLifecycle.prospect)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Proposed from the field. You can visit and record against it now; '
                'XInfo will confirm it as a customer.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (customer.phone != null)
            DetailRow(label: 'Phone', value: customer.phone!, icon: Icons.phone),
          if (customer.email != null)
            DetailRow(label: 'Email', value: customer.email!, icon: Icons.email),
          if (customer.xinfoId != null)
            DetailRow(label: 'XInfo id', value: customer.xinfoId!, icon: Icons.link),
          if (customer.gstNumber != null)
            DetailRow(label: 'GST', value: customer.gstNumber!, icon: Icons.badge),
        ],
      );
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary});

  final Customer360 summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return FormSectionCard(
      title: 'At a glance',
      // Cached XInfo data always carries its age: a stale figure shown as current is
      // worse than showing none.
      subtitle: summary.salesAsOf == null
          ? null
          : 'Sales data as of ${dateTimeFormat.format(summary.salesAsOf!)}',
      children: [
        Row(
          children: [
            _Metric(
              label: 'Sales (12m)',
              value: currencyFormat.format(summary.sales12m),
              icon: Icons.currency_rupee,
            ),
            _Metric(
              label: 'Visits (90d)',
              value: '${summary.visits90d}',
              icon: Icons.how_to_reg,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            _Metric(
              label: 'Open deals',
              value: '${summary.openOpportunities}',
              icon: Icons.trending_up,
            ),
            _Metric(
              label: 'Pipeline',
              value: currencyFormat.format(summary.openPipelineValue),
              icon: Icons.savings_outlined,
            ),
          ],
        ),
        if (summary.lastVisitAt != null) ...[
          const SizedBox(height: 8),
          Text('Last visit ${dateFormat.format(summary.lastVisitAt!)}',
              style: theme.textTheme.bodySmall),
        ],
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, required this.icon});

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        margin: const EdgeInsets.only(right: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.5),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 6),
            Text(value, style: theme.textTheme.titleMedium),
            Text(label,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

class _SitesCard extends StatelessWidget {
  const _SitesCard({required this.customer});

  final Customer customer;

  @override
  Widget build(BuildContext context) => FormSectionCard(
        title: 'Sites',
        subtitle: 'Visits are recorded against a site, not the account.',
        trailing: IconButton(
          icon: const Icon(Icons.add_location_alt),
          tooltip: 'Add a site',
          onPressed: () => context.push('/customers/${customer.id}/sites/new'),
        ),
        children: [
          for (final site in customer.sites)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: Icon(site.hasLocation ? Icons.place : Icons.location_off,
                  color: site.geoSource.isTrusted ? Colors.green : Colors.orange),
              title: Text('${site.name}${site.isPrimary ? ' · primary' : ''}'),
              subtitle: Text(
                site.hasLocation
                    ? '${site.addressSummary}\n${site.geoSource.label} · fence ${site.geofenceRadiusM} m'
                    : 'No location recorded — arrival cannot be detected',
              ),
              isThreeLine: site.hasLocation,
              trailing: TextButton(
                onPressed: () =>
                    context.push('/customers/${customer.id}/sites/${site.id}/location'),
                child: Text(site.geoSource.isTrusted ? 'Edit' : 'Capture'),
              ),
            ),
          if (customer.sites.isEmpty)
            const Text('No sites yet. Add one so visits can be recorded against it.'),
        ],
      );
}

class _ContactsCard extends StatelessWidget {
  const _ContactsCard({required this.customer});

  final Customer customer;

  @override
  Widget build(BuildContext context) => FormSectionCard(
        title: 'Contacts',
        children: [
          for (final contact in customer.contacts)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.person_outline),
              title: Text(contact.fullName),
              subtitle: Text([contact.designation, contact.phone]
                  .where((s) => s != null && s.isNotEmpty)
                  .join(' · ')),
            ),
          if (customer.contacts.isEmpty) const Text('No contacts recorded yet.'),
        ],
      );
}

class _OpportunitiesCard extends ConsumerWidget {
  const _OpportunitiesCard({required this.customerId});

  final String customerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final opportunities =
        ref.watch(opportunitiesProvider((customerId: customerId, openOnly: true)));

    return FormSectionCard(
      title: 'Open opportunities',
      trailing: IconButton(
        icon: const Icon(Icons.add),
        tooltip: 'New opportunity',
        onPressed: () => context.push('/opportunities/new?customerId=$customerId'),
      ),
      children: [
        opportunities.when(
          loading: () => const LinearProgressIndicator(),
          error: (e, _) => Text('$e'),
          data: (list) => list.isEmpty
              ? const Text('Nothing open. Create one when a requirement comes up.')
              : Column(
                  children: [
                    for (final opportunity in list)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        leading: const Icon(Icons.trending_up),
                        title: Text(opportunity.title),
                        subtitle: Text(
                          '${opportunity.stageCode}'
                          '${opportunity.estimatedValue != null ? ' · ${currencyFormat.format(opportunity.estimatedValue)}' : ''}'
                          '${opportunity.expectedCloseDate != null ? ' · closes ${dateFormat.format(opportunity.expectedCloseDate!)}' : ''}',
                        ),
                        trailing: opportunity.isOverdue
                            ? const StatusChip(label: 'Overdue', color: Colors.red)
                            : const Icon(Icons.chevron_right),
                        onTap: () => context.push('/opportunities/${opportunity.id}'),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _SalesHistoryCard extends ConsumerWidget {
  const _SalesHistoryCard({required this.customerId});

  final String customerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(salesHistoryProvider(customerId));

    return FormSectionCard(
      title: 'Recent orders',
      subtitle: 'From XInfo — read-only',
      children: [
        history.when(
          loading: () => const LinearProgressIndicator(),
          error: (e, _) => Text('$e'),
          data: (list) => list.isEmpty
              ? const Text('No order history on file.')
              : Column(
                  children: [
                    for (final item in list.take(5))
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        leading: Icon(item.documentType == 'INVOICE'
                            ? Icons.receipt
                            : Icons.shopping_cart_outlined),
                        title: Text('${item.documentNo ?? item.documentType} · '
                            '${currencyFormat.format(item.amount)}'),
                        subtitle: Text(
                          '${dateFormat.format(item.documentDate)}'
                          '${item.summary != null ? ' · ${item.summary}' : ''}',
                        ),
                        trailing: item.status == null ? null : StatusChip(label: item.status!),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _VisitHistoryCard extends ConsumerWidget {
  const _VisitHistoryCard({required this.customerId});

  final String customerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visits = ref.watch(customerVisitsProvider(customerId));

    return FormSectionCard(
      title: 'Past visits',
      children: [
        visits.when(
          loading: () => const LinearProgressIndicator(),
          error: (e, _) => Text('$e'),
          data: (list) => list.isEmpty
              ? const Text('No visits recorded yet.')
              : Column(
                  children: [
                    for (final visit in list.take(5))
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        leading: const Icon(Icons.history),
                        title: Text(dateFormat.format(visit.checkInAt)),
                        subtitle: Text(
                          '${visit.siteName}'
                          '${visit.duration != null ? ' · ${visit.duration!.inMinutes} min' : ''}',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => context.push('/visits/${visit.id}'),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}
