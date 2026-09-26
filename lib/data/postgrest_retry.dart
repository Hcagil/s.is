import 'package:supabase_flutter/supabase_flutter.dart';

/// PostgREST retries a failed GET three times, with 1s+2s+4s of backoff
/// between attempts, by default. `SupabaseClient.from()` does not forward
/// `PostgrestClientOptions.retryEnabled` to the query it builds -- a gap in
/// supabase 2.16.1 (the latest published version; nothing newer fixes it
/// yet) -- so that default cannot be turned off from the client's own
/// options. This is the one place that works around it: chained onto a
/// read, it keeps a single retry, enough to survive one blip on a real
/// connection, so an actually unreachable server is reported in about a
/// second instead of about seven. A write is never retried by PostgREST
/// regardless (only GET and HEAD are), so calling this on one is harmless
/// but does nothing -- it is meant for reads only.
extension QuickRetry<T, S, R> on PostgrestBuilder<T, S, R> {
  PostgrestBuilder<T, S, R> retriedOnce() => retry(count: 1);
}
