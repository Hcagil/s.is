// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Turkish (`tr`).
class AppLocalizationsTr extends AppLocalizations {
  AppLocalizationsTr([String locale = 'tr']) : super(locale);

  @override
  String get deliverySending => 'Gönderiliyor';

  @override
  String get deliverySent => 'Gönderildi';

  @override
  String get deliveryDelivered => 'Teslim edildi';

  @override
  String get deliveryRead => 'Okundu';

  @override
  String get settingsAppearance => 'Görünüm';

  @override
  String get settingsTextSize => 'Yazı boyutu';

  @override
  String get settingsLanguage => 'Dil';

  @override
  String get settingsAutoDownload => 'Otomatik indirme';

  @override
  String get themeViolet => 'Mor';

  @override
  String get themeOcean => 'Okyanus';

  @override
  String get themeForest => 'Orman';

  @override
  String get themeSunset => 'Gün batımı';

  @override
  String get themeGraphite => 'Grafit';

  @override
  String get themeRose => 'Gül';

  @override
  String get appearanceBuiltIn => 'Hazır temalar';

  @override
  String get appearanceMyThemes => 'Temalarım';

  @override
  String get appearanceNewTheme => 'Yeni tema';

  @override
  String get appearanceNoExport =>
      'Temalar bu telefonda kalır. Dışa aktarma yoktur.';

  @override
  String get appearanceWallpaper => 'Duvar kağıdı';

  @override
  String get appearanceDim => 'Karartma';

  @override
  String get appearanceBlur => 'Bulanıklık';

  @override
  String get previewTheirs => 'Cumartesi için herkes hâlâ var mı?';

  @override
  String get previewMine => 'Harika, pastayı ben getiririm';

  @override
  String get textSystemFont => 'Telefonun kendi yazı tipini kullan';

  @override
  String get textSystemFontHint =>
      'Sisteminle aynı olur. Kapalıyken SIS yazı tipi kullanılır';

  @override
  String get textChatSize => 'Sohbet yazı boyutu';

  @override
  String get textAppSize => 'Uygulama yazı boyutu';

  @override
  String get textAppSample => 'Ayarlar ve sohbet listesi yazısı';

  @override
  String get textSmall => 'Küçük';

  @override
  String get textMedium => 'Orta';

  @override
  String get textLarge => 'Büyük';

  @override
  String get languageSystem => 'Sistem';

  @override
  String get languageSystemHint => 'Telefonu izler';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageTurkish => 'Türkçe';

  @override
  String get chatMenuMute => 'Sessize al';

  @override
  String get chatMenuUnmute => 'Sesi aç';

  @override
  String get chatMenuPin => 'Sohbeti sabitle';

  @override
  String get chatArchive => 'Arşivle';

  @override
  String get chatUnarchive => 'Arşivden çıkar';

  @override
  String get archivedChatsTitle => 'Arşivlenen sohbetler';

  @override
  String archivedChatsCount(int count) {
    return '$count sohbet';
  }

  @override
  String get archivedChatsHint =>
      'Yeni mesaj gelse de arşivlenen sohbetler arşivde kalır. Ses, bildirim ve rozet yok.';

  @override
  String get archivedChatsEmpty => 'Arşivlenmiş sohbet yok';

  @override
  String get chatMutedLabel => 'Sessiz';

  @override
  String get muteOneHour => '1 saat';

  @override
  String get muteEightHours => '8 saat';

  @override
  String get muteOneDay => '1 gün';

  @override
  String get muteThreeDays => '3 gün';

  @override
  String get muteOneWeek => '1 hafta';

  @override
  String get groupSettingsTitle => 'Grup ayarları';

  @override
  String get groupPickSwitch => 'Üyeler grup resmini değiştirebilir';

  @override
  String get groupAddSwitch => 'Üyeler kişi ekleyebilir';

  @override
  String get groupHistSwitch => 'Yeni üyeler önceki mesajları görür';

  @override
  String get groupPinWho => 'Mesajları kimler sabitleyebilir';

  @override
  String get groupDeleteForAll => 'Grubu herkes için sil';

  @override
  String groupDeleteTitle(String name) {
    return '$name herkes için silinsin mi?';
  }

  @override
  String get groupDeleteBody =>
      'Bu gruptaki tüm mesajlar ve fotoğraflar herkes için silinir. Geri alınamaz.';

  @override
  String get groupDeletedNotice => 'Grup silindi';

  @override
  String get groupLeave => 'Gruptan ayrıl';

  @override
  String get groupLeaveTitle => 'Gruptan ayrılsın mı?';

