import 'dart:async';
import 'dart:developer';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import '../../../core/platform_features.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/domain/member.dart';
import '../../auth/domain/session_state.dart';
import '../../autodownload/application/auto_download_controller.dart';
import '../../autodownload/domain/auto_download_settings.dart';
import '../../notifications/application/push_controller.dart';
import '../../profile/application/profile_controller.dart';
import '../domain/attachment.dart';
import '../domain/chat_archive_repository.dart';
import '../domain/chat_delete_repository.dart';
import '../domain/chat_list_snapshot_store.dart';
import '../domain/chat_pin_repository.dart';
import '../domain/chat_repository.dart';
import '../domain/conversation.dart';
import '../domain/contact_share_repository.dart';
import '../domain/contacts_repository.dart';
import '../domain/external_picker.dart';
import '../domain/file_attachment.dart';
import '../domain/file_repository.dart';
import '../domain/gallery.dart';
import '../domain/group_settings.dart';
import '../domain/group_settings_repository.dart';
import '../domain/geo.dart';
import '../domain/links.dart';
import '../domain/location_services.dart';
import '../domain/location_share_repository.dart';
import '../domain/message.dart';
import '../domain/phone_book.dart';
import '../domain/picture_cropper.dart';
import '../domain/poll.dart';
import '../domain/poll_repository.dart';
import '../domain/reaction.dart';
import '../domain/reaction_repository.dart';
import '../domain/read_marks.dart';
import '../domain/send_queue_store.dart';
import '../domain/recent_sticker_store.dart';
import '../domain/shared_location.dart';
import '../domain/shared_contact.dart';
import '../domain/sticker.dart';
import '../domain/sticker_repository.dart';
import '../domain/video.dart';
import '../domain/video_gallery.dart';
import '../domain/voice.dart';
import 'chat_drafts.dart';

part 'open_conversation.dart';
part 'conversation_list_controller.dart';
part 'contacts_controller.dart';
part 'file_controllers.dart';
part 'video_controllers.dart';
part 'voice_capture_controller.dart';
part 'voice_player_controller.dart';
part 'location_controllers.dart';
part 'sticker_controllers.dart';
part 'messages_controller.dart';
part 'reply_edit_controllers.dart';
part 'read_marks_controller.dart';
part 'reactions_controller.dart';
part 'polls_controller.dart';
part 'phone_book_controller.dart';
part 'chat_search_controller.dart';
part 'chat_list_search_controller.dart';

final chatRepositoryProvider = Provider<ChatRepository>(
  (_) => throw UnimplementedError('override in main'),
);
final reactionRepositoryProvider = Provider<ReactionRepository>(
  (_) => throw UnimplementedError('override in main'),
);
final pollRepositoryProvider = Provider<PollRepository>(
  (_) => throw UnimplementedError('override in main'),
);
final groupSettingsRepositoryProvider = Provider<GroupSettingsRepository>(
  (_) => throw UnimplementedError('override in main'),
);
final chatArchiveRepositoryProvider = Provider<ChatArchiveRepository>(
  (_) => throw UnimplementedError('override in main'),
);

final chatPinRepositoryProvider = Provider<ChatPinRepository>(
  (_) => throw UnimplementedError('override in main'),
);

final chatDeleteRepositoryProvider = Provider<ChatDeleteRepository>(
  (_) => throw UnimplementedError('override in main'),
);
final linkOpenerProvider = Provider<LinkOpener>(
  (_) => throw UnimplementedError('override in main'),
);

/// A short-lived URL for one attachment, kept while something shows it.
/// Signed for an hour; a screen open longer re-asks by being rebuilt.
final attachmentUrlProvider = FutureProvider.autoDispose.family<Uri, String>((
  ref,
  path,
) async {
  // A signed URL is issued to one account; a new account asks again.
  ref.watch(currentUserIdProvider);
  return switch (await ref.read(chatRepositoryProvider).attachmentUrl(path)) {
    Ok(:final value) => value,
    Err(:final failure) => throw failure,
  };
}, retry: (_, _) => null);

/// The phone's own photo library, for the attachment sheet's grid.
final galleryProvider = Provider<Gallery>(
  (_) => throw UnimplementedError('override in main'),
);

/// The phone's own contacts, for the Send a contact picker.
final phoneBookProvider = Provider<PhoneBook>(
  (_) => throw UnimplementedError('override in main'),
);

/// Sends a contact as a message.
final contactShareRepositoryProvider = Provider<ContactShareRepository>(
  (_) => throw UnimplementedError('override in main'),
);

/// Picks photos through another app on the phone (Google Photos, the
/// maker's gallery, Files...), for the attachment sheet's "From an app"
/// entry.
final externalPickerProvider = Provider<ExternalPicker>(
  (_) => throw UnimplementedError('override in main'),
);

