import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../core/api/api_client.dart';
import '../../core/models/models.dart';
import '../../core/state/providers.dart';
import '../../core/ui/common.dart';
import '../../core/ui/form_fields.dart';

/// Create or update an opportunity.
///
/// Only the fields the rep owns are editable here — stage, value, expected close date,
/// competitor. Ownership and customer linkage belong to XInfo, which is what makes the
/// two-way sync safe: both sides write, but never to the same field.
class OpportunityFormScreen extends ConsumerStatefulWidget {
  const OpportunityFormScreen({super.key, this.opportunityId, this.customerId, this.visitId});

  final String? opportunityId;
  final String? customerId;

  /// When set, the change is attributed to this visit — that link is what turns visit
  /// reports into pipeline analytics.
  final String? visitId;

  @override
  ConsumerState<OpportunityFormScreen> createState() => _OpportunityFormScreenState();
}

class _OpportunityFormScreenState extends ConsumerState<OpportunityFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _uuid = const Uuid();

  final _title = TextEditingController();
  final _description = TextEditingController();
  final _value = TextEditingController();
  final _competitor = TextEditingController();
  final _reason = TextEditingController();

  Customer? _customer;
  Opportunity? _existing;
  String? _stageCode;
  DateTime? _closeDate;

  bool _loading = true;
  bool _busy = false;
  Map<String, String> _fieldErrors = {};

  bool get _isEdit => widget.opportunityId != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _value.dispose();
    _competitor.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final api = ref.read(apiClientProvider);
    try {
      if (_isEdit) {
        final all = await api.opportunities(openOnly: false);
        _existing = all.where((o) => o.id == widget.opportunityId).firstOrNull;
        if (_existing != null) {
          _title.text = _existing!.title;
          _description.text = _existing!.description ?? '';
          _value.text = _existing!.estimatedValue?.toStringAsFixed(0) ?? '';
          _competitor.text = _existing!.competitor ?? '';
          _stageCode = _existing!.stageCode;
          _closeDate = _existing!.expectedCloseDate;
          _customer = await api.customer(_existing!.customerId);
        }
      } else if (widget.customerId != null) {
        _customer = await api.customer(widget.customerId!);
      }

      final stages = await api.opportunityStages();
      _stageCode ??= stages.where((s) => s.isOpen).firstOrNull?.code;
    } catch (e) {
      if (mounted) showApiError(context, e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_customer == null) {
      showApiError(context, 'Choose a customer');
      return;
    }

    setState(() {
      _busy = true;
      _fieldErrors = {};
    });

    final api = ref.read(apiClientProvider);
    final opportunity = Opportunity(
      id: _existing?.id ?? _uuid.v4(),
      customerId: _customer!.id,
      customerName: _customer!.name,
      title: _title.text.trim(),
      stageCode: _stageCode ?? 'IDENTIFIED',
      xinfoId: _existing?.xinfoId,
      siteId: _existing?.siteId ?? _customer!.primarySite?.id,
      description: _description.text.trim().isEmpty ? null : _description.text.trim(),
      estimatedValue: double.tryParse(_value.text.trim()),
      expectedCloseDate: _closeDate,
      competitor: _competitor.text.trim().isEmpty ? null : _competitor.text.trim(),
      source: _existing?.source ?? 'FIELD',
      isFieldCreated: _existing?.isFieldCreated ?? true,
      closedAt: _existing?.closedAt,
    );

    try {
      if (_isEdit) {
        await api.updateOpportunity(
          opportunity,
          visitId: widget.visitId,
          reason: _reason.text.trim().isEmpty ? null : _reason.text.trim(),
        );
      } else {
        await api.createOpportunity(opportunity);
        if (widget.visitId != null) {
          final linked = await api.visitOpportunityIds(widget.visitId!);
          await api.linkVisitOpportunities(widget.visitId!, [...linked, opportunity.id]);
        }
      }

      bumpRefreshFrom(ref);
      if (!mounted) return;
      showSuccess(context, _isEdit ? 'Opportunity updated' : 'Opportunity created');
      context.pop();
    } catch (e) {
      if (!mounted) return;
      if (e is OfflineException) {
        ref.read(outboxProvider.notifier).enqueue(
              entity: 'opportunity',
              entityId: opportunity.id,
              operation: _isEdit ? 'UPDATE' : 'INSERT',
              description: '${_isEdit ? 'Update' : 'New'}: ${opportunity.title}',
            );
        ref.read(connectivityProvider.notifier).state = false;
        showSuccess(context, 'Saved on this device — will sync when you are online');
        context.pop();
        return;
      }
      if (e is ApiException) setState(() => _fieldErrors = e.fieldErrors);
      showApiError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Opportunity')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final stages = ref.watch(opportunityStagesProvider);
    final customers = ref.watch(customersProvider(null));
    final history = _isEdit ? ref.watch(opportunityHistoryProvider(widget.opportunityId!)) : null;

    final selectedStage =
        stages.valueOrNull?.where((s) => s.code == _stageCode).firstOrNull;
    final needsReason = selectedStage?.requiresReason == true &&
        _existing?.stageCode != _stageCode;

    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'Opportunity' : 'New opportunity')),
      bottomNavigationBar: SubmitBar(
        label: _isEdit ? 'Save changes' : 'Create',
        busy: _busy,
        onSubmit: _save,
        note: widget.visitId != null
            ? 'This change will be attributed to the current visit.'
            : null,
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          children: [
            FormSectionCard(
              title: 'Opportunity',
              children: [
                if (_isEdit)
                  DetailRow(label: 'Customer', value: _customer?.name ?? '—', emphasise: true)
                else
                  customers.when(
                    loading: () => const LinearProgressIndicator(),
                    error: (e, _) => Text('$e'),
                    data: (list) => AppDropdown<Customer>(
                      label: 'Customer',
                      required: true,
                      items: list,
                      value: _customer,
                      itemLabel: (c) => c.name,
                      onChanged: (customer) => setState(() => _customer = customer),
                    ),
                  ),
                AppTextField(
                  label: 'Title',
                  controller: _title,
                  required: true,
                  hint: 'e.g. Q4 bulk supply — Grade A',
                  errorText: _fieldErrors['title'],
                ),
                AppTextField(
                  label: 'What the customer needs',
                  controller: _description,
                  maxLines: 3,
                ),
              ],
            ),
            FormSectionCard(
              title: 'Where it stands',
              subtitle: 'These are the fields you own. XInfo keeps ownership and linkage.',
              children: [
                stages.when(
                  loading: () => const LinearProgressIndicator(),
                  error: (e, _) => Text('$e'),
                  data: (list) => AppDropdown<OpportunityStage>(
                    label: 'Stage',
                    required: true,
                    items: list,
                    value: list.where((s) => s.code == _stageCode).firstOrNull,
                    itemLabel: (s) => '${s.name} (${s.probabilityPct}%)',
                    onChanged: (stage) => setState(() => _stageCode = stage?.code),
                  ),
                ),
                AppNumberField(
                  label: 'Estimated value',
                  controller: _value,
                  prefix: '₹ ',
                ),
                AppDateField(
                  label: 'Expected to close',
                  value: _closeDate,
                  lastDate: DateTime.now().add(const Duration(days: 730)),
                  onChanged: (date) => setState(() => _closeDate = date),
                ),
                AppTextField(label: 'Competitor in play', controller: _competitor),
                if (needsReason)
                  AppTextField(
                    label: 'Reason',
                    controller: _reason,
                    required: true,
                    maxLines: 2,
                    helper: '${selectedStage!.name} needs an explanation',
                    errorText: _fieldErrors['reason'],
                  ),
              ],
            ),
            if (history != null)
              FormSectionCard(
                title: 'History',
                children: [
                  history.when(
                    loading: () => const LinearProgressIndicator(),
                    error: (e, _) => Text('$e'),
                    data: (changes) => changes.isEmpty
                        ? const Text('No changes recorded yet.')
                        : Column(
                            children: [
                              for (final change in changes)
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  dense: true,
                                  leading: const Icon(Icons.timeline, size: 18),
                                  title: Text(change.fromStage == null
                                      ? 'Created at ${change.toStage}'
                                      : '${change.fromStage} → ${change.toStage}'),
                                  subtitle: Text([
                                    dateTimeFormat.format(change.changedAt),
                                    if (change.visitId != null) 'during a visit',
                                    if (change.reason != null) change.reason!,
                                  ].join(' · ')),
                                ),
                            ],
                          ),
                  ),
                ],
              ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
