import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/models.dart';
import '../../core/state/providers.dart';
import '../../core/ui/common.dart';
import '../../core/ui/form_fields.dart';

/// Tracking health — a first-class screen, not a debug page.
///
/// With no MDM, nothing can be enforced centrally: every permission and OEM setting has
/// to be obtained from the rep and re-verified continuously. This screen shows the same
/// score the manager sees, so a conversation about a gap starts from a shared checklist
/// rather than an accusation — and a rep who did everything right can prove it.
///
/// The toggles here stand in for real permission dialogs until the platform plugins are
/// wired; the diagnosis, scoring and guidance are what ship.
class TrackingHealthScreen extends ConsumerStatefulWidget {
  const TrackingHealthScreen({super.key});

  @override
  ConsumerState<TrackingHealthScreen> createState() => _TrackingHealthScreenState();
}

class _TrackingHealthScreenState extends ConsumerState<TrackingHealthScreen> {
  bool _busy = false;

  Future<void> _update(TrackingHealth health) async {
    setState(() => _busy = true);
    try {
      await ref.read(apiClientProvider).updateTrackingHealth(health);
      bumpRefreshFrom(ref);
    } catch (e) {
      if (mounted) showApiError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _togglePause(bool currentlyActive) async {
    if (currentlyActive) {
      final reasons = await ref.read(reasonCodesProvider('TRACKING_PAUSE').future);
      if (!mounted) return;

      String? selected;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) => AlertDialog(
            title: const Text('Pause tracking'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Tracking will resume automatically after an hour so it is not left off '
                  'by accident.',
                ),
                const SizedBox(height: 12),
                AppDropdown<ReasonCode>(
                  label: 'Reason',
                  required: true,
                  items: reasons,
                  value: reasons.where((r) => r.code == selected).firstOrNull,
                  itemLabel: (r) => r.name,
                  onChanged: (r) => setDialogState(() => selected = r?.code),
                ),
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancel')),
              FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('Pause')),
            ],
          ),
        ),
      );

      if (confirmed != true || selected == null || !mounted) return;

      try {
        await ref
            .read(apiClientProvider)
            .setTrackingActive(false, pauseReasonCode: selected);
        bumpRefreshFrom(ref);
        if (mounted) showSuccess(context, 'Tracking paused — your manager will see this');
      } catch (e) {
        if (mounted) showApiError(context, e);
      }
    } else {
      await ref.read(apiClientProvider).setTrackingActive(true);
      bumpRefreshFrom(ref);
      if (mounted) showSuccess(context, 'Tracking resumed');
    }
  }

  @override
  Widget build(BuildContext context) {
    final health = ref.watch(trackingHealthProvider);
    final active = ref.watch(trackingActiveProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Tracking health')),
      body: AsyncBody(
        value: health,
        onRetry: () => bumpRefreshFrom(ref),
        builder: (h) => ListView(
          children: [
            _ScoreCard(health: h),
            FormSectionCard(
              title: 'Tracking',
              children: [
                active.when(
                  loading: () => const LinearProgressIndicator(),
                  error: (_, __) => const SizedBox.shrink(),
                  data: (isActive) => AppSwitchField(
                    label: isActive ? 'Tracking is on' : 'Tracking is paused',
                    subtitle: isActive
                        ? 'Recording your location during working hours and tours'
                        : 'Nothing is being recorded right now',
                    value: isActive,
                    onChanged: (_) => _togglePause(isActive),
                  ),
                ),
              ],
            ),
            FormSectionCard(
              title: 'Setup checklist',
              subtitle: 'Your phone is not managed by the company, so these are yours to '
                  'grant — and to keep granted.',
              children: [
                _CheckItem(
                  label: 'Location permission',
                  ok: h.locationPermission == 'ALWAYS',
                  detail: h.locationPermission == 'ALWAYS'
                      ? 'Set to Always — correct'
                      : 'Currently "${h.locationPermission}". Tracking stops when the app is '
                          'in the background.',
                  fixLabel: 'Set to Always',
                  busy: _busy,
                  onFix: () => _update(h.copyWith(locationPermission: 'ALWAYS')),
                ),
                _CheckItem(
                  label: 'Battery optimisation',
                  ok: !h.batteryOptimised,
                  detail: h.batteryOptimised
                      ? 'Android may kill tracking in the background to save power.'
                      : 'XMobile is exempt — correct',
                  fixLabel: 'Exempt XMobile',
                  busy: _busy,
                  onFix: () => _update(h.copyWith(batteryOptimised: false)),
                ),
                _CheckItem(
                  label: 'Autostart',
                  ok: h.autostartConfigured,
                  detail: h.autostartConfigured
                      ? 'Enabled — tracking restarts after a reboot'
                      : 'Xiaomi, Oppo, Vivo and Realme phones stop apps from restarting '
                          'unless autostart is enabled.',
                  fixLabel: 'Enable autostart',
                  busy: _busy,
                  onFix: () => _update(h.copyWith(autostartConfigured: true)),
                ),
                _CheckItem(
                  label: 'Notifications',
                  ok: h.notificationsAllowed,
                  detail: h.notificationsAllowed
                      ? 'Allowed — correct'
                      : 'Without notifications the tracking indicator is hidden and Android '
                          'may treat tracking as inactive.',
                  fixLabel: 'Allow notifications',
                  busy: _busy,
                  onFix: () => _update(h.copyWith(notificationsAllowed: true)),
                ),
                _CheckItem(
                  label: 'Physical activity',
                  ok: h.activityPermission,
                  detail: h.activityPermission
                      ? 'Granted — correct'
                      : 'Used to tell moving from parked, which saves a lot of battery.',
                  fixLabel: 'Grant',
                  busy: _busy,
                  onFix: () => _update(h.copyWith(activityPermission: true)),
                ),
              ],
            ),
            FormSectionCard(
              title: 'Your privacy',
              children: [
                const Text(
                  'Location is recorded only during your working hours and while a tour is '
                  'running. You can pause tracking at any time with a reason, and you can '
                  'always see your own trail on the journey screen.',
                ),
                const SizedBox(height: 8),
                Text(
                  'Your manager sees the same health score you see here.',
                  style: Theme.of(context).textTheme.bodySmall,
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

class _ScoreCard extends StatelessWidget {
  const _ScoreCard({required this.health});

  final TrackingHealth health;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final score = health.score;
    final color = score >= 80
        ? Colors.green
        : (score >= 50 ? Colors.orange : theme.colorScheme.error);

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            SizedBox(
              width: 64,
              height: 64,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CircularProgressIndicator(
                    value: score / 100,
                    strokeWidth: 6,
                    color: color,
                    backgroundColor: color.withOpacity(0.15),
                  ),
                  Text('$score', style: theme.textTheme.titleMedium),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    score >= 80
                        ? 'Tracking is set up correctly'
                        : '${health.issues.length} thing'
                            '${health.issues.length == 1 ? '' : 's'} to fix',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    score >= 80
                        ? 'Nothing to do. Your journeys will be recorded accurately.'
                        : 'Until these are fixed, parts of your day may go unrecorded — '
                            'and gaps take explaining later.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CheckItem extends StatelessWidget {
  const _CheckItem({
    required this.label,
    required this.ok,
    required this.detail,
    required this.fixLabel,
    required this.onFix,
    required this.busy,
  });

  final String label;
  final bool ok;
  final String detail;
  final String fixLabel;
  final VoidCallback onFix;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            ok ? Icons.check_circle : Icons.error_outline,
            color: ok ? Colors.green : Colors.orange,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.titleSmall),
                Text(detail, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          if (!ok)
            TextButton(onPressed: busy ? null : onFix, child: Text(fixLabel)),
        ],
      ),
    );
  }
}
