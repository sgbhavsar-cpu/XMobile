import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/models.dart';
import '../../core/state/providers.dart';
import '../../core/ui/common.dart';
import '../../core/ui/form_fields.dart';

/// A visit in progress or finished: check out, write the report, link opportunities.
class VisitDetailScreen extends ConsumerStatefulWidget {
  const VisitDetailScreen({super.key, required this.visitId});

  final String visitId;

  @override
  ConsumerState<VisitDetailScreen> createState() => _VisitDetailScreenState();
}

class _VisitDetailScreenState extends ConsumerState<VisitDetailScreen> {
  bool _busy = false;

  Future<void> _checkOut(Visit visit) async {
    var checkOutAt = DateTime.now();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Check out'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Leaving ${visit.customerName}?'),
              const SizedBox(height: 12),
              AppDateTimeField(
                label: 'Check-out time',
                value: checkOutAt,
                onChanged: (value) => setDialogState(() => checkOutAt = value),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Check out')),
          ],
        ),
      ),
    );

    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);

    try {
      await ref
          .read(apiClientProvider)
          .checkOut(visit.id, checkOutAt, visit.checkInPoint);
      bumpRefreshFrom(ref);
      if (!mounted) return;
      showSuccess(context, 'Checked out — write the report while it is fresh');
      context.push('/visits/${visit.id}/report');
    } catch (e) {
      if (mounted) showApiError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final visits = ref.watch(visitsProvider((from: null, to: null)));
    final report = ref.watch(visitReportProvider(widget.visitId));

    return Scaffold(
      appBar: AppBar(title: const Text('Visit')),
      body: AsyncBody(
        value: visits,
        onRetry: () => bumpRefreshFrom(ref),
        builder: (list) {
          final visit = list.where((v) => v.id == widget.visitId).firstOrNull;
          if (visit == null) {
            return const EmptyState(icon: Icons.help_outline, title: 'Visit not found');
          }

          return ListView(
            children: [
              FormSectionCard(
                title: visit.customerName,
                subtitle: visit.siteName,
                trailing: StatusChip(
                  label: visit.status.label,
                  color: visit.isOpen ? Colors.blue : Colors.green,
                ),
                children: [
                  DetailRow(
                    label: 'Checked in',
                    value: dateTimeFormat.format(visit.checkInAt),
                    icon: Icons.login,
                  ),
                  if (visit.checkOutAt != null)
                    DetailRow(
                      label: 'Checked out',
                      value: dateTimeFormat.format(visit.checkOutAt!),
                      icon: Icons.logout,
                    ),
                  if (visit.duration != null)
                    DetailRow(
                      label: 'Time on site',
                      value: '${visit.duration!.inMinutes} minutes',
                      icon: Icons.timer_outlined,
                      emphasise: true,
                    ),
                  if (visit.checkInDistanceM != null)
                    DetailRow(
                      label: 'Distance',
                      value: '${visit.checkInDistanceM} m from the recorded location',
                      icon: Icons.straighten,
                    ),
                  if (visit.isUnplanned)
                    const DetailRow(
                        label: 'Type', value: 'Unplanned visit', icon: Icons.event_note),
                ],
              ),
              if (visit.isOutOfGeofence)
                Card(
                  margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                  color: Theme.of(context).colorScheme.errorContainer.withOpacity(0.4),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.flag_outlined, size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Checked in away from the site',
                                  style: Theme.of(context).textTheme.titleSmall),
                              const SizedBox(height: 2),
                              Text(
                                visit.outOfFenceRemark?.isNotEmpty == true
                                    ? visit.outOfFenceRemark!
                                    : 'Reason: ${visit.outOfFenceReasonCode ?? 'not given'}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              Text('Your manager will see this as an exception.',
                                  style: Theme.of(context).textTheme.bodySmall),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (visit.isOpen)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: FilledButton.icon(
                    onPressed: _busy ? null : () => _checkOut(visit),
                    icon: const Icon(Icons.logout),
                    label: const Text('Check out'),
                  ),
                ),
              report.when(
                loading: () => const SizedBox.shrink(),
                error: (_, __) => const SizedBox.shrink(),
                data: (r) => _ReportCard(visit: visit, report: r),
              ),
              _OpportunitiesCard(visit: visit),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: OutlinedButton.icon(
                  onPressed: () => context.push('/expenses/new?tourId=${visit.tourId ?? ''}'),
                  icon: const Icon(Icons.receipt_long),
                  label: const Text('Add an expense for this visit'),
                ),
              ),
              const SizedBox(height: 32),
            ],
          );
        },
      ),
    );
  }
}