  @override
  String get groupLeaveBody =>
      'Grup diğerleri için kalır. Tekrar eklenebilirsin.';

  @override
  String get groupLeaveCancel => 'Vazgeç';

  @override
  String get cropTitle => 'Resmi kırp';

  @override
  String get cropChoose => 'Seç';

  @override
  String get cropPreview => 'Önizleme';

  @override
  String get cropPreviewHint => 'Resim böyle görünecek';

  @override
  String get cropGestureHint =>
      'Yakınlaştırmak için sıkıştır, taşımak için sürükle';

  @override
  String get groupLeftNotice => 'Gruptan ayrıldın';

  @override
  String get groupLeftUnsentNotice =>
      'Gruptan ayrıldın. Gönderilmeyen mesajlar gönderilmedi.';

  @override
  String get attachPhoto => 'Fotoğraf';

  @override
  String get attachVideo => 'Video';

  @override
  String get attachFile => 'Dosya';

  @override
  String get attachVoice => 'Ses';

  @override
  String get attachLocation => 'Konum';

  @override
  String get attachContact => 'Kişi';

  @override
  String get attachPoll => 'Anket';

  @override
  String get signInWithApple => 'Apple ile giriş yap';

  @override
  String get findFromContacts => 'Kişilerinden insanları bul';

  @override
  String get pickerAddCaption => 'Alt yazı ekle';

  @override
  String get pickerNewChat => 'Yeni sohbet';

  @override
  String get pickerRecent => 'Son kullanılanlar';

  @override
  String whatsNewVersion(String version) {
    return 'Sürüm $version';
  }

  @override
  String get whatsNewUpToDate => 'Güncelsiniz';

  @override
  String get messageActionReply => 'Yanıtla';

  @override
  String get messageActionCopy => 'Kopyala';

  @override
  String get messageActionForward => 'İlet';

  @override
  String get messageActionEdit => 'Düzenle';

  @override
  String get messageActionPin => 'Mesajı sabitle';

  @override
  String get messageActionUnpin => 'Mesajın sabitlemesini kaldır';

  @override
  String get chatMenuUnpin => 'Sohbeti sabitlemeyi kaldır';

  @override
  String get chatPinLimit => 'En fazla 5 sohbet sabitleyebilirsin.';

  @override
  String eventPinned(String name) {
    return '$name bir mesajı sabitledi';
  }

  @override
  String get pinnedBarTitle => 'Sabitlenmiş mesaj';

  @override
  String get pinnedBarPhoto => 'Fotoğraf';

  @override
  String get groupPinAll => 'Tüm üyeler';

  @override
  String get groupPinAdmins => 'Yalnızca yöneticiler';

  @override
  String get listPinnedHeader => 'Sabitlenenler';

  @override
  String get listChatsHeader => 'Sohbetler';

  @override
  String get messageActionDeleteForMe => 'Benim için sil';

  @override
  String get messageActionDeleteForEveryone => 'Herkes için sil';

  @override
  String messageSeenBy(int count) {
    return '$count kişi gördü';
  }

  @override
  String get messageMoreReactions => 'Daha fazla tepki';

  @override
  String get messageDeleteTitle => 'Mesaj silinsin mi?';

  @override
  String get messageDeleteForMeBody => 'Yalnızca senin cihazlarında gizlenir.';

  @override
  String get messageDeleteForEveryoneBody =>
      'Bu sohbetteki herkes için kaldırılır.';

  @override
  String get messageDeleteCancel => 'Vazgeç';

  @override
  String get commonTryAgain => 'Tekrar dene';

  @override
  String get commonMember => 'Üye';

  @override
  String get commonSomeone => 'Biri';

  @override
  String get commonSettings => 'Ayarlar';

  @override
  String get commonNotifications => 'Bildirimler';

  @override
  String get commonSound => 'Ses';

  @override
  String get commonVibration => 'Titreşim';

  @override
  String get commonYourPeople => 'Kişilerin';

  @override
  String get commonNobodyFound => 'Kimse bulunamadı';

  @override
  String get commonNewGroup => 'Yeni grup';

  @override
  String get commonMessage => 'Mesaj';

  @override
  String get commonGallery => 'Galeri';

  @override
  String get commonAddMembers => 'Üye ekle';

  @override
  String get commonSave => 'Kaydet';

  @override
  String get commonContinue => 'Devam';

  @override
  String get settingsPrivacy => 'Gizlilik';

  @override
  String get settingsAccount => 'Hesap';

  @override
  String get settingsAbout => 'Hakkında';

  @override
  String get settingsProfile => 'Profil';

