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
      'Telefonunuzun yazı tipini kullanır. Kapalıyken SIS kendi yazı tipini kullanır.';

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
  String get archivedChatsTitle => 'Arşivlenmiş sohbetler';

  @override
  String archivedChatsCount(int count) {
    return '$count sohbet';
  }

  @override
  String get archivedChatsHint =>
      'Yeni mesaj gelse de arşivlenen sohbetler arşivde kalır; ses, bildirim ve rozet olmaz.';

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
  String get groupPickSwitch => 'Üyeler grup fotoğrafını değiştirebilir';

  @override
  String get groupAddSwitch => 'Üyeler kişi ekleyebilir';

  @override
  String get groupHistSwitch => 'Yeni üyeler önceki mesajları görür';

  @override
  String get groupPinWho => 'Mesajları kimler sabitleyebilir';

  @override
  String get groupDeletedNotice => 'Grup silindi';

  @override
  String get groupLeave => 'Gruptan ayrıl';

  @override
  String get groupLeaveTitle => 'Gruptan ayrılmak ister misiniz?';

  @override
  String get groupLeaveBody =>
      'Grup diğerleri için kalır. Tekrar eklenebilirsiniz.';

  @override
  String get groupLeaveCancel => 'İptal et';

  @override
  String get cropTitle => 'Fotoğrafı kırp';

  @override
  String get cropChoose => 'Seç';

  @override
  String get cropPreview => 'Önizleme';

  @override
  String get cropPreviewHint => 'Fotoğraf böyle görünecek';

  @override
  String get cropGestureHint =>
      'Yakınlaştırmak için sıkıştırın, taşımak için sürükleyin';

  @override
  String get groupLeftNotice => 'Gruptan ayrıldınız';

  @override
  String get groupLeftUnsentNotice =>
      'Gruptan ayrıldınız. Bekleyen mesajlarınız gönderilmedi.';

  @override
  String get attachPhoto => 'Fotoğraf';

  @override
  String get attachVideo => 'Video';

  @override
  String get attachFile => 'Dosya';

  @override
  String get attachVoice => 'Sesli mesaj';

  @override
  String get attachLocation => 'Konum';

  @override
  String get locationShareTitle => 'Konumu paylaş';

  @override
  String get locationShareCurrent => 'Şu anki konumu paylaş';

  @override
  String get locationShareCurrentSub => 'Şu an bulunduğunuz yeri gönderir';

  @override
  String locationShareAccuracy(int meters) {
    return 'Yaklaşık $meters m doğrulukla';
  }

  @override
  String get locationPickTitle => 'Yer seç';

  @override
  String get locationPickSub => 'İğneyi haritada taşıyın';

  @override
  String get locationPermNote =>
      'Konum izni yalnızca Paylaş\'a dokunduğunuzda istenir';

  @override
  String get locationSearchHint => 'Yer ara';

  @override
  String get locationSendThis => 'Bu yeri gönder';

  @override
  String get locationDenied =>
      'SIS için konum kapalı. Telefon ayarlarından açabilir veya haritadan yer seçebilirsiniz.';

  @override
  String get locationUnavailable =>
      'Konumunuz bulunamadı. Konumunuzun açık olduğundan emin olun.';

  @override
  String get locationPreviewLine => 'Konum';

  @override
  String get locationOpenTitle => 'Haritalar\'da açılsın mı?';

  @override
  String get locationOpen => 'Aç';

  @override
  String get locationCancel => 'İptal et';

  @override
  String get locationOpenFailed =>
      'Bu yeri hiçbir harita uygulaması açamadı. Bir harita uygulaması yükleyip tekrar deneyin.';

  @override
  String get locationNoResults => 'Yer bulunamadı';

  @override
  String get attachContact => 'Kişi';

  @override
  String get attachPoll => 'Anket';

  @override
  String get signInWithApple => 'Apple ile oturum aç';

  @override
  String get signInHiddenEmail =>
      'SIS gerçek e-posta adresinizi gerektirir. Apple ile oturum açarken E-postamı Paylaş\'ı seçip tekrar deneyin.';

  @override
  String get findFromContacts => 'Rehberdeki kişileri bul';

  @override
  String get pickerAddCaption => 'Açıklama ekle';

  @override
  String get pickerNewChat => 'Yeni sohbet';

  @override
  String get pickerRecent => 'Son kullanılanlar';

  @override
  String whatsNewVersion(String version) {
    return 'Sürüm $version';
  }

  @override
  String get whatsNewUpToDate => 'Uygulamanız güncel';

  @override
  String get whatsNewInstalled => 'Yüklü (sürümünüz)';

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
  String get messageActionUnpin => 'Mesaj sabitlemesini kaldır';

  @override
  String get chatMenuUnpin => 'Sabitlemeyi kaldır';

  @override
  String get chatPinLimit =>
      'En fazla 5 sohbet sabitleyebilirsiniz. Yenisini sabitlemek için birinin sabitlemesini kaldırın.';

  @override
  String eventPinned(String name) {
    return '$name bir mesajı sabitledi';
  }

  @override
  String get encryptionRowTitle => 'Şifreleme';

  @override
  String get encryptionRowSubtitle =>
      'Yazılı mesajlar uçtan uca şifrelidir. Doğrulamak için dokunun.';

  @override
  String get securityCodeTitle => 'Güvenlik kodunu doğrula';

  @override
  String securityCodeIntro(String name) {
    return 'Bu kodu $name adlı kişinin telefonundaki kodla yüz yüze veya arayarak karşılaştırın. Aynıysa Eşleşiyor\'a dokunun. Seçiminiz yalnızca bu telefonda saklanır.';
  }

  @override
  String securityCodeChanged(String name) {
    return '$name ile güvenlik kodunuz değişti. Doğrulamak için dokunun.';
  }

  @override
  String securityCodeChangedUnverified(String name) {
    return '$name ile güvenlik kodunuz değişti ve artık doğrulanmış değil. Doğrulamak için dokunun.';
  }

  @override
  String get securityCodeMatches => 'Eşleşiyor';

  @override
  String get securityCodeDiffers => 'Eşleşmiyor';

  @override
  String get securityCodeVerified => 'Doğrulandı';

  @override
  String securityCodeVerifiedNote(String name) {
    return 'Yalnızca bu telefonda saklanır. $name bilgilendirilmez.';
  }

  @override
  String get securityCodeUnverify => 'Doğrulamayı kaldır';

  @override
  String get securityCodeMismatchTitle => 'Kodlar farklı';

  @override
  String securityCodeMismatchBody(String name) {
    return '$name yeni bir telefon aldıysa ya da SIS\'i yeniden yüklediyse böyle olabilir. Biri mesajlarınıza müdahale ediyor da olabilir. Durumu $name ile yüz yüze veya arayarak kontrol edin; emin olana kadar hassas bir şey göndermeyin. Hiçbir şey doğrulanmış olarak işaretlenmedi.';
  }

  @override
  String get securityCodeOk => 'Tamam';

  @override
  String get encryptionRowVerified => 'Doğrulandı';

  @override
  String securityCodeUnavailable(String name) {
    return 'Henüz güvenlik kodu yok. $name ile mesajlaştıktan sonra görünür.';
  }

  @override
  String securityCodeNewPhoneNote(String name) {
    return '$name yeni bir telefon alırsa kod değişir ve yeniden kontrol etmeniz gerekir.';
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
  String get messageActionDeleteForEveryone => 'Herkesten sil';

  @override
  String messageSeenBy(int count) {
    return '$count kişi gördü';
  }

  @override
  String get messageMoreReactions => 'Daha fazla tepki';

  @override
  String get messageDeleteTitle => 'Mesaj silinsin mi?';

  @override
  String get messageDeleteForMeBody => 'Yalnızca sizin için gizlenir.';

  @override
  String get messageDeleteForEveryoneBody =>
      'Bu sohbetteki herkes için kaldırılır.';

  @override
  String get messageDeleteCancel => 'İptal et';

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
  String get commonYourPeople => 'Kişileriniz';

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
      'Bu kapalıyken siz de kimsenin son görülmesini göremezsiniz.';

  @override
  String get settingsShowRead => 'Mesajları okuduğumu göster';

  @override
  String get settingsShowReadHint =>
      'Bu kapalıyken başkalarının mesajlarınızı ne zaman okuduğunu göremezsiniz.';

  @override
  String get settingsAvatarVisibility => 'Profil fotoğrafını kimler görsün';

  @override
  String get settingsAvatarEveryone => 'Herkes';

  @override
  String get settingsAvatarEveryoneHint => 'Profilinizi görebilen herkes';

  @override
  String get settingsAvatarContacts => 'Kişilerim';

  @override
  String get settingsAvatarContactsHint => 'Yalnızca kaydettiğiniz kişiler';

  @override
  String get settingsAvatarNobody => 'Hiç kimse';

  @override
  String get settingsAvatarNobodyHint =>
      'Yalnızca siz. Diğerleri baş harflerinizi görür.';

  @override
  String get settingsSignedInAs => 'Oturum açılan hesap';

  @override
  String get settingsUnknownAccount => 'Bilinmeyen hesap';

  @override
  String get settingsSignOut => 'Oturumu kapat';

  @override
  String settingsVersion(String name) {
    return 'Sürüm $name';
  }

  @override
  String get appTagline => 'Hep bağlantıda kalın';

  @override
  String get settingsLicences => 'Açık kaynak lisansları';

  @override
  String get notifSwitchHint => 'Uygulama kapalıyken yeni mesajlar';

  @override
  String get notifLockScreen => 'Kilit ekranında';

  @override
  String get notifPreviewFull => 'Ad ve mesaj';

  @override
  String get notifPreviewSender => 'Yalnızca gönderen';

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
  String get notifExplainerTitle => 'SIS yeni mesajları size bildirecek';

  @override
  String get commonYou => 'Siz';

  @override
  String get commonGroup => 'Grup';

  @override
  String get commonSend => 'Gönder';

  @override
  String get commonRemove => 'Çıkar';

  @override
  String get commonSkip => 'Atla';

  @override
  String get commonSearchPeople => 'Kişilerde ara';

  @override
  String get commonForwarded => 'İletildi';

  @override
  String get commonImageUnavailable => 'Görsel kullanılamıyor';

  @override
  String get composerPhotoLimit => 'Yalnızca ilk 10 fotoğraf gönderildi.';

  @override
  String get composerReadOnlySystem => 'Burada yalnızca SIS yazabilir';

  @override
  String get composerLeftGroup => 'Artık bu grubun üyesi değilsiniz';

  @override
  String get composerSendPhoto => 'Fotoğraf gönder';

  @override
  String composerReplyingTo(String name) {
    return 'Yanıt: $name';
  }

  @override
  String get composerCancelReply => 'Yanıtı iptal et';

  @override
  String get composerLinkRemove => 'Düz bağlantı olarak gönder';

  @override
  String get linkCardOpen => 'Bağlantıyı aç';

  @override
  String get composerEditing => 'Mesaj düzenleniyor';

  @override
  String get composerCancelEdit => 'Düzenlemeyi iptal et';

  @override
  String get quoteOriginal => 'Asıl mesaj';

  @override
  String get quoteDeleted => 'Bu mesaj silindi';

  @override
  String get quotePhoto => 'Fotoğraf';

  @override
  String quotePhotos(int count) {
    return '$count fotoğraf';
  }

  @override
  String get messageActionDeletePhoto => 'Bu fotoğrafı sil';

  @override
  String get listNoMessages => 'Henüz mesaj yok';

  @override
  String listYouPrefix(String message) {
    return 'Siz: $message';
  }

  @override
  String get listEmpty => 'Henüz sohbet yok.\nYeni sohbet ile başlayın.';

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
  String get lastSeenJustNow => 'son görülme az önce';

  @override
  String lastSeenMinutes(int minutes) {
    return 'son görülme $minutes dk önce';
  }

  @override
  String lastSeenToday(String time) {
    return 'son görülme bugün $time';
  }

  @override
  String lastSeenYesterday(String time) {
    return 'son görülme dün $time';
  }

  @override
  String get dayChipToday => 'Bugün';

  @override
  String seenYesterdayAt(String time) {
    return 'dün $time';
  }

  @override
  String seenDateAt(String date, String time) {
    return '$date $time';
  }

  @override
  String lastSeenDate(String date) {
    return 'son görülme $date';
  }

  @override
  String get messageEmpty => 'Henüz mesaj yok. Merhaba deyin.';

  @override
  String get addMembersDone => 'Gruba eklendi';

  @override
  String get addMembersNoneTitle => 'Eklenecek kimse kalmadı';

  @override
  String get addMembersNoneBody => 'Kişilerinizdeki herkes zaten bu grupta.';

  @override
  String get addMembersOldTitle => 'Önceki mesajları göster';

  @override
  String get addMembersOldHint => 'Yeni üyeler önceki mesajları görür';

  @override
  String get addMembersAdminDecides =>
      'Yeni üyelerin önceki mesajları görüp görmeyeceğini grup yöneticileri belirler';

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
  String get newChatEmpty => 'Henüz kimse yok — etiketiyle birini bulun';

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
  String get forwardNothing => 'Sonuç bulunamadı';

  @override
  String forwardSendCount(int count) {
    return 'Gönder ($count)';
  }

  @override
  String get shareTitle => 'Paylaş';

  @override
  String sharePhotos(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Paylaşılacak $count fotoğraf',
      one: 'Paylaşılacak 1 fotoğraf',
    );
    return '$_temp0';
  }

  @override
  String shareVideos(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Paylaşılacak $count video',
      one: 'Paylaşılacak 1 video',
    );
    return '$_temp0';
  }

  @override
  String shareItems(int count) {
    return 'Paylaşılacak $count öğe';
  }

  @override
  String get shareSending => 'Gönderiliyor…';

  @override
  String shareDone(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count sohbete gönderildi',
      one: '1 sohbete gönderildi',
    );
    return '$_temp0';
  }

  @override
  String shareUnreadable(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count fotoğraf okunamadı ve gönderilmedi.',
      one: '1 fotoğraf okunamadı ve gönderilmedi.',
    );
    return '$_temp0';
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
  String get newGroupNobody => 'Henüz başka kimse oturum açmadı';

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
    return '$name (siz)';
  }

  @override
  String get membersAdmin => 'Yönetici';

  @override
  String get membersRemoveAdmin => 'Yöneticilikten çıkar';

  @override
  String get membersMakeAdmin => 'Yöneticiliğe yükselt';

  @override
  String get membersLeft => 'Ayrıldı';

  @override
  String get membersRemovedBadge => 'Çıkarıldı';

  @override
  String get bubbleDeletedByAdmin => 'Bir yönetici tarafından silindi';

  @override
  String get chatLockedMessage =>
      'Bu mesaj açılamadı. Gönderenden mesajı yeniden göndermesini isteyin.';

  @override
  String get chatOpeningMessage => 'Mesaj açılıyor…';

  @override
  String filePreviewLine(String name) {
    return 'Dosya: $name';
  }

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
  String get mediaEmpty => 'Henüz paylaşılan medya yok';

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
    return '$name grup fotoğrafını değiştirdi';
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
  String get searchNoResults => 'Sonuç bulunamadı';

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
    return 'Tek seferde en fazla $count fotoğraf gönderebilirsiniz.';
  }

  @override
  String get attachOpenFailedMany => 'Bu fotoğraflar açılamadı.';

  @override
  String get attachOpenFailedSome => 'Bazı fotoğraflar açılamadı.';

  @override
  String get attachOpenFailed => 'Bu öğe açılamadı. Başka birini seçin.';

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
  String get attachTickSelect => 'Fotoğrafı seç';

  @override
  String get attachTickSelected => 'Seçildi';

  @override
  String get attachFasterTitle => 'Fotoğrafları daha hızlı gönderin';

  @override
  String get attachFasterBody =>
      'Galerinizin burada görünmesi için erişime izin verin. Siz göndermeden hiçbir şey yüklenmez.';

  @override
  String get attachOpenSettings => 'Ayarları aç';

  @override
  String get attachAllowPhotos => 'Fotoğraflara izin ver';

  @override
  String get attachNotNow => 'Şimdi değil';

  @override
  String get attachCamera => 'Kamera';

  @override
  String get onboardingWelcome => 'Hoş geldiniz';

  @override
  String get onboardingHeading => 'Diğerleri sizi nasıl görsün?';

  @override
  String get onboardingHint =>
      'İkisini de sonra Ayarlar\'dan değiştirebilirsiniz.';

  @override
  String get tagChecking => 'Kontrol ediliyor…';

  @override
  String tagFree(String tag) {
    return '@$tag kullanılabilir';
  }

  @override
  String tagTaken(String tag) {
    return '@$tag kullanımda';
  }

  @override
  String get tagUnknown => 'Müsaitlik kontrol edilemedi';

  @override
  String get profileDisplayName => 'Görünen ad';

  @override
  String get profileDisplayNameHint =>
      'Diğer üyeler bu adı görür. Aynı ad başkalarında da olabilir.';

  @override
  String get profileTag => 'Etiket';

  @override
  String get profileTagHint =>
      'Başka kimse bu etiketi kullanamaz. 3-20 harf, rakam veya _ kullanın.';

  @override
  String get signInBody => 'Tanıdığınız insanlarla mesajlaşma.';

  @override
  String get signInGoogle => 'Google ile devam et';

  @override
  String get signInInvitedOnly =>
      'Yalnızca davet edilen hesaplar oturum açabilir.';

  @override
  String get statusDeniedTitle => 'Erişim reddedildi';

  @override
  String get statusDeniedBody =>
      'Bu Google hesabı henüz SIS\'i kullanamıyor. Davet eden kişiden bu e-postayı eklemesini isteyin ya da oturumu kapatıp başka bir Google hesabıyla oturum açın.';

  @override
  String get replacedTitle => 'Başka bir telefonda oturum açtınız';

  @override
  String get replacedBody =>
      'SIS aynı anda tek telefonda çalışır. Burada kullanmak için yeniden oturum açın; diğer telefonun oturumu kapanır.';

  @override
  String get replacedSignIn => 'Oturum aç';

  @override
  String get removedTitle => 'Artık SIS\'i kullanamazsınız';

  @override
  String get removedBody =>
      'Bunun bir hata olduğunu düşünüyorsanız sizi davet eden kişiye sorun.';

  @override
  String replacedUnsentDeleted(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Bu telefondan gönderilmemiş $count mesaj silindi.',
    );
    return '$_temp0';
  }

  @override
  String get statusConnectTitle => 'Bağlanılamadı';

  @override
  String get statusStartTitle => 'SIS başlatılamadı';

  @override
  String statusStartBody(String reason) {
    return 'Uygulamayı yeniden başlatın. Yine olmazsa lütfen daha sonra tekrar deneyin.\n\n$reason';
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
  String get updateRequiredBody =>
      'SIS\'i kullanmaya devam etmek için güncelleyin. Bu sürüm artık desteklenmiyor.';

  @override
  String get updateNow => 'Şimdi güncelle';

  @override
  String get updateTestFlightOpenFailed =>
      'TestFlight açılamadı. TestFlight uygulamasını açın ve Güncelle\'ye dokunun.';

  @override
  String get updateTestFlightHint =>
      'TestFlight uygulaması açılır. SIS\'in yanındaki Güncelle\'ye dokunun.';

  @override
  String licencesCount(int count) {
    return '$count lisans';
  }

  @override
  String get commonConversation => 'Sohbet';

  @override
  String get statusStartBootstrap => 'SIS başlatılamadı. Tekrar deneyin.';

  @override
  String get appearanceRename => 'Yeniden adlandır';

  @override
  String get appearanceDuplicate => 'Çoğalt';

  @override
  String get appearanceDelete => 'Sil';

  @override
  String get appearanceCancel => 'İptal et';

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
  String get appearanceThemePlaceholder => 'Temam';

  @override
  String get themeTabAccent => 'Vurgu rengi';

  @override
  String get themeTabBackground => 'Arka plan';

  @override
  String get themeTabMyMessages => 'Mesajlarım';

  @override
  String get themePickAccent => 'Bir vurgu rengi seçin';

  @override
  String get themePickBackground => 'Arka plan rengini seçin';

  @override
  String get themePickMine => 'Mesaj balonunuz için bir renk seçin';

  @override
  String get themeMineFollow => 'Vurgu rengini kullan';

  @override
  String get themeMineFollowHint => 'Balon, vurgu renginizi izler.';

  @override
  String get themeMineFixedHint =>
      'Vurgu renginizi değiştirseniz de bu renk sabit kalır.';

  @override
  String get themeLowContrast =>
      'Bu vurgu rengini okumak zor olabilir. Daha koyu bir ton deneyin.';

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
  String get wallpaperGradient => 'Degrade';

  @override
  String get wallpaperPicture => 'Fotoğraf';

  @override
  String get wallpaperChoosePhoto => 'Fotoğraf seç';

  @override
  String get wallpaperPickFailed =>
      'Bu fotoğraf kullanılamadı. Başka birini deneyin.';

  @override
  String get wallpaperReset => 'Sohbet duvar kağıtlarını sıfırla';

  @override
  String get wallpaperResetInfo =>
      'Eklediğiniz sohbet duvar kağıtlarını kaldırır ve hazır olanları geri getirir.';

  @override
  String get wallpaperResetTitle => 'Sohbet duvar kağıtları sıfırlansın mı?';

  @override
  String get wallpaperResetConfirm =>
      'Eklediğiniz duvar kağıtları kaldırılacak.';

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
  String get chatDeleteUndo => 'Geri al';

  @override
  String get chatDeleteChat => 'Sohbeti sil';

  @override
  String chatDeleteSure(String name) {
    return '**$name** ile olan sohbet sadece sizin için silinsin mi? $name sohbeti görmeye devam eder.';
  }

  @override
  String get chatDeletedUndo => 'Sohbet silindi';

  @override
  String get chatLeaveGroupTitle => 'Gruptan ayrılmak ister misiniz?';

  @override
  String chatDeleteLeaveSure(String name) {
    return '**$name** grubunu silmek ve gruptan ayrılmak istediğinizden emin misiniz?';
  }

  @override
  String get chatGroupLeftUndo => 'Gruptan ayrıldınız';

  @override
  String chatDeleteFewTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count sohbeti sil',
    );
    return '$_temp0';
  }

  @override
  String get chatDeleteFewSure =>
      'Bu sohbetleri silmek istediğinizden emin misiniz?';

  @override
  String get chatsDeletedUndo => 'Sohbetler silindi';

  @override
  String get pollNewTitle => 'Yeni anket';

  @override
  String get pollQuestionLabel => 'Soru';

  @override
  String get pollQuestionHint => 'Bir soru sor';

  @override
  String get pollOptionsLabel => 'Seçenekler';

  @override
  String get pollOptionHint => 'Seçenek';

  @override
  String get pollAddOption => 'Seçenek ekle';

  @override
  String get pollOptionsMax => 'En yüksek sayıda seçenek eklediniz.';

  @override
  String get pollMultipleTitle => 'Birden fazla yanıta izin ver';

  @override
  String get pollAnonymousTitle => 'Anonim oylama';

  @override
  String get pollAnonymousSubtitle => 'Kimin neye oy verdiğini kimse görmez';

  @override
  String get pollSend => 'Anketi gönder';

  @override
  String get pollDiscardTitle => 'Anket silinsin mi?';

  @override
  String get pollDiscardBody => 'Soru ve seçenekler silinecek.';

  @override
  String get pollDiscardConfirm => 'Sil';

  @override
  String get pollDiscardCancel => 'İptal et';

  @override
  String get pollTypeAnonymous => 'Anonim anket';

  @override
  String get pollTypePublic => 'Anket';

  @override
  String get pollTypeClosed => 'Kesin sonuçlar';

  @override
  String pollVotes(int count) {
    return '$count oy';
  }

  @override
  String get pollNoVotes => 'Oy yok';

  @override
  String get pollVoteButton => 'Oy ver';

  @override
  String pollViewVotes(int count) {
    return 'Oyları görüntüle ($count)';
  }

  @override
  String get pollResultsTitle => 'Anket sonuçları';

  @override
  String pollOptionVoters(int count) {
    return '$count oy';
  }

  @override
  String get messageActionRetractVote => 'Oyu geri al';

  @override
  String get messageActionStopPoll => 'Anketi durdur';

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
    return 'Anket: $question';
  }

  @override
  String get contactPickerTitle => 'Kişi gönder';

  @override
  String get contactSearchHint => 'Rehberde ara';

  @override
  String get contactSend => 'Kişiyi gönder';

  @override
  String get contactAccessTitle => 'Rehberinize erişime izin verin';

  @override
  String get contactAccessBody =>
      'SIS rehberinize yalnızca bu listeyi açtığınızda erişir. Bir kişi göndermeden hiçbir şey yüklenmez.';

  @override
  String get contactAllowAccess => 'Erişime izin ver';

  @override
  String get contactEmpty => 'Telefon numarası olan kişi yok';

  @override
  String get contactNoMatch => 'Aramanıza uyan kişi yok';

  @override
  String contactPreviewLine(String name) {
    return 'Kişi: $name';
  }

  @override
  String get contactPermNote =>
      'Rehber izni yalnızca bu listeyi açtığınızda istenir';

  @override
  String get autoDownloadSection => 'Medya otomatik indirme';

  @override
  String get autoDownloadEnable => 'Açık';

  @override
  String get autoDownloadWifiOnly => 'Yalnızca Wi-Fi\'de';

  @override
  String get autoDownloadDisabled => 'Kapalı';

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
  String get autoDownloadCancel => 'İptal et';

  @override
  String get autoDownloadOk => 'Tamam';

  @override
  String fileTapToDownload(String size) {
    return '$size · İndirmek için dokunun';
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
  String get filePhotoTapToDownload => 'Fotoğrafı indirmek için dokunun';

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
  String get videoWaitingNetwork => 'Ağ bağlantısı bekleniyor';

  @override
  String get videoWaiting => 'Bekleniyor…';

  @override
  String get videoCancelSend => 'İptal et';

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
  String get videoTooBig =>
      'Bu video göndermek için çok büyük. Daha küçük bir video seçin.';

  @override
  String videoPickFailed(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count video gönderilemedi. Tekrar deneyin.',
      one: 'Bu video gönderilemedi. Tekrar deneyin.',
    );
    return '$_temp0';
  }

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
  String get videoAccessTitle => 'Videoları burada seçin';

  @override
  String get videoAccessBody =>
      'Videolarınızın burada görünmesi için erişime izin verin. Siz gönderene kadar hiçbir şey yüklenmez.';

  @override
  String get videoAllow => 'Videolara izin ver';

  @override
  String get videoUsePhonePicker => 'Telefonun seçicisini kullan';

  @override
  String get videoLoadMoreFailed => 'Daha fazla video yüklenemedi.';

  @override
  String get voicePreviewLine => 'Sesli mesaj';

  @override
  String get notifSummaryOne => '1 yeni mesaj';

  @override
  String notifSummaryMany(int count) {
    return '$count yeni mesaj';
  }

  @override
  String notifSummaryChats(int count, int chats) {
    return '$chats sohbetten $count yeni mesaj';
  }

  @override
  String get notifChannelSummary => 'Özet';

  @override
  String get notifChannelMessages => 'Yeni mesajlar';

  @override
  String get voiceHoldHint =>
      'Kaydetmek için basılı tutun, göndermek için bırakın';

  @override
  String get voiceMicDenied => 'Kayıt için Ayarlar\'dan mikrofona izin verin.';

  @override
  String get voiceMicFailed => 'Kayıt başlatılamadı.';

  @override
  String get voicePauseRecording => 'Kaydı duraklat';

  @override
  String get voiceResumeRecording => 'Kayda devam et';

  @override
  String get voiceDictationUnavailable =>
      'Telefonunuzda bu dil için sesle yazma kullanılamıyor.';

  @override
  String get voiceSlideToCancel => 'İptal etmek için kaydırın';

  @override
  String get voiceCancel => 'İptal et';

  @override
  String get voiceShowText => 'Metni göster';

  @override
  String get voiceHideText => 'Metni gizle';

  @override
  String get voiceCannotPlay => 'Bu sesli mesaj oynatılamıyor.';

  @override
  String get voiceButtonVoice => 'Sesli mesaj kaydet';

  @override
  String get voiceButtonDictation => 'Yazıyı sesle yaz';

  @override
  String get voiceSend => 'Sesli mesajı gönder';

  @override
  String get stickerPreviewLine => 'Çıkartma';

  @override
  String get stickerAlbumPreviewLine => 'Çıkartma albümü';

  @override
  String get stickerButtonTooltip => 'Çıkartmalar';

  @override
  String get stickerKeyboardTooltip => 'Klavye';

  @override
  String get stickerTabRecent => 'Son kullanılan';

  @override
  String get stickerTabFavourites => 'Favoriler';

  @override
  String get stickerTabStarter => 'Başlangıç seti';

  @override
  String get stickerTabMine => 'Çıkartmalarım';

  @override
  String get stickerTabNew => '+ Yeni';

  @override
  String get stickerEmptyRecent => 'Gönderdiğiniz çıkartmalar burada görünür.';

  @override
  String get stickerEmptyFavourites =>
      'Favorilere eklemek için sohbetteki bir çıkartmaya uzun basın.';

  @override
  String get stickerEmptyAlbum => 'Bu albüm boş.';

  @override
  String get stickerNoAlbums =>
      'Henüz albüm yok. Çıkartmalarınızı saklamak için bir tane oluşturun.';

  @override
  String get stickerLabel => 'Çıkartma';

  @override
  String get stickerLoadFailed => 'Bu çıkartma yüklenemedi.';

  @override
  String get messageActionStickerFavourite => 'Favorilere ekle';

  @override
  String get messageActionStickerAlbum => 'Albüme ekle';

  @override
  String get stickerAddedFavourite => 'Favorilere eklendi';

  @override
  String stickerAddedAlbum(String name) {
    return '$name albümüne eklendi';
  }

  @override
  String get stickerPickAlbumTitle => 'Albüme ekle';

  @override
  String get stickerNewAlbum => 'Yeni albüm';

  @override
  String get stickerAlbumNameHint => 'Albüm adı';

  @override
  String get stickerAlbumCreate => 'Oluştur';

  @override
  String get stickerAlbumRenameTitle => 'Albümü yeniden adlandır';

  @override
  String get stickerAlbumsTitle => 'Albümlerim';

  @override
  String stickerAlbumsCount(int count, int max) {
    return '$count / $max';
  }

  @override
  String get stickerAlbumShare => 'Albümü paylaş';

  @override
  String get stickerAlbumRename => 'Yeniden adlandır';

  @override
  String get stickerAlbumDelete => 'Albümü sil';

  @override
  String get stickerAlbumDeleteTitle => 'Bu albüm silinsin mi?';

  @override
  String get stickerAlbumDeleteBody =>
      'Albüm yalnızca sizde silinir. Sohbetlerdeki çıkartmalar kalır.';

  @override
  String get stickerDelete => 'Sil';

  @override
  String get stickerCancel => 'İptal et';

  @override
  String get stickerAlbumShared => 'Albüm paylaşıldı';

  @override
  String stickerAlbumStickers(int count) {
    return '$count çıkartma';
  }

  @override
  String get stickerAlbumAdd => 'Albümü ekle';

  @override
  String get stickerAlbumAddFavourites => 'Favorilere ekle';

  @override
  String get stickerAlbumAdded => 'Albüm eklendi';

  @override
  String get stickerAlbumFavouritesAdded => 'Favorilerinize eklendi';

  @override
  String get stickerAlbumGone => 'Bu albüm artık mevcut değil.';

  @override
  String get stickerRemoveFromAlbum => 'Albümden çıkar';

  @override
  String get stickerRemoveFavourite => 'Favorilerden çıkar';

  @override
  String stickerLimitAlbums(int max) {
    return 'En fazla $max albümünüz olabilir.';
  }

  @override
  String stickerLimitInAlbum(int max) {
    return 'Bir albüme en fazla $max çıkartma girer.';
  }

  @override
  String stickerLimitFavourites(int max) {
    return 'En fazla $max favori tutabilirsiniz.';
  }

  @override
  String get stickerCreateTitle => 'Çıkartma oluştur';

  @override
  String get makerUsePhoto => 'Fotoğraf kullan';

  @override
  String get makerCancel => 'İptal et';

  @override
  String get makerCutoutTitle => 'Arka planı kaldır';

  @override
  String get makerWhole => 'Tüm görsel';

  @override
  String get makerCut => 'Arka plansız';

  @override
  String get makerErase => 'Sil';

  @override
  String get makerRestore => 'Geri getir';

  @override
  String get makerUndo => 'Geri al';

  @override
  String get makerReset => 'Sıfırla';

  @override
  String get makerBrushHint => 'Silmek ya da geri getirmek için boyayın';

  @override
  String get makerCutoutPreparing => 'Arka plan kaldırılıyor…';

  @override
  String get makerCutoutUnavailable =>
      'Arka plan şu an kaldırılamadı. Görseliniz olduğu gibi kaldı.';

  @override
  String get makerCutoutNoSupport =>
      'Bu telefon arka planı kaldıramıyor. Görseliniz olduğu gibi kaldı.';

  @override
  String get makerEditTitle => 'Çıkartmayı düzenle';

  @override
  String get makerEditHint => 'Çıkartmanıza yazı ekleyin ya da çizin';

  @override
  String get makerToAlbum => 'Albüme kaydet';

  @override
  String get makerTextTitle => 'Yazı';

  @override
  String get makerTextHint => 'Yazı yaz';

  @override
  String get makerSize => 'Boyut';

  @override
  String get makerFontSans => 'Sans';

  @override
  String get makerFontSerif => 'Serif';

  @override
  String get makerFontHand => 'El yazısı';

  @override
  String get makerDrawTitle => 'Çiz';

  @override
  String get makerThin => 'İnce';

  @override
  String get makerMedium => 'Orta';

  @override
  String get makerThick => 'Kalın';

  @override
  String get makerSaveTitle => 'Çıkartmayı kaydet';

  @override
  String get makerFull => 'Dolu';

  @override
  String get makerLimitReached => 'Sınıra ulaşıldı';

  @override
  String get makerAlsoFavourite => 'Favorilere de ekle';

  @override
  String get makerSave => 'Kaydet';

  @override
  String get makerDone => 'Bitti';

  @override
  String get makerSaveFailed => 'Çıkartma kaydedilemedi. Tekrar deneyin.';

  @override
  String makerSaveToCount(int count, int max) {
    return 'Albüme kaydet ($count/$max)';
  }

  @override
  String makerCountOf(int count, int max) {
    return '$count/$max';
  }

  @override
  String makerSavedTo(String name) {
    return '$name albümüne kaydedildi';
  }

  @override
  String get makerGalleryTitle => 'Fotoğraf seç';

  @override
  String get makerRecent => 'Son eklenenler';

  @override
  String get videoPlayerClose => 'Kapat';

  @override
  String get videoPlayerDone => 'Bitti';

  @override
  String get videoPlayerCopy => 'Bağlantıyı kopyala';

  @override
  String get videoPlayerCopied => 'Bağlantı kopyalandı';

  @override
  String videoOpenIn(String site) {
    String _temp0 = intl.Intl.selectLogic(site, {
      'youtube': 'YouTube\'da aç',
      'instagram': 'Instagram\'da aç',
      'tiktok': 'TikTok\'ta aç',
      'x': 'X\'te aç',
      'other': 'Tarayıcıda aç',
    });
    return '$_temp0';
  }

  @override
  String videoPlayerPrivacy(String site) {
    return 'İzlerken $site IP adresinizi ve cihazınızı görür. Kapatınca SIS çerezlerini siler.';
  }

  @override
  String get videoRefusedPrivate => 'Bu video gizli.';

  @override
  String get videoRefusedDeleted => 'Bu video silinmiş.';

  @override
  String get videoRefusedRegion => 'Bu video bölgenizde izlenemiyor.';

  @override
  String get videoRefusedLogin =>
      'Bu videoyu izlemek için oturum açmak gerekiyor.';

  @override
  String get videoRefusedOther => 'Video yüklenemedi.';

  @override
  String get videoRefusedMore => 'SIS içinde oynatılamıyor.';

  @override
  String get adminUnk => 'Bu komutu bilmiyorum.';

  @override
  String get adminNoem => 'Bu komut bir e-posta adresi gerektiriyor.';

  @override
  String get adminBad => 'E-posta adresi doğru görünmüyor.';

  @override
  String get staffChatTitleFallback => 'Ekip sohbeti';

  @override
  String get adminHelpHeader => 'Komutlar:';

  @override
  String adminIosOk(String email) {
    return '$email izin listesine eklendi. Apple, daveti e-posta ile gönderecek. Aynı e-postayla oturum açmasını söyleyin.';
  }

  @override
  String get adminP1 => 'Apple’a davet gönderiliyor…';

  @override
  String get adminP2 => 'Apple yavaş. Tekrar deneniyor (2/3)…';

  @override
  String get adminP3 => 'Apple kabul etti. Davet e-postası yollanıyor.';

  @override
  String adminFail(String email, String reason) {
    return 'Komutu yeniden yazarak tekrar deneyin. $email için Apple adımı başarısız oldu: $reason. İzin listesi satırı kaydedildi.';
  }

  @override
  String adminAndOk(String email) {
    return '$email izin listesine eklendi. Elle yapılacak bir adım var: bu e-postayı Play Console’daki iç test kullanıcıları listesine ekleyin.';
  }

  @override
  String get adminFwdTitle => 'İletilmeye hazır';

  @override
  String adminFwdBody(String email, String link) {
    return 'Merhaba! SIS’i Android ile test edebilirsiniz.\n1. Bu bağlantıyı açın ve daveti kabul edin: $link\n2. Google Play’den SIS’i yükleyin.\n3. Şu e-postayla oturum açın: $email';
  }

  @override
  String get adminCopy => 'Kopyala';

  @override
  String get adminCopied => 'Kopyalandı';

  @override
  String get adminShare => 'Paylaş';

  @override
  String get adminConfTitle => 'Bu test kullanıcısı kaldırılsın mı?';

  @override
  String adminConfBody(String email) {
    return '$email artık SIS’e erişemeyecek.';
  }

  @override
  String get adminConfNo => 'İptal et';

  @override
  String get adminConfYes => 'Kaldır';

  @override
  String get adminConfDone => 'Kaldırıldı';

  @override
  String get adminConfCancelled => 'İptal edildi';

  @override
  String get adminCardConfirm => 'Onayla';

  @override
  String get adminCardCancel => 'İptal et';

  @override
  String get adminCardDone => 'Tamamlandı';

  @override
  String get adminCardExpired => 'Sona erdi';

  @override
  String adminRmOk(String email) {
    return '$email izin listesinden kaldırıldı. Şimdi Play’de elle kaldırın: Play Console > Internal testing > Testers: bu e-postayı iç test kullanıcıları listesinden silin.';
  }

  @override
  String get adminCanOk => 'İptal edildi. Hiçbir şey kaldırılmadı.';

  @override
  String adminNoList(String email) {
    return '$email test kullanıcıları listesinde yok.';
  }

  @override
  String adminR1(String email) {
    return '$email TestFlight grubundan çıkarılıyor…';
  }

  @override
  String get adminR2 => 'Apple yavaş. Tekrar deneniyor (2/3)…';

  @override
  String get adminR3 => 'TestFlight’tan çıkarıldı.';

  @override
  String adminFailRm(String email, String reason) {
    return 'Komutu yeniden yazarak tekrar deneyin. $email için Apple adımı başarısız oldu: $reason. İzin listesi satırı zaten kaldırıldı.';
  }

  @override
  String get adminReasonTimeout => 'Apple zamanında yanıt vermedi';

  @override
  String get adminReasonRejected => 'Apple isteği reddetti';

  @override
  String get adminReasonDispatch => 'GitHub işi başlatamadı';

  @override
  String adminListHeader(int count) {
    return 'Test kullanıcıları: $count';
  }

  @override
  String adminListIos(int count) {
    return 'iPhone ($count)';
  }

  @override
  String adminListAnd(int count) {
    return 'Android ($count)';
  }

  @override
  String get adminRate =>
      'Çok fazla komut. Bir dakika bekleyip tekrar deneyin.';

  @override
  String get adminKeep => 'İptal edildi: bu kart artık geçerli değil.';

  @override
  String get adminErr => 'Bir şeyler ters gitti. Hiçbir şey değiştirilmedi.';

  @override
  String get adminNoLink =>
      'Play davet bağlantısı henüz ayarlanmadı. Sahibinden ayarlamasını isteyin, sonra komutu yeniden yazın.';

  @override
  String adminListOther(int count) {
    return 'Diğer ($count)';
  }

  @override
  String get findPeopleTitle => 'Kişi bul';

  @override
  String get findPeopleSub => 'Rehberinizden';

  @override
  String get findOnSis => 'SIS\'te';

  @override
  String get findNotOnSis => 'Henüz SIS\'te değil';

  @override
  String get findNotOnSisSub => 'SIS\'te değil';

  @override
  String get findMessage => 'Mesaj';

  @override
  String get findInvite => 'Davet et';

  @override
  String get findDiscTitle => 'Rehberdeki kişileri bul';

  @override
  String get findDiscBody =>
      'SIS, rehberinizdeki kişilerden hangilerinin SIS kullandığını gösterebilmek için bu kişilerin e-posta adreslerini kodlanmış (hash) biçimde SIS sunucusuna gönderir. Bu işlem Kişi bul sayfasını her açtığınızda yapılır. Kodlar saklanmaz; SIS yalnızca bulduğunuz üyeleri kaydeder. Adlar ve telefon numaraları telefonunuzda kalır.';

  @override
  String get findContinue => 'Devam';

  @override
  String get findNotNow => 'Şimdi değil';

  @override
  String get findAskTitle => 'Arkadaşlarınızı SIS\'te bulun';

  @override
  String get findAskBody =>
      'SIS, kimlerin zaten burada olduğunu göstermek için rehberinize bakabilir.';

  @override
  String get findAllow => 'Rehbere erişime izin ver';

  @override
  String get findLater => 'Daha sonra tekrar deneyin.';

  @override
  String get findEmpty => 'Kişi bulunamadı';

  @override
  String get appearanceModeTitle => 'Açık veya koyu';

  @override
  String get appearanceModeFollow => 'Sistem varsayılanı';

  @override
  String get appearanceModeFollowHint =>
      'Telefonunuzun açık veya koyu ayarına uyar';

  @override
  String get appearanceModeLight => 'Açık';

  @override
  String get appearanceModeDark => 'Koyu';

  @override
  String get appearanceModeNoteBuiltIn =>
      'Temanızın kendi renkleri korunur; bu yalnızca açık ya da koyu sürümü seçer.';

  @override
  String appearanceModeNoteFollows(String name) {
    return '“$name” bu seçimi izler.';
  }

  @override
  String appearanceModeNoteAlwaysLight(String name) {
    return '“$name” her zaman açıktır. Burada ne seçerseniz seçin açık kalır.';
  }

  @override
  String appearanceModeNoteAlwaysDark(String name) {
    return '“$name” her zaman koyudur. Burada ne seçerseniz seçin koyu kalır.';
  }

  @override
  String get cropCancel => 'İptal et';

  @override
  String get cropDone => 'Bitti';

  @override
  String get cropReset => 'Sıfırla';

  @override
  String get cropOriginal => 'Orijinal';

  @override
  String get cropSquare => 'Kare';

  @override
  String get cropFree => 'Serbest';

  @override
  String get cropButtonLabel => 'Fotoğrafı kırp';

  @override
  String get cropRotateLabel => 'Döndür';

  @override
  String get noticeNewMessage => 'Yeni mesaj';

  @override
  String get noticeReactionGeneric => 'Mesajınıza yeni tepki';

  @override
  String noticeReactionToMessage(String emoji) {
    return 'Mesajınıza $emoji tepkisini verdi';
  }

  @override
  String noticeReactionToQuote(String emoji, String quote) {
    return '\"$quote\" mesajınıza $emoji tepkisini verdi';
  }

  @override
  String noticeReactionToPhoto(String emoji) {
    return 'Fotoğrafınıza $emoji tepkisini verdi';
  }

  @override
  String noticeReactionToVideo(String emoji) {
    return 'Videonuza $emoji tepkisini verdi';
  }

  @override
  String noticeReactionToSticker(String emoji) {
    return 'Çıkartmanıza $emoji tepkisini verdi';
  }

  @override
  String noticeReactionToVoice(String emoji) {
    return 'Sesli mesajınıza $emoji tepkisini verdi';
  }

  @override
  String noticeReactionToFile(String emoji) {
    return 'Dosyanıza $emoji tepkisini verdi';
  }

  @override
  String get salesTitle => 'Toplam para';

  @override
  String salesPrevTitle(String date) {
    return 'Önceki günün toplamı ($date)';
  }

  @override
  String salesFetched(String source, String time) {
    return '$source aracılığıyla alındı: $time';
  }

  @override
  String salesFetchedNoSource(String time) {
    return 'Alındı: $time';
  }

  @override
  String get salesFail => 'Hizmet yanıt vermedi. Daha sonra tekrar deneyin.';

  @override
  String get salesOff => 'Bu komut kapalı.';

  @override
  String salesUnknown(String cmd) {
    return 'Bilinmeyen komut. $cmd yazın.';
  }

  @override
  String get salesRate =>
      'Çok fazla komut. Bir dakika bekleyip tekrar deneyin.';

  @override
  String salesSwOn(String cmd) {
    return '$cmd komutu açıldı.';
  }

  @override
  String salesSwOff(String cmd) {
    return '$cmd komutu kapatıldı.';
  }

  @override
  String get salesHint => 'Komutlar için / yazın';

  @override
  String get adminHint => 'Komutlar için / yazın';

  @override
  String get cmdArgEmail => 'E-posta';

  @override
  String get cmdArgTag => 'Etiket';

  @override
  String cmdRowLabel(String command, String meaning) {
    return '$command, $meaning';
  }

  @override
  String get salesNotEnc => 'Uçtan uca şifreli değil';

  @override
  String get messageDeleteQuestion =>
      'Bu mesajı silmek istediğinizden emin misiniz?';

  @override
  String get messageDeleteFewQuestion =>
      'Bu mesajları silmek istediğinizden emin misiniz?';

  @override
  String messageDeleteAlsoFor(String name) {
    return '$name için de sil';
  }

  @override
  String get messageDeleteConfirm => 'Sil';

  @override
  String get messageDeleteForAllMembers => 'Tüm üyelerden sil';

  @override
  String get messageDeleteMediaNote =>
      'İletilen ve SIS dışına kaydedilen kopyalar silinmez.';

  @override
  String messageDeleteTooLate(int hours) {
    return 'Çok geç: $hours saat geçti';
  }

  @override
  String get groupCloseTitle => 'Grup kapatılsın mı?';

  @override
  String get groupCloseBody =>
      'Bu grubu kapatırsanız siz dahil tüm üyeler gruptan çıkarılır. Artık kimse yazamaz. Bu işlem geri alınamaz.';

  @override
  String get groupCloseAction => 'Grubu kapat';

  @override
  String get groupCloseDebugWarning =>
      'Test kullanıcıları geri bildirimlerini bu gruba gönderiyor. Grubu kapatırsanız buraya artık geri bildirim gönderemezler.';

  @override
  String composerGroupClosed(String name) {
    return 'Bu grup $name tarafından kapatıldı';
  }

  @override
  String get composerGroupClosedNoName => 'Bu grup kapatıldı';

  @override
  String eventClosed(String name) {
    return '$name grubu kapattı';
  }

  @override
  String get failPeerKeysCheck =>
      'Bu kişinin şifreleme anahtarları kontrol edilemedi. Tekrar deneyin.';

  @override
  String get failNameEmpty => 'Bir ad girin';

  @override
  String get failDenied => 'Bunu yapma izniniz yok.';

  @override
  String get failSearchLimit =>
      'Çok fazla arama yaptınız. Biraz sonra tekrar deneyin.';

  @override
  String get failStickerLimit => 'Çıkartma sınırına ulaştınız.';

  @override
  String get failStickerCreate => 'Çıkartma oluşturulamadı.';

  @override
  String get failPollClosed => 'Bu anket kapandı.';

  @override
  String get failVideoPrepare => 'Bu video hazırlanamadı.';

  @override
  String get failCanceled => 'İptal edildi.';

  @override
  String get failLocationOff => 'SIS için konum kapalı.';

  @override
  String get failPositionNotFound =>
      'Konumunuz bulunamadı. Konumunuzun açık olduğundan emin olun.';

  @override
  String get failAppleEmail =>
      'SIS gerçek e-posta adresinizi gerektirir. Apple ile oturum açarken E-postamı Paylaş\'ı seçip tekrar deneyin.';

  @override
  String get failEncryptionSetup =>
      'Şifreleme hazırlanıyor. Biraz sonra tekrar deneyin.';

  @override
  String get failKeysSave => 'Şifreleme anahtarları bu telefona kaydedilemedi.';

  @override
  String get failGeneric => 'Bir şeyler ters gitti. Tekrar deneyin.';

  @override
  String get failOffline =>
      'Bağlantı yok. İnternetinizi kontrol edip tekrar deneyin.';

  @override
  String get failServer => 'Bizden kaynaklı bir sorun oluştu. Tekrar deneyin.';

  @override
  String get failSignIn => 'Oturum açılamadı. Tekrar deneyin.';

  @override
  String get failSignInCanceled => 'Oturum açma iptal edildi.';

  @override
  String get failMessageSave => 'Mesaj bu telefona kaydedilemedi.';

  @override
  String get failPlaceSearch => 'Yer arama şu an kullanılamıyor.';

  @override
  String get failFileUnavailable => 'Bu dosya kullanılamıyor.';

  @override
  String get failPhotoUnavailable => 'Bu fotoğraf kullanılamıyor.';

  @override
  String get failTagTaken => 'Bu etiket az önce alındı. Başka bir tane seçin.';

  @override
  String get failNameNotAllowed => 'Bu ad veya etiket kullanılamaz.';

  @override
  String get failTagShort => 'En az 3 karakter olmalı';

  @override
  String get failTagLong => 'En fazla 20 karakter olabilir';

  @override
  String get failTagStart => 'Harfle başlamalı';

  @override
  String get failTagChars => 'Yalnızca harf, rakam ve _ kullanılabilir';

  @override
  String failNameTooLong(int max) {
    return 'En fazla $max karakter olabilir';
  }

  @override
  String get adminTitle => 'Admin Panelleri';

  @override
  String get adminTalk => 'Talk';

  @override
  String get adminQuestions => 'Questions';

  @override
  String get adminTasks => 'Tasks';

  @override
  String get adminDashboard => 'Dashboard';

  @override
  String get adminLoadFailed => 'Yüklenemedi. Tekrar deneyin.';

  @override
  String get adminRetry => 'Tekrar dene';

  @override
  String get adminRename => 'Yeniden adlandır';

  @override
  String get adminDelete => 'Sil';

  @override
  String get adminDeleteConfirm =>
      'Bu konuşmayı kalıcı olarak silmek istiyor musunuz?';

  @override
  String get adminTalkHint => 'Manager\'a mesaj yazın';

  @override
  String get adminTalkEmpty =>
      'Henüz konuşma yok. Başlatmak için aşağıya yazın.';

  @override
  String get adminSendFailed =>
      'Mesaj gönderilemedi. Yazdığınız metin duruyor. Tekrar deneyin.';

  @override
  String get adminRecommended => 'Önerilen';

  @override
  String get adminOther => 'Diğer (kendi yanıtınızı yazın)';

  @override
  String get adminDone => 'Bitti';

  @override
  String adminSend(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count yanıtı gönder',
      one: '1 yanıtı gönder',
    );
    return '$_temp0';
  }

  @override
  String get adminWaiting => 'Gönderildi, henüz okunmadı';

  @override
  String get adminTalkAbout => 'Bunun hakkında konuş';

  @override
  String get adminQuestionsEmpty => 'Açık soru yok';

  @override
  String get adminBoxM => 'Manager';

  @override
  String get adminBoxC => 'AI Control';

  @override
  String get adminBoxS => 'Support';

  @override
  String get adminBasis => 'Dayandığı kararlar';

  @override
  String get adminGo => 'Başlat';

  @override
  String get adminDiscard => 'Vazgeç';

  @override
  String get adminDecided => 'Karar kaydedildi';

  @override
  String get adminTasksEmpty => 'Sizi bekleyen görev yok';

  @override
  String get adminDashContext => 'Bağlam boyutu';

  @override
  String get adminDashWorking => 'Şu an çalışan';

  @override
  String get adminDashComputer => 'Bilgisayar yükü';

  @override
  String get adminDashTasksLeft => 'Kalan görevler';

  @override
  String get adminDashEmpty => 'Açık bir şey yok';

  @override
  String adminDashStateRunning(int count) {
    return 'Çalışıyor $count';
  }

  @override
  String adminDashStateReview(int count) {
    return 'İncelemede $count';
  }

  @override
  String adminDashStateBlocked(int count) {
    return 'Takılı $count';
  }

  @override
  String adminDashStatePending(int count) {
    return 'Başlamadı $count';
  }

  @override
  String get adminLinkTitle => 'Bu telefonu bağla';

  @override
  String get adminLinkBody =>
      'Bu kodu bilgisayarınızdaki Questions panelinde görünen kodla karşılaştırın. Aynıysa Eşleşiyor\'a dokunun.';

  @override
  String get adminLinkButton => 'Eşleşiyor';

  @override
  String get adminLinkStatusIdle =>
      'Bu telefonu yalnızca bilgisayarınızın başında bağlayabilirsiniz.';

  @override
  String get adminLinkStatusWorking => 'Bilgisayarınızın onayı bekleniyor…';

  @override
  String get adminLinkStatusDone => 'Bu telefon bağlandı';

  @override
  String get adminLinkStatusFailed => 'Bu telefon bağlanamadı. Tekrar deneyin.';

  @override
  String get adminLinkCodeChanged =>
      'Kod değişti. Eşleşiyor\'a dokunmadan önce bilgisayarınızdaki yeni kodu kontrol edin.';

  @override
  String get adminUnlockReason =>
      'Admin Panelleri için telefonunuzun kilidini açın';

  @override
  String get adminUnlockNoLock =>
      'Admin Panellerini açmak için telefonunuzun Ayarlar bölümünden ekran kilidi (PIN, desen, parmak izi veya yüz tanıma) ayarlayın, sonra buraya dönün.';

  @override
  String get adminUnlockCancelled =>
      'Admin Panelleri kapalı kaldı. Görmek için telefonunuzun kilidini açın.';

  @override
  String get adminUnlockRetry => 'Kilidi aç';

  @override
  String get adminTalkTruncated => 'Burada yalnızca son mesajlar gösteriliyor.';

  @override
  String get adminAnswerSending => 'Gönderiliyor';

  @override
  String get adminAnswerNotSent => 'Gönderilemedi';

  @override
  String get adminAnswerRetry => 'Tekrar gönder';

  @override
  String get adminAnswerNotSentYet =>
      'Henüz gönderilmedi. Bilgisayarınız kapalı olabilir.';

  @override
  String get adminAnswerNewConversation => 'Yeni konuşma olarak gönder';

  @override
  String get adminReasonConvMissing => 'Bu konuşma bilgisayarınızda silindi.';

  @override
  String get adminReasonNotOpen =>
      'Bu, bilgisayarınızda zaten yanıtlandı veya kapatıldı.';

  @override
  String get adminReasonDeskOnly =>
      'Bunu yalnızca bilgisayarınızın başında yanıtlayabilirsiniz.';

  @override
  String get adminReasonUnknownItem => 'Bu öğe artık bilgisayarınızda yok.';

  @override
  String get adminReasonGeneric => 'Bir hata oluştu. Tekrar deneyin.';

  @override
  String get adminDashboardStale =>
      'Bilgisayarınızdan güncel durum gelmiyor. Bilgisayarınız kapalı veya uykuda olabilir.';
}
