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

  /// Long-press card: pin row (greyed, not built yet)
  ///
  /// In en, this message translates to:
  /// **'Pin chat'**
  String get chatMenuPin;

  /// Pill revealed by swiping a chat row (greyed, not built yet)
  ///
  /// In en, this message translates to:
  /// **'Archive'**
  String get chatArchive;

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

  /// Long-press card row: pin (greyed, not built yet)
  ///
  /// In en, this message translates to:
  /// **'Pin message'**
  String get messageActionPin;

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
