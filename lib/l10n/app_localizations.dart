import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_tr.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('tr'),
  ];

  /// Screen-reader label of the clock tick on a message waiting to go out
  ///
  /// In en, this message translates to:
  /// **'Sending'**
  String get deliverySending;

  /// Screen-reader label of the one-tick state
  ///
  /// In en, this message translates to:
  /// **'Sent'**
  String get deliverySent;

  /// Screen-reader label of the two-grey-ticks state
  ///
  /// In en, this message translates to:
  /// **'Delivered'**
  String get deliveryDelivered;

  /// Screen-reader label of the two-blue-ticks state
  ///
  /// In en, this message translates to:
  /// **'Read'**
  String get deliveryRead;

  /// Settings row: themes
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get settingsAppearance;

  /// Settings row and page title: text size
  ///
  /// In en, this message translates to:
  /// **'Text size'**
  String get settingsTextSize;

  /// Settings row and page title: language
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get settingsLanguage;

  /// Settings row (not available yet)
  ///
  /// In en, this message translates to:
  /// **'Auto-download'**
  String get settingsAutoDownload;

  /// Theme name
  ///
  /// In en, this message translates to:
  /// **'Violet'**
  String get themeViolet;

  /// Theme name
  ///
  /// In en, this message translates to:
  /// **'Ocean'**
  String get themeOcean;

  /// Theme name
  ///
  /// In en, this message translates to:
  /// **'Forest'**
  String get themeForest;

  /// Theme name
  ///
  /// In en, this message translates to:
  /// **'Sunset'**
  String get themeSunset;

  /// Theme name
  ///
  /// In en, this message translates to:
  /// **'Graphite'**
  String get themeGraphite;

  /// Theme name
  ///
  /// In en, this message translates to:
  /// **'Rose'**
  String get themeRose;

  /// Section label on the Appearance page
  ///
  /// In en, this message translates to:
  /// **'Built-in themes'**
  String get appearanceBuiltIn;

  /// Section label for custom themes (not available yet)
  ///
  /// In en, this message translates to:
  /// **'My themes'**
  String get appearanceMyThemes;

  /// Button to make a custom theme (not available yet)
  ///
  /// In en, this message translates to:
  /// **'New theme'**
  String get appearanceNewTheme;

  /// Hint under the themes
  ///
  /// In en, this message translates to:
  /// **'Themes stay on this phone. There is no export.'**
  String get appearanceNoExport;

  /// Row for the chat wallpaper (not available yet)
  ///
  /// In en, this message translates to:
  /// **'Wallpaper'**
  String get appearanceWallpaper;

  /// Slider label for picture wallpaper (not available yet)
  ///
  /// In en, this message translates to:
  /// **'Dim'**
  String get appearanceDim;

  /// Slider label for picture wallpaper (not available yet)
  ///
  /// In en, this message translates to:
  /// **'Blur'**
  String get appearanceBlur;

  /// Sample incoming message in the live preview
  ///
  /// In en, this message translates to:
  /// **'Is everyone still in for Saturday?'**
  String get previewTheirs;

  /// Sample outgoing message in the live preview
  ///
  /// In en, this message translates to:
  /// **'Great, I\'ll bring the cake'**
  String get previewMine;

  /// Switch title
  ///
  /// In en, this message translates to:
  /// **'Use the phone\'s own font'**
  String get textSystemFont;

  /// Switch subtitle
  ///
  /// In en, this message translates to:
  /// **'Matches your system. Off = SIS font'**
  String get textSystemFontHint;

  /// Section label
  ///
  /// In en, this message translates to:
  /// **'Chat text size'**
  String get textChatSize;

  /// Section label
  ///
  /// In en, this message translates to:
  /// **'App text size'**
  String get textAppSize;

  /// Sample line for the app text size
  ///
  /// In en, this message translates to:
  /// **'Settings and chat list text'**
  String get textAppSample;

  /// Text size
  ///
  /// In en, this message translates to:
  /// **'Small'**
  String get textSmall;

  /// Text size
  ///
  /// In en, this message translates to:
  /// **'Medium'**
  String get textMedium;

  /// Text size
  ///
  /// In en, this message translates to:
  /// **'Large'**
  String get textLarge;

  /// Language option: follow the phone
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get languageSystem;

  /// Subtitle of the System language option
  ///
  /// In en, this message translates to:
  /// **'Follows the phone'**
  String get languageSystemHint;

  /// Language option, written in its own language
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get languageEnglish;

  /// Language option, written in its own language
  ///
  /// In en, this message translates to:
  /// **'Türkçe'**
  String get languageTurkish;

  /// Long-press card on a chat row: expandable mute row
  ///
  /// In en, this message translates to:
  /// **'Mute'**
  String get chatMenuMute;

  /// Long-press card: ends a chat's mute
  ///
  /// In en, this message translates to:
  /// **'Unmute'**
  String get chatMenuUnmute;

  /// Long-press card: pin row
  ///
  /// In en, this message translates to:
  /// **'Pin chat'**
  String get chatMenuPin;

  /// Pill revealed by swiping a chat row in the chat list
  ///
  /// In en, this message translates to:
  /// **'Archive'**
  String get chatArchive;

  /// Pill revealed by swiping a chat row on the Archived screen
  ///
  /// In en, this message translates to:
  /// **'Unarchive'**
  String get chatUnarchive;

  /// Row above the chat list (pull down to reveal) and title of the Archived screen
  ///
  /// In en, this message translates to:
  /// **'Archived chats'**
  String get archivedChatsTitle;

  /// Subtitle of the Archived screen: how many chats are archived
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 chat} other{{count} chats}}'**
  String archivedChatsCount(int count);

  /// Note at the top of the Archived screen
  ///
  /// In en, this message translates to:
  /// **'Archived chats stay archived when a new message arrives. No sound, no push, no badge.'**
  String get archivedChatsHint;

  /// Archived screen with nothing in it
  ///
  /// In en, this message translates to:
  /// **'No archived chats'**
  String get archivedChatsEmpty;

  /// Screen-reader label of the bell on a muted chat row
  ///
  /// In en, this message translates to:
  /// **'Muted'**
  String get chatMutedLabel;

  /// Mute length choice
  ///
  /// In en, this message translates to:
  /// **'1 hour'**
  String get muteOneHour;

  /// Mute length choice
  ///
  /// In en, this message translates to:
  /// **'8 hours'**
  String get muteEightHours;

  /// Mute length choice
  ///
  /// In en, this message translates to:
  /// **'1 day'**
  String get muteOneDay;

  /// Mute length choice
  ///
  /// In en, this message translates to:
  /// **'3 days'**
  String get muteThreeDays;

  /// Mute length choice
  ///
  /// In en, this message translates to:
  /// **'1 week'**
  String get muteOneWeek;

  /// Group info: section label
  ///
  /// In en, this message translates to:
  /// **'Group settings'**
  String get groupSettingsTitle;

  /// Group info: greyed setting
  ///
  /// In en, this message translates to:
  /// **'Members can change the group picture'**
  String get groupPickSwitch;

  /// Group info: greyed setting
  ///
  /// In en, this message translates to:
  /// **'Members can add people'**
  String get groupAddSwitch;

  /// Group info: greyed setting
  ///
  /// In en, this message translates to:
  /// **'New members see earlier messages'**
  String get groupHistSwitch;

  /// Group info: greyed setting row
  ///
  /// In en, this message translates to:
  /// **'Who may pin messages'**
  String get groupPinWho;

  /// Group info: greyed admin button
  ///
  /// In en, this message translates to:
  /// **'Delete group for everyone'**
  String get groupDeleteForAll;

  /// Delete group confirm card title
  ///
  /// In en, this message translates to:
  /// **'Delete {name} for everyone?'**
  String groupDeleteTitle(String name);

  /// Delete group confirm card text
  ///
  /// In en, this message translates to:
  /// **'All messages and photos in this group are gone for everyone. This cannot be undone.'**
  String get groupDeleteBody;

  /// Notice after the group was deleted by an admin
  ///
  /// In en, this message translates to:
  /// **'Group deleted'**
  String get groupDeletedNotice;

  /// Group info: leave button and confirm button
  ///
  /// In en, this message translates to:
  /// **'Leave group'**
  String get groupLeave;

  /// Leave confirm card title
  ///
  /// In en, this message translates to:
  /// **'Leave group?'**
  String get groupLeaveTitle;

  /// Leave confirm card text
  ///
  /// In en, this message translates to:
  /// **'The group stays for the others. You can be added again.'**
  String get groupLeaveBody;

  /// Leave confirm card cancel
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get groupLeaveCancel;

  /// Crop screen title
  ///
  /// In en, this message translates to:
  /// **'Crop picture'**
  String get cropTitle;

  /// Crop screen confirm button
  ///
  /// In en, this message translates to:
  /// **'Choose'**
  String get cropChoose;

  /// Crop screen preview label
  ///
  /// In en, this message translates to:
  /// **'Preview'**
  String get cropPreview;

  /// Crop screen preview text
  ///
  /// In en, this message translates to:
  /// **'This is how the picture shows up'**
  String get cropPreviewHint;

  /// Crop screen gesture hint
  ///
  /// In en, this message translates to:
  /// **'Pinch to zoom, drag to move'**
  String get cropGestureHint;

  /// Notice after leaving a group
  ///
  /// In en, this message translates to:
  /// **'Left the group'**
  String get groupLeftNotice;

  /// Notice after leaving a group when queued messages were dropped
  ///
  /// In en, this message translates to:
  /// **'Left the group. Unsent messages weren\'t sent.'**
  String get groupLeftUnsentNotice;

  /// Attach card tile under the composer
  ///
  /// In en, this message translates to:
  /// **'Photo'**
  String get attachPhoto;

  /// Attach card tile under the composer
  ///
  /// In en, this message translates to:
  /// **'Video'**
  String get attachVideo;

  /// Attach card tile under the composer
  ///
  /// In en, this message translates to:
  /// **'File'**
  String get attachFile;

  /// Attach card tile under the composer
  ///
  /// In en, this message translates to:
  /// **'Voice'**
  String get attachVoice;

  /// Attach card tile under the composer
  ///
  /// In en, this message translates to:
  /// **'Location'**
  String get attachLocation;

  /// Attach card tile under the composer
  ///
  /// In en, this message translates to:
  /// **'Contact'**
  String get attachContact;

  /// Attach card tile under the composer
  ///
  /// In en, this message translates to:
  /// **'Poll'**
  String get attachPoll;

  /// Sign-in button, iPhone only
  ///
  /// In en, this message translates to:
  /// **'Sign in with Apple'**
  String get signInWithApple;

  /// New chat page row
  ///
  /// In en, this message translates to:
  /// **'Find people from contacts'**
  String get findFromContacts;

  /// Share picker caption box
  ///
  /// In en, this message translates to:
  /// **'Add a caption'**
  String get pickerAddCaption;

  /// Picker top row
  ///
  /// In en, this message translates to:
  /// **'New chat'**
  String get pickerNewChat;

  /// Picker section header
  ///
  /// In en, this message translates to:
  /// **'Recent'**
  String get pickerRecent;

  /// Heading of a What's new card in the SIS chat
  ///
  /// In en, this message translates to:
  /// **'Version {version}'**
  String whatsNewVersion(String version);

  /// Mark above the SIS chat's footer when no update is waiting
  ///
  /// In en, this message translates to:
  /// **'You\'re up to date'**
  String get whatsNewUpToDate;

  /// Long-press card row: reply
  ///
  /// In en, this message translates to:
  /// **'Reply'**
  String get messageActionReply;

  /// Long-press card row: copy the text
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get messageActionCopy;

  /// Long-press card row: forward
  ///
  /// In en, this message translates to:
  /// **'Forward'**
  String get messageActionForward;

  /// Long-press card row: edit an own message
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get messageActionEdit;

  /// Long-press card row: pin
  ///
  /// In en, this message translates to:
  /// **'Pin message'**
  String get messageActionPin;

  /// Long-press card row: unpin
  ///
  /// In en, this message translates to:
  /// **'Unpin message'**
  String get messageActionUnpin;

  /// Long-press card: unpin row
  ///
  /// In en, this message translates to:
  /// **'Unpin chat'**
  String get chatMenuUnpin;

  /// Notice when a sixth chat is pinned
  ///
  /// In en, this message translates to:
  /// **'You can pin up to 5 chats.'**
  String get chatPinLimit;

  /// Chat line when someone pins a message
  ///
  /// In en, this message translates to:
  /// **'{name} pinned a message'**
  String eventPinned(String name);

  /// Bar under the chat header
  ///
  /// In en, this message translates to:
  /// **'Pinned message'**
  String get pinnedBarTitle;

  /// Pinned bar text when the message is only a photo
  ///
  /// In en, this message translates to:
  /// **'Photo'**
  String get pinnedBarPhoto;

  /// Who may pin messages: value
  ///
  /// In en, this message translates to:
  /// **'All members'**
  String get groupPinAll;

  /// Who may pin messages: value
  ///
  /// In en, this message translates to:
  /// **'Admins only'**
  String get groupPinAdmins;

  /// Chat list section header
  ///
  /// In en, this message translates to:
  /// **'Pinned'**
  String get listPinnedHeader;

  /// Chat list section header
  ///
  /// In en, this message translates to:
  /// **'Chats'**
  String get listChatsHeader;

  /// Long-press card row: hide on my devices only
  ///
  /// In en, this message translates to:
  /// **'Delete for me'**
  String get messageActionDeleteForMe;

  /// Long-press card row: remove for everyone in the chat
  ///
  /// In en, this message translates to:
  /// **'Delete for everyone'**
  String get messageActionDeleteForEveryone;

  /// Pill above a tapped own message: how many members have read it
  ///
  /// In en, this message translates to:
  /// **'Seen by {count}'**
  String messageSeenBy(int count);

  /// Screen-reader label of the plus button on the reactions bar
  ///
  /// In en, this message translates to:
  /// **'More reactions'**
  String get messageMoreReactions;

  /// Delete confirm card: title
  ///
  /// In en, this message translates to:
  /// **'Delete message?'**
  String get messageDeleteTitle;

  /// Delete confirm card: body for Delete for me
  ///
  /// In en, this message translates to:
  /// **'It is hidden on your devices only.'**
  String get messageDeleteForMeBody;

  /// Delete confirm card: body for Delete for everyone
  ///
  /// In en, this message translates to:
  /// **'It is removed for everyone in this chat.'**
  String get messageDeleteForEveryoneBody;

  /// Delete confirm card: cancel
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get messageDeleteCancel;

  /// Retry button after something failed to load
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get commonTryAgain;

  /// Name shown for a member who has no display name
  ///
  /// In en, this message translates to:
  /// **'Member'**
  String get commonMember;

  /// Name shown when a person in an event line is unknown
  ///
  /// In en, this message translates to:
  /// **'Someone'**
  String get commonSomeone;

  /// Settings title or tooltip
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get commonSettings;

  /// Notifications title
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get commonNotifications;

  /// Sound label
  ///
  /// In en, this message translates to:
  /// **'Sound'**
  String get commonSound;

  /// Vibration label
  ///
  /// In en, this message translates to:
  /// **'Vibration'**
  String get commonVibration;

  /// Section header above the list of people the member already knows
  ///
  /// In en, this message translates to:
  /// **'Your people'**
  String get commonYourPeople;

  /// Empty result of a people search
  ///
  /// In en, this message translates to:
  /// **'Nobody found'**
  String get commonNobodyFound;

  /// Button and page title to start a group
  ///
  /// In en, this message translates to:
  /// **'New group'**
  String get commonNewGroup;

  /// Message label or text field hint
  ///
  /// In en, this message translates to:
  /// **'Message'**
  String get commonMessage;

  /// Photo gallery button
  ///
  /// In en, this message translates to:
  /// **'Gallery'**
  String get commonGallery;

  /// Add people to a group
  ///
  /// In en, this message translates to:
  /// **'Add members'**
  String get commonAddMembers;

  /// Save button
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get commonSave;

  /// Continue button
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get commonContinue;

  /// Settings row and page title for privacy
  ///
  /// In en, this message translates to:
  /// **'Privacy'**
  String get settingsPrivacy;

  /// Settings row and page title for the account
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get settingsAccount;

  /// Settings row and page title for the About page
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get settingsAbout;

  /// Title of the profile settings page
  ///
  /// In en, this message translates to:
  /// **'Profile'**
  String get settingsProfile;

  /// Notice after the profile was saved
  ///
  /// In en, this message translates to:
  /// **'Saved'**
  String get settingsSaved;

  /// Notice after the profile picture was removed
  ///
  /// In en, this message translates to:
  /// **'Profile picture removed'**
  String get settingsPictureRemoved;

  /// Notice after the profile picture was changed
  ///
  /// In en, this message translates to:
  /// **'Profile picture updated'**
  String get settingsPictureUpdated;

  /// Privacy switch for the online status
  ///
  /// In en, this message translates to:
  /// **'Show when I am online'**
  String get settingsShowOnline;

  /// Privacy switch for the typing indicator
  ///
  /// In en, this message translates to:
  /// **'Show when I am typing'**
  String get settingsShowTyping;

  /// Privacy switch for last seen
  ///
  /// In en, this message translates to:
  /// **'Show my last seen'**
  String get settingsShowLastSeen;

  /// Explains the last seen switch
  ///
  /// In en, this message translates to:
  /// **'While this is off, you can\'t see anyone else\'s either.'**
  String get settingsShowLastSeenHint;

  /// Privacy switch for read receipts
  ///
  /// In en, this message translates to:
  /// **'Show when I have read messages'**
  String get settingsShowRead;

  /// Explains the read receipts switch
  ///
  /// In en, this message translates to:
  /// **'While this is off, you can\'t see when others read yours.'**
  String get settingsShowReadHint;

  /// Heading above the profile picture audience options
  ///
  /// In en, this message translates to:
  /// **'Profile picture visibility'**
  String get settingsAvatarVisibility;

  /// Profile picture audience: everyone
  ///
  /// In en, this message translates to:
  /// **'Everyone'**
  String get settingsAvatarEveryone;

  /// Explains the everyone option
  ///
  /// In en, this message translates to:
  /// **'Anyone who can see your profile'**
  String get settingsAvatarEveryoneHint;

  /// Profile picture audience: saved contacts
  ///
  /// In en, this message translates to:
  /// **'My contacts'**
  String get settingsAvatarContacts;

  /// Explains the contacts option
  ///
  /// In en, this message translates to:
  /// **'Only people you have saved'**
  String get settingsAvatarContactsHint;

  /// Profile picture audience: nobody
  ///
  /// In en, this message translates to:
  /// **'Nobody'**
  String get settingsAvatarNobody;

  /// Explains the nobody option
  ///
  /// In en, this message translates to:
  /// **'Only you -- others see your initials'**
  String get settingsAvatarNobodyHint;

  /// Label above the signed-in email
  ///
  /// In en, this message translates to:
  /// **'Signed in with Google as'**
  String get settingsSignedInAs;

  /// Shown when the email is not known
  ///
  /// In en, this message translates to:
  /// **'Unknown account'**
  String get settingsUnknownAccount;

  /// Sign out button
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get settingsSignOut;

  /// Installed app version on the About page
  ///
  /// In en, this message translates to:
  /// **'Version {name} ({build})'**
  String settingsVersion(String name, int build);

  /// Short app tagline on the sign-in and About pages
  ///
  /// In en, this message translates to:
  /// **'Stay in sync'**
  String get appTagline;

  /// Row that opens the licences page
  ///
  /// In en, this message translates to:
  /// **'Open-source licences'**
  String get settingsLicences;

  /// Subtitle of the master notifications switch
  ///
  /// In en, this message translates to:
  /// **'New messages when the app is closed'**
  String get notifSwitchHint;

  /// Header above the notification preview options
  ///
  /// In en, this message translates to:
  /// **'On the lock screen'**
  String get notifLockScreen;

  /// Preview option: sender and text shown
  ///
  /// In en, this message translates to:
  /// **'Name and message'**
  String get notifPreviewFull;

  /// Preview option: only the sender shown
  ///
  /// In en, this message translates to:
  /// **'Only who it is from'**
  String get notifPreviewSender;

  /// Preview option: nothing shown
  ///
  /// In en, this message translates to:
  /// **'No details'**
  String get notifPreviewNone;

  /// Sample notification text under the name-and-message option
  ///
  /// In en, this message translates to:
  /// **'Ayşe: See you at 8'**
  String get notifSampleFull;

  /// Sample notification text under the sender-only option
  ///
  /// In en, this message translates to:
  /// **'Ayşe: New message'**
  String get notifSampleSender;

  /// Sample notification text under the no-details option
  ///
  /// In en, this message translates to:
  /// **'SIS: New message'**
  String get notifSampleNone;

  /// Empty state of the muted list
  ///
  /// In en, this message translates to:
  /// **'Nothing is muted'**
  String get notifNothingMuted;

  /// Name of a muted chat that is no longer in the list
  ///
  /// In en, this message translates to:
  /// **'A chat'**
  String get notifAChat;

  /// Title of the mute row on a chat or person page
  ///
  /// In en, this message translates to:
  /// **'Mute notifications'**
  String get notifMuteTitle;

  /// A mute with no end
  ///
  /// In en, this message translates to:
  /// **'Always'**
  String get muteAlways;

  /// Mute ends later today
  ///
  /// In en, this message translates to:
  /// **'Until {time}'**
  String muteUntilToday(String time);

  /// Mute ends tomorrow
  ///
  /// In en, this message translates to:
  /// **'Until tomorrow {time}'**
  String muteUntilTomorrow(String time);

  /// Mute ends on a later day
  ///
  /// In en, this message translates to:
  /// **'Until {date} {time}'**
  String muteUntilDate(DateTime date, String time);

  /// Header of the alert defaults section
  ///
  /// In en, this message translates to:
  /// **'Sound and vibration'**
  String get alertSoundAndVibration;

  /// Subtitle of the sound switch
  ///
  /// In en, this message translates to:
  /// **'Play a sound for new messages'**
  String get alertSoundHint;

  /// Row that picks the notification tone
  ///
  /// In en, this message translates to:
  /// **'Tone'**
  String get alertTone;

  /// Tone name when none was picked
  ///
  /// In en, this message translates to:
  /// **'System default'**
  String get alertToneDefault;

  /// Subtitle of the vibration switch
  ///
  /// In en, this message translates to:
  /// **'Vibrate for new messages'**
  String get alertVibrationHint;

  /// Per-chat alert choice: follow the defaults
  ///
  /// In en, this message translates to:
  /// **'Default'**
  String get alertChoiceDefault;

  /// Per-chat alert choice: on
  ///
  /// In en, this message translates to:
  /// **'On'**
  String get alertChoiceOn;

  /// Per-chat alert choice: off
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get alertChoiceOff;

  /// Headline of the notification permission explainer
  ///
  /// In en, this message translates to:
  /// **'SIS will tell you about new messages'**
  String get notifExplainerTitle;

  /// Name shown for the signed-in member in their own messages and quotes
  ///
  /// In en, this message translates to:
  /// **'You'**
  String get commonYou;

  /// Fallback title of a group, or the subtitle of a group in a list
  ///
  /// In en, this message translates to:
  /// **'Group'**
  String get commonGroup;

  /// Send button
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get commonSend;

  /// Remove button or tooltip
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get commonRemove;

  /// Skip button
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get commonSkip;

  /// Hint of the search field above a list of people
  ///
  /// In en, this message translates to:
  /// **'Search your people'**
  String get commonSearchPeople;

  /// Label on a forwarded message and notice after forwarding
  ///
  /// In en, this message translates to:
  /// **'Forwarded'**
  String get commonForwarded;

  /// Shown where a picture could not be loaded
  ///
  /// In en, this message translates to:
  /// **'Image unavailable'**
  String get commonImageUnavailable;

  /// Notice when more than 10 photos were picked
  ///
  /// In en, this message translates to:
  /// **'Only the first 10 photos were sent.'**
  String get composerPhotoLimit;

  /// Footer of the read-only SIS chat
  ///
  /// In en, this message translates to:
  /// **'Only SIS can post here'**
  String get composerReadOnlySystem;

  /// Footer of a group the member has left or was removed from
  ///
  /// In en, this message translates to:
  /// **'You\'re no longer in this group'**
  String get composerLeftGroup;

  /// Tooltip of the photo button in the composer
  ///
  /// In en, this message translates to:
  /// **'Send a photo'**
  String get composerSendPhoto;

  /// Title of the reply bar above the composer
  ///
  /// In en, this message translates to:
  /// **'Replying to {name}'**
  String composerReplyingTo(String name);

  /// Tooltip of the close button on the reply bar
  ///
  /// In en, this message translates to:
  /// **'Cancel reply'**
  String get composerCancelReply;

  /// Title of the edit bar above the composer
  ///
  /// In en, this message translates to:
  /// **'Editing message'**
  String get composerEditing;

  /// Tooltip of the close button on the edit bar
  ///
  /// In en, this message translates to:
  /// **'Cancel edit'**
  String get composerCancelEdit;

  /// Quoted message that can no longer be found
  ///
  /// In en, this message translates to:
  /// **'Original message'**
  String get quoteOriginal;

  /// Placeholder for a deleted message, in a quote and in the chat
  ///
  /// In en, this message translates to:
  /// **'This message was deleted'**
  String get quoteDeleted;

  /// A quoted message that is only a photo
  ///
  /// In en, this message translates to:
  /// **'📷 Photo'**
  String get quotePhoto;

  /// Preview line of a conversation with no messages
  ///
  /// In en, this message translates to:
  /// **'No messages yet'**
  String get listNoMessages;

  /// Preview line when the member wrote the last message
  ///
  /// In en, this message translates to:
  /// **'You: {message}'**
  String listYouPrefix(String message);

  /// Empty state of the conversation list
  ///
  /// In en, this message translates to:
  /// **'No conversations yet.\nStart one with New chat.'**
  String get listEmpty;

  /// Hint of the search field on the conversation list
  ///
  /// In en, this message translates to:
  /// **'Search messages'**
  String get listSearchHint;

  /// No result for a message search
  ///
  /// In en, this message translates to:
  /// **'No messages found'**
  String get listNoResults;

  /// Fallback title of a conversation without a name
  ///
  /// In en, this message translates to:
  /// **'Conversation'**
  String get listConversation;

  /// Header status while the other person types
  ///
  /// In en, this message translates to:
  /// **'typing…'**
  String get statusTyping;

  /// Group header status while several people type
  ///
  /// In en, this message translates to:
  /// **'{count} people are typing…'**
  String statusPeopleTyping(int count);

  /// Group header status while one person types
  ///
  /// In en, this message translates to:
  /// **'{name} is typing…'**
  String statusWhoTyping(String name);

  /// Header status of a person who is online
  ///
  /// In en, this message translates to:
  /// **'online'**
  String get statusOnline;

  /// Last seen less than a minute ago
  ///
  /// In en, this message translates to:
  /// **'last seen just now'**
  String get lastSeenJustNow;

  /// Last seen within the hour
  ///
  /// In en, this message translates to:
  /// **'last seen {minutes} min ago'**
  String lastSeenMinutes(int minutes);

  /// Last seen earlier today
  ///
  /// In en, this message translates to:
  /// **'last seen today at {time}'**
  String lastSeenToday(String time);

  /// Last seen yesterday
  ///
  /// In en, this message translates to:
  /// **'last seen yesterday at {time}'**
  String lastSeenYesterday(String time);

  /// Last seen on an older date
  ///
  /// In en, this message translates to:
  /// **'last seen {date}'**
  String lastSeenDate(String date);

  /// Empty state of a conversation
  ///
  /// In en, this message translates to:
  /// **'No messages yet. Say something.'**
  String get messageEmpty;

  /// Notice after adding members
  ///
  /// In en, this message translates to:
  /// **'Added to the group'**
  String get addMembersDone;

  /// Empty state of the add members page
  ///
  /// In en, this message translates to:
  /// **'Nobody left to add'**
  String get addMembersNoneTitle;

  /// Explains the empty state of the add members page
  ///
  /// In en, this message translates to:
  /// **'Everyone in your people list is already in this group.'**
  String get addMembersNoneBody;

  /// Switch on the add members page
  ///
  /// In en, this message translates to:
  /// **'Show earlier messages'**
  String get addMembersOldTitle;

  /// Explains the old messages switch
  ///
  /// In en, this message translates to:
  /// **'New member sees history'**
  String get addMembersOldHint;

  /// Note on the add members page for a non-admin: the group switch decides about history
  ///
  /// In en, this message translates to:
  /// **'Group admin sets whether new members see earlier messages'**
  String get addMembersAdminDecides;

  /// Label of the add button while it works
  ///
  /// In en, this message translates to:
  /// **'Adding…'**
  String get addMembersAdding;

  /// Add button on the add members page
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get addMembersAdd;

  /// Add button with the number of chosen people
  ///
  /// In en, this message translates to:
  /// **'Add ({count})'**
  String addMembersAddCount(int count);

  /// Notice after saving a person as a contact
  ///
  /// In en, this message translates to:
  /// **'Added to contacts'**
  String get contactAdded;

  /// Notice after removing a contact
  ///
  /// In en, this message translates to:
  /// **'Removed from contacts'**
  String get contactRemoved;

  /// Button that saves a person as a contact
  ///
  /// In en, this message translates to:
  /// **'Add to contacts'**
  String get contactAdd;

  /// Button that removes a contact
  ///
  /// In en, this message translates to:
  /// **'Remove from contacts'**
  String get contactRemove;

  /// Hint of the tag search on the new chat page
  ///
  /// In en, this message translates to:
  /// **'Find by exact tag'**
  String get newChatTagHint;

  /// No person found for the tag
  ///
  /// In en, this message translates to:
  /// **'Nobody has that tag'**
  String get newChatNoTag;

  /// Header above the person found by tag
  ///
  /// In en, this message translates to:
  /// **'Found'**
  String get newChatFound;

  /// Button that opens a chat with the person found
  ///
  /// In en, this message translates to:
  /// **'Chat'**
  String get newChatChat;

  /// Empty state of the new chat page
  ///
  /// In en, this message translates to:
  /// **'Nobody yet — find someone by their tag'**
  String get newChatEmpty;

  /// Notice after forwarding to several chats
  ///
  /// In en, this message translates to:
  /// **'Forwarded to {count} chats'**
  String forwardDoneMany(int count);

  /// Title of the forward page
  ///
  /// In en, this message translates to:
  /// **'Forward to'**
  String get forwardTitle;

  /// Hint of the search field on the forward page
  ///
  /// In en, this message translates to:
  /// **'Search chats and people'**
  String get forwardSearch;

  /// Label before the preview of the message being forwarded
  ///
  /// In en, this message translates to:
  /// **'Forwarding: '**
  String get forwardPrefix;

  /// Header above people on the forward page
  ///
  /// In en, this message translates to:
  /// **'People'**
  String get forwardPeople;

  /// No result on the forward page
  ///
  /// In en, this message translates to:
  /// **'Nothing found'**
  String get forwardNothing;

  /// Send button with the number of chosen chats
  ///
  /// In en, this message translates to:
  /// **'Send ({count})'**
  String forwardSendCount(int count);

  /// Picture menu: use the camera
  ///
  /// In en, this message translates to:
  /// **'Take photo'**
  String get avatarTakePhoto;

  /// Picture menu: pick from the gallery
  ///
  /// In en, this message translates to:
  /// **'Choose from library'**
  String get avatarChoose;

  /// Picture menu: remove the picture
  ///
  /// In en, this message translates to:
  /// **'Remove picture'**
  String get avatarRemove;

  /// Notice when the camera fails
  ///
  /// In en, this message translates to:
  /// **'The camera could not take a photo.'**
  String get cameraFailed;

  /// Label of the group name field
  ///
  /// In en, this message translates to:
  /// **'Group name'**
  String get newGroupName;

  /// Empty state of the new group page
  ///
  /// In en, this message translates to:
  /// **'Nobody else has signed in yet'**
  String get newGroupNobody;

  /// Button that creates the group
  ///
  /// In en, this message translates to:
  /// **'Create group'**
  String get newGroupCreate;

  /// Notice after removing a member
  ///
  /// In en, this message translates to:
  /// **'{name} removed'**
  String membersRemoved(String name);

  /// Notice after making a member admin
  ///
  /// In en, this message translates to:
  /// **'{name} is now an admin'**
  String membersNowAdmin(String name);

  /// Notice after removing admin rights
  ///
  /// In en, this message translates to:
  /// **'{name} is no longer an admin'**
  String membersNoLongerAdmin(String name);

  /// Empty state of the members tab
  ///
  /// In en, this message translates to:
  /// **'No members'**
  String get membersEmpty;

  /// The signed-in member's own row in the members tab
  ///
  /// In en, this message translates to:
  /// **'{name} (you)'**
  String membersYou(String name);

  /// Badge of an admin
  ///
  /// In en, this message translates to:
  /// **'Admin'**
  String get membersAdmin;

  /// Menu action
  ///
  /// In en, this message translates to:
  /// **'Remove as admin'**
  String get membersRemoveAdmin;

  /// Menu action
  ///
  /// In en, this message translates to:
  /// **'Make admin'**
  String get membersMakeAdmin;

  /// Badge of a member who left
  ///
  /// In en, this message translates to:
  /// **'Left'**
  String get membersLeft;

  /// Badge of a member who was removed
  ///
  /// In en, this message translates to:
  /// **'Removed'**
  String get membersRemovedBadge;

  /// Placeholder of a message an admin deleted
  ///
  /// In en, this message translates to:
  /// **'Deleted by an admin'**
  String get bubbleDeletedByAdmin;

  /// Mark on an edited message
  ///
  /// In en, this message translates to:
  /// **'edited {time}'**
  String bubbleEdited(String time);

  /// Empty state of the links tab
  ///
  /// In en, this message translates to:
  /// **'No links shared yet'**
  String get linksEmpty;

  /// Notice when a link cannot be opened
  ///
  /// In en, this message translates to:
  /// **'Could not open {host}'**
  String linkOpenFailed(String host);

  /// Empty state of the media tab
  ///
  /// In en, this message translates to:
  /// **'No photos shared yet'**
  String get mediaEmpty;

  /// Group event line
  ///
  /// In en, this message translates to:
  /// **'{name} left'**
  String eventLeft(String name);

  /// Group event line
  ///
  /// In en, this message translates to:
  /// **'{name} was removed'**
  String eventRemoved(String name);

  /// Group event line
  ///
  /// In en, this message translates to:
  /// **'{name} changed the group picture'**
  String eventPictureChanged(String name);

  /// Group event line
  ///
  /// In en, this message translates to:
  /// **'{name} was added'**
  String eventAdded(String name);

  /// Tooltip on the photo preview
  ///
  /// In en, this message translates to:
  /// **'Remove this photo'**
  String get previewRemovePhoto;

  /// Subtitle on the SIS chat page
  ///
  /// In en, this message translates to:
  /// **'What\'s new in the app'**
  String get systemChatSubtitle;

  /// Position in the photo viewer
  ///
  /// In en, this message translates to:
  /// **'{index} of {total}'**
  String viewerCounter(int index, int total);

  /// Tooltip of the photo viewer menu button
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get viewerMore;

  /// Hint of the in-chat search field
  ///
  /// In en, this message translates to:
  /// **'Search in this chat'**
  String get searchInChat;

  /// No result in the in-chat search
  ///
  /// In en, this message translates to:
  /// **'No results'**
  String get searchNoResults;

  /// Notice after copying a message
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get messageCopied;

  /// Notice when a picked photo cannot be opened
  ///
  /// In en, this message translates to:
  /// **'That photo could not be opened.'**
  String get photoOpenFailed;

  /// Notice when a photo cannot be cropped
  ///
  /// In en, this message translates to:
  /// **'That photo could not be used.'**
  String get cropUnusable;

  /// Screen-reader label of the area that closes a menu
  ///
  /// In en, this message translates to:
  /// **'Close menu'**
  String get menuClose;

  /// Notice
  ///
  /// In en, this message translates to:
  /// **'Group picture removed'**
  String get groupPictureRemoved;

  /// Notice
  ///
  /// In en, this message translates to:
  /// **'Group picture updated'**
  String get groupPictureUpdated;

  /// Member count under the group name
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 member} other{{count} members}}'**
  String groupMemberCount(int count);

  /// Tab of the group page
  ///
  /// In en, this message translates to:
  /// **'Members'**
  String get groupTabMembers;

  /// Tab of the group page
  ///
  /// In en, this message translates to:
  /// **'Media'**
  String get groupTabMedia;

  /// Tab of the group page
  ///
  /// In en, this message translates to:
  /// **'Links'**
  String get groupTabLinks;

  /// Notice in the attach sheet
  ///
  /// In en, this message translates to:
  /// **'Could not load more photos.'**
  String get attachLoadMoreFailed;

  /// Notice when the photo limit is reached
  ///
  /// In en, this message translates to:
  /// **'You can send up to {count} photos at once.'**
  String attachLimit(int count);

  /// Notice
  ///
  /// In en, this message translates to:
  /// **'Those photos could not be opened.'**
  String get attachOpenFailedMany;

  /// Notice
  ///
  /// In en, this message translates to:
  /// **'Some photos could not be opened.'**
  String get attachOpenFailedSome;

  /// Notice
  ///
  /// In en, this message translates to:
  /// **'That could not be opened.'**
  String get attachOpenFailed;

  /// Header of the photo grid
  ///
  /// In en, this message translates to:
  /// **'Recent photos'**
  String get attachRecentPhotos;

  /// Button that widens the photo access
  ///
  /// In en, this message translates to:
  /// **'Allow more'**
  String get attachAllowMore;

  /// Empty photo grid
  ///
  /// In en, this message translates to:
  /// **'No photos yet'**
  String get attachNoPhotos;

  /// Send button of the attach sheet
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Send 1 photo} other{Send {count} photos}}'**
  String attachSendPhotos(int count);

  /// Title of the photo permission prompt
  ///
  /// In en, this message translates to:
  /// **'Send photos faster'**
  String get attachFasterTitle;

  /// Explains the photo permission prompt
  ///
  /// In en, this message translates to:
  /// **'Allow access so your gallery loads right here – nothing is uploaded until you send it.'**
  String get attachFasterBody;

  /// Button when the permission was denied for good
  ///
  /// In en, this message translates to:
  /// **'Open settings'**
  String get attachOpenSettings;

  /// Button that asks for photo access
  ///
  /// In en, this message translates to:
  /// **'Allow photos'**
  String get attachAllowPhotos;

  /// Button that dismisses the prompt
  ///
  /// In en, this message translates to:
  /// **'Not now'**
  String get attachNotNow;

  /// Camera tile in the attach sheet
  ///
  /// In en, this message translates to:
  /// **'Camera'**
  String get attachCamera;

  /// Title of the first-run screen
  ///
  /// In en, this message translates to:
  /// **'Welcome'**
  String get onboardingWelcome;

  /// Heading of the first-run screen
  ///
  /// In en, this message translates to:
  /// **'How should others see you?'**
  String get onboardingHeading;

  /// Explains that name and tag can be changed later
  ///
  /// In en, this message translates to:
  /// **'You can change both later in Settings.'**
  String get onboardingHint;

  /// Tag field status while checking
  ///
  /// In en, this message translates to:
  /// **'Checking…'**
  String get tagChecking;

  /// Tag field status
  ///
  /// In en, this message translates to:
  /// **'@{tag} is available'**
  String tagFree(String tag);

  /// Tag field status
  ///
  /// In en, this message translates to:
  /// **'@{tag} is taken'**
  String tagTaken(String tag);

  /// Tag field status
  ///
  /// In en, this message translates to:
  /// **'Could not check availability'**
  String get tagUnknown;

  /// Label of the display name field
  ///
  /// In en, this message translates to:
  /// **'Display name'**
  String get profileDisplayName;

  /// Helper under the display name field
  ///
  /// In en, this message translates to:
  /// **'Shown to other members. Need not be unique.'**
  String get profileDisplayNameHint;

  /// Label of the tag field
  ///
  /// In en, this message translates to:
  /// **'Tag'**
  String get profileTag;

  /// Helper under the tag field
  ///
  /// In en, this message translates to:
  /// **'Unique. Letters, digits and _; 3 to 20.'**
  String get profileTagHint;

  /// Sign-in screen description
  ///
  /// In en, this message translates to:
  /// **'Private messages for the people on your list.'**
  String get signInBody;

  /// Google sign-in button
  ///
  /// In en, this message translates to:
  /// **'Continue with Google'**
  String get signInGoogle;

  /// Sign-in screen footnote
  ///
  /// In en, this message translates to:
  /// **'Only invited Google accounts can sign in.'**
  String get signInInvitedOnly;

  /// Title of the screen for an account that is not approved
  ///
  /// In en, this message translates to:
  /// **'Access denied'**
  String get statusDeniedTitle;

  /// Body of the access denied screen
  ///
  /// In en, this message translates to:
  /// **'This Google account is not currently approved for SIS.'**
  String get statusDeniedBody;

  /// Title of the connection error screen
  ///
  /// In en, this message translates to:
  /// **'Could not connect'**
  String get statusConnectTitle;

  /// Title of the start-up error screen
  ///
  /// In en, this message translates to:
  /// **'Could not start SIS'**
  String get statusStartTitle;

  /// Body of the start-up error screen
  ///
  /// In en, this message translates to:
  /// **'Restart the app. If it keeps failing, reinstall it.\n\n{reason}'**
  String statusStartBody(String reason);

  /// Update banner
  ///
  /// In en, this message translates to:
  /// **'Update available'**
  String get updateAvailable;

  /// Update banner: dismiss
  ///
  /// In en, this message translates to:
  /// **'Later'**
  String get updateLater;

  /// Update banner: start the download
  ///
  /// In en, this message translates to:
  /// **'Update'**
  String get updateAction;

  /// Update banner while downloading
  ///
  /// In en, this message translates to:
  /// **'Downloading update…'**
  String get updateDownloading;

  /// Update banner when the download is done
  ///
  /// In en, this message translates to:
  /// **'Ready to install'**
  String get updateReady;

  /// Update banner: install and restart
  ///
  /// In en, this message translates to:
  /// **'Restart'**
  String get updateRestart;

  /// Title of the blocking update screen
  ///
  /// In en, this message translates to:
  /// **'Update required'**
  String get updateRequiredTitle;

  /// Body of the blocking update screen
  ///
  /// In en, this message translates to:
  /// **'This version ({installed}) is no longer supported (minimum {minimum}).'**
  String updateRequiredBody(int installed, int minimum);

  /// Button on the blocking update screen
  ///
  /// In en, this message translates to:
  /// **'Update now'**
  String get updateNow;

  /// Number of licences of a package
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 licence} other{{count} licences}}'**
  String licencesCount(int count);

  /// Fallback title for a chat whose name is not known yet
  ///
  /// In en, this message translates to:
  /// **'Conversation'**
  String get commonConversation;

  /// Reason shown on the start-up error screen when start-up itself failed
  ///
  /// In en, this message translates to:
  /// **'SIS could not start. Please try again.'**
  String get statusStartBootstrap;

  /// Menu card row on a custom theme
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get appearanceRename;

  /// Menu card row on a theme
  ///
  /// In en, this message translates to:
  /// **'Duplicate'**
  String get appearanceDuplicate;

  /// Menu card row on a custom theme
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get appearanceDelete;

  /// Cancel button of the rename card
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get appearanceCancel;

  /// Title of the rename card
  ///
  /// In en, this message translates to:
  /// **'Rename theme'**
  String get appearanceRenameTitle;

  /// Hint of the theme name field
  ///
  /// In en, this message translates to:
  /// **'Theme name'**
  String get appearanceThemeName;

  /// Screen-reader label of the dots button on a custom theme
  ///
  /// In en, this message translates to:
  /// **'Theme options'**
  String get appearanceThemeMenu;

  /// Name given to a duplicated theme
  ///
  /// In en, this message translates to:
  /// **'{name} copy'**
  String appearanceCopyName(String name);

  /// Title of the new theme card
  ///
  /// In en, this message translates to:
  /// **'Create a new theme'**
  String get appearanceCreateTheme;

  /// Create button of the new theme card
  ///
  /// In en, this message translates to:
  /// **'Create'**
  String get appearanceCreate;

  /// Shown when the new theme name is empty
  ///
  /// In en, this message translates to:
  /// **'Name cannot be empty'**
  String get appearanceNameEmpty;

  /// Hint of the new theme name field
  ///
  /// In en, this message translates to:
  /// **'My theme'**
  String get appearanceThemePlaceholder;

  /// Theme editor tab
  ///
  /// In en, this message translates to:
  /// **'Accent Color'**
  String get themeTabAccent;

  /// Theme editor tab
  ///
  /// In en, this message translates to:
  /// **'Background'**
  String get themeTabBackground;

  /// Theme editor tab
  ///
  /// In en, this message translates to:
  /// **'My Messages'**
  String get themeTabMyMessages;

  /// Theme editor accent tab label
  ///
  /// In en, this message translates to:
  /// **'Pick an accent color'**
  String get themePickAccent;

  /// Theme editor background tab label
  ///
  /// In en, this message translates to:
  /// **'Pick background color'**
  String get themePickBackground;

  /// Theme editor my messages tab label
  ///
  /// In en, this message translates to:
  /// **'Pick my message bubble color'**
  String get themePickMine;

  /// Theme editor warning
  ///
  /// In en, this message translates to:
  /// **'Accent may be hard to read. Consider a darker shade.'**
  String get themeLowContrast;

  /// Theme editor mode switch label
  ///
  /// In en, this message translates to:
  /// **'Appearance mode'**
  String get themeModeLabel;

  /// Theme editor mode
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get themeModeLight;

  /// Theme editor mode
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get themeModeDark;

  /// Theme editor mode, follows the phone
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get themeModeAuto;

  /// Theme editor reset button
  ///
  /// In en, this message translates to:
  /// **'Reset to default'**
  String get themeReset;

  /// Screen-reader label of a colour swatch
  ///
  /// In en, this message translates to:
  /// **'Colour {hex}'**
  String themeSwatch(String hex);

  /// Wallpaper tab
  ///
  /// In en, this message translates to:
  /// **'Colour'**
  String get wallpaperColour;

  /// Wallpaper tab
  ///
  /// In en, this message translates to:
  /// **'Gradient'**
  String get wallpaperGradient;

  /// Wallpaper tab
  ///
  /// In en, this message translates to:
  /// **'Picture'**
  String get wallpaperPicture;

  /// Button to pick a wallpaper photo
  ///
  /// In en, this message translates to:
  /// **'Choose photo'**
  String get wallpaperChoosePhoto;

  /// Shown when the chosen wallpaper photo could not be read
  ///
  /// In en, this message translates to:
  /// **'That photo could not be used. Try another.'**
  String get wallpaperPickFailed;

  /// Row at the bottom of the wallpaper page; opens the confirm card
  ///
  /// In en, this message translates to:
  /// **'Reset Chat Backgrounds'**
  String get wallpaperReset;

  /// Info line under the reset row
  ///
  /// In en, this message translates to:
  /// **'Remove all uploaded chat backgrounds and restore the pre-installed ones.'**
  String get wallpaperResetInfo;

  /// Title of the reset confirm card
  ///
  /// In en, this message translates to:
  /// **'Reset chat backgrounds'**
  String get wallpaperResetTitle;

  /// Question on the reset confirm card
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to reset all chat backgrounds?'**
  String get wallpaperResetConfirm;

  /// Confirm button of the reset card
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get wallpaperResetAction;

  /// Tooltip of the pin button in the selection bar
  ///
  /// In en, this message translates to:
  /// **'Pin'**
  String get chatSelPin;

  /// Selection bar menu: mark the selected chats read
  ///
  /// In en, this message translates to:
  /// **'Mark as read'**
  String get chatSelMarkRead;

  /// Delete button of the selection bar and of the many-chats dialog
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get chatDeleteAction;

  /// Cancel button of the delete-chat dialogs
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get chatDeleteCancel;

  /// Button of the undo bar after deleting chats
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get chatDeleteUndo;

  /// Title and button of the delete dialog for one chat or group
  ///
  /// In en, this message translates to:
  /// **'Delete Chat'**
  String get chatDeleteChat;

  /// Delete dialog for one person; the name between ** is shown bold
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete the chat with **{name}**?'**
  String chatDeleteSure(String name);

  /// Checkbox: delete the chat for the other person too
  ///
  /// In en, this message translates to:
  /// **'Also delete for {name}'**
  String chatDeleteAlso(String name);

  /// Undo bar after deleting one chat
  ///
  /// In en, this message translates to:
  /// **'Chat deleted'**
  String get chatDeletedUndo;

  /// Title of the delete dialog for a group
  ///
  /// In en, this message translates to:
  /// **'Leave Group'**
  String get chatLeaveGroupTitle;

  /// Delete dialog for a group; the name between ** is shown bold
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete and leave the group **{name}**?'**
  String chatDeleteLeaveSure(String name);

  /// Checkbox shown to a group admin
  ///
  /// In en, this message translates to:
  /// **'Delete the group for all members'**
  String get chatDeleteGroupForAll;

  /// Undo bar after deleting a group the member only leaves
  ///
  /// In en, this message translates to:
  /// **'You left the group.'**
  String get chatGroupLeftUndo;

  /// Undo bar after an admin deletes a group for everyone
  ///
  /// In en, this message translates to:
  /// **'Group deleted.'**
  String get chatGroupDeletedUndo;

  /// Title of the delete dialog for several chats
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Delete 1 chat} other{Delete {count} chats}}'**
  String chatDeleteFewTitle(int count);

  /// Body of the delete dialog for several chats
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete selected chats?'**
  String get chatDeleteFewSure;

  /// Checkbox of the several-chats delete dialog
  ///
  /// In en, this message translates to:
  /// **'Delete for both sides where possible'**
  String get chatDeleteBothSides;

  /// Undo bar after deleting several chats
  ///
  /// In en, this message translates to:
  /// **'Chats deleted.'**
  String get chatsDeletedUndo;

  /// Title of the create-poll screen
  ///
  /// In en, this message translates to:
  /// **'New poll'**
  String get pollNewTitle;

  /// Section label above the poll question field
  ///
  /// In en, this message translates to:
  /// **'Question'**
  String get pollQuestionLabel;

  /// Hint inside the poll question field
  ///
  /// In en, this message translates to:
  /// **'Ask a question'**
  String get pollQuestionHint;

  /// Section label above the poll options
  ///
  /// In en, this message translates to:
  /// **'Options'**
  String get pollOptionsLabel;

  /// Hint inside an empty poll option field
  ///
  /// In en, this message translates to:
  /// **'Option'**
  String get pollOptionHint;

  /// Row that adds another poll option
  ///
  /// In en, this message translates to:
  /// **'Add option'**
  String get pollAddOption;

  /// Shown when the poll has the maximum number of options
  ///
  /// In en, this message translates to:
  /// **'You have added the maximum number of options.'**
  String get pollOptionsMax;

  /// Switch: members may pick more than one option
  ///
  /// In en, this message translates to:
  /// **'Allow several answers'**
  String get pollMultipleTitle;

  /// Switch: votes are anonymous
  ///
  /// In en, this message translates to:
  /// **'Anonymous votes'**
  String get pollAnonymousTitle;

  /// Subtitle of the anonymous votes switch
  ///
  /// In en, this message translates to:
  /// **'Nobody sees who voted for what'**
  String get pollAnonymousSubtitle;

  /// Button that sends the new poll
  ///
  /// In en, this message translates to:
  /// **'Send poll'**
  String get pollSend;

  /// Title of the leave-create-poll confirmation
  ///
  /// In en, this message translates to:
  /// **'Discard poll?'**
  String get pollDiscardTitle;

  /// Body of the leave-create-poll confirmation
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to discard this poll?'**
  String get pollDiscardBody;

  /// Confirm button of the leave-create-poll confirmation
  ///
  /// In en, this message translates to:
  /// **'Discard'**
  String get pollDiscardConfirm;

  /// Cancel button of the leave-create-poll confirmation
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get pollDiscardCancel;

  /// Subtitle of an anonymous poll bubble
  ///
  /// In en, this message translates to:
  /// **'Anonymous poll'**
  String get pollTypeAnonymous;

  /// Subtitle of a public poll bubble
  ///
  /// In en, this message translates to:
  /// **'Poll'**
  String get pollTypePublic;

  /// Subtitle of a closed poll bubble
  ///
  /// In en, this message translates to:
  /// **'Final results'**
  String get pollTypeClosed;

  /// Vote count in a poll bubble footer
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 vote} other{{count} votes}}'**
  String pollVotes(int count);

  /// Footer of a poll bubble nobody voted in
  ///
  /// In en, this message translates to:
  /// **'No votes'**
  String get pollNoVotes;

  /// Button that submits the chosen options of a several-answers poll
  ///
  /// In en, this message translates to:
  /// **'Vote'**
  String get pollVoteButton;

  /// Button that opens who voted for what
  ///
  /// In en, this message translates to:
  /// **'View votes ({count})'**
  String pollViewVotes(int count);

  /// Title of the voters list
  ///
  /// In en, this message translates to:
  /// **'Poll results'**
  String get pollResultsTitle;

  /// Votes of one option in the voters list
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 vote} other{{count} votes}}'**
  String pollOptionVoters(int count);

  /// Message menu: take your vote back
  ///
  /// In en, this message translates to:
  /// **'Retract vote'**
  String get messageActionRetractVote;

  /// Message menu: close your own poll
  ///
  /// In en, this message translates to:
  /// **'Stop poll'**
  String get messageActionStopPoll;

  /// Title of the stop-poll confirmation
  ///
  /// In en, this message translates to:
  /// **'Stop poll?'**
  String get pollStopTitle;

  /// Body of the stop-poll confirmation
  ///
  /// In en, this message translates to:
  /// **'If you stop this poll now, nobody will be able to vote in it anymore. This action cannot be undone.'**
  String get pollStopBody;

  /// Confirm button of the stop-poll confirmation
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get pollStopConfirm;

  /// Cancel button of the stop-poll confirmation
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get pollStopCancel;

  /// Notice when voting in a poll that was just closed
  ///
  /// In en, this message translates to:
  /// **'This poll is closed.'**
  String get pollClosedNotice;

  /// Chat list preview of a poll message
  ///
  /// In en, this message translates to:
  /// **'📊 Poll: {question}'**
  String pollPreviewLine(String question);
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'tr'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'tr':
      return AppLocalizationsTr();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
