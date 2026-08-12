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

/// Check in to a customer site.
///
/// Location is entered by hand here (pick "I'm at the site", or type coordinates). That
/// is how it works until the GPS plugin is wired — and the manual path stays afterwards,
/// because a rep whose GPS will not fix still has to be able to record the visit.
///
/// Checking in from outside the site's fence is allowed but must be explained. Refusing
/// it would strand reps whose recorded customer location is simply wrong.
class CheckInScreen extends ConsumerStatefulWidget {
  const CheckInScreen({super.key, this.planId, this.customerId, this.siteId});

  final String? planId;
  final String? customerId;
  final String? siteId;

  @override
  ConsumerState<CheckInScreen> createState() => _CheckInScreenState();
}

class _CheckInScreenState extends ConsumerState<CheckInScreen> {
  final _formKey = GlobalKey<FormState>();
  final _uuid = const Uuid();
  final _outOfFenceRemark = TextEditingController();

  VisitPlan? _plan;
  Customer? _customer;
  CustomerSite? _site;
  CustomerContact? _contact;
  VisitType? _visitType;
  GeoPoint? _point;
  DateTime _checkInAt = DateTime.now();
  String? _outOfFenceReason;

  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _outOfFenceRemark.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final api = ref.read(apiClientProvider);
    try {
      if (widget.planId != null) {
        final plans = await api.visitPlans();
        _plan = plans.where((p) => p.id == widget.planId).firstOrNull;
      }

      final customerId = _plan?.customerId ?? widget.customerId;
      if (customerId != null) {
        _customer = await api.customer(customerId);
        final siteId = _plan?.siteId ?? widget.siteId;
        _site = _customer!.sites.where((s) => s.id == siteId).firstOrNull ??
            _customer!.primarySite;
        _contact = _customer!.contacts.where((c) => c.id == _plan?.contactId).firstOrNull;
      }

      final types = await api.visitTypes();
      _visitType = types.where((t) => t.code == _plan?.visitTypeCode).firstOrNull ??
          types.firstOrNull;

      // Pre-fill with the site's own position: the common case is a rep standing there.
      _point = _site?.point;
    } catch (e) {
      if (mounted) showApiError(context, e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  int? get _distanceM {
    if (_point == null || _site?.point == null) return null;
    return _point!.distanceTo(_site!.point!).round();
  }

  bool get _isOutOfFence {
    final distance = _distanceM;
    if (distance == null || _site == null) return false;
    return distance > _site!.geofenceRadiusM;
  }

  Future<void> _checkIn() async {
    if (!_formKey.currentState!.validate()) return;
    if (_customer == null || _site == null || _visitType == null) {
      showApiError(context, 'Choose a customer and site first');
      return;
    }

    setState(() => _busy = true);

    final visit = Visit(
      id: _uuid.v4(),
      visitPlanId: _plan?.id,
      tourId: _plan?.tourId,
      customerId: _customer!.id,
      customerName: _customer!.name,
      siteId: _site!.id,
      siteName: _site!.name,
      contactId: _contact?.id,
      visitTypeCode: _visitType!.code,
      checkInAt: _checkInAt,
      status: VisitStatus.checkedIn,
      checkInPoint: _point,
      checkInDistanceM: _distanceM,
      checkInMethod: CheckInMethod.manual,
      isOutOfGeofence: _isOutOfFence,
      outOfFenceReasonCode: _isOutOfFence ? _outOfFenceReason : null,
      outOfFenceRemark: _isOutOfFence ? _outOfFenceRemark.text.trim() : null,
      isUnplanned: _plan == null,
    );

    try {
      await ref.read(apiClientProvider).checkIn(visit);
      bumpRefreshFrom(ref);
      if (!mounted) return;
      showSuccess(context, 'Checked in at ${_customer!.name}');
      context.pushReplacement('/visits/${visit.id}');
    } catch (e) {
      if (!mounted) return;
      if (e is OfflineException) {
        // Offline is not a failure: queue it and let the rep get on with the call.
        ref.read(outboxProvider.notifier).enqueue(
              entity: 'visit',
              entityId: visit.id,
              operation: 'INSERT',
              description: 'Check-in at ${_customer!.name}',
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

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Check in')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final customers = ref.watch(customersProvider(null));
    final visitTypes = ref.watch(visitTypesProvider);
    final outOfFenceReasons = ref.watch(reasonCodesProvider('OUT_OF_GEOFENCE'));
    final home = ref.watch(sessionProvider).user?.homeLocation;

    return Scaffold(
      appBar: AppBar(title: Text(_plan == null ? 'Unplanned visit' : 'Check in')),
      bottomNavigationBar: SubmitBar(
        label: 'Check in',
        busy: _busy,
        onSubmit: _checkIn,
        note: _isOutOfFence
            ? 'You are $_distanceM m from the recorded location — this will be flagged for your manager.'
            : null,
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          children: [
            if (_plan != null)
              FormSectionCard(
                title: 'Planned visit',
                children: [
                  DetailRow(label: 'Customer', value: _plan!.customerName, emphasise: true),
                  DetailRow(label: 'Site', value: _plan!.siteName),
                  if (_plan!.plannedStartTime != null)
                    DetailRow(label: 'Planned for', value: _plan!.plannedStartTime!),
                  if (_plan!.objective != null)
                    DetailRow(label: 'Objective', value: _plan!.objective!),
                ],
              )
            else
              FormSectionCard(
                title: 'Who are you visiting?',
                subtitle: 'Not on the plan — this will be recorded as an unplanned visit.',
                children: [
                  customers.when(
                    loading: () => const LinearProgressIndicator(),
                    error: (e, _) => Text('$e'),
                    data: (list) => Column(
                      children: [
                        AppDropdown<Customer>(
                          label: 'Customer',
                          required: true,
                          items: list.where((c) => c.isVisitable).toList(),
                          value: _customer,
                          itemLabel: (c) => c.name,
                          onChanged: (customer) => setState(() {
                            _customer = customer;
                            _site = customer?.primarySite;
                            _point = _site?.point;
                            _contact = null;
                          }),
                        ),
                        if (_customer != null)
                          AppDropdown<CustomerSite>(
                            label: 'Site',
                            required: true,
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
            FormSectionCard(
              title: 'Where and when',
              subtitle: 'Location is entered manually in this build.',
              children: [
                AppDateTimeField(
                  label: 'Check-in time',
                  value: _checkInAt,
                  required: true,
                  helper: 'Defaults to now — change it if you are recording after the fact',
                  onChanged: (value) => setState(() => _checkInAt = value),
                ),
                LocationPickerField(
                  label: 'Your location',
                  value: _point,
                  helper: _distanceM == null
                      ? 'No location on file for this site — distance cannot be checked'
                      : '$_distanceM m from the recorded site location '
                          '(fence is ${_site?.geofenceRadiusM ?? 0} m)',
                  suggestions: [
                    if (_site?.point != null) (name: _site!.name, point: _site!.point!),
                    if (home != null) (name: 'home', point: home.point),
                  ],
                  onChanged: (point) => setState(() => _point = point),
                ),
                if (_isOutOfFence) ...[
                  const Divider(height: 24),
                  Text(
                    'You are outside the recorded site location',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(color: Theme.of(context).colorScheme.error),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'That is fine — the location on file may be wrong. Tell us why so it is '
                    'not read as a false check-in.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  outOfFenceReasons.when(
                    loading: () => const LinearProgressIndicator(),
                    error: (e, _) => Text('$e'),
                    data: (reasons) => AppDropdown<ReasonCode>(
                      label: 'Reason',
                      required: true,
                      items: reasons,
                      value: reasons.where((r) => r.code == _outOfFenceReason).firstOrNull,
                      itemLabel: (r) => r.name,
                      onChanged: (reason) => setState(() => _outOfFenceReason = reason?.code),
                    ),
                  ),
                  AppTextField(
                    label: 'Remark',
                    controller: _outOfFenceRemark,
                    maxLines: 2,
                  ),
                  if (_site != null && _site!.geoSource != GeoSource.fieldCaptured)
                    OutlinedButton.icon(
                      onPressed: () => context.push(
                          '/customers/${_customer!.id}/sites/${_site!.id}/location'),
                      icon: const Icon(Icons.edit_location_alt, size: 18),
                      label: const Text('Fix the site location instead'),
                    ),
                ],
              ],
            ),
            FormSectionCard(
              title: 'Details',
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
                if (_customer != null && _customer!.contacts.isNotEmpty)
                  AppDropdown<CustomerContact>(
                    label: 'Meeting',
                    items: _customer!.contacts,
                    value: _contact,
                    itemLabel: (c) => c.fullName,
                    onChanged: (contact) => setState(() => _contact = contact),
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
