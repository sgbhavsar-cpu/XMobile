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

/// Record a journey event by hand, or correct one the system got wrong.
///
/// This screen is why reps keep trusting automatic tracking: when detection misses a
/// departure or puts an arrival twenty minutes late, they can fix it themselves. The
/// original detection is kept either way — a correction that erases what was detected
/// leaves nothing to audit and nothing to learn from.
class ManualEventScreen extends ConsumerStatefulWidget {
  const ManualEventScreen({super.key, this.eventId});

  final String? eventId;

  @override
  ConsumerState<ManualEventScreen> createState() => _ManualEventScreenState();
}

class _ManualEventScreenState extends ConsumerState<ManualEventScreen> {
  final _formKey = GlobalKey<FormState>();
  final _uuid = const Uuid();
  final _reason = TextEditingController();

  JourneyEventType _type = JourneyEventType.departHome;
  DateTime _occurredAt = DateTime.now();
  Customer? _customer;
  CustomerSite? _site;
  GeoPoint? _point;
  JourneyEvent? _existing;

  bool _loading = true;
  bool _busy = false;

  bool get _isCorrection => widget.eventId != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!_isCorrection) {
      setState(() => _loading = false);
      return;
    }

    try {
      final now = DateTime.now();
      final events = await ref.read(apiClientProvider).journeyEvents(
            from: now.subtract(const Duration(days: 90)),
            to: now.add(const Duration(days: 1)),
          );
      _existing = events.where((e) => e.id == widget.eventId).firstOrNull;
      if (_existing != null) {
        _type = _existing!.type;
        _occurredAt = _existing!.occurredAt;
      }
    } catch (e) {
      if (mounted) showApiError(context, e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);

    final api = ref.read(apiClientProvider);

    try {
      if (_isCorrection) {
        await api.correctJourneyEvent(widget.eventId!, _occurredAt, _reason.text.trim());
      } else {
        await api.addManualJourneyEvent(JourneyEvent(
          id: _uuid.v4(),
          type: _type,
          occurredAt: _occurredAt,
          status: EventStatus.confirmed,
          point: _point ?? _site?.point,
          placeName: _site?.name ?? (_type == JourneyEventType.departHome ||
                  _type == JourneyEventType.arriveHome
              ? 'Home'
              : null),
          customerId: _customer?.id,
          method: 'MANUAL',
          isManual: true,
        ));
      }

      bumpRefreshFrom(ref);
      if (!mounted) return;
      showSuccess(context, _isCorrection ? 'Time corrected' : 'Event added');
      context.pop();
    } catch (e) {
      if (!mounted) return;
      if (e is OfflineException) {
        ref.read(outboxProvider.notifier).enqueue(
              entity: 'journey_event',
              entityId: widget.eventId ?? _uuid.v4(),
              operation: _isCorrection ? 'UPDATE' : 'INSERT',
              description: '${_isCorrection ? 'Correction' : 'Manual event'}: ${_type.label}',
            );
        ref.read(connectivityProvider.notifier).state = false;
        showSuccess(context, 'Saved on this device — will sync when you are online');
        context.pop();
        return;
      }
      showApiError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool get _needsCustomer =>
      _type == JourneyEventType.arriveCustomer || _type == JourneyEventType.departCustomer;

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Journey event')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final customers = ref.watch(customersProvider(null));
    final home = ref.watch(sessionProvider).user?.homeLocation;

    return Scaffold(
      appBar: AppBar(title: Text(_isCorrection ? 'Correct the time' : 'Add what happened')),
      bottomNavigationBar: SubmitBar(
        label: _isCorrection ? 'Save correction' : 'Add event',
        busy: _busy,
        onSubmit: _save,
        note: _isCorrection
            ? 'What was detected is kept alongside your correction.'
            : 'Anything you enter here is treated as certain and is never overwritten.',
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          children: [
            if (_existing != null)
              FormSectionCard(
                title: 'What the system recorded',
                children: [
                  DetailRow(label: 'Event', value: _existing!.type.label),
                  DetailRow(
                    label: 'Detected time',
                    value: dateTimeFormat.format(_existing!.originalOccurredAt ??
                        _existing!.occurredAt),
                  ),
                  DetailRow(
                    label: 'How',
                    value: '${_existing!.method ?? 'unknown'} · '
                        '${(_existing!.confidence * 100).round()}% confident',
                  ),
                  if (_existing!.placeName != null)
                    DetailRow(label: 'Where', value: _existing!.placeName!),
                ],
              ),
            FormSectionCard(
              title: _isCorrection ? 'The correct time' : 'What happened',
              children: [
                if (!_isCorrection)
                  AppDropdown<JourneyEventType>(
                    label: 'Event',
                    required: true,
                    items: JourneyEventType.manualEntryTypes,
                    value: _type,
                    itemLabel: (t) => t.label,
                    onChanged: (type) => setState(() => _type = type ?? _type),
                  ),
                AppDateTimeField(
                  label: 'When',
                  value: _occurredAt,
                  required: true,
                  onChanged: (value) => setState(() => _occurredAt = value),
                ),
                if (_isCorrection)
                  AppTextField(
                    label: 'Why are you changing it',
                    controller: _reason,
                    required: true,
                    maxLines: 2,
                    hint: 'e.g. phone was off, I actually left at 6:15',
                  ),
              ],
            ),
            if (!_isCorrection && _needsCustomer)
              FormSectionCard(
                title: 'Which customer',
                children: [
                  customers.when(
                    loading: () => const LinearProgressIndicator(),
                    error: (e, _) => Text('$e'),
                    data: (list) => Column(
                      children: [
                        AppDropdown<Customer>(
                          label: 'Customer',
                          required: true,
                          items: list,
                          value: _customer,
                          itemLabel: (c) => c.name,
                          onChanged: (customer) => setState(() {
                            _customer = customer;
                            _site = customer?.primarySite;
                            _point = _site?.point;
                          }),
                        ),
                        if (_customer != null)
                          AppDropdown<CustomerSite>(
                            label: 'Site',
                            items: _customer!.sites,
                            value: _site,
                            itemLabel: (s) => s.name,
                            onChanged: (site) => setState(() {
                              _site = site;
                              _point = site?.point;
                            }),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            if (!_isCorrection)
              FormSectionCard(
                title: 'Where',
                subtitle: 'Optional — helps the map, not required',
                children: [
                  LocationPickerField(
                    label: 'Location',
                    value: _point,
                    suggestions: [
                      if (_site?.point != null) (name: _site!.name, point: _site!.point!),
                      if (home != null) (name: 'home', point: home.point),
                    ],
                    onChanged: (point) => setState(() => _point = point),
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