  @override
  String get settingsSaved => 'Kaydedildi';

  @override
  String get settingsPictureRemoved => 'Profil fotoğrafı kaldırıldı';

  @override
  String get settingsPictureUpdated => 'Profil fotoğrafı güncellendi';

  @override
  String get settingsShowOnline => 'Çevrimiçi olduğumu göster';

  @override
  String get settingsShowTyping => 'Yazdığımı göster';

  @override
  String get settingsShowLastSeen => 'Son görülmemi göster';

  @override
  String get settingsShowLastSeenHint =>
      'Bu kapalıyken sen de kimsenin son görülmesini göremezsin.';

  @override
  String get settingsShowRead => 'Mesajları okuduğumu göster';

  @override
  String get settingsShowReadHint =>
      'Bu kapalıyken başkalarının senin mesajlarını ne zaman okuduğunu göremezsin.';

  @override
  String get settingsAvatarVisibility => 'Profil fotoğrafını kimler görsün';

  @override
  String get settingsAvatarEveryone => 'Herkes';

  @override
  String get settingsAvatarEveryoneHint => 'Profilini görebilen herkes';

  @override
  String get settingsAvatarContacts => 'Kişilerim';

  @override
  String get settingsAvatarContactsHint => 'Yalnızca kaydettiğin kişiler';

  @override
  String get settingsAvatarNobody => 'Hiç kimse';

  @override
  String get settingsAvatarNobodyHint =>
      'Yalnızca sen -- diğerleri baş harflerini görür';

  @override
  String get settingsSignedInAs => 'Google ile giriş yapılan hesap';

  @override
  String get settingsUnknownAccount => 'Bilinmeyen hesap';

  @override
  String get settingsSignOut => 'Çıkış yap';

  @override
  String settingsVersion(String name, int build) {
    return 'Sürüm $name ($build)';
  }

  @override
  String get appTagline => 'Hep bağlantıda kal';

  @override
  String get settingsLicences => 'Açık kaynak lisansları';

  @override
  String get notifSwitchHint => 'Uygulama kapalıyken yeni mesajlar';

  @override
  String get notifLockScreen => 'Kilit ekranında';

  @override
  String get notifPreviewFull => 'Ad ve mesaj';

  @override
  String get notifPreviewSender => 'Yalnızca kimden geldiği';

  @override
  String get notifPreviewNone => 'Ayrıntı yok';

  @override
  String get notifSampleFull => 'Ayşe: 8\'de görüşürüz';

  @override
  String get notifSampleSender => 'Ayşe: Yeni mesaj';

  @override
  String get notifSampleNone => 'SIS: Yeni mesaj';

  @override
  String get notifNothingMuted => 'Sessize alınan bir şey yok';

  @override
  String get notifAChat => 'Bir sohbet';

  @override
  String get notifMuteTitle => 'Bildirimleri sessize al';

  @override
  String get muteAlways => 'Süresiz';

  @override
  String muteUntilToday(String time) {
    return '$time saatine kadar';
  }

  @override
  String muteUntilTomorrow(String time) {
    return 'Yarın $time saatine kadar';
  }

  @override
  String muteUntilDate(DateTime date, String time) {
    final intl.DateFormat dateDateFormat = intl.DateFormat.MMMd(localeName);
    final String dateString = dateDateFormat.format(date);

    return '$dateString $time saatine kadar';
  }

  @override
  String get alertSoundAndVibration => 'Ses ve titreşim';

  @override
  String get alertSoundHint => 'Yeni mesajlarda ses çal';

  @override
  String get alertTone => 'Zil sesi';

  @override
  String get alertToneDefault => 'Sistem varsayılanı';

  @override
  String get alertVibrationHint => 'Yeni mesajlarda titret';

  @override
  String get alertChoiceDefault => 'Varsayılan';

  @override
  String get alertChoiceOn => 'Açık';

  @override
  String get alertChoiceOff => 'Kapalı';

  @override
  String get notifExplainerTitle => 'SIS yeni mesajlardan seni haberdar edecek';

  @override
  String get commonYou => 'Sen';

  @override
  String get commonGroup => 'Grup';

  @override
  String get commonSend => 'Gönder';

  @override
  String get commonRemove => 'Çıkar';

  @override
  String get commonSkip => 'Atla';

  @override
  String get commonSearchPeople => 'Kişilerinde ara';

  @override
  String get commonForwarded => 'İletildi';

  @override
  String get commonImageUnavailable => 'Görsel kullanılamıyor';

  @override
  String get composerPhotoLimit => 'Yalnızca ilk 10 fotoğraf gönderildi.';

