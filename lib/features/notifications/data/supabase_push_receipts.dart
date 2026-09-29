import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/push.dart';
import 'push_receipt_log.dart';

/// Sends the receipts the background handler kept (PushReceiptLog) through the
/// `report_push_receipts` RPC. Thin on purpose (ARCHITECTURE rule 4).
final class SupabasePushReceipts implements PushReceipts {
  SupabasePushReceipts(this._client);

  final SupabaseClient _client;

  @override
  Future<void> upload() async {
    try {
      final batch = (await PushReceiptLog.pending()).take(100).toList();
      if (batch.isEmpty) return;
      await _client.rpc('report_push_receipts', params: {'receipts': batch});
      await PushReceiptLog.removeUploaded(batch);
    } catch (_) {
      // Kept on the phone; tried again on the next start.
    }
  }
}
