import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../models/models.dart';

final dateFormat = DateFormat('d MMM yyyy');
final dateTimeFormat = DateFormat('d MMM, h:mm a');
final timeFormat = DateFormat('h:mm a');
final currencyFormat = NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 0);

/// A titled group of fields. Keeps long forms readable without a card per field.
class FormSectionCard extends StatelessWidget {
  const FormSectionCard({
    super.key,
    required this.title,
    required this.children,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: theme.textTheme.titleMedium),
                      if (subtitle != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(subtitle!,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                        ),
                    ],
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}

class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    required this.label,
    this.controller,
    this.initialValue,
    this.hint,
    this.helper,
    this.errorText,
    this.maxLines = 1,
    this.maxLength,
    this.keyboardType,
    this.required = false,
    this.enabled = true,
    this.onChanged,
    this.validator,
    this.prefix,
  });

  final String label;
  final TextEditingController? controller;
  final String? initialValue;
  final String? hint;
  final String? helper;
  final String? errorText;
  final int maxLines;
  final int? maxLength;
  final TextInputType? keyboardType;
  final bool required;
  final bool enabled;
  final ValueChanged<String>? onChanged;
  final String? Function(String?)? validator;
  final String? prefix;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextFormField(
          controller: controller,
          initialValue: controller == null ? initialValue : null,
          enabled: enabled,
          maxLines: maxLines,
          maxLength: maxLength,
          keyboardType: keyboardType,
          onChanged: onChanged,
          validator: validator ??
              (required
                  ? (value) => (value == null || value.trim().isEmpty) ? '$label is required' : null
                  : null),
          decoration: InputDecoration(
            labelText: required ? '$label *' : label,
            hintText: hint,
            helperText: helper,
            errorText: errorText,
            prefixText: prefix,
            border: const OutlineInputBorder(),
          ),
        ),
      );
}

class AppNumberField extends StatelessWidget {
  const AppNumberField({
    super.key,
    required this.label,
    this.controller,
    this.helper,
    this.errorText,
    this.required = false,
    this.allowDecimal = true,
    this.min,
    this.max,
    this.suffix,
    this.prefix,
    this.onChanged,
    this.enabled = true,
  });

  final String label;
  final TextEditingController? controller;
  final String? helper;
  final String? errorText;
  final bool required;
  final bool allowDecimal;
  final num? min;
  final num? max;
  final String? suffix;
  final String? prefix;
  final ValueChanged<String>? onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextFormField(
          controller: controller,
          enabled: enabled,
          keyboardType: TextInputType.numberWithOptions(decimal: allowDecimal),
          inputFormatters: [
            FilteringTextInputFormatter.allow(
                allowDecimal ? RegExp(r'^\d*\.?\d{0,2}') : RegExp(r'^\d*')),
          ],
          onChanged: onChanged,
          validator: (value) {
            final text = value?.trim() ?? '';
            if (text.isEmpty) return required ? '$label is required' : null;
            final parsed = num.tryParse(text);
            if (parsed == null) return 'Enter a number';
            if (min != null && parsed < min!) return 'Must be at least $min';
            if (max != null && parsed > max!) return 'Must be at most $max';
            return null;
          },
          decoration: InputDecoration(
            labelText: required ? '$label *' : label,
            helperText: helper,
            errorText: errorText,
            suffixText: suffix,
            prefixText: prefix,
            border: const OutlineInputBorder(),
          ),
        ),
      );
}

class AppDropdown<T> extends StatelessWidget {
  const AppDropdown({
    super.key,
    required this.label,
    required this.items,
    required this.itemLabel,
    required this.onChanged,
    this.value,
    this.required = false,
    this.helper,
    this.errorText,
    this.enabled = true,
  });