  @override
  String get composerReadOnlySystem => 'Burada yalnızca SIS yazabilir';

  @override
  String get composerLeftGroup => 'Artık bu grubun üyesi değilsin';

  @override
  String get composerSendPhoto => 'Fotoğraf gönder';

  @override
  String composerReplyingTo(String name) {
    return '$name kişisine yanıt';
  }

  @override
  String get composerCancelReply => 'Yanıtı iptal et';

  @override
  String get composerEditing => 'Mesaj düzenleniyor';

  @override
  String get composerCancelEdit => 'Düzenlemeyi iptal et';

  @override
  String get quoteOriginal => 'Asıl mesaj';

  @override
  String get quoteDeleted => 'Bu mesaj silindi';

  @override
  String get quotePhoto => '📷 Fotoğraf';

  @override
  String get listNoMessages => 'Henüz mesaj yok';

  @override
  String listYouPrefix(String message) {
    return 'Sen: $message';
  }

  @override
  String get listEmpty => 'Henüz sohbet yok.\nYeni sohbet ile başla.';

  @override
  String get listSearchHint => 'Mesajlarda ara';

  @override
  String get listNoResults => 'Mesaj bulunamadı';

  @override
  String get listConversation => 'Sohbet';

  @override
  String get statusTyping => 'yazıyor…';

  @override
  String statusPeopleTyping(int count) {
    return '$count kişi yazıyor…';
  }

  @override
  String statusWhoTyping(String name) {
    return '$name yazıyor…';
  }

  @override
  String get statusOnline => 'çevrimiçi';

  @override
  String get lastSeenJustNow => 'az önce görüldü';

  @override
  String lastSeenMinutes(int minutes) {
    return '$minutes dk önce görüldü';
  }

  @override
  String lastSeenToday(String time) {
    return 'bugün $time görüldü';
  }

  @override
  String lastSeenYesterday(String time) {
    return 'dün $time görüldü';
  }

  @override
  String lastSeenDate(String date) {
    return '$date görüldü';
  }

  @override
  String get messageEmpty => 'Henüz mesaj yok. Bir şey yaz.';

  @override
  String get addMembersDone => 'Gruba eklendi';

  @override
  String get addMembersNoneTitle => 'Eklenecek kimse kalmadı';

  @override
  String get addMembersNoneBody => 'Kişilerindeki herkes zaten bu grupta.';

  @override
  String get addMembersOldTitle => 'Önceki mesajları göster';

  @override
  String get addMembersOldHint => 'Yeni üye geçmişi görür';

  @override
  String get addMembersAdminDecides =>
      'Yeni üyeler önceki mesajları görecekler mi, grup yöneticisi belirler';

  @override
  String get addMembersAdding => 'Ekleniyor…';

  @override
  String get addMembersAdd => 'Ekle';

  @override
  String addMembersAddCount(int count) {
    return 'Ekle ($count)';
  }

  @override
  String get contactAdded => 'Kişilere eklendi';

  @override
  String get contactRemoved => 'Kişilerden çıkarıldı';

  @override
  String get contactAdd => 'Kişilere ekle';

  @override
  String get contactRemove => 'Kişilerden çıkar';

  @override
  String get newChatTagHint => 'Tam etiketle bul';

  @override
  String get newChatNoTag => 'Bu etikette kimse yok';

  @override
  String get newChatFound => 'Bulundu';

  @override
  String get newChatChat => 'Sohbet';

  @override
  String get newChatEmpty => 'Henüz kimse yok — etiketiyle birini bul';

  @override
  String forwardDoneMany(int count) {
    return '$count sohbete iletildi';
  }

  @override
  String get forwardTitle => 'İlet';

  @override
  String get forwardSearch => 'Sohbetlerde ve kişilerde ara';

  @override
  String get forwardPrefix => 'İletiliyor: ';

  @override
  String get forwardPeople => 'Kişiler';

  @override
  String get forwardNothing => 'Hiçbir şey bulunamadı';

  @override
  String forwardSendCount(int count) {
    return 'Gönder ($count)';
  }

  @override
  String get avatarTakePhoto => 'Fotoğraf çek';

  @override
  String get avatarChoose => 'Galeriden seç';

  @override
  String get avatarRemove => 'Fotoğrafı kaldır';

  @override
  String get cameraFailed => 'Kamera fotoğraf çekemedi.';

  @override
  String get newGroupName => 'Grup adı';

  @override
  String get newGroupNobody => 'Henüz başka kimse giriş yapmadı';

  @override
  String get newGroupCreate => 'Grubu oluştur';

