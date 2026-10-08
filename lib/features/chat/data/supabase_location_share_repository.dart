import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/failure.dart';
import '../../../data/failures.dart';
import '../domain/location_share_repository.dart';
import '../domain/shared_location.dart';

/// [LocationShareRepository] backed by the send_location function: the only write path for a location message; the server refuses (42501) a caller who may not post in the conversation.
final class SupabaseLocationShareRepository implements LocationShareRepository {
  SupabaseLocationShareRepository(this._client);
  final SupabaseClient _client;

  @override
  Future<Result<void>> send(
    String conversationId,
    String messageId,
    SharedLocation location,
  ) async {
    try {
      await _client.rpc(
        'send_location',
        params: {
          'p_conversation': conversationId,
          'p_id': messageId,
          'p_lat': location.lat,
          'p_lng': location.lng,
          'p_name': location.name,
          'p_address': location.address,
        },
      );
      return const Ok(null);
    } catch (e) {
      return Err(switch (e) {
        PostgrestException(:final code) when code == '42501' =>
          const DeniedFailure(),
        _ => readableFailure(e),
      });
    }
  }
}