  final String label;
  final List<T> items;
  final String Function(T) itemLabel;
  final ValueChanged<T?> onChanged;
  final T? value;
  final bool required;
  final String? helper;
  final String? errorText;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: DropdownButtonFormField<T>(
          value: items.contains(value) ? value : null,
          isExpanded: true,
          onChanged: enabled ? onChanged : null,
          validator: required ? (v) => v == null ? '$label is required' : null : null,
          decoration: InputDecoration(
            labelText: required ? '$label *' : label,
            helperText: helper,
            errorText: errorText,
            border: const OutlineInputBorder(),
          ),
          items: items
              .map((item) => DropdownMenuItem<T>(
                    value: item,
                    child: Text(itemLabel(item), overflow: TextOverflow.ellipsis),
                  ))
              .toList(),
        ),
      );
}

class AppDateField extends StatelessWidget {
  const AppDateField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.firstDate,
    this.lastDate,
    this.required = false,
    this.helper,
    this.errorText,
    this.enabled = true,
  });

  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;
  final DateTime? firstDate;
  final DateTime? lastDate;
  final bool required;
  final String? helper;
  final String? errorText;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: InkWell(
          onTap: enabled
              ? () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: value ?? DateTime.now(),
                    firstDate: firstDate ?? DateTime.now().subtract(const Duration(days: 365)),
                    lastDate: lastDate ?? DateTime.now().add(const Duration(days: 365)),
                  );
                  if (picked != null) onChanged(picked);
                }
              : null,
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: required ? '$label *' : label,
              helperText: helper,
              errorText: errorText,
              border: const OutlineInputBorder(),
              suffixIcon: const Icon(Icons.calendar_today, size: 18),
              enabled: enabled,
            ),
            child: Text(
              value == null ? 'Not set' : dateFormat.format(value!),
              style: value == null
                  ? TextStyle(color: Theme.of(context).hintColor)
                  : null,
            ),
          ),
        ),
      );
}

class AppTimeField extends StatelessWidget {
  const AppTimeField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.required = false,
    this.helper,
    this.enabled = true,
  });

  final String label;
  final TimeOfDay? value;
  final ValueChanged<TimeOfDay?> onChanged;
  final bool required;
  final String? helper;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: InkWell(
          onTap: enabled
              ? () async {
                  final picked = await showTimePicker(
                    context: context,
                    initialTime: value ?? TimeOfDay.now(),
                  );
                  if (picked != null) onChanged(picked);
                }
              : null,
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: required ? '$label *' : label,
              helperText: helper,
              border: const OutlineInputBorder(),
              suffixIcon: const Icon(Icons.schedule, size: 18),
              enabled: enabled,
            ),
            child: Text(
              value == null ? 'Not set' : value!.format(context),
              style: value == null ? TextStyle(color: Theme.of(context).hintColor) : null,
            ),
          ),
        ),
      );
}

class AppDateTimeField extends StatelessWidget {
  const AppDateTimeField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.helper,
    this.required = false,
  });

  final String label;
  final DateTime? value;
  final ValueChanged<DateTime> onChanged;
  final String? helper;
  final bool required;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: InkWell(
          onTap: () async {
            final date = await showDatePicker(
              context: context,
              initialDate: value ?? DateTime.now(),
              firstDate: DateTime.now().subtract(const Duration(days: 30)),
              lastDate: DateTime.now().add(const Duration(days: 7)),
            );
            if (date == null) return;
            if (!context.mounted) return;

            final time = await showTimePicker(
              context: context,
              initialTime: TimeOfDay.fromDateTime(value ?? DateTime.now()),
            );
            if (time == null) return;

            onChanged(DateTime(date.year, date.month, date.day, time.hour, time.minute));
          },
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: required ? '$label *' : label,
              helperText: helper,
              border: const OutlineInputBorder(),
              suffixIcon: const Icon(Icons.event, size: 18),
            ),
            child: Text(value == null ? 'Not set' : dateTimeFormat.format(value!)),
          ),
        ),
      );
}

class AppSwitchField extends StatelessWidget {
  const AppSwitchField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  final String? subtitle;

  @override
  Widget build(BuildContext context) => SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        subtitle: subtitle == null ? null : Text(subtitle!),
        value: value,
        onChanged: onChanged,
      );
}

