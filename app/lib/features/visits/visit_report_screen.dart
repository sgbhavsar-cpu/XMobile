import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_client.dart';
import '../../core/models/models.dart';
import '../../core/state/providers.dart';
import '../../core/ui/common.dart';
import '../../core/ui/form_fields.dart';
import 'dynamic_form.dart';

/// The visit report: fixed core fields that are always queryable, plus the admin-defined
/// dynamic section rendered from its template.
///
/// A draft is editable; once submitted the report is read-only, because a report that can
/// be quietly rewritten afterwards is not evidence of anything.
class VisitReportScreen extends ConsumerStatefulWidget {
  const VisitReportScreen({super.key, required this.visitId});

  final String visitId;

  @override
  ConsumerState<VisitReportScreen> createState() => _VisitReportScreenState();
}

class _VisitReportScreenState extends ConsumerState<VisitReportScreen> {
  final _formKey = GlobalKey<FormState>();

  final _summary = TextEditingController();
  final _discussion = TextEditingController();
  final _nextAction = TextEditingController();
  final _competitorNotes = TextEditingController();
  final _issues = TextEditingController();
  final _orderValue = TextEditingController();
  final _contactName = TextEditingController();

  String? _outcomeCode;
  DateTime? _followUpDate;
  bool _orderIntent = false;
  bool _competitorSeen = false;
  int? _sentiment;
  Map<String, dynamic> _answers = {};
  Map<String, String> _dynamicErrors = {};
  Map<String, String> _fieldErrors = {};

  Visit? _visit;
  VisitReport? _existing;
  FormTemplate? _template;
  bool _loading = true;
  bool _busy = false;

