import 'package:flutter/material.dart';

import '../../core/models/models.dart';
import '../../core/ui/form_fields.dart';

/// Renders an admin-defined form template into widgets.
///
/// This is what lets the questions change without an app release: the template arrives
/// as data, the answers are stored as data, and the app only has to know how to draw
/// each field type. An unknown type renders as read-only text rather than crashing, so
/// an app one version behind the server degrades instead of breaking.
class DynamicFormSection extends StatelessWidget {
  const DynamicFormSection({
    super.key,
    required this.section,
    required this.answers,
    required this.onChanged,
    this.enabled = true,
  });

  final FormSection section;
  final Map<String, dynamic> answers;
  final void Function(String key, dynamic value) onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final visible = section.fields.where((f) => f.isVisible(answers)).toList();
    if (visible.isEmpty) return const SizedBox.shrink();

    return FormSectionCard(
      title: section.title,
      children: [
        for (final field in visible)
          DynamicFormField(
            field: field,
            value: answers[field.key],
            enabled: enabled,
            onChanged: (value) => onChanged(field.key, value),
          ),
      ],
    );
  }
}

class DynamicFormField extends StatelessWidget {
  const DynamicFormField({
    super.key,
    required this.field,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final FormFieldDef field;
  final dynamic value;
  final ValueChanged<dynamic> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    switch (field.type) {
      case 'text':
        return AppTextField(
          label: field.label,
          initialValue: value as String?,
          required: field.required,
          maxLength: field.maxLength,
          maxLines: (field.maxLength ?? 0) > 120 ? 3 : 1,
          helper: field.helpText,
          enabled: enabled,
          onChanged: onChanged,
        );

      case 'number':
        return AppNumberField(
          label: field.label,
          controller: TextEditingController(text: value?.toString() ?? '')
            ..selection = TextSelection.collapsed(offset: (value?.toString() ?? '').length),
          required: field.required,
          min: field.min,
          max: field.max,
          helper: field.helpText,
          enabled: enabled,
          onChanged: (text) => onChanged(num.tryParse(text)),
        );

      case 'bool':
        return AppSwitchField(
          label: field.label,
          subtitle: field.helpText,
          value: value == true,
          onChanged: enabled ? onChanged : (_) {},
        );

      case 'choice':
        return AppDropdown<String>(
          label: field.label,
          items: field.options,
          value: value as String?,
          itemLabel: (option) => option,
          required: field.required,
          helper: field.helpText,
          enabled: enabled,
          onChanged: onChanged,
        );

      case 'multichoice':
        final selected = (value as List?)?.cast<String>() ?? const <String>[];
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(field.required ? '${field.label} *' : field.label,
                  style: Theme.of(context).textTheme.bodyMedium),
              if (field.helpText != null)
                Text(field.helpText!, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                children: [
                  for (final option in field.options)
                    FilterChip(
                      label: Text(option),
                      selected: selected.contains(option),
                      onSelected: enabled
                          ? (isSelected) {
                              final updated = [...selected];
                              isSelected ? updated.add(option) : updated.remove(option);
                              onChanged(updated);
                            }
                          : null,
                    ),
                ],
              ),
            ],
          ),
        );

      case 'date':
        return AppDateField(
          label: field.label,
          value: value == null ? null : DateTime.tryParse(value as String),
          required: field.required,
          helper: field.helpText,
          enabled: enabled,
          onChanged: (date) => onChanged(date?.toIso8601String()),
        );

      case 'rating':
        return AppRatingField(
          label: field.label,
          helper: field.helpText,
          value: value is num ? value.toInt() : null,
          onChanged: enabled ? onChanged : (_) {},
        );

      case 'photo':
        // Photos are optional and rep-chosen; the picker lands with the camera plugin.
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: OutlinedButton.icon(
            onPressed: enabled
                ? () => ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Photo capture arrives with the camera plugin'),
                        behavior: SnackBarBehavior.floating,
                      ),
                    )
                : null,
            icon: const Icon(Icons.photo_camera_outlined),
            label: Text(field.label),
          ),
        );

      default:
        // Forward compatibility: a field type this build does not know about is shown,
        // not hidden and not fatal.
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: field.label,
              helperText: 'This question needs a newer version of the app',
              border: const OutlineInputBorder(),
            ),
            child: Text(value?.toString() ?? '—'),
          ),
        );
    }
  }
}

/// Validates answers against the template. Runs locally so an offline rep gets the same
/// feedback; the server re-validates against the same pinned version.
Map<String, String> validateDynamicAnswers(
  List<FormSection> sections,
  Map<String, dynamic> answers,
) {
  final errors = <String, String>{};

  for (final section in sections) {
    for (final field in section.fields) {
      if (!field.isVisible(answers)) continue;

      final value = answers[field.key];
      final isEmpty = value == null ||
          (value is String && value.trim().isEmpty) ||
          (value is List && value.isEmpty);

      if (field.required && isEmpty) {
        errors[field.key] = '${field.label} is required';
        continue;
      }
      if (isEmpty) continue;

      if (field.type == 'number' && value is num) {
        if (field.min != null && value < field.min!) {
          errors[field.key] = '${field.label} must be at least ${field.min}';
        }
        if (field.max != null && value > field.max!) {
          errors[field.key] = '${field.label} must be at most ${field.max}';
        }
      }
      if (field.type == 'text' && value is String && field.maxLength != null) {
        if (value.length > field.maxLength!) {
          errors[field.key] = '${field.label} is too long';
        }
      }
    }
  }

  return errors;
}