class AppRatingField extends StatelessWidget {
  const AppRatingField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.helper,
    this.max = 5,
  });

  final String label;
  final int? value;
  final ValueChanged<int> onChanged;
  final String? helper;
  final int max;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.bodyMedium),
            if (helper != null)
              Text(helper!, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            Row(
              children: List.generate(
                max,
                (index) => IconButton(
                  onPressed: () => onChanged(index + 1),
                  icon: Icon(
                    (value ?? 0) > index ? Icons.star : Icons.star_border,
                    color: (value ?? 0) > index ? Colors.amber.shade700 : null,
                  ),
                  tooltip: '${index + 1}',
                ),
              ),
            ),
          ],
        ),
      );
}

/// Manual coordinate entry, with shortcuts for the places the rep is likely to be.
///
/// Until the location plugin is wired this *is* how a position gets into the app —
/// and it stays afterwards, because a rep whose GPS is refusing to fix still has to be
/// able to record where they were.
class LocationPickerField extends StatelessWidget {
  const LocationPickerField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.suggestions = const [],
    this.helper,
    this.required = false,
  });

  final String label;
  final GeoPoint? value;
  final ValueChanged<GeoPoint?> onChanged;

  /// Named places offered as one-tap options, e.g. the site being visited or home.
  final List<({String name, GeoPoint point})> suggestions;

  final String? helper;
  final bool required;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InputDecorator(
            decoration: InputDecoration(
              labelText: required ? '$label *' : label,
              helperText: helper,
              border: const OutlineInputBorder(),
              suffixIcon: const Icon(Icons.my_location, size: 18),
            ),
            child: Text(value?.toString() ?? 'Not set',
                style: value == null ? TextStyle(color: theme.hintColor) : null),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final suggestion in suggestions)
                ActionChip(
                  avatar: const Icon(Icons.place, size: 16),
                  label: Text('At ${suggestion.name}'),
                  onPressed: () => onChanged(suggestion.point),
                ),
              ActionChip(
                avatar: const Icon(Icons.edit_location_alt, size: 16),
                label: const Text('Enter manually'),
                onPressed: () async {
                  final point = await showDialog<GeoPoint>(
                    context: context,
                    builder: (_) => _ManualCoordinateDialog(initial: value),
                  );
                  if (point != null) onChanged(point);
                },
              ),
              if (value != null)
                ActionChip(
                  avatar: const Icon(Icons.clear, size: 16),
                  label: const Text('Clear'),
                  onPressed: () => onChanged(null),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ManualCoordinateDialog extends StatefulWidget {
  const _ManualCoordinateDialog({this.initial});

  final GeoPoint? initial;

  @override
  State<_ManualCoordinateDialog> createState() => _ManualCoordinateDialogState();
}

class _ManualCoordinateDialogState extends State<_ManualCoordinateDialog> {
  late final _lat = TextEditingController(text: widget.initial?.lat.toStringAsFixed(5) ?? '');
  late final _lon = TextEditingController(text: widget.initial?.lon.toStringAsFixed(5) ?? '');
  String? _error;

  @override
  void dispose() {
    _lat.dispose();
    _lon.dispose();
    super.dispose();
  }

  void _submit() {
    final lat = double.tryParse(_lat.text.trim());
    final lon = double.tryParse(_lon.text.trim());

    if (lat == null || lon == null) {
      setState(() => _error = 'Enter both latitude and longitude');
      return;
    }
    if (lat < -90 || lat > 90) {
      setState(() => _error = 'Latitude must be between -90 and 90');
      return;
    }
    if (lon < -180 || lon > 180) {
      setState(() => _error = 'Longitude must be between -180 and 180');
      return;
    }
    Navigator.of(context).pop(GeoPoint(lat, lon));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Enter coordinates'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _lat,
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
              decoration: const InputDecoration(labelText: 'Latitude', hintText: '18.52043'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _lon,
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
              decoration: const InputDecoration(labelText: 'Longitude', hintText: '73.85674'),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(onPressed: _submit, child: const Text('Use this')),
        ],
      );
}
