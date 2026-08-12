import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../core/models/enums.dart';
import '../../core/models/models.dart';
import '../../core/state/providers.dart';
import '../../core/ui/common.dart';
import '../../core/ui/form_fields.dart';

/// Add a site, or capture/correct the location of an existing one.
///
/// New sites on an existing account go straight through with no approval gate — they
/// change constantly in the field, and gating them just means reps stop recording them.
class SiteFormScreen extends ConsumerStatefulWidget {
  const SiteFormScreen({super.key, required this.customerId, this.siteId});

  final String customerId;
  final String? siteId;

  @override
  ConsumerState<SiteFormScreen> createState() => _SiteFormScreenState();
}

class _SiteFormScreenState extends ConsumerState<SiteFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _uuid = const Uuid();

  final _name = TextEditingController();
  final _address = TextEditingController();
  final _city = TextEditingController();
  final _state = TextEditingController();
  final _radius = TextEditingController(text: '150');

  GeoPoint? _point;
  CustomerSite? _existing;
  Customer? _customer;
  bool _loading = true;
  bool _busy = false;

  bool get _isEdit => widget.siteId != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _city.dispose();
    _state.dispose();
    _radius.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      _customer = await ref.read(apiClientProvider).customer(widget.customerId);
      if (_isEdit) {
        _existing = _customer!.sites.where((s) => s.id == widget.siteId).firstOrNull;
        if (_existing != null) {
          _name.text = _existing!.name;
          _address.text = _existing!.addressLine1 ?? '';
          _city.text = _existing!.city ?? '';
          _state.text = _existing!.state ?? '';
          _radius.text = '${_existing!.geofenceRadiusM}';
          _point = _existing!.point;
        }
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
    final radius = int.tryParse(_radius.text.trim()) ?? 150;

    try {
      if (_isEdit && _existing != null) {
        if (_point == null) {
          showApiError(context, 'Set a location, or go back to leave it as it was');
          setState(() => _busy = false);
          return;
        }
        await api.captureSiteLocation(_existing!.id, _point!, radiusM: radius);
      } else {
        await api.addSite(CustomerSite(
          id: _uuid.v4(),
          customerId: widget.customerId,
          name: _name.text.trim(),
          point: _point,
          geoSource: _point == null ? GeoSource.none : GeoSource.fieldCaptured,
          geofenceRadiusM: radius,
          addressLine1: _address.text.trim().isEmpty ? null : _address.text.trim(),
          city: _city.text.trim().isEmpty ? null : _city.text.trim(),
          state: _state.text.trim().isEmpty ? null : _state.text.trim(),
        ));
      }

      bumpRefreshFrom(ref);
      if (!mounted) return;
      showSuccess(context, _isEdit ? 'Location updated' : 'Site added');
      context.pop();
    } catch (e) {
      if (mounted) showApiError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Site')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final home = ref.watch(sessionProvider).user?.homeLocation;

    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'Site location' : 'Add site')),
      bottomNavigationBar: SubmitBar(
        label: _isEdit ? 'Save location' : 'Add site',
        busy: _busy,
        onSubmit: _save,
        note: _isEdit
            ? 'Captured on site, this replaces whatever was geocoded from the address.'
            : null,
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          children: [
            if (_existing != null)
              FormSectionCard(
                title: _existing!.name,
                subtitle: _customer?.name,
                children: [
                  DetailRow(label: 'Current source', value: _existing!.geoSource.label),
                  if (_existing!.point != null)
                    DetailRow(label: 'Current position', value: _existing!.point.toString()),
                  if (!_existing!.geoSource.isTrusted)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'This position came from the address, not from anyone standing here. '
                        'Arrivals against it are held for review until it is confirmed.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                ],
              ),
            if (!_isEdit)
              FormSectionCard(
                title: 'Site',
                children: [
                  AppTextField(
                    label: 'Site name',
                    controller: _name,
                    required: true,
                    hint: 'e.g. Warehouse, Plant 2, Head office',
                  ),
                  AppTextField(label: 'Address', controller: _address, maxLines: 2),
                  Row(
                    children: [
                      Expanded(child: AppTextField(label: 'City', controller: _city)),
                      const SizedBox(width: 12),
                      Expanded(child: AppTextField(label: 'State', controller: _state)),
                    ],
                  ),
                ],
              ),
            FormSectionCard(
              title: 'Location',
              children: [
                LocationPickerField(
                  label: 'Coordinates',
                  value: _point,
                  required: _isEdit,
                  helper: 'Stand at the entrance for the most useful position',
                  suggestions: [
                    if (_existing?.point != null)
                      (name: 'current record', point: _existing!.point!),
                    if (home != null) (name: 'home', point: home.point),
                  ],
                  onChanged: (point) => setState(() => _point = point),
                ),
                AppNumberField(
                  label: 'Geofence radius',
                  controller: _radius,
                  suffix: 'm',
                  allowDecimal: false,
                  min: 50,
                  max: 5000,
                  helper: 'A city shop needs ~100 m; a rural yard may need 400 m or more',
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