  @override
  String membersRemoved(String name) {
    return '$name çıkarıldı';
  }

  @override
  String membersNowAdmin(String name) {
    return '$name artık yönetici';
  }

  @override
  String membersNoLongerAdmin(String name) {
    return '$name artık yönetici değil';
  }

  @override
  String get membersEmpty => 'Üye yok';

  @override
  String membersYou(String name) {
    return '$name (sen)';
  }

  @override
  String get membersAdmin => 'Yönetici';

  @override
  String get membersRemoveAdmin => 'Yöneticiliği al';

  @override
  String get membersMakeAdmin => 'Yönetici yap';

  @override
  String get membersLeft => 'Ayrıldı';

  @override
  String get membersRemovedBadge => 'Çıkarıldı';

  @override
  String get bubbleDeletedByAdmin => 'Yönetici tarafından silindi';

  @override
  String bubbleEdited(String time) {
    return 'düzenlendi $time';
  }

  @override
  String get linksEmpty => 'Henüz paylaşılan bağlantı yok';

  @override
  String linkOpenFailed(String host) {
    return '$host açılamadı';
  }

  @override
  String get mediaEmpty => 'Henüz paylaşılan fotoğraf yok';

  @override
  String eventLeft(String name) {
    return '$name ayrıldı';
  }

  @override
  String eventRemoved(String name) {
    return '$name çıkarıldı';
  }

  @override
  String eventPictureChanged(String name) {
    return '$name grup resmini değiştirdi';
  }

  @override
  String eventAdded(String name) {
    return '$name eklendi';
  }

  @override
  String get previewRemovePhoto => 'Bu fotoğrafı kaldır';

  @override
  String get systemChatSubtitle => 'Uygulamadaki yenilikler';

  @override
  String viewerCounter(int index, int total) {
    return '$index / $total';
  }

  @override
  String get viewerMore => 'Daha fazla';

  @override
  String get searchInChat => 'Bu sohbette ara';

  @override
  String get searchNoResults => 'Sonuç yok';

  @override
  String get messageCopied => 'Kopyalandı';

  @override
  String get photoOpenFailed => 'Bu fotoğraf açılamadı.';

  @override
  String get cropUnusable => 'Bu fotoğraf kullanılamadı.';

  @override
  String get menuClose => 'Menüyü kapat';

  @override
  String get groupPictureRemoved => 'Grup fotoğrafı kaldırıldı';

  @override
  String get groupPictureUpdated => 'Grup fotoğrafı güncellendi';