/// Crops a picture on the phone into the final square JPEG, for the crop
/// screen.
final pictureCropperProvider = Provider<PictureCropper>(
  (_) => throw UnimplementedError('override in main'),
);

/// Photos already on this phone. Cleared on sign-out.
final attachmentCacheProvider = Provider<AttachmentCache>(
  (_) => throw UnimplementedError('override in main'),
);

/// Runs [onEnd] on every settled answer that the session has ended --
/// signed out, or Denied (revoked or replaced on another device) -- with
/// `fireImmediately` so a cold start landing directly on either state is
/// caught too. Shared by [attachmentCacheOwnerProvider] and
/// [chatListSnapshotOwnerProvider], mirroring pushInboxOwnerProvider's reach.
void _onSessionEnd(Ref ref, Future<void> Function() onEnd) {
  ref.listen(sessionControllerProvider, (_, next) {
    switch (next.value) {
      case SignedOut() || Denied():
        unawaited(onEnd());
      case _:
    }
  }, fireImmediately: true);
}

/// Wipes the cache above as soon as the session is found to have ended --
/// signed out, or Denied (revoked or replaced on another device) -- so
/// nothing of a previous member's photos or pictures survives on this phone.
final attachmentCacheOwnerProvider = Provider<void>((ref) {
  _onSessionEnd(ref, () => ref.read(attachmentCacheProvider).clear());
});

/// Where the conversation list's last snapshot lives on the phone. The real
/// implementation is overridden in main.dart; data/ is the only layer
/// allowed to import path_provider.
final chatListSnapshotStoreProvider = Provider<ChatListSnapshotStore>(
  (_) => throw UnimplementedError('override in main'),
);

/// Erases the snapshot above as soon as the session is found to have ended,
/// mirroring [attachmentCacheOwnerProvider] exactly: same two states, same
/// fireImmediately, same reach (a cold start landing directly on SignedOut
/// or Denied included). A snapshot is per-owner-checked on read too (see
/// FileChatListSnapshotStore.load), so this is defence in depth, not the
/// only guard.
final chatListSnapshotOwnerProvider = Provider<void>((ref) {
  _onSessionEnd(ref, () => ref.read(chatListSnapshotStoreProvider).clear());
});

/// One attachment's bytes: from this phone when they are here, otherwise
/// downloaded once and kept. Replaces a signed URL per look, which fetched
/// the whole photo again every time.
final attachmentBytesProvider = FutureProvider.autoDispose
    .family<Uint8List, String>((ref, path) async {
      // Per account, like every other read.
      ref.watch(currentUserIdProvider);
      return switch (await ref
          .read(chatRepositoryProvider)
          .attachmentBytes(path)) {
        Ok(:final value) => value,
        Err(:final failure) => throw failure,
      };
    }, retry: (_, _) => null);

/// One profile's or group's picture: from this phone when it is here,
/// otherwise downloaded once and kept. A changed picture is a new storage
/// path (never an overwrite), so this is never stale.
final avatarBytesProvider = FutureProvider.autoDispose
    .family<Uint8List, String>((ref, path) async {
      ref.watch(currentUserIdProvider);
      return switch (await ref.read(chatRepositoryProvider).avatarBytes(path)) {
        Ok(:final value) => value,
        Err(:final failure) => throw failure,
      };
    }, retry: (_, _) => null);

/// Riverpod 3 retries a failed build automatically, which leaves the provider
/// loading-with-an-error indefinitely instead of settling on [AsyncError] — an
/// endless spinner where ARCHITECTURE requires a reason on screen. Worse, a
/// DeniedFailure is a refusal that no amount of retrying can turn into data.
/// Retries are off; [refresh] is the explicit way back.
Duration? _never(int retryCount, Object error) => null;

Future<T> _value<T>(Future<Result<T>> call) async => switch (await call) {
  Ok(:final value) => value,
  Err(:final failure) => throw failure,
};

/// Who is in a conversation, for its group page.
final conversationMembersProvider = FutureProvider.autoDispose
    .family<List<Member>, String>((ref, id) {
      // Per account: what a member may read depends on who "you" are.
      ref.watch(currentUserIdProvider);
      return _value(ref.read(chatRepositoryProvider).conversationMembers(id));
    }, retry: _never);

/// A conversation's photos, newest first.
final sharedMediaProvider = FutureProvider.autoDispose
    .family<List<Message>, String>((ref, id) {
      ref.watch(currentUserIdProvider);
      return _value(ref.read(chatRepositoryProvider).sharedMedia(id));
    }, retry: _never);

/// A conversation's links, newest first.
final sharedLinksProvider = FutureProvider.autoDispose
    .family<List<SharedLink>, String>((ref, id) async {
      ref.watch(currentUserIdProvider);
      return sharedLinksIn(
        await _value(ref.read(chatRepositoryProvider).sharedLinks(id)),
      );
    }, retry: _never);
