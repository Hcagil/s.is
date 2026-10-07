// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get deliverySending => 'Sending';

  @override
  String get deliverySent => 'Sent';

  @override
  String get deliveryDelivered => 'Delivered';

  @override
  String get deliveryRead => 'Read';

  @override
  String get settingsAppearance => 'Appearance';

  @override
  String get settingsTextSize => 'Text size';

  @override
  String get settingsLanguage => 'Language';

  @override
  String get settingsAutoDownload => 'Auto-download';

  @override
  String get themeViolet => 'Violet';

  @override
  String get themeOcean => 'Ocean';

  @override
  String get themeForest => 'Forest';

  @override
  String get themeSunset => 'Sunset';

  @override
  String get themeGraphite => 'Graphite';

  @override
  String get themeRose => 'Rose';

  @override
  String get appearanceBuiltIn => 'Built-in themes';

  @override
  String get appearanceMyThemes => 'My themes';

  @override
  String get appearanceNewTheme => 'New theme';

  @override
  String get appearanceNoExport =>
      'Themes stay on this phone. There is no export.';

  @override
  String get appearanceWallpaper => 'Wallpaper';

  @override
  String get appearanceDim => 'Dim';

  @override
  String get appearanceBlur => 'Blur';

  @override
  String get previewTheirs => 'Is everyone still in for Saturday?';

  @override
  String get previewMine => 'Great, I\'ll bring the cake';

  @override
  String get textSystemFont => 'Use the phone\'s own font';

  @override
  String get textSystemFontHint => 'Matches your system. Off = SIS font';

  @override
  String get textChatSize => 'Chat text size';

  @override
  String get textAppSize => 'App text size';

  @override
  String get textAppSample => 'Settings and chat list text';

  @override
  String get textSmall => 'Small';

  @override
  String get textMedium => 'Medium';

  @override
  String get textLarge => 'Large';

  @override
  String get languageSystem => 'System';

  @override
  String get languageSystemHint => 'Follows the phone';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageTurkish => 'Türkçe';

  @override
  String get chatMenuMute => 'Mute';

  @override
  String get chatMenuUnmute => 'Unmute';

  @override
  String get chatMenuPin => 'Pin chat';

  @override
  String get chatArchive => 'Archive';

  @override
  String get chatUnarchive => 'Unarchive';

  @override
  String get archivedChatsTitle => 'Archived chats';

  @override
  String archivedChatsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count chats',
      one: '1 chat',
    );
    return '$_temp0';
  }

  @override
  String get archivedChatsHint =>
      'Archived chats stay archived when a new message arrives. No sound, no push, no badge.';

  @override
  String get archivedChatsEmpty => 'No archived chats';

  @override
  String get chatMutedLabel => 'Muted';

  @override
  String get muteOneHour => '1 hour';

  @override
  String get muteEightHours => '8 hours';

  @override
  String get muteOneDay => '1 day';

  @override
  String get muteThreeDays => '3 days';

  @override
  String get muteOneWeek => '1 week';

  @override
  String get groupSettingsTitle => 'Group settings';

  @override
  String get groupPickSwitch => 'Members can change the group picture';

  @override
  String get groupAddSwitch => 'Members can add people';

  @override
  String get groupHistSwitch => 'New members see earlier messages';

  @override
  String get groupPinWho => 'Who may pin messages';

  @override
  String get groupDeleteForAll => 'Delete group for everyone';

  @override
  String groupDeleteTitle(String name) {
    return 'Delete $name for everyone?';
  }

  @override
  String get groupDeleteBody =>
      'All messages and photos in this group are gone for everyone. This cannot be undone.';

  @override
  String get groupDeletedNotice => 'Group deleted';

  @override
  String get groupLeave => 'Leave group';

  @override
  String get groupLeaveTitle => 'Leave group?';

  @override
  String get groupLeaveBody =>
      'The group stays for the others. You can be added again.';

  @override
  String get groupLeaveCancel => 'Cancel';

  @override
  String get cropTitle => 'Crop picture';

  @override
  String get cropChoose => 'Choose';

  @override
  String get cropPreview => 'Preview';

  @override
  String get cropPreviewHint => 'This is how the picture shows up';

  @override
  String get cropGestureHint => 'Pinch to zoom, drag to move';

  @override
  String get groupLeftNotice => 'Left the group';

  @override
  String get groupLeftUnsentNotice =>
      'Left the group. Unsent messages weren\'t sent.';

  @override
  String get attachPhoto => 'Photo';

  @override
  String get attachVideo => 'Video';

  @override
  String get attachFile => 'File';

  @override
  String get attachVoice => 'Voice';

  @override
  String get attachLocation => 'Location';

  @override
  String get attachContact => 'Contact';

  @override
  String get attachPoll => 'Poll';

  @override
  String get signInWithApple => 'Sign in with Apple';

  @override
  String get findFromContacts => 'Find people from contacts';

  @override
  String get pickerAddCaption => 'Add a caption';

  @override
  String get pickerNewChat => 'New chat';

  @override
  String get pickerRecent => 'Recent';

  @override
  String whatsNewVersion(String version) {
    return 'Version $version';
  }

  @override
  String get whatsNewUpToDate => 'You\'re up to date';

  @override
  String get messageActionReply => 'Reply';

  @override
  String get messageActionCopy => 'Copy';

  @override
  String get messageActionForward => 'Forward';

  @override
  String get messageActionEdit => 'Edit';

  @override
  String get messageActionPin => 'Pin message';

  @override
  String get messageActionDeleteForMe => 'Delete for me';

  @override
  String get messageActionDeleteForEveryone => 'Delete for everyone';

  @override
  String messageSeenBy(int count) {
    return 'Seen by $count';
  }

  @override
  String get messageMoreReactions => 'More reactions';

  @override
  String get messageDeleteTitle => 'Delete message?';

  @override
  String get messageDeleteForMeBody => 'It is hidden on your devices only.';

  @override
  String get messageDeleteForEveryoneBody =>
      'It is removed for everyone in this chat.';

  @override
  String get messageDeleteCancel => 'Cancel';

  @override
  String get commonTryAgain => 'Try again';

  @override
  String get commonMember => 'Member';

  @override
  String get commonSomeone => 'Someone';

  @override
  String get commonSettings => 'Settings';

  @override
  String get commonNotifications => 'Notifications';

  @override
  String get commonSound => 'Sound';

  @override
  String get commonVibration => 'Vibration';

  @override
  String get commonYourPeople => 'Your people';

  @override
  String get commonNobodyFound => 'Nobody found';

  @override
  String get commonNewGroup => 'New group';

  @override
  String get commonMessage => 'Message';

  @override
  String get commonGallery => 'Gallery';

  @override
  String get commonAddMembers => 'Add members';

  @override
  String get commonSave => 'Save';

  @override
  String get commonContinue => 'Continue';

  @override
  String get settingsPrivacy => 'Privacy';

  @override
  String get settingsAccount => 'Account';

  @override
  String get settingsAbout => 'About';

  @override
  String get settingsProfile => 'Profile';

  @override
  String get settingsSaved => 'Saved';

  @override
  String get settingsPictureRemoved => 'Profile picture removed';

  @override
  String get settingsPictureUpdated => 'Profile picture updated';

  @override
  String get settingsShowOnline => 'Show when I am online';

  @override
  String get settingsShowTyping => 'Show when I am typing';

  @override
  String get settingsShowLastSeen => 'Show my last seen';

  @override
  String get settingsShowLastSeenHint =>
      'While this is off, you can\'t see anyone else\'s either.';

  @override
  String get settingsShowRead => 'Show when I have read messages';

  @override
  String get settingsShowReadHint =>
      'While this is off, you can\'t see when others read yours.';

  @override
  String get settingsAvatarVisibility => 'Profile picture visibility';

  @override
  String get settingsAvatarEveryone => 'Everyone';

  @override
  String get settingsAvatarEveryoneHint => 'Anyone who can see your profile';

  @override
  String get settingsAvatarContacts => 'My contacts';

  @override
  String get settingsAvatarContactsHint => 'Only people you have saved';

  @override
  String get settingsAvatarNobody => 'Nobody';

  @override
  String get settingsAvatarNobodyHint => 'Only you -- others see your initials';

  @override
  String get settingsSignedInAs => 'Signed in with Google as';

  @override
  String get settingsUnknownAccount => 'Unknown account';

  @override
  String get settingsSignOut => 'Sign out';

  @override
  String settingsVersion(String name, int build) {
    return 'Version $name ($build)';
  }

  @override
  String get appTagline => 'Stay in sync';

  @override
  String get settingsLicences => 'Open-source licences';

  @override
  String get notifSwitchHint => 'New messages when the app is closed';

  @override
  String get notifLockScreen => 'On the lock screen';

  @override
  String get notifPreviewFull => 'Name and message';

  @override
  String get notifPreviewSender => 'Only who it is from';

  @override
  String get notifPreviewNone => 'No details';

  @override
  String get notifSampleFull => 'Ayşe: See you at 8';

  @override
  String get notifSampleSender => 'Ayşe: New message';

  @override
  String get notifSampleNone => 'SIS: New message';

  @override
  String get notifNothingMuted => 'Nothing is muted';

  @override
  String get notifAChat => 'A chat';

  @override
  String get notifMuteTitle => 'Mute notifications';

  @override
  String get muteAlways => 'Always';

  @override
  String muteUntilToday(String time) {
    return 'Until $time';
  }

  @override
  String muteUntilTomorrow(String time) {
    return 'Until tomorrow $time';
  }

  @override
  String muteUntilDate(DateTime date, String time) {
    final intl.DateFormat dateDateFormat = intl.DateFormat.MMMd(localeName);
    final String dateString = dateDateFormat.format(date);

    return 'Until $dateString $time';
  }

  @override
  String get alertSoundAndVibration => 'Sound and vibration';

  @override
  String get alertSoundHint => 'Play a sound for new messages';

  @override
  String get alertTone => 'Tone';

  @override
  String get alertToneDefault => 'System default';

  @override
  String get alertVibrationHint => 'Vibrate for new messages';

  @override
  String get alertChoiceDefault => 'Default';

  @override
  String get alertChoiceOn => 'On';

  @override
  String get alertChoiceOff => 'Off';

  @override
  String get notifExplainerTitle => 'SIS will tell you about new messages';

  @override
  String get commonYou => 'You';

  @override
  String get commonGroup => 'Group';

  @override
  String get commonSend => 'Send';

  @override
  String get commonRemove => 'Remove';

  @override
  String get commonSkip => 'Skip';

  @override
  String get commonSearchPeople => 'Search your people';

  @override
  String get commonForwarded => 'Forwarded';

  @override
  String get commonImageUnavailable => 'Image unavailable';

  @override
  String get composerPhotoLimit => 'Only the first 10 photos were sent.';

  @override
  String get composerReadOnlySystem => 'Only SIS can post here';

  @override
  String get composerLeftGroup => 'You\'re no longer in this group';

  @override
  String get composerSendPhoto => 'Send a photo';

  @override
  String composerReplyingTo(String name) {
    return 'Replying to $name';
  }

  @override
  String get composerCancelReply => 'Cancel reply';

  @override
  String get composerEditing => 'Editing message';

  @override
  String get composerCancelEdit => 'Cancel edit';

  @override
  String get quoteOriginal => 'Original message';

  @override
  String get quoteDeleted => 'This message was deleted';

  @override
  String get quotePhoto => '📷 Photo';

  @override
  String get listNoMessages => 'No messages yet';

  @override
  String listYouPrefix(String message) {
    return 'You: $message';
  }

  @override
  String get listEmpty => 'No conversations yet.\nStart one with New chat.';

  @override
  String get listSearchHint => 'Search messages';

  @override
  String get listNoResults => 'No messages found';

  @override
  String get listConversation => 'Conversation';

  @override
  String get statusTyping => 'typing…';

  @override
  String statusPeopleTyping(int count) {
    return '$count people are typing…';
  }

  @override
  String statusWhoTyping(String name) {
    return '$name is typing…';
  }

  @override
  String get statusOnline => 'online';

  @override
  String get lastSeenJustNow => 'last seen just now';

  @override
  String lastSeenMinutes(int minutes) {
    return 'last seen $minutes min ago';
  }

  @override
  String lastSeenToday(String time) {
    return 'last seen today at $time';
  }

  @override
  String lastSeenYesterday(String time) {
    return 'last seen yesterday at $time';
  }

  @override
  String lastSeenDate(String date) {
    return 'last seen $date';
  }

  @override
  String get messageEmpty => 'No messages yet. Say something.';

  @override
  String get addMembersDone => 'Added to the group';

  @override
  String get addMembersNoneTitle => 'Nobody left to add';

  @override
  String get addMembersNoneBody =>
      'Everyone in your people list is already in this group.';

  @override
  String get addMembersOldTitle => 'Show earlier messages';

  @override
  String get addMembersOldHint => 'New member sees history';

  @override
  String get addMembersAdminDecides =>
      'Group admin sets whether new members see earlier messages';

  @override
  String get addMembersAdding => 'Adding…';

  @override
  String get addMembersAdd => 'Add';

  @override
  String addMembersAddCount(int count) {
    return 'Add ($count)';
  }

  @override
  String get contactAdded => 'Added to contacts';

  @override
  String get contactRemoved => 'Removed from contacts';

  @override
  String get contactAdd => 'Add to contacts';

  @override
  String get contactRemove => 'Remove from contacts';

  @override
  String get newChatTagHint => 'Find by exact tag';

  @override
  String get newChatNoTag => 'Nobody has that tag';

  @override
  String get newChatFound => 'Found';

  @override
  String get newChatChat => 'Chat';

  @override
  String get newChatEmpty => 'Nobody yet — find someone by their tag';

  @override
  String forwardDoneMany(int count) {
    return 'Forwarded to $count chats';
  }

  @override
  String get forwardTitle => 'Forward to';

  @override
  String get forwardSearch => 'Search chats and people';

  @override
  String get forwardPrefix => 'Forwarding: ';

  @override
  String get forwardPeople => 'People';

  @override
  String get forwardNothing => 'Nothing found';

  @override
  String forwardSendCount(int count) {
    return 'Send ($count)';
  }

  @override
  String get avatarTakePhoto => 'Take photo';

  @override
  String get avatarChoose => 'Choose from library';

  @override
  String get avatarRemove => 'Remove picture';

  @override
  String get cameraFailed => 'The camera could not take a photo.';

  @override
  String get newGroupName => 'Group name';

  @override
  String get newGroupNobody => 'Nobody else has signed in yet';

  @override
  String get newGroupCreate => 'Create group';

  @override
  String membersRemoved(String name) {
    return '$name removed';
  }

  @override
  String membersNowAdmin(String name) {
    return '$name is now an admin';
  }

  @override
  String membersNoLongerAdmin(String name) {
    return '$name is no longer an admin';
  }

  @override
  String get membersEmpty => 'No members';

  @override
  String membersYou(String name) {
    return '$name (you)';
  }

  @override
  String get membersAdmin => 'Admin';

  @override
  String get membersRemoveAdmin => 'Remove as admin';

  @override
  String get membersMakeAdmin => 'Make admin';

  @override
  String get membersLeft => 'Left';

  @override
  String get membersRemovedBadge => 'Removed';

  @override
  String get bubbleDeletedByAdmin => 'Deleted by an admin';

  @override
  String bubbleEdited(String time) {
    return 'edited $time';
  }

  @override
  String get linksEmpty => 'No links shared yet';

  @override
  String linkOpenFailed(String host) {
    return 'Could not open $host';
  }

  @override
  String get mediaEmpty => 'No photos shared yet';

  @override
  String eventLeft(String name) {
    return '$name left';
  }

  @override
  String eventRemoved(String name) {
    return '$name was removed';
  }

  @override
  String eventPictureChanged(String name) {
    return '$name changed the group picture';
  }

  @override
  String eventAdded(String name) {
    return '$name was added';
  }

  @override
  String get previewRemovePhoto => 'Remove this photo';

  @override
  String get systemChatSubtitle => 'What\'s new in the app';

  @override
  String viewerCounter(int index, int total) {
    return '$index of $total';
  }

  @override
  String get viewerMore => 'More';

  @override
  String get searchInChat => 'Search in this chat';

  @override
  String get searchNoResults => 'No results';

  @override
  String get messageCopied => 'Copied';

  @override
  String get photoOpenFailed => 'That photo could not be opened.';

  @override
  String get cropUnusable => 'That photo could not be used.';

  @override
  String get menuClose => 'Close menu';

  @override
  String get groupPictureRemoved => 'Group picture removed';

  @override
  String get groupPictureUpdated => 'Group picture updated';

  @override
  String groupMemberCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count members',
      one: '1 member',
    );
    return '$_temp0';
  }

  @override
  String get groupTabMembers => 'Members';

  @override
  String get groupTabMedia => 'Media';

  @override
  String get groupTabLinks => 'Links';

  @override
  String get attachLoadMoreFailed => 'Could not load more photos.';

  @override
  String attachLimit(int count) {
    return 'You can send up to $count photos at once.';
  }

  @override
  String get attachOpenFailedMany => 'Those photos could not be opened.';

  @override
  String get attachOpenFailedSome => 'Some photos could not be opened.';

  @override
  String get attachOpenFailed => 'That could not be opened.';

  @override
  String get attachRecentPhotos => 'Recent photos';

  @override
  String get attachAllowMore => 'Allow more';

  @override
  String get attachNoPhotos => 'No photos yet';

  @override
  String attachSendPhotos(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Send $count photos',
      one: 'Send 1 photo',
    );
    return '$_temp0';
  }

  @override
  String get attachFasterTitle => 'Send photos faster';

  @override
  String get attachFasterBody =>
      'Allow access so your gallery loads right here – nothing is uploaded until you send it.';

  @override
  String get attachOpenSettings => 'Open settings';

  @override
  String get attachAllowPhotos => 'Allow photos';

  @override
  String get attachNotNow => 'Not now';

  @override
  String get attachCamera => 'Camera';

  @override
  String get onboardingWelcome => 'Welcome';

  @override
  String get onboardingHeading => 'How should others see you?';

  @override
  String get onboardingHint => 'You can change both later in Settings.';

  @override
  String get tagChecking => 'Checking…';

  @override
  String tagFree(String tag) {
    return '@$tag is available';
  }

  @override
  String tagTaken(String tag) {
    return '@$tag is taken';
  }

  @override
  String get tagUnknown => 'Could not check availability';

  @override
  String get profileDisplayName => 'Display name';

  @override
  String get profileDisplayNameHint =>
      'Shown to other members. Need not be unique.';

  @override
  String get profileTag => 'Tag';

  @override
  String get profileTagHint => 'Unique. Letters, digits and _; 3 to 20.';

  @override
  String get signInBody => 'Private messages for the people on your list.';

  @override
  String get signInGoogle => 'Continue with Google';

  @override
  String get signInInvitedOnly => 'Only invited Google accounts can sign in.';

  @override
  String get statusDeniedTitle => 'Access denied';

  @override
  String get statusDeniedBody =>
      'This Google account is not currently approved for SIS.';

  @override
  String get statusConnectTitle => 'Could not connect';

  @override
  String get statusStartTitle => 'Could not start SIS';

  @override
  String statusStartBody(String reason) {
    return 'Restart the app. If it keeps failing, reinstall it.\n\n$reason';
  }

  @override
  String get updateAvailable => 'Update available';

  @override
  String get updateLater => 'Later';

  @override
  String get updateAction => 'Update';

  @override
  String get updateDownloading => 'Downloading update…';

  @override
  String get updateReady => 'Ready to install';

  @override
  String get updateRestart => 'Restart';

  @override
  String get updateRequiredTitle => 'Update required';

  @override
  String updateRequiredBody(int installed, int minimum) {
    return 'This version ($installed) is no longer supported (minimum $minimum).';
  }

  @override
  String get updateNow => 'Update now';

  @override
  String licencesCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count licences',
      one: '1 licence',
    );
    return '$_temp0';
  }

  @override
  String get commonConversation => 'Conversation';

  @override
  String get statusStartBootstrap => 'SIS could not start. Please try again.';

  @override
  String get appearanceRename => 'Rename';

  @override
  String get appearanceDuplicate => 'Duplicate';

  @override
  String get appearanceDelete => 'Delete';

  @override
  String get appearanceCancel => 'Cancel';

  @override
  String get appearanceRenameTitle => 'Rename theme';

  @override
  String get appearanceThemeName => 'Theme name';

  @override
  String get appearanceThemeMenu => 'Theme options';

  @override
  String appearanceCopyName(String name) {
    return '$name copy';
  }

  @override
  String get wallpaperColour => 'Colour';

  @override
  String get wallpaperGradient => 'Gradient';

  @override
  String get wallpaperPicture => 'Picture';

  @override
  String get wallpaperChoosePhoto => 'Choose photo';

  @override
  String get wallpaperPickFailed =>
      'That photo could not be used. Try another.';

  @override
  String get wallpaperReset => 'Reset Chat Backgrounds';

  @override
  String get wallpaperResetInfo =>
      'Remove all uploaded chat backgrounds and restore the pre-installed ones.';

  @override
  String get wallpaperResetTitle => 'Reset chat backgrounds';

  @override
  String get wallpaperResetConfirm =>
      'Are you sure you want to reset all chat backgrounds?';

  @override
  String get wallpaperResetAction => 'Reset';
}
