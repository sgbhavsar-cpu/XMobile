import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/state/providers.dart';
import '../../core/ui/common.dart';
import '../../core/ui/form_fields.dart';

/// Receipts shared into XMobile from other apps, waiting to become expenses.
///
/// The inbox exists so nothing is lost: a screenshot shared while the app is busy is
/// queued rather than dropped, and nothing is auto-converted — OCR misreads amounts, and
/// a silently-wrong expense is worse than a missing one.
///
/// The "simulate" buttons stand in for the Android share sheet and iOS share extension
/// until those plugins are wired; the rest of the flow is exactly what ships.
class ShareInboxScreen extends ConsumerStatefulWidget {
  const ShareInboxScreen({super.key});

  @override
  ConsumerState<ShareInboxScreen> createState() => _ShareInboxScreenState();
}

class _ShareInboxScreenState extends ConsumerState<ShareInboxScreen> {
  bool _busy = false;

  Future<void> _simulate(String fileName, String sourceApp) async {
    setState(() => _busy = true);
    try {
      await ref
          .read(apiClientProvider)
          .simulateSharedFile(fileName: fileName, sourceApp: sourceApp);
      bumpRefreshFrom(ref);
      if (mounted) showSuccess(context, 'Receipt received and read');
    } catch (e) {
      if (mounted) showApiError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final inbox = ref.watch(shareInboxProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Shared receipts')),
      body: Column(
        children: [
          Card(
            margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.science_outlined, size: 18),
                      const SizedBox(width: 8),
                      Text('Simulate a share',
                          style: Theme.of(context).textTheme.titleSmall),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'On a real device you would tap Share in your UPI app and pick XMobile. '
                    'These buttons do the same thing, including the on-device OCR.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _busy
                            ? null
                            : () => _simulate('upi_payment.jpg',
                                'com.google.android.apps.nbu.paisa.user'),
                        icon: const Icon(Icons.account_balance_wallet, size: 18),
                        label: const Text('UPI screenshot'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _busy
                            ? null
                            : () => _simulate('irctc_ticket.pdf', 'com.whatsapp'),
                        icon: const Icon(Icons.picture_as_pdf, size: 18),
                        label: const Text('Ticket PDF'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _busy
                            ? null
                            : () => _simulate('hotel_bill.jpg', 'com.google.android.gm'),
                        icon: const Icon(Icons.hotel, size: 18),
                        label: const Text('Hotel bill'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: AsyncBody(
              value: inbox,
              onRetry: () => bumpRefreshFrom(ref),
              builder: (list) => list.isEmpty
                  ? const EmptyState(
                      icon: Icons.inbox,
                      title: 'Nothing waiting',
                      message: 'Receipts you share into XMobile appear here, already read, '
                          'ready to become an expense in one tap.',
                    )
                  : ListView.builder(
                      itemCount: list.length,
                      itemBuilder: (context, index) {
                        final item = list[index];
                        final ocr = item.ocr;

                        return Card(
                          margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                          child: ListTile(
                            leading: CircleAvatar(
                              child: Icon(
                                  item.attachment.isPdf ? Icons.picture_as_pdf : Icons.image),
                            ),
                            title: Text(
                              ocr?.amount != null
                                  ? '${currencyFormat.format(ocr!.amount)}'
                                      '${ocr.merchantName != null ? ' to ${ocr.merchantName}' : ''}'
                                  : item.attachment.fileName,
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(item.attachment.fileName),
                                Text(
                                  'Shared ${dateTimeFormat.format(item.receivedAt)}'
                                  '${ocr?.txnDate != null ? ' · paid ${dateFormat.format(ocr!.txnDate!)}' : ''}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                if (ocr?.confidence != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: StatusChip(
                                      label: 'OCR ${(ocr!.confidence! * 100).round()}%',
                                      color: ocr.confidence! > 0.8 ? Colors.green : Colors.orange,
                                    ),
                                  ),
                              ],
                            ),
                            isThreeLine: true,
                            trailing: PopupMenuButton<String>(
                              onSelected: (value) async {
                                if (value == 'convert') {
                                  context.push('/expenses/new?fromInbox=${item.id}');
                                } else {
                                  await ref
                                      .read(apiClientProvider)
                                      .dismissShareInboxItem(item.id);
                                  bumpRefreshFrom(ref);
                                }
                              },
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                    value: 'convert', child: Text('Make an expense')),
                                PopupMenuItem(value: 'dismiss', child: Text('Dismiss')),
                              ],
                            ),
                            onTap: () => context.push('/expenses/new?fromInbox=${item.id}'),
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
