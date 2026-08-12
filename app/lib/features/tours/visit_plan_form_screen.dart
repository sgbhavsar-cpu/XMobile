import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../core/models/enums.dart';
import '../../core/models/models.dart';
import '../../core/state/providers.dart';
import '../../core/ui/common.dart';
import '../../core/ui/form_fields.dart';

/// Plan a visit: pick the customer, the specific site, when, and what for.
///
/// The site matters, not just the account — an account can have several physical
/// locations and tracking against the wrong one is meaningless.
class VisitPlanFormScreen extends ConsumerStatefulWidget {
  const VisitPlanFormScreen({super.key, this.tourId, this.date});

  final String? tourId;
  final DateTime? date;

  @override
  ConsumerState<VisitPlanFormScreen> createState() => _VisitPlanFormScreenState();
}

class _VisitPlanFormScreenState extends ConsumerState<VisitPlanFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _uuid = const Uuid();
  final _objective = TextEditingController();

  Customer? _customer;
  CustomerSite? _site;
  CustomerContact? _contact;
  VisitType? _visitType;
  late DateTime _date;
  TimeOfDay? _time;
  int _seq = 1;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _date = widget.date ?? DateTime.now();
  }

  @override
  void dispose() {
    _objective.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_customer == null || _site == null || _visitType == null) return;

    setState(() => _busy = true);

    final plan = VisitPlan(
      id: _uuid.v4(),
      customerId: _customer!.id,
      customerName: _customer!.name,
      siteId: _site!.id,
      siteName: _site!.name,
      visitTypeCode: _visitType!.code,
      plannedDate: DateTime(_date.year, _date.month, _date.day),
      status: PlanStatus.planned,
      tourId: widget.tourId,
      tourDayId: await _resolveTourDayId(),
      contactId: _contact?.id,
      plannedStartTime: _time == null
          ? null
          : '${_time!.hour.toString().padLeft(2, '0')}:${_time!.minute.toString().padLeft(2, '0')}',
      seq: _seq,
      objective: _objective.text.trim().isEmpty ? null : _objective.text.trim(),
    );

    try {
      await ref.read(apiClientProvider).saveVisitPlan(plan);
      bumpRefreshFrom(ref);
      if (!mounted) return;
      showSuccess(context, 'Visit planned');
      context.pop();
    } catch (e) {
      if (mounted) showApiError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Attaches the plan to the tour day matching its date, so it appears on the right day.
  Future<String?> _resolveTourDayId() async {
    if (widget.tourId == null) return null;
    try {
      final tour = await ref.read(apiClientProvider).tour(widget.tourId!);
      for (final day in tour.days) {
        if (day.planDate.year == _date.year &&
            day.planDate.month == _date.month &&
            day.planDate.day == _date.day) {
          return day.id;
        }
      }
    } catch (_) {
      // The plan is still valid without a day link; it shows under the date instead.
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final customers = ref.watch(customersProvider(null));
    final visitTypes = ref.watch(visitTypesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Plan a visit')),
      bottomNavigationBar: SubmitBar(
        label: 'Add to plan',
        busy: _busy,
        onSubmit: _save,
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          children: [
            FormSectionCard(
              title: 'Who',
              children: [
                customers.when(
                  loading: () => const LinearProgressIndicator(),
                  error: (e, _) => Text('Could not load customers: $e'),
                  data: (list) => Column(
                    children: [
                      AppDropdown<Customer>(
                        label: 'Customer',
                        required: true,
                        items: list.where((c) => c.isVisitable).toList(),
                        value: _customer,
                        itemLabel: (c) => c.lifecycleStatus == AccountLifecycle.active
                            ? c.name
                            : '${c.name} (${c.lifecycleStatus.label})',
                        onChanged: (customer) => setState(() {
                          _customer = customer;
                          _site = customer?.primarySite;
                          _contact = null;
                        }),
                      ),
                      if (_customer != null)
                        AppDropdown<CustomerSite>(
                          label: 'Site',
                          required: true,
                          helper: 'Which physical location — tracking is against the site',
                          items: _customer!.sites,
                          value: _site,
                          itemLabel: (s) =>
                              '${s.name}${s.hasLocation ? '' : ' (no location on file)'}',
                          onChanged: (site) => setState(() => _site = site),
                        ),
                      if (_customer != null && _customer!.contacts.isNotEmpty)
                        AppDropdown<CustomerContact>(
                          label: 'Contact to meet',
                          items: _customer!.contacts,
                          value: _contact,
                          itemLabel: (c) => '${c.fullName}${c.designation != null ? ' — ${c.designation}' : ''}',
                          onChanged: (contact) => setState(() => _contact = contact),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            FormSectionCard(
              title: 'When',
              children: [
                AppDateField(
                  label: 'Date',
                  value: _date,
                  required: true,
                  onChanged: (date) => setState(() => _date = date ?? _date),
                ),
                AppTimeField(
                  label: 'Planned time',
                  value: _time,
                  helper: 'Optional — helps order the day',
                  onChanged: (time) => setState(() => _time = time),
                ),
                AppNumberField(
                  label: 'Order in the day',
                  allowDecimal: false,
                  min: 1,
                  controller: TextEditingController(text: '$_seq'),
                  onChanged: (value) => _seq = int.tryParse(value) ?? 1,
                ),
              ],
            ),
            FormSectionCard(
              title: 'What for',
              children: [
                visitTypes.when(
                  loading: () => const LinearProgressIndicator(),
                  error: (e, _) => Text('$e'),
                  data: (types) => AppDropdown<VisitType>(
                    label: 'Visit type',
                    required: true,
                    items: types,
                    value: _visitType,
                    itemLabel: (t) => t.name,
                    onChanged: (type) => setState(() => _visitType = type),
                  ),
                ),
                AppTextField(
                  label: 'Objective',
                  controller: _objective,
                  maxLines: 3,
                  hint: 'What you want out of this call',
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