class _ReportCard extends StatelessWidget {
  const _ReportCard({required this.visit, required this.report});

  final Visit visit;
  final VisitReport? report;

  @override
  Widget build(BuildContext context) {
    final submitted = report != null && !report!.isDraft;

    return FormSectionCard(
      title: 'Visit report',
      subtitle: submitted
          ? 'Submitted ${dateTimeFormat.format(report!.submittedAt!)}'
          : (report == null ? 'Not started' : 'Draft saved'),
      children: [
        if (report != null) ...[
          if (report!.outcomeCode != null)
            DetailRow(label: 'Outcome', value: report!.outcomeCode!, emphasise: true),
          if (report!.summary != null) DetailRow(label: 'Summary', value: report!.summary!),
          if (report!.nextAction != null)
            DetailRow(label: 'Next action', value: report!.nextAction!),
          if (report!.followUpDate != null)
            DetailRow(label: 'Follow up', value: dateFormat.format(report!.followUpDate!)),
          const SizedBox(height: 8),
        ],
        FilledButton.tonalIcon(
          onPressed: () => context.push('/visits/${visit.id}/report'),
          icon: Icon(submitted ? Icons.visibility : Icons.edit_note),
          label: Text(submitted
              ? 'View report'
              : (report == null ? 'Write the report' : 'Continue the draft')),
        ),
      ],
    );
  }
}

class _OpportunitiesCard extends ConsumerWidget {
  const _OpportunitiesCard({required this.visit});

  final Visit visit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final opportunities =
        ref.watch(opportunitiesProvider((customerId: visit.customerId, openOnly: true)));
    final linkedIds = ref.watch(visitOpportunityIdsProvider(visit.id));

    return FormSectionCard(
      title: 'Opportunities',
      subtitle: 'Tag what this call moved, so the pipeline knows which visit did it.',
      children: [
        opportunities.when(
          loading: () => const LinearProgressIndicator(),
          error: (e, _) => Text('$e'),
          data: (list) {
            if (list.isEmpty) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('No open opportunities for this customer.',
                      style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () => context.push(
                        '/opportunities/new?customerId=${visit.customerId}&visitId=${visit.id}'),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Create one'),
                  ),
                ],
              );
            }

            final linked = linkedIds.valueOrNull ?? const <String>[];

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final opportunity in list)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: linked.contains(opportunity.id),
                    title: Text(opportunity.title),
                    subtitle: Text(
                      '${opportunity.stageCode}'
                      '${opportunity.estimatedValue != null ? ' · ${currencyFormat.format(opportunity.estimatedValue)}' : ''}',
                    ),
                    onChanged: (checked) async {
                      final updated = [...linked];
                      if (checked == true) {
                        updated.add(opportunity.id);
                      } else {
                        updated.remove(opportunity.id);
                      }
                      await ref
                          .read(apiClientProvider)
                          .linkVisitOpportunities(visit.id, updated);
                      bumpRefreshFrom(ref);
                    },
                    secondary: IconButton(
                      icon: const Icon(Icons.arrow_forward),
                      tooltip: 'Update this opportunity',
                      onPressed: () => context
                          .push('/opportunities/${opportunity.id}?visitId=${visit.id}'),
                    ),
                  ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => context.push(
                      '/opportunities/new?customerId=${visit.customerId}&visitId=${visit.id}'),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('New opportunity'),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}