  @override
  String groupMemberCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count üye',
    );
    return '$_temp0';
  }

  @override
  String get groupTabMembers => 'Üyeler';

  @override
  String get groupTabMedia => 'Medya';

  @override
  String get groupTabLinks => 'Bağlantılar';

  @override
  String get attachLoadMoreFailed => 'Daha fazla fotoğraf yüklenemedi.';

  @override
  String attachLimit(int count) {
    return 'Tek seferde en fazla $count fotoğraf gönderebilirsin.';
  }

  @override
  String get attachOpenFailedMany => 'Bu fotoğraflar açılamadı.';

  @override
  String get attachOpenFailedSome => 'Bazı fotoğraflar açılamadı.';

  @override
  String get attachOpenFailed => 'Açılamadı.';

  @override
  String get attachRecentPhotos => 'Son fotoğraflar';

  @override
  String get attachAllowMore => 'Daha fazlasına izin ver';

  @override
  String get attachNoPhotos => 'Henüz fotoğraf yok';

  @override
  String attachSendPhotos(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count fotoğraf gönder',
    );
    return '$_temp0';
  }

  @override
  String get attachFasterTitle => 'Fotoğrafları daha hızlı gönder';

  @override
  String get attachFasterBody =>
      'Galeri burada hemen yüklensin diye erişime izin ver – sen göndermeden hiçbir şey yüklenmez.';

  @override
  String get attachOpenSettings => 'Ayarları aç';

  @override
  String get attachAllowPhotos => 'Fotoğraflara izin ver';

  @override
  String get attachNotNow => 'Şimdi değil';

  @override
  String get attachCamera => 'Kamera';

  @override
  String get onboardingWelcome => 'Hoş geldin';

  @override
  String get onboardingHeading => 'Diğerleri seni nasıl görsün?';

  @override
  String get onboardingHint =>
      'İkisini de sonra Ayarlar\'dan değiştirebilirsin.';

  @override
  String get tagChecking => 'Kontrol ediliyor…';

  @override
  String tagFree(String tag) {
    return '@$tag müsait';
  }

  @override
  String tagTaken(String tag) {
    return '@$tag alınmış';
  }

  @override
  String get tagUnknown => 'Müsaitlik kontrol edilemedi';

  @override
  String get profileDisplayName => 'Görünen ad';

  @override
  String get profileDisplayNameHint =>
      'Diğer üyelere görünür. Benzersiz olması gerekmez.';

  @override
  String get profileTag => 'Etiket';

  @override
  String get profileTagHint => 'Benzersiz. Harf, rakam ve _; 3-20 karakter.';

  @override
  String get signInBody => 'Listendeki kişiler için özel mesajlar.';

  @override
  String get signInGoogle => 'Google ile devam et';

  @override
  String get signInInvitedOnly =>
      'Yalnızca davet edilen Google hesapları giriş yapabilir.';

  @override
  String get statusDeniedTitle => 'Erişim reddedildi';

  @override
  String get statusDeniedBody =>
      'Bu Google hesabı şu an SIS için onaylı değil.';

  @override
  String get statusConnectTitle => 'Bağlanılamadı';

  @override
  String get statusStartTitle => 'SIS başlatılamadı';

  @override
  String statusStartBody(String reason) {
    return 'Uygulamayı yeniden başlat. Yine olmazsa uygulamayı kaldırıp tekrar yükle.\n\n$reason';
  }

  @override
  String get updateAvailable => 'Güncelleme var';

  @override
  String get updateLater => 'Sonra';

  @override
  String get updateAction => 'Güncelle';

  @override
  String get updateDownloading => 'Güncelleme indiriliyor…';

  @override
  String get updateReady => 'Yüklemeye hazır';

  @override
  String get updateRestart => 'Yeniden başlat';

  @override
  String get updateRequiredTitle => 'Güncelleme gerekli';

  @override
  String updateRequiredBody(int installed, int minimum) {
    return 'Bu sürüm ($installed) artık desteklenmiyor (en az $minimum).';
  }

  @override
  String get updateNow => 'Şimdi güncelle';

  @override
  String licencesCount(int count) {
    return '$count lisans';
  }

  @override
  String get commonConversation => 'Sohbet';

  @override
  String get statusStartBootstrap => 'SIS başlatılamadı. Tekrar dene.';

  @override
  String get appearanceRename => 'Yeniden adlandır';

  @override
  String get appearanceDuplicate => 'Çoğalt';

  @override
  String get appearanceDelete => 'Sil';

  @override
  String get appearanceCancel => 'Vazgeç';

  @override
  String get appearanceRenameTitle => 'Temayı yeniden adlandır';

  @override
  String get appearanceThemeName => 'Tema adı';

  @override
  String get appearanceThemeMenu => 'Tema seçenekleri';

  @override
  String appearanceCopyName(String name) {
    return '$name kopyası';
  }

  @override
  String get appearanceCreateTheme => 'Yeni tema oluştur';

  @override
  String get appearanceCreate => 'Oluştur';

  @override
  String get appearanceNameEmpty => 'Ad boş olamaz';

  @override
  String get appearanceThemePlaceholder => 'Ad';

  @override
  String get themeTabAccent => 'Vurgu Rengi';

  @override
  String get themeTabBackground => 'Arka Plan';

  @override
  String get themeTabMyMessages => 'Mesajlarım';

  @override
  String get themePickAccent => 'Bir vurgu rengi seçin';

  @override
  String get themePickBackground => 'Arka plan rengini seçin';

  @override
  String get themePickMine => 'Mesaj balonumun rengini seçin';

  @override
  String get themeLowContrast =>
      'Bu vurgu rengi zor okunabilir. Daha koyu bir ton seçin.';

  @override
  String get themeModeLabel => 'Görünüm modu';

  @override
  String get themeModeLight => 'Açık';

  @override
  String get themeModeDark => 'Koyu';

  @override
  String get themeModeAuto => 'Otomatik';

  @override
  String get themeReset => 'Varsayılana sıfırla';

  @override
  String themeSwatch(String hex) {
    return 'Renk $hex';
  }

  @override
  String get wallpaperColour => 'Renk';

  @override
  String get wallpaperGradient => 'Gradyan';

  @override
  String get wallpaperPicture => 'Resim';

  @override
  String get wallpaperChoosePhoto => 'Fotoğraf seç';

  @override
  String get wallpaperPickFailed =>
      'Bu fotoğraf kullanılamadı. Başka birini dene.';

  @override
  String get wallpaperReset => 'Sohbet Arka Planlarını Sıfırla';

  @override
  String get wallpaperResetInfo =>
      'Yüklenen tüm sohbet arka planlarını kaldır ve önceden yüklenmiş olanları geri getir.';

  @override
  String get wallpaperResetTitle => 'Sohbet arka planlarını sıfırla';

  @override
  String get wallpaperResetConfirm =>
      'Tüm sohbet arka planlarını sıfırlamak istediğine emin misin?';

  @override
  String get wallpaperResetAction => 'Sıfırla';

  @override
  String get chatSelPin => 'Sabitle';

  @override
  String get chatSelMarkRead => 'Okundu olarak işaretle';

  @override
  String get chatDeleteAction => 'Sil';

  @override
  String get chatDeleteCancel => 'İptal et';

  @override
  String get chatDeleteUndo => 'Geri Al';

  @override
  String get chatDeleteChat => 'Sohbeti Sil';

  @override
  String chatDeleteSure(String name) {
    return '**$name** ile olan sohbet kalıcı olarak silinsin mi?';
  }

  @override
  String chatDeleteAlso(String name) {
    return '$name için de sil';
  }

  @override
  String get chatDeletedUndo => 'Sohbet silindi.';

  @override
  String get chatLeaveGroupTitle => 'Gruptan Ayrıl';

  @override
  String chatDeleteLeaveSure(String name) {
    return '**$name** grubunu silmek ve gruptan ayrılmak istediğinizden emin misiniz?';
  }

  @override
  String get chatDeleteGroupForAll => 'Grubu tüm üyeler için sil';

  @override
  String get chatGroupLeftUndo => 'Gruptan ayrıldınız.';

  @override
  String get chatGroupDeletedUndo => 'Grup silindi';

  @override
  String chatDeleteFewTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count sohbet sil',
    );
    return '$_temp0';
  }

  @override
  String get chatDeleteFewSure =>
      'Bu sohbetleri silmek istediğinizden emin misiniz?';

  @override
  String get chatDeleteBothSides => 'Mümkünse her iki taraftan da silin';

  @override
  String get chatsDeletedUndo => 'Sohbetler silindi.';

  @override
  String get pollNewTitle => 'Yeni Anket';

  @override
  String get pollQuestionLabel => 'Soru';

  @override
  String get pollQuestionHint => 'Bir soru sor';

  @override
  String get pollOptionsLabel => 'Seçenekler';

  @override
  String get pollOptionHint => 'Seçenek';

  @override
  String get pollAddOption => 'Bir seçenek ekle…';

  @override
  String get pollOptionsMax => 'En yüksek sayıda seçenek eklediniz.';

  @override
  String get pollMultipleTitle => 'Birden Fazla Cevap';

  @override
  String get pollAnonymousTitle => 'Anonim Oylama';

  @override
  String get pollAnonymousSubtitle => 'Kimin neye oy verdiğini kimse görmez';

  @override
  String get pollSend => 'Anketi gönder';

  @override
  String get pollDiscardTitle => 'Anket silinsin mi?';

  @override
  String get pollDiscardBody => 'Bu anketi silmek istediğinizden emin misiniz?';

  @override
  String get pollDiscardConfirm => 'Sil';

  @override
  String get pollDiscardCancel => 'İptal et';

  @override
  String get pollTypeAnonymous => 'Anonim Anket';

  @override
  String get pollTypePublic => 'Anket';

  @override
  String get pollTypeClosed => 'Kesin Sonuçlar';

  @override
  String pollVotes(int count) {
    return '$count oy';
  }

  @override
  String get pollNoVotes => 'Oy yok';

  @override
  String get pollVoteButton => 'Oy';

  @override
  String pollViewVotes(int count) {
    return 'Oyları Görüntüle ($count)';
  }

  @override
  String get pollResultsTitle => 'Anket Sonuçları';

  @override
  String pollOptionVoters(int count) {
    return '$count oy';
  }

  @override
  String get messageActionRetractVote => 'Oyu Geri Al';

  @override
  String get messageActionStopPoll => 'Anketi Durdur';

  @override
  String get pollStopTitle => 'Anket durdurulsun mu?';

  @override
  String get pollStopBody =>
      'Bu anketi şimdi durdurursanız, artık kimse oy kullanamayacak. Bu işlem geri alınamaz.';

  @override
  String get pollStopConfirm => 'Durdur';

  @override
  String get pollStopCancel => 'İptal et';

  @override
  String get pollClosedNotice => 'Bu anket kapandı.';

  @override
  String pollPreviewLine(String question) {
    return '📊 Anket: $question';
  }

  @override
  String get contactPickerTitle => 'Kişi gönder';

  @override
  String get contactSearchHint => 'Kişilerinde ara';

  @override
  String get contactSend => 'Kişiyi gönder';

  @override
  String get contactAccessTitle => 'Kişilerine erişime izin ver';

  @override
  String get contactAccessBody =>
      'SIS kişilerini yalnızca bu listeyi açtığında ister. Bir kişi göndermeden hiçbir şey yüklenmez.';

  @override
  String get contactAllowAccess => 'Erişime izin ver';

  @override
  String get contactEmpty => 'Telefon numarası olan kişi yok';

  @override
  String get contactNoMatch => 'Aramana uyan kişi yok';

  @override
  String contactPreviewLine(String name) {
    return '👤 Kişi: $name';
  }

  @override
  String get contactPermNote =>
      'Kişiler izni yalnızca bu listeyi açtığında istenir.';

  @override
  String get autoDownloadSection => 'Medya otomatik indirme';

  @override
  String get autoDownloadEnable => 'Etkinleştir';

  @override
  String get autoDownloadWifiOnly => 'Yalnızca Wi-Fi\'de etkinleştir';

  @override
  String get autoDownloadDisabled => 'Devre dışı';

  @override
  String get autoDownloadChoose => 'Neyin indirileceğini seç';

  @override
  String get autoDownloadMobile => 'Mobil veri kullanırken';

  @override
  String get autoDownloadWifi => 'Wi-Fi\'ye bağlıyken';

  @override
  String get autoDownloadRoaming => 'Dolaşımdayken';

  @override
  String get autoDownloadPhotos => 'Fotoğraflar';

  @override
  String get autoDownloadAudio => 'Ses';

  @override
  String get autoDownloadVideos => 'Videolar';

  @override
  String get autoDownloadDocuments => 'Belgeler';

  @override
  String get autoDownloadAllMedia => 'Tüm medya';

  @override
  String get autoDownloadNoMedia => 'Medya yok';

  @override
  String get autoDownloadCancel => 'İptal';

  @override
  String get autoDownloadOk => 'Tamam';

  @override
  String fileTapToDownload(String size) {
    return '$size · İndirmek için dokun';
  }

  @override
  String fileTooBig(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count dosya 50 MB\'ı aşıyor ve gönderilmedi.',
      one: '1 dosya 50 MB\'ı aşıyor ve gönderilmedi.',
    );
    return '$_temp0';
  }

  @override
  String get fileCannotOpen =>
      'Bu telefonda bu dosyayı açabilen bir uygulama yok.';

  @override
  String get filePhotoTapToDownload => 'Fotoğrafı indirmek için dokun';

  @override
  String get videoReviewTitle => 'Videolar';

  @override
  String videoSendCount(int count) {
    return 'Gönder ($count)';
  }

  @override
  String videoCompressing(int percent) {
    return 'Sıkıştırılıyor %$percent';
  }

  @override
  String videoSending(int percent) {
    return 'Gönderiliyor %$percent';
  }

  @override
  String get videoWaitingNetwork => 'Ağ bekleniyor';

  @override
  String get videoWaiting => 'Bekleniyor…';

  @override
  String get videoCancelSend => 'İptal';

  @override
  String videoTooLong(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count video 5 dakikadan uzun olduğu için eklenmedi.',
      one: '1 video 5 dakikadan uzun olduğu için eklenmedi.',
    );
    return '$_temp0';
  }

  @override
  String get videoTooBig => 'Bu video gönderilemeyecek kadar büyük.';

  @override
  String get videoFailed => 'Bu video hazırlanamadı.';

  @override
  String get videoShare => 'Paylaş';

  @override
  String get videoClose => 'Kapat';

  @override
  String get videoMute => 'Sesi kapat';

  @override
  String get videoUnmute => 'Sesi aç';

  @override
  String get videoPlay => 'Oynat';

  @override
  String get videoPause => 'Duraklat';

  @override
  String get videoCannotPlay => 'Bu video oynatılamıyor.';

  @override
  String get videoSelectLabel => 'Videoyu seç';

  @override
  String get videoGridEmpty => 'Henüz video yok';

  @override
  String get videoAccessTitle => 'Videoları burada seç';

  @override
  String get videoAccessBody =>
      'Videoların burada görünmesi için erişime izin ver – sen gönderene kadar hiçbir şey gönderilmez.';

  @override
  String get videoAllow => 'Videolara izin ver';

  @override
  String get videoUsePhonePicker => 'Telefonun seçicisini kullan';

  @override
  String get videoLoadMoreFailed => 'Daha fazla video yüklenemedi.';
}