  bool get _readOnly => _existing != null && !_existing!.isDraft;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _summary.dispose();
    _discussion.dispose();
    _nextAction.dispose();
    _competitorNotes.dispose();
    _issues.dispose();
    _orderValue.dispose();
    _contactName.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final api = ref.read(apiClientProvider);
    try {
      final visits = await api.visits();
      _visit = visits.where((v) => v.id == widget.visitId).firstOrNull;

      _existing = await api.visitReport(widget.visitId);
      final templates = await api.formTemplates();

      // The template is pinned at first save, so a mid-day publish cannot change a form
      // the rep is part-way through filling in.
      _template = _existing?.templateCode != null
          ? templates
              .where((t) =>
                  t.code == _existing!.templateCode && t.version == _existing!.templateVersion)
              .firstOrNull
          : templates.where((t) => t.visitTypeCode == _visit?.visitTypeCode).firstOrNull;

      if (_existing != null) {
        _outcomeCode = _existing!.outcomeCode;
        _summary.text = _existing!.summary ?? '';
        _discussion.text = _existing!.discussionPoints ?? '';
        _nextAction.text = _existing!.nextAction ?? '';
        _followUpDate = _existing!.followUpDate;
        _orderIntent = _existing!.orderIntent;
        _orderValue.text = _existing!.orderValueEst?.toStringAsFixed(0) ?? '';
        _competitorSeen = _existing!.competitorSeen;
        _competitorNotes.text = _existing!.competitorNotes ?? '';
        _sentiment = _existing!.customerSentiment;
        _issues.text = _existing!.issuesRaised ?? '';
        _contactName.text = _existing!.contactMetName ?? '';
        _answers = Map.of(_existing!.answers);
      }
    } catch (e) {
      if (mounted) showApiError(context, e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  VisitReport _build() => VisitReport(
        visitId: widget.visitId,
        templateCode: _template?.code,
        templateVersion: _template?.version,
        outcomeCode: _outcomeCode,
        summary: _summary.text.trim(),
        discussionPoints: _discussion.text.trim(),
        nextAction: _nextAction.text.trim(),
        followUpDate: _followUpDate,
        orderIntent: _orderIntent,
        orderValueEst: double.tryParse(_orderValue.text.trim()),
        competitorSeen: _competitorSeen,
        competitorNotes: _competitorNotes.text.trim(),
        customerSentiment: _sentiment,
        issuesRaised: _issues.text.trim(),
        contactMetId: _visit?.contactId,
        contactMetName: _contactName.text.trim(),
        answers: _answers,
      );

  Future<void> _save({required bool submit}) async {
    if (submit && !_formKey.currentState!.validate()) return;

    // Validate the dynamic section locally so an offline rep gets the same answer the
    // server would give.
    if (submit && _template != null) {
      final errors = validateDynamicAnswers(_template!.sections, _answers);
      if (errors.isNotEmpty) {
        setState(() => _dynamicErrors = errors);
        showApiError(context, 'Some questions still need answers');
        return;
      }
    }

    setState(() {
      _busy = true;
      _fieldErrors = {};
      _dynamicErrors = {};
    });

    try {
      await ref.read(apiClientProvider).saveVisitReport(_build(), submit: submit);
      bumpRefreshFrom(ref);
      if (!mounted) return;
      showSuccess(context, submit ? 'Report submitted' : 'Draft saved');
      if (submit) context.pop();
    } catch (e) {
      if (!mounted) return;
      if (e is OfflineException) {
        ref.read(outboxProvider.notifier).enqueue(
              entity: 'visit_report',
              entityId: widget.visitId,
              operation: 'UPDATE',
              description: 'Report for ${_visit?.customerName ?? 'visit'}',
            );
        ref.read(connectivityProvider.notifier).state = false;
        showSuccess(context, 'Saved on this device — will sync when you are online');
        if (submit) context.pop();
        return;
      }
      showApiError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Visit report')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final outcomes = ref.watch(visitOutcomesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Visit report'),
        actions: [
          if (_readOnly)
            IconButton(
              icon: const Icon(Icons.lock_outline),
              tooltip: 'Submitted reports cannot be edited',
              onPressed: () => showSuccess(
                  context, 'Submitted. Corrections go through an amendment with a reason.'),
            ),
        ],
      ),
      bottomNavigationBar: _readOnly
          ? null
          : SubmitBar(
              label: 'Submit report',
              secondaryLabel: 'Save draft',
              busy: _busy,
              onSubmit: () => _save(submit: true),
              onSecondary: () => _save(submit: false),
              note: 'Once submitted the report is locked.',
            ),
      body: Form(
        key: _formKey,
        child: ListView(
          children: [
            if (_visit != null)
              FormSectionCard(
                title: _visit!.customerName,
                subtitle: '${_visit!.siteName} · ${dateTimeFormat.format(_visit!.checkInAt)}'
                    '${_visit!.duration != null ? ' · ${_visit!.duration!.inMinutes} min' : ''}',
                children: const [],
              ),

            // --- fixed core: always present, always queryable ---
            FormSectionCard(
              title: 'Outcome',
              children: [
                outcomes.when(
                  loading: () => const LinearProgressIndicator(),
                  error: (e, _) => Text('$e'),
                  data: (list) => AppDropdown<VisitOutcome>(
                    label: 'How did it go',
                    required: true,
                    enabled: !_readOnly,
                    items: list,
                    value: list.where((o) => o.code == _outcomeCode).firstOrNull,
                    itemLabel: (o) => o.name,
                    errorText: _fieldErrors['outcomeCode'],
                    onChanged: (outcome) => setState(() {
                      _outcomeCode = outcome?.code;
                      if (outcome?.requiresFollowUp == true) {
                        _followUpDate ??= DateTime.now().add(const Duration(days: 7));
                      }
                    }),
                  ),
                ),
                AppTextField(
                  label: 'Summary',
                  controller: _summary,
                  required: true,
                  maxLines: 3,
                  enabled: !_readOnly,
                  hint: 'What was discussed and agreed',
                  errorText: _fieldErrors['summary'],
                ),
                AppTextField(
                  label: 'Discussion points',
                  controller: _discussion,
                  maxLines: 3,
                  enabled: !_readOnly,
                ),
                AppTextField(
                  label: 'Contact met',
                  controller: _contactName,
                  enabled: !_readOnly,
                  helper: 'Free text if they are not in the customer record yet',
                ),
                AppRatingField(
                  label: 'How is the relationship',
                  value: _sentiment,
                  onChanged: _readOnly ? (_) {} : (v) => setState(() => _sentiment = v),
                ),
              ],
            ),
            FormSectionCard(
              title: 'Next steps',
              children: [
                AppTextField(
                  label: 'Next action',
                  controller: _nextAction,
                  maxLines: 2,
                  enabled: !_readOnly,
                ),
                AppDateField(
                  label: 'Follow up on',
                  value: _followUpDate,
                  enabled: !_readOnly,
                  errorText: _fieldErrors['followUpDate'],
                  onChanged: (date) => setState(() => _followUpDate = date),
                ),
                AppSwitchField(
                  label: 'Order expected',
                  value: _orderIntent,
                  onChanged: _readOnly ? (_) {} : (v) => setState(() => _orderIntent = v),
                ),
                if (_orderIntent)
                  AppNumberField(
                    label: 'Estimated value',
                    controller: _orderValue,
                    prefix: '₹ ',
                    enabled: !_readOnly,
                  ),
              ],
            ),
            FormSectionCard(
              title: 'Market',
              children: [
                AppSwitchField(
                  label: 'Competitor activity seen',
                  value: _competitorSeen,
                  onChanged: _readOnly ? (_) {} : (v) => setState(() => _competitorSeen = v),
                ),
                if (_competitorSeen)
                  AppTextField(
                    label: 'What did you see',
                    controller: _competitorNotes,
                    maxLines: 2,
                    enabled: !_readOnly,
                  ),
                AppTextField(
                  label: 'Issues raised by the customer',
                  controller: _issues,
                  maxLines: 2,
                  enabled: !_readOnly,
                ),
              ],
            ),

            // --- dynamic extension: whatever the admin published ---
            if (_template != null) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text(
                  '${_template!.name} (v${_template!.version})',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ),
              for (final section in _template!.sections)
                DynamicFormSection(
                  section: section,
                  answers: _answers,
                  enabled: !_readOnly,
                  onChanged: (key, value) => setState(() => _answers[key] = value),
                ),
              if (_dynamicErrors.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final error in _dynamicErrors.values) Text('• $error'),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}
