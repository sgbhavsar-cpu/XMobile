import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../models/enums.dart';
import '../state/providers.dart';

/// A small coloured label. Used for statuses everywhere, so they read the same way
/// on every screen.
class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.label, this.color, this.icon, this.dense = true});

  final String label;
  final Color? color;
  final IconData? icon;
  final bool dense;

  factory StatusChip.forTour(TourStatus status) => StatusChip(
        label: status.label,
        color: switch (status) {
          TourStatus.inProgress => Colors.blue,
          TourStatus.completed => Colors.green,
          TourStatus.cancelled || TourStatus.abandoned => Colors.grey,
          _ => null,
        },
      );

  factory StatusChip.forPlan(PlanStatus status) => StatusChip(
        label: status.label,
        color: switch (status) {
          PlanStatus.completed => Colors.green,
          PlanStatus.skipped => Colors.orange,
          PlanStatus.cancelled => Colors.grey,
          _ => null,
        },
      );

  factory StatusChip.forExpense(ExpenseStatus status) => StatusChip(
        label: status.label,
        color: switch (status) {
          ExpenseStatus.pushed || ExpenseStatus.acknowledged => Colors.green,
          ExpenseStatus.pushFailed => Colors.red,
          ExpenseStatus.submitted => Colors.blue,
          _ => null,
        },
      );

  factory StatusChip.forLifecycle(AccountLifecycle status) => StatusChip(
        label: status.label,
        icon: switch (status) {
          AccountLifecycle.prospect || AccountLifecycle.pendingApproval => Icons.hourglass_empty,
          AccountLifecycle.rejected => Icons.block,
          _ => null,
        },
        color: switch (status) {
          AccountLifecycle.prospect => Colors.purple,
          AccountLifecycle.pendingApproval => Colors.orange,
          AccountLifecycle.rejected => Colors.red,
          AccountLifecycle.inactive => Colors.grey,
          _ => null,
        },
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effective = color ?? theme.colorScheme.primary;

    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 8 : 12, vertical: dense ? 3 : 6),
      decoration: BoxDecoration(
        color: effective.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: effective.withOpacity(0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: effective),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: effective,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown instead of an empty list. An empty screen with no explanation is the most
/// common way a field app looks broken when it is working correctly.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text(title, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
            if (message != null) ...[
              const SizedBox(height: 6),
              Text(
                message!,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
            ],
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

/// Standard async rendering: content, spinner, or an error you can act on.
class AsyncBody<T> extends StatelessWidget {
  const AsyncBody({super.key, required this.value, required this.builder, this.onRetry});

  final AsyncValue<T> value;
  final Widget Function(T data) builder;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => value.when(
        data: builder,
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => EmptyState(
          icon: error is OfflineException ? Icons.cloud_off : Icons.error_outline,
          title: error is OfflineException ? 'You are offline' : 'Could not load',
          message: error is OfflineException
              ? 'Showing what is on the device. This will refresh when you are back online.'
              : error.toString(),
          action: onRetry == null
              ? null
              : FilledButton.tonal(onPressed: onRetry, child: const Text('Try again')),
        ),
      );
}

/// Persistent, unobtrusive indicator of offline state and queued work — so a rep always
/// knows whether their day has left the device.
class OfflineBanner extends ConsumerWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final online = ref.watch(connectivityProvider);
    final pending = ref.watch(pendingSyncCountProvider);

    if (online && pending == 0) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final color = online ? theme.colorScheme.tertiary : theme.colorScheme.error;

    return Material(
      color: color.withOpacity(0.12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(online ? Icons.sync : Icons.cloud_off, size: 16, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                online
                    ? '$pending change${pending == 1 ? '' : 's'} waiting to sync'
                    : 'Offline — your work is saved on this device'
                        '${pending > 0 ? ' ($pending waiting)' : ''}',
                style: theme.textTheme.bodySmall?.copyWith(color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A row of label and value, for read-only detail screens.
class DetailRow extends StatelessWidget {
  const DetailRow({super.key, required this.label, required this.value, this.icon, this.emphasise = false});

  final String label;
  final String value;
  final IconData? icon;
  final bool emphasise;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
          ],
          SizedBox(
            width: 130,
            child: Text(label,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
          Expanded(
            child: Text(
              value,
              style: emphasise
                  ? theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)
                  : theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

/// Bottom action bar for forms — keeps the primary action reachable with a thumb.
class SubmitBar extends StatelessWidget {
  const SubmitBar({
    super.key,
    required this.label,
    required this.onSubmit,
    this.secondaryLabel,
    this.onSecondary,
    this.busy = false,
    this.note,
  });

  final String label;
  final VoidCallback? onSubmit;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;
  final bool busy;
  final String? note;

  @override
  Widget build(BuildContext context) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (note != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(note!,
                      style: Theme.of(context).textTheme.bodySmall, textAlign: TextAlign.center),
                ),
              Row(
                children: [
                  if (secondaryLabel != null) ...[
                    Expanded(
                      child: OutlinedButton(
                        onPressed: busy ? null : onSecondary,
                        child: Text(secondaryLabel!),
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      onPressed: busy ? null : onSubmit,
                      child: busy
                          ? const SizedBox(
                              height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : Text(label),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
}

/// Shows an API failure in language a rep can act on, and never loses their input.
void showApiError(BuildContext context, Object error) {
  final message = switch (error) {
    OfflineException() => 'Saved on this device. It will sync when you are back online.',
    ApiException(:final message) => message,
    _ => 'Something went wrong: $error',
  };

  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
      backgroundColor: error is OfflineException ? null : Theme.of(context).colorScheme.error,
    ));
}

void showSuccess(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(message), behavior: SnackBarBehavior.floating));
}

/// Confirmation for anything destructive or hard to undo.
Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error)
              : null,
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}
