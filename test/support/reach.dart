// Since v0.22.0 a member can only start a chat with, or invite, someone they
// can reach: themselves, someone they share a chat with, a saved contact, or
// someone they found by exact tag (docs/SECURITY.md, "Reach"). Integration
// fixtures get reach the way a member does -- by finding the other by their
// exact tag, as the New chat picker does -- and only for the pairs a suite
// actually starts, so no suite's negative subject gains reach it should not
// have.
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The signed-in member's own current tag.
Future<String> tagOf(SupabaseClient client) async {
  final own = await client
      .from('profiles')
      .select('tag')
      .eq('user_id', client.auth.currentUser!.id)
      .single();
  return own['tag'] as String;
}

/// [from] finds the member [id] by their exact [tag].
Future<void> findTag(
  SupabaseClient from,
  String tag, {
  required String id,
}) async {
  final rows = await from.rpc(
    'find_by_tag',
    params: {'search_tag': tag},
  ) as List<dynamic>;
  expect(rows.map((r) => (r as Map<String, dynamic>)['user_id']), [
    id,
  ], reason: 'find_by_tag did not find $tag');
}

/// [from] finds each of [others] by their current tag.
Future<void> findByTag(
  SupabaseClient from,
  Iterable<SupabaseClient> others,
) async {
  for (final other in others) {
    await findTag(from, await tagOf(other), id: other.auth.currentUser!.id);
  }
}
