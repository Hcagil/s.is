import 'link_preview.dart';

/// Reads the page behind a link, once, on the sender's phone. Its own
/// boundary because the network is a platform capability, and presentation/
/// and application/ may not import an SDK.
abstract interface class LinkPreviewFetcher {
  /// The card for [url] with its picture (already shrunk to fit), or null
  /// when the page could not be read in time or has no title. Never throws.
  Future<LinkPreviewDraft?> fetch(Uri url);
}
