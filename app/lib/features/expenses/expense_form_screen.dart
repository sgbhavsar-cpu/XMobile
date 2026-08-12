import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../core/api/api_client.dart';
import '../../core/models/enums.dart';
import '../../core/models/models.dart';
import '../../core/state/providers.dart';
import '../../core/ui/common.dart';
import '../../core/ui/form_fields.dart';

/// Capture an expense.
///
/// Three things this form has to get right, all from docs/05:
///  * category rules drive what is required (receipt, route, tour link) — enforced here
///    so an offline rep gets the same answer the server would give;
///  * a shared receipt pre-fills the form from on-device OCR, but never saves itself:
///    OCR misreads amounts, and a silently-wrong expense is worse than a missing one;
///  * mileage and per-diem amounts are *suggestions* from synced rates. XInfo decides.
class ExpenseFormScreen extends ConsumerStatefulWidget {
  const ExpenseFormScreen({super.key, this.expenseId, this.shareInboxItemId, this.tourId});

  final String? expenseId;
  final String? shareInboxItemId;
  final String? tourId;

  @override
  ConsumerState<ExpenseFormScreen> createState() => _ExpenseFormScreenState();
}

class _ExpenseFormScreenState extends ConsumerState<ExpenseFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _uuid = const Uuid();

  final _amount = TextEditingController();
  final _merchant = TextEditingController();
  final _paymentRef = TextEditingController();
  final _description = TextEditingController();
  final _fromPlace = TextEditingController();
  final _toPlace = TextEditingController();
  final _distanceKm = TextEditingController();

  String? _categoryCode;
  DateTime _date = DateTime.now();
  String? _paymentMode;
  TravelMode? _travelMode;
  String? _tourId;
  List<String> _attachmentIds = [];
  Attachment? _attachment;
  OcrResult? _ocr;
  Expense? _existing;
  MileageSuggestion? _mileage;
  List<Expense> _duplicates = [];

  bool _loading = true;
  bool _busy = false;
  Map<String, String> _fieldErrors = {};

  static const _paymentModes = ['CASH', 'UPI', 'CARD', 'NETBANKING', 'COMPANY_PAID', 'OTHER'];

  bool get _readOnly => _existing != null && !_existing!.status.isEditable;

  @override
  void initState() {
    super.initState();
    _tourId = widget.tourId?.isEmpty == true ? null : widget.tourId;
    _load();
  }

  @override
  void dispose() {
    for (final c in [
      _amount, _merchant, _paymentRef, _description, _fromPlace, _toPlace, _distanceKm,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final api = ref.read(apiClientProvider);
    try {
      if (widget.expenseId != null) {
        final all = await api.expenses();
        _existing = all.where((e) => e.id == widget.expenseId).firstOrNull;
        if (_existing != null) {
          _categoryCode = _existing!.categoryCode;
          _date = _existing!.expenseDate;
          _amount.text = _existing!.amount.toStringAsFixed(0);
          _merchant.text = _existing!.merchantName ?? '';
          _paymentRef.text = _existing!.paymentRef ?? '';
          _description.text = _existing!.description ?? '';
          _fromPlace.text = _existing!.fromPlace ?? '';
          _toPlace.text = _existing!.toPlace ?? '';
          _distanceKm.text = _existing!.distanceKm?.toStringAsFixed(1) ?? '';
          _paymentMode = _existing!.paymentMode;
          _travelMode = _existing!.travelMode;
          _tourId = _existing!.tourId;
          _attachmentIds = List.of(_existing!.attachmentIds);
        }
      }

      // A shared receipt pre-fills the form. The rep still confirms every field.
      if (widget.shareInboxItemId != null) {
        final inbox = await api.shareInbox();
        final item = inbox.where((i) => i.id == widget.shareInboxItemId).firstOrNull;
        if (item != null) {
          _attachment = item.attachment;
          _attachmentIds = [item.attachment.id];
          _ocr = item.ocr;
          _categoryCode = item.suggestedCategoryCode;
          if (item.ocr != null) {
            _amount.text = item.ocr!.amount?.toStringAsFixed(0) ?? '';
            _merchant.text = item.ocr!.merchantName ?? '';
            _paymentRef.text = item.ocr!.paymentRef ?? '';
            _paymentMode = item.ocr!.paymentMode;
            _date = item.ocr!.txnDate ?? DateTime.now();
          }
        }
      }

      _mileage = await api.mileageSuggestion(_date, tourId: _tourId);
    } catch (e) {
      if (mounted) showApiError(context, e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  ExpenseCategory? get _category => ref
      .read(expenseCategoriesProvider)
      .valueOrNull
      ?.where((c) => c.code == _categoryCode)
      .firstOrNull;

  Expense _build() => Expense(
        id: _existing?.id ?? _uuid.v4(),
        categoryCode: _categoryCode ?? '',
        expenseDate: _date,
        amount: double.tryParse(_amount.text.trim()) ?? 0,
        status: _existing?.status ?? ExpenseStatus.draft,
        tourId: _tourId,
        visitId: _existing?.visitId,
        paymentMode: _paymentMode,
        merchantName: _merchant.text.trim().isEmpty ? null : _merchant.text.trim(),
        paymentRef: _paymentRef.text.trim().isEmpty ? null : _paymentRef.text.trim(),
        description: _description.text.trim().isEmpty ? null : _description.text.trim(),
        travelMode: _travelMode,
        fromPlace: _fromPlace.text.trim().isEmpty ? null : _fromPlace.text.trim(),
        toPlace: _toPlace.text.trim().isEmpty ? null : _toPlace.text.trim(),
        distanceKm: double.tryParse(_distanceKm.text.trim()),
        captureSource: _attachment?.captureSource ?? _existing?.captureSource ?? CaptureSource.manual,
        sourceApp: _attachment?.sourceApp ?? _existing?.sourceApp,
        attachmentIds: _attachmentIds,
        suggestedAmount: _mileage?.suggestedAmount,
      );

  Future<void> _checkDuplicates() async {
    try {
      final found = await ref.read(apiClientProvider).duplicateCandidates(_build());
      if (mounted) setState(() => _duplicates = found);
    } catch (_) {
      // A duplicate check that cannot run must never block saving.
    }
  }

  Future<void> _save({required bool submit}) async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _busy = true;
      _fieldErrors = {};
    });

    final expense = _build();

    try {
      await ref.read(apiClientProvider).saveExpense(expense, submit: submit);

      // Converting a shared receipt clears it from the inbox.
      if (widget.shareInboxItemId != null) {
        await ref.read(apiClientProvider).dismissShareInboxItem(widget.shareInboxItemId!);
      }

      bumpRefreshFrom(ref);
      if (!mounted) return;
      showSuccess(context, submit ? 'Expense submitted' : 'Draft saved');
      context.pop();
    } catch (e) {
      if (!mounted) return;
      if (e is OfflineException) {
        ref.read(outboxProvider.notifier).enqueue(
              entity: 'expense',
              entityId: expense.id,
              operation: _existing == null ? 'INSERT' : 'UPDATE',
              description: '${_category?.name ?? 'Expense'} '
                  '${currencyFormat.format(expense.amount)}',
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
        appBar: AppBar(title: const Text('Expense')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final categories = ref.watch(expenseCategoriesProvider);
    final tours = ref.watch(toursProvider);
    final category = _category;
    final amount = double.tryParse(_amount.text.trim()) ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: Text(_existing == null ? 'New expense' : 'Expense'),
        actions: [
          if (_existing != null && _existing!.status.isEditable)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete',
              onPressed: () async {
                final ok = await confirm(
                  context,
                  title: 'Delete this expense?',
                  message: 'It has not been sent to XInfo yet.',
                  confirmLabel: 'Delete',
                  destructive: true,
                );
                if (!ok || !context.mounted) return;
                await ref.read(apiClientProvider).deleteExpense(_existing!.id);
                bumpRefreshFrom(ref);
                if (context.mounted) context.pop();
              },
            ),
        ],
      ),
      bottomNavigationBar: _readOnly
          ? null
          : SubmitBar(
              label: 'Submit',
              secondaryLabel: 'Save draft',
              busy: _busy,
              onSubmit: () => _save(submit: true),
              onSecondary: () => _save(submit: false),
              note: 'Submitted expenses go to XInfo, which decides the final amount.',
            ),
      body: Form(
        key: _formKey,
        child: ListView(
          children: [
            if (_readOnly)
              Card(
                margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: ListTile(
                  leading: const Icon(Icons.lock_outline),
                  title: Text('Sent to XInfo — ${_existing!.xinfoStatus ?? 'pending'}'),
                  subtitle: const Text(
                      'This can no longer be edited here. Add a new entry to correct it.'),
                ),
              ),

            if (_ocr != null) _OcrCard(ocr: _ocr!, attachment: _attachment),

            FormSectionCard(
              title: 'What was it',
              children: [
                categories.when(
                  loading: () => const LinearProgressIndicator(),
                  error: (e, _) => Text('$e'),
                  data: (list) => AppDropdown<ExpenseCategory>(
                    label: 'Category',
                    required: true,
                    enabled: !_readOnly,
                    items: list,
                    value: list.where((c) => c.code == _categoryCode).firstOrNull,
                    itemLabel: (c) => c.name,
                    errorText: _fieldErrors['categoryCode'],
                    onChanged: (value) => setState(() {
                      _categoryCode = value?.code;
                      if (value?.isDistanceBased == true && _mileage != null) {
                        _distanceKm.text = _mileage!.distanceKm.toStringAsFixed(1);
                        _travelMode = _mileage!.travelMode;
                        _amount.text = _mileage!.suggestedAmount?.toStringAsFixed(0) ?? '';
                      }
                    }),
                  ),
                ),
                AppNumberField(
                  label: 'Amount',
                  controller: _amount,
                  required: true,
                  prefix: '₹ ',
                  enabled: !_readOnly,
                  errorText: _fieldErrors['amount'],
                  helper: category?.dailyCap != null
                      ? 'Daily cap ${currencyFormat.format(category!.dailyCap)}'
                      : null,
                  onChanged: (_) => _checkDuplicates(),
                ),
                AppDateField(
                  label: 'Date',
                  value: _date,
                  required: true,
                  enabled: !_readOnly,
                  lastDate: DateTime.now(),
                  errorText: _fieldErrors['expenseDate'],
                  onChanged: (date) => setState(() => _date = date ?? _date),
                ),
                AppDropdown<String>(
                  label: 'Paid by',
                  items: _paymentModes,
                  value: _paymentMode,
                  enabled: !_readOnly,
                  itemLabel: (m) => m.replaceAll('_', ' ').toLowerCase(),
                  onChanged: (value) => setState(() => _paymentMode = value),
                ),
                AppTextField(
                    label: 'Merchant', controller: _merchant, enabled: !_readOnly),
                AppTextField(
                    label: 'Payment reference',
                    controller: _paymentRef,
                    enabled: !_readOnly,
                    helper: 'UPI transaction id, bill number'),
                AppTextField(
                    label: 'Notes',
                    controller: _description,
                    maxLines: 2,
                    enabled: !_readOnly),
              ],
            ),

            if (category?.requiresRoute == true || category?.isDistanceBased == true)
              FormSectionCard(
                title: 'Journey',
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: AppTextField(
                          label: 'From',
                          controller: _fromPlace,
                          required: category?.requiresRoute == true,
                          enabled: !_readOnly,
                          errorText: _fieldErrors['fromPlace'],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: AppTextField(
                          label: 'To',
                          controller: _toPlace,
                          required: category?.requiresRoute == true,
                          enabled: !_readOnly,
                          errorText: _fieldErrors['toPlace'],
                        ),
                      ),
                    ],
                  ),
                  if (category?.isDistanceBased == true) ...[
                    AppDropdown<TravelMode>(
                      label: 'Travelled by',
                      items: const [TravelMode.car, TravelMode.twoWheeler],
                      value: _travelMode,
                      enabled: !_readOnly,
                      itemLabel: (m) => m.label,
                      onChanged: (mode) => setState(() => _travelMode = mode),
                    ),
                    AppNumberField(
                      label: 'Distance',
                      controller: _distanceKm,
                      suffix: 'km',
                      enabled: !_readOnly,
                    ),
                    if (_mileage != null) _MileageCard(mileage: _mileage!, onUse: () {
                      setState(() {
                        _distanceKm.text = _mileage!.distanceKm.toStringAsFixed(1);
                        _travelMode = _mileage!.travelMode;
                        _amount.text = _mileage!.suggestedAmount?.toStringAsFixed(0) ?? '';
                      });
                    }),
                  ],
                ],
              ),

            FormSectionCard(
              title: 'Receipt and linkage',
              subtitle: category == null
                  ? null
                  : (category.receiptRequiredFor(amount)
                      ? 'A receipt is required for this category and amount'
                      : 'No receipt needed for this one'),
              children: [
                if (_attachment != null)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(_attachment!.isPdf ? Icons.picture_as_pdf : Icons.image),
                    title: Text(_attachment!.fileName),
                    subtitle: Text(
                      '${(_attachment!.sizeBytes / 1024).round()} KB'
                      '${_attachment!.sourceApp != null ? ' · shared from another app' : ''}',
                    ),
                  )
                else if (!_readOnly)
                  OutlinedButton.icon(
                    onPressed: () => context.push('/share-inbox'),
                    icon: const Icon(Icons.attach_file),
                    label: const Text('Attach a shared receipt'),
                  ),
                tours.when(
                  loading: () => const SizedBox.shrink(),
                  error: (_, __) => const SizedBox.shrink(),
                  data: (list) => AppDropdown<Tour>(
                    label: 'Against tour',
                    required: category?.requiresTour == true,
                    enabled: !_readOnly,
                    items: list,
                    value: list.where((t) => t.id == _tourId).firstOrNull,
                    itemLabel: (t) => t.title,
                    errorText: _fieldErrors['tourId'],
                    helper: category?.requiresTour == true
                        ? 'This category must be linked to a tour'
                        : null,
                    onChanged: (tour) => setState(() => _tourId = tour?.id),
                  ),
                ),
              ],
            ),

            if (_duplicates.isNotEmpty)
              Card(
                margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                color: Theme.of(context).colorScheme.errorContainer.withOpacity(0.5),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.content_copy, size: 18),
                          const SizedBox(width: 8),
                          Text('Possible duplicate',
                              style: Theme.of(context).textTheme.titleSmall),
                        ],
                      ),
                      const SizedBox(height: 6),
                      for (final duplicate in _duplicates)
                        Text('${currencyFormat.format(duplicate.amount)} on '
                            '${dateFormat.format(duplicate.expenseDate)}'
                            '${duplicate.merchantName != null ? ' · ${duplicate.merchantName}' : ''}'),
                      const SizedBox(height: 4),
                      Text('Save anyway if this is a separate expense.',
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

class _OcrCard extends StatelessWidget {
  const _OcrCard({required this.ocr, this.attachment});

  final OcrResult ocr;
  final Attachment? attachment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final confidence = ocr.confidence ?? 0;

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.auto_awesome, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Read from your receipt', style: theme.textTheme.titleSmall),
                ),
                StatusChip(
                  label: '${(confidence * 100).round()}% sure',
                  color: confidence > 0.8 ? Colors.green : Colors.orange,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'We have filled in what we could. Check every field before saving — '
              'OCR gets amounts wrong sometimes.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _MileageCard extends StatelessWidget {
  const _MileageCard({required this.mileage, required this.onUse});

  final MileageSuggestion mileage;
  final VoidCallback onUse;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      color: theme.colorScheme.tertiaryContainer.withOpacity(0.4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('From your tracked travel', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              '${mileage.distanceKm.toStringAsFixed(1)} km by ${mileage.travelMode.label.toLowerCase()}'
              '${mileage.ratePerKm != null ? ' × ₹${mileage.ratePerKm!.toStringAsFixed(2)}/km' : ''}'
              '${mileage.suggestedAmount != null ? ' = ${currencyFormat.format(mileage.suggestedAmount)}' : ''}',
              style: theme.textTheme.bodyMedium,
            ),
            if (mileage.estimatedPortionKm > 0)
              Text(
                '${mileage.estimatedPortionKm.toStringAsFixed(1)} km of this was estimated '
                'across a gap in tracking.',
                style: theme.textTheme.bodySmall,
              ),
            const SizedBox(height: 6),
            Text(
              'Indicative only — XInfo applies the policy and decides the final amount.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: onUse, child: const Text('Use this')),
          ],
        ),
      ),
    );
  }
}
