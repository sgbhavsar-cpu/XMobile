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

/// Propose a new customer from the field.
///
/// XInfo owns the customer master, so this creates a PROSPECT: visitable immediately —
/// the rep is standing in front of them now — and pushed to XInfo for approval. The
/// local id never changes when it is approved, so visits recorded against the prospect
/// stay attached.
class CustomerFormScreen extends ConsumerStatefulWidget {
  const CustomerFormScreen({super.key});

  @override
  ConsumerState<CustomerFormScreen> createState() => _CustomerFormScreenState();
}

class _CustomerFormScreenState extends ConsumerState<CustomerFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _uuid = const Uuid();

  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _gst = TextEditingController();

  final _siteName = TextEditingController(text: 'Main location');
  final _address = TextEditingController();
  final _city = TextEditingController();
  final _state = TextEditingController();

  final _contactName = TextEditingController();
  final _contactDesignation = TextEditingController();
  final _contactPhone = TextEditingController();

  String _accountType = 'DEALER';
  GeoPoint? _point;
  bool _busy = false;
  Map<String, String> _fieldErrors = {};

  static const _accountTypes = ['DISTRIBUTOR', 'DEALER', 'RETAILER', 'OEM', 'OTHER'];

  @override
  void dispose() {
    for (final controller in [
      _name, _phone, _email, _gst, _siteName, _address, _city, _state,
      _contactName, _contactDesignation, _contactPhone,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _busy = true;
      _fieldErrors = {};
    });

    final customerId = _uuid.v4();
    final siteId = _uuid.v4();

    final customer = Customer(
      id: customerId,
      name: _name.text.trim(),
      lifecycleStatus: AccountLifecycle.prospect,
      accountType: _accountType,
      phone: _phone.text.trim().isEmpty ? null : _phone.text.trim(),
      email: _email.text.trim().isEmpty ? null : _email.text.trim(),
      gstNumber: _gst.text.trim().isEmpty ? null : _gst.text.trim(),
      isFieldCreated: true,
      sites: [
        CustomerSite(
          id: siteId,
          customerId: customerId,
          name: _siteName.text.trim().isEmpty ? 'Main location' : _siteName.text.trim(),
          point: _point,
          geoSource: _point == null ? GeoSource.none : GeoSource.fieldCaptured,
          addressLine1: _address.text.trim().isEmpty ? null : _address.text.trim(),
          city: _city.text.trim().isEmpty ? null : _city.text.trim(),
          state: _state.text.trim().isEmpty ? null : _state.text.trim(),
          isPrimary: true,
        ),
      ],
      contacts: [
        if (_contactName.text.trim().isNotEmpty)
          CustomerContact(
            id: _uuid.v4(),
            customerId: customerId,
            fullName: _contactName.text.trim(),
            designation: _contactDesignation.text.trim().isEmpty
                ? null
                : _contactDesignation.text.trim(),
            phone: _contactPhone.text.trim().isEmpty ? null : _contactPhone.text.trim(),
            isPrimary: true,
          ),
      ],
    );

    try {
      await ref.read(apiClientProvider).proposeCustomer(customer);
      bumpRefreshFrom(ref);
      if (!mounted) return;
      showSuccess(context, 'Prospect saved — you can visit them now');
      context.pop();
    } catch (e) {
      if (!mounted) return;
      if (e is OfflineException) {
        ref.read(outboxProvider.notifier).enqueue(
              entity: 'customer',
              entityId: customerId,
              operation: 'INSERT',
              description: 'New prospect ${customer.name}',
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
    final home = ref.watch(sessionProvider).user?.homeLocation;

    return Scaffold(
      appBar: AppBar(title: const Text('New prospect')),
      bottomNavigationBar: SubmitBar(
        label: 'Save prospect',
        busy: _busy,
        onSubmit: _save,
        note: 'Sent to XInfo for approval. You can visit and report against it right away.',
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          children: [
            FormSectionCard(
              title: 'Business',
              children: [
                AppTextField(
                  label: 'Business name',
                  controller: _name,
                  required: true,
                  errorText: _fieldErrors['name'],
                ),
                AppDropdown<String>(
                  label: 'Type',
                  items: _accountTypes,
                  value: _accountType,
                  itemLabel: (t) => t[0] + t.substring(1).toLowerCase(),
                  onChanged: (value) => setState(() => _accountType = value ?? 'DEALER'),
                ),
                AppTextField(label: 'Phone', controller: _phone, keyboardType: TextInputType.phone),
                AppTextField(
                    label: 'Email', controller: _email, keyboardType: TextInputType.emailAddress),
                AppTextField(label: 'GST number', controller: _gst),
              ],
            ),
            FormSectionCard(
              title: 'Location',
              subtitle: 'Capture where you are standing — a field-captured position beats '
                  'anything geocoded from an address.',
              children: [
                AppTextField(label: 'Site name', controller: _siteName),
                AppTextField(label: 'Address', controller: _address, maxLines: 2),
                Row(
                  children: [
                    Expanded(child: AppTextField(label: 'City', controller: _city)),
                    const SizedBox(width: 12),
                    Expanded(child: AppTextField(label: 'State', controller: _state)),
                  ],
                ),
                LocationPickerField(
                  label: 'Coordinates',
                  value: _point,
                  helper: 'Without a location, arrival here cannot be detected automatically',
                  suggestions: [if (home != null) (name: 'home', point: home.point)],
                  onChanged: (point) => setState(() => _point = point),
                ),
              ],
            ),
            FormSectionCard(
              title: 'Contact',
              subtitle: 'Optional, but the reason you will get back in',
              children: [
                AppTextField(label: 'Name', controller: _contactName),
                AppTextField(label: 'Designation', controller: _contactDesignation),
                AppTextField(
                    label: 'Phone', controller: _contactPhone, keyboardType: TextInputType.phone),
              ],
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
