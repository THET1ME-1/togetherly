import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:love_app/config/update_notes.dart';

/// Supported languages
enum AppLanguage { ru, en }

/// Singleton localization manager with Russian and English support.
/// Determines default language from device locale, stores user choice.
class LocaleService extends ChangeNotifier {
  LocaleService._();
  static final LocaleService _instance = LocaleService._();
  static LocaleService get instance => _instance;

  /// Short accessor used everywhere: `S.of`
  static AppStrings get current => _instance.strings;

  AppLanguage _language = AppLanguage.en;
  bool _initialized = false;

  AppLanguage get language => _language;
  bool get isRussian => _language == AppLanguage.ru;
  bool get isEnglish => _language == AppLanguage.en;

  AppStrings get strings =>
      _language == AppLanguage.ru ? const _RuStrings() : const _EnStrings();

  /// Initialize: load saved preference or detect from device locale.
  Future<void> init() async {
    if (_initialized) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString('app_language');
      if (saved != null) {
        _language = saved == 'ru' ? AppLanguage.ru : AppLanguage.en;
      } else {
        // Detect from device locale
        final locale = ui.PlatformDispatcher.instance.locale;
        _language = locale.languageCode == 'ru'
            ? AppLanguage.ru
            : AppLanguage.en;
        // Персистим определённый по локали язык, чтобы фоновые изоляты
        // (WorkManager / foreground-сервис) читали конкретное значение из
        // prefs, а не дефолтный EN — иначе mood-виджет обновляется в фоне с
        // английскими метками. PlatformDispatcher.locale в headless-изоляте
        // ненадёжен, prefs шарятся между изолятами и надёжны.
        await prefs.setString(
          'app_language',
          _language == AppLanguage.ru ? 'ru' : 'en',
        );
      }
    } catch (_) {
      _language = AppLanguage.en;
    }
    _initialized = true;
    notifyListeners();
  }

  /// Change language and persist.
  Future<void> setLanguage(AppLanguage lang) async {
    if (_language == lang) return;
    _language = lang;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'app_language',
        lang == AppLanguage.ru ? 'ru' : 'en',
      );
    } catch (_) {}
    notifyListeners();
  }

  String get languageLabel =>
      _language == AppLanguage.ru ? 'Русский' : 'English';
}

// ══════════════════════════════════════════════════════════════════════════════
// ABSTRACT STRINGS
// ══════════════════════════════════════════════════════════════════════════════

abstract class AppStrings {
  const AppStrings();

  // ── Common ──
  String get save;
  String get cancel;
  String get delete;
  String get edit;
  String get add;
  String get done;
  String get loading;
  String get error;
  String get ok;
  String get yes;
  String get no;
  String get close;
  String get back;
  String get reset;
  String get clear;

  // ── Welcome Screen ──
  String get welcomeTitle1;
  String get welcomeTitle2;
  String get welcomeSubtitle;
  String get welcomeFeatureMemories;
  String get welcomeFeatureMood;
  String get welcomeFeatureWidgets;
  String get welcomeStepCreateProfile;
  String get welcomeStepConnectPartner;
  String get welcomeStepStartTogether;
  String get createAccount;
  String get alreadyHaveAccount;
  String get privateSecure;

  // ── Login Screen ──
  String get welcomeBack;
  String get loginToAccount;
  String get signInWithGoogle;
  String get or;
  String get email;
  String get yourEmail;
  String get password;
  String get yourPassword;
  String get login;
  String get noAccount;
  String get create;
  String get invalidEmail;
  String get enterPassword;
  String get loginFailed;
  String get profileNotFound;
  String get userNotFound;
  String get wrongPassword;
  String get invalidEmailFormat;
  String get tooManyAttempts;
  String get serverNotResponding;
  String get googleNotResponding;
  String loginError(String e);
  String googleLoginError(String e);

  // ── Setup Screen ──
  String get whoAreYou;
  String get selectGenderForTheme;
  String get boy;
  String get girl;
  String get continueBtn;
  String get createProfile;
  String get signInGoogleOrManual;
  String get orManually;
  String get name;
  String get yourName;
  String get minCharsPassword;
  String get start;
  String get alreadyHaveAccountQuestion;
  String get enterYourName;
  String get enterValidEmail;
  String get selectGender;
  String get passwordMin6;
  String get accountExists;
  String get emailAlreadyRegistered;
  String registrationError(String e);
  // Согласие на онбординге собирается из частей: чекбокс «Я принимаю
  // <Условия использования> и <Политику конфиденциальности>», где обе ссылки
  // кликабельны (требование сторов к UGC-приложениям).
  String get agreeToTermsPrefix;
  String get termsOfUse;
  String get agreeToTermsAnd;
  String get privacyPolicyLink;
  String get forgotPassword;
  String passwordResetSent(String email);
  String get passwordResetError;
  String get showPassword;
  String get hidePassword;
  String get min8Chars;
  String get oneUppercase;
  String get oneSpecialChar;
  String get fullName;
  String get createAccountBtn;
  String get continueWithGoogle;
  String get continueWithApple;
  String get signInWith;
  String get signUpWith;
  String get rememberMe;
  String get alreadyHaveAccountLogin;
  String get passwordRequirements;

  // ── Home Screen ──
  String get home;
  String get widgets;
  String get connect;
  String get profile;
  String get solo;
  String get waitingForConnection;
  String daysLabel(String suffix);
  String monthsLabel(String suffix);
  String timeLabel(String suffix);
  String get inLove;
  String get together;
  String get days;
  String get months;
  String get time;
  String get inviteYourPartner;
  String get shareLinkCodeQr;
  String get relationshipMemoryLane;
  String get memoriesWillAppear;
  String get connectWithPartnerToStart;
  String partnerIsMood(String name, String mood);
  String get answerSent;
  String get dailyReflection;
  String get today;
  String get answerPrompt;
  String get editAnswer;
  String get clearMood;
  String get removeMood;
  String get howAreYouFeeling;
  String get partnerWillSeeMood;
  String moodDateLabel(String dateLabel);
  String get indicateMoodForDay;
  // ── Самочувствие («болячки») ──
  String get moodTabLabel;
  String get ailmentTabLabel;
  String get ailmentPickerSubtitle;
  String get clearAilment;
  String partnerAilmentBanner(String name, String label);
  String get relationshipStatus;
  String get chooseHowToConnect;
  String get inLoveStatus;
  String get perfectForCouples;
  String get married;
  String get forMarriedPartners;
  String get friends;
  String get connectWithBestFriend;
  String get bestBuddies;
  String get forInseparableCompanions;
  String get addCustomStatus;
  String get editCustomStatus;
  String get addCaption;
  String get optionalDescribe;
  String get writeSmth;
  String get skip;
  String get post;
  String get posting;
  String get failedUploadPhoto;
  String get memoryNotSaved;
  String get achievementUnlocked;
  String get achievementsTitle;
  String get achievementDone;
  String achievementsUnlockedOf(int unlocked, int total);
  String get markSecret;
  String get unmarkSecret;
  String get markedSecret;
  String get unmarkedSecret;
  String get secretMemories;
  String get enterPinTitle;
  String get setPinTitle;
  String get setPinHint;
  String get wrongPin;
  String get pinTooShort;
  String get pinDone;
  String get timeCapsule;
  String get capsuleIntro;
  String get capsuleLetterHint;
  String get capsuleAttachPhoto;
  String get capsuleOpenDate;
  String get change;
  String capsuleOpensIn(int days);
  String get capsulePreset1m;
  String get capsulePreset6m;
  String get capsulePreset1y;
  String get capsuleSeal;
  String get capsuleNeedsContent;
  String get capsuleNeedsFutureDate;
  String capsuleOpensOn(String date);
  String capsuleFrom(String name);
  String capsuleNotReady(String date);
  String get capsuleAddSub;
  String get capsuleCreated;
  String get capsuleOpenedTitle;
  String get capsuleOpenedBody;
  String capsuleOpenedBodyNamed(String title);
  String get postedToMemoryLane;
  String get moodCalendar;
  String get seeAll;
  String get addMemory;
  String get viewAll;

  // ── Widget Screen ──
  String get widgetsTitle;
  String get resetBtn;
  String get desktopPreview;
  String get me;
  String get partner;
  String get noStatus;
  String get myWidget;
  String get tapToEdit;
  String get editBtn;
  String widgetOfPartner(String name);
  String get emptyYet;
  String get updated;
  String get live;
  String get mood;
  String get status;
  String get message;
  String get photo;
  String get photoUploaded;
  String get widgetPhotoOwnerOnlyHint;
  String get music;
  String get addBtn;
  String get widgetSettings;
  String get photoToMemoryLane;
  String get autoSavePhotoToMemories;
  String get messagestoMemoryLane;
  String get autoSaveMessages;
  String get musicToMemoryLane;
  String get autoSaveTracks;
  String get moodToCalendar;
  String get autoMarkMoodCalendar;
  String get connectPartnerForWidgets;
  String get chooseMood;
  String get statusHint;
  String get messageHint;
  String get chooseSource;
  String get camera;
  String get gallery;
  String get musicTitle;
  String get trackName;
  String get artist;
  String get linkOptional;
  String get uploadingPhoto;
  String get resetWidget;
  String get resetWidgetConfirm;
  String get notPairedWidgets;
  String get notPairedWidgetsDesc;

  // ── Profile Screen ──
  String get user;
  String get noEmail;
  String get gender;
  String get male;
  String get female;
  String get information;
  String get theme;
  String get relationships;
  String get statusLabel;
  String get partnerLabel;
  String get notSelected;
  String daysTogetherLabel(String days);
  String get invitePartnerToCount;
  String get anniversaryDate;
  String get anniversaryWheelHint;
  String get firstKissDate;
  String get myBirthday;
  String get partnerBirthday;
  String get notifCelebrations;
  String get notifCelebrationsHint;
  String get anniversaryTodayTitle;
  String get anniversaryTodayBody;
  String get birthdayTodayTitle;
  String get birthdayTodayBody;
  String get anniversaryTomorrowTitle;
  String get anniversaryTomorrowBody;
  String get birthdayTomorrowTitle;
  String get birthdayTomorrowBody;
  String get celebrationBannerAnniversary;
  String get celebrationBannerBirthday;
  String get daysUntilAnniversary;
  String get daysUntilBirthday;
  String get inLoveRelType;
  String get marriedRelType;
  String get friendsRelType;
  String get bestFriendsRelType;
  String get customStatus;
  String get relationshipType;
  String get selectPartner;
  String get noConnectedPartners;
  String get settings;
  String get editProfile;
  String get notifications;
  String get privacy;
  String get aboutApp;
  String get supportAuthors;
  String get logout;
  String get logoutQuestion;
  String get logoutConfirm;
  String get logoutBtn;
  String get deleteAccount;
  String get deleteAccountQuestion;
  String get deleteAccountConfirm;
  String get deleteAccountBtn;
  String get deleteAccountReauth;
  String get deleteAccountError;
  String get chooseColorTheme;
  String get themeNamePink;
  String get themeNamePurple;
  String get themeNameBlue;
  String get themeNamePeach;
  String get themeNameSage;
  String get themeNameMidnight;
  String get themeNameLavender;
  String get themeNameCherry;
  String get themeNameMint;
  String get themeNameSunset;
  String get themeNameMonochrome;
  String get themeNameForest;
  String get themeNameOcean;
  String get themeNameHoney;
  String get themeNameLemon;
  String get themeNameSand;
  String get themeNameAurora;
  String get themeNameBordeaux;
  String get themeNameTeal;
  String get themeNameNord;
  String get themeNameCharcoalTeal;
  String get themeNameCoffee;
  String get themeNameForestDark;
  String get themeNameGarnet;
  String get themeNameDarkHoney;
  String premiumThemeLocked(int price);
  String get coinBalance;
  String get coinShopTitle;
  String get coinShopSubtitle;
  String get buyThemeTitle;
  String buyThemeDescription(String themeName, int price);
  String get buyThemeConfirm;
  String get notEnoughCoins;
  String get themePurchased;
  // ── Профильные иконки ──
  String get iconShopTitle;
  String get iconShopSubtitle;
  String get noIconOption;
  String get iconRewardOnly;
  String get iconRewardHint;
  String get iconPurchased;
  String get watchAdTitle;
  String get watchAdSubtitle;
  String get adNotReady;
  String get adRewardLimitReached;
  String get rewardPending;
  String get changesApplyImmediately;

  // ── Бесплатные монеты ──
  String get dailyBonusTitle;
  String get dailyBonusSubtitle;
  String coinEarned(int amount);
  String get memoryRewardTitle;
  String get memoryRewardSubtitle;
  String get partnerInviteRewardTitle;
  String get partnerInviteRewardSubtitle;
  String get moodStreakRewardTitle;
  String get moodStreakRewardSubtitle;
  String get earnCoinsSection;

  // ── IAP — покупка монет ──
  String get coinPacksSectionTitle;
  String coinPackTitle(int coins);
  String get coinPurchaseSuccess;
  String coinPurchaseSuccessAmount(int coins);
  String get coinPurchasePending;
  String get coinPurchaseCancelled;
  String get coinPurchaseError;
  String get coinStoreUnavailable;
  String get restorePurchasesTitle;
  String get restorePurchasesSuccess;
  String get restorePurchasesError;
  String get editProfileTitle;
  String get uploading;
  String get userNotAuthorized;
  String get failedUploadImage;
  String get avatarUpdated;
  String get nameUpdated;
  String uploadError(String e);
  String get language;
  String get selectLanguage;
  String get blobAnimation;

  // ── Mood Calendar Screen ──
  String get moodCalendarTitle;
  String get moodSettings;
  String get moodMultiplePerDay;
  String get moodMultiplePerDaySubtitle;
  String get zoomIn;
  String get zoomOut;
  String get week;
  String get month;
  String get year;
  String get myMood;
  String partnerMood(String name);
  String get moods;

  // ── Home Screen (continued) ──
  String get emoji;
  String get label;
  String get egSoulmates;
  String get shareYourThoughts;
  String get draw;
  String get calendar;
  String get noMemoriesYet;

  // ── Draw Screen ──
  String get drawTogether;
  String get brush;
  String get eraser;
  String get panTool;
  String get fillBg;
  String get rotateCanvas;
  String get drawLine;
  String get drawRect;
  String get drawCircle;
  String get drawTriangle;
  String get fillShapes;
  String get insertPhoto;
  String get photoRequiresPartner;
  String get photoFromGallery;
  String get photoFromCamera;
  String get undoAction;
  String get redoAction;
  String get clearCanvas;
  String get clearCanvasConfirm;
  String get deletePhoto;
  String get mascotBoyName;
  String get mascotGirlName;
  String get mascotSpikyName;
  String get mascotLuluName;
  String get mascotIskrikName;
  String get mascotZhuzhaName;
  String get saveDrawing;
  String get shareDrawing;
  String drawingSavedTo(String path);
  String get failedToSaveDrawing;
  String get failedToShareDrawing;
  String get strokeThickness;
  String get drawHint;
  String partnerIsDrawing(String name);
  String get addFirstMemory;
  String get video;
  String get videoLabel;
  String get location;
  String get audio;
  List<String> get reflectionQuestions;

  // ── Draw Gallery / Canvas ──
  String get palmTool;
  String get drawingMode;
  String get newCanvas;
  String get myDrawings;
  String get untitledCanvas;
  String get renameCanvas;
  String get deleteCanvas;
  String get deleteCanvasConfirm;
  String get canvasNameLabel;
  String get noDrawingsYet;

  // ── Connect Partner Screen ──
  String get newGroup;
  String get waiting;
  String get deleteGroupConfirm;
  String get deleteGroupTitle;
  String get removeGroup;
  String get connected;
  String groupOf(int count);
  String membersCount(int count);
  String get member;
  String get online;
  String get offline;
  String get chatOnline;
  String get chatTypingShort;
  String get inviteMore;
  String get scanQr;
  String get disconnect;
  String get connectYourPartner;
  String get shareInviteCodeDesc;
  String get yourInviteCode;
  String get copy;
  String get share;
  String get codeCopied;
  String shareInviteText(String code, String link);
  String get loveAppInvitation;
  String get newCodeGenerated;
  String get showQr;
  String get haveACode;
  String get connectPartnerBtn;
  String get inviteMoreMembers;
  String membersOfMax(int current, int max);
  String shareGroupInviteText(String code, String link);
  String get groupInvitation;
  String connectedWithCouple(String name);
  String marriedTo(String name);
  String friendsWith(String name);
  String buddiesWith(String name);
  String customRelWith(String label, String name);
  String get joinAnotherGroup;
  String get enterCodeScanQr;
  String get enterCode;
  String get invalidCodeTryAgain;
  String get joinGroup;
  String get cantInviteSelf;
  String get codeNotFound;
  String get scanToConnect;
  String get scanPartnersQr;
  String get addNewConnection;
  String get chooseTypeForConnection;
  String get yourCustomType;
  String get newConnectionAdded;
  String get deleteConnection;
  String get deleteConnectionDesc;
  String get connectionRemoved;
  String get disconnectQuestion;
  String get disconnectDesc;
  String get renamePartner;
  String get renamePartnerHint;
  String get resetNickname;
  String joinMeLinkText(String link);
  String get custom;
  String membersCountBracket(int count);

  // ── Memory Lane Screen ──
  String get memoryLane;
  String get addMemoryBtn;
  String get pinned;

  // ── Timer Card ──
  String get timers;
  String get failedUploadBackground;

  // -- Mini Mood Calendar --
  String get todayLabel;

  // ── Date helpers ──
  String get todayDate;
  String get yesterday;
  List<String> get shortMonths;
  List<String> get shortWeekdays;

  // ── I Miss You / Vibes ──
  String get iMissYou;
  String get iMissYouSent;
  String missYouNotifTitle(String name);
  String get missYouNotifBody;
  String missYouStreak(int count);
  String get thinkingOfYou;
  String get wantHug;
  String get vibeSent;
  String get customVibe;
  String get customVibeTitle;
  String get customVibeHint;
  String thinkingOfYouNotifTitle(String name);
  String wantHugNotifTitle(String name);
  String customVibeNotifTitle(String name);

  // ── Photo Card ──
  String get sharedAPicture;
  String kmFromYou(String km);
  String get openInMaps;
  String get justNow;
  String minutesAgo(int m);
  String hoursAgo(int h);
  String daysAgo(int d);

  // ── Memory Lane Feed ──
  String get sharedAVideo;
  String get sharedAVideoLink;
  String get sharedAThought;
  String get sharedALocation;
  String get sharedMusic;
  String get vibesTo;
  String get setARoute;
  String get isListening;
  String get playTrack;
  String get note;

  // ── Memory Lane (extended) ──
  String get noMemoriesYetDesc;
  String get unpinMemory;
  String get pinMemory;
  String get saveToDevice;
  String get editMemory;
  String get deleteMemory;
  String get deleteMemoryQuestion;
  String get actionCannotBeUndone;
  String get editMemoryTitle;
  String get titleOptional;
  String get description;
  String get locationName;
  String get changeLocationOnMap;
  String get pickLocationOnMap;
  String get saveChanges;
  String get addMemoryTitle;
  String get chooseWhatToShare;
  String newMemory(String type);
  String get memoryDetails;
  String get writeYourNote;
  String get descriptionOptional;
  String get locationNameHint;
  String get locationSet;
  String get useCurrent;
  String get pickOnMap;
  String get songDetails;
  String get songName;
  String get artistsCommaSeparated;
  String get egArtists;
  String get source;
  String get streamingLink;
  String get fetched;
  String get pasteLinkFromService;
  String get autoFetchSongInfo;
  String get orDivider;
  String get fileSelected;
  String get pickAudioFromDevice;
  String get uploadingMemory;
  String get failedUploadPhotos;
  String get failedUploadVideo;
  String get memoryAddedSuccess;
  String failedAddMemory(String e);
  String get noMediaUrl;
  String get downloading;
  String get savedToGallery;
  String savedToPath(String path);
  String downloadFailed(String e);
  String failedSelectPhotos(String e);
  String failedSelectVideo(String e);
  String get locationServicesDisabled;
  String get locationPermissionDenied;
  String get cameraPermissionDenied;
  String get failedGetLocation;
  String get tapToSelectPhotos;
  String get tapToSelectVideo;
  String get adultContent;
  String get photoBlurred;
  String get fromGallery;
  String get byLink;
  String get videoLink;
  // ── Books ──
  String get books;
  String get bookSearchHint;
  String get searchBooksPrompt;
  String get noBooksFound;
  String get bookSearchFailed;
  String get bookSearchFailedHint;
  String get bookEnterManually;
  String get bookManualEntryHint;
  String get sharedABook;
  String get bookAuthorLabel;
  String get bookAuthorHint;
  String get bookTitleHint;
  String get bookDetails;
  String get bookReadMore;
  String get bookSearchAgain;

  // ── Movies & series ──
  String get movies;
  String get movieSearchHint;
  String get searchMoviesPrompt;
  String get noMoviesFound;
  String get movieSearchFailed;
  String get movieSearchFailedHint;
  String get movieEnterManually;
  String get movieManualEntryHint;
  String get movieNoToken;
  String get sharedAMovie;
  String get movieTitleHint;
  String get movieOriginalTitleHint;
  String get movieDetails;
  String get movieReadMore;
  String get movieSearchAgain;

  // ── Rating & review (books / movies) ──
  String get yourRating;
  String get ratingNotRated;
  String get ratingHint;
  String get ratingMasterpiece;
  String get ratingExcellent;
  String get ratingGood;
  String get ratingMixed;
  String get ratingBad;
  String get ratingAwful;
  String get yourReview;
  String get reviewHint;

  // ── Memory date picker ──
  String get memoryDateLabel;
  String get memoryDateNow;
  String get memoryDatePickDate;
  String get memoryDatePickTime;
  String get memoryDateClear;
  String get fetchData;
  String get supportedPlatformsHint;
  String get supportedPlatforms;
  String get pasteLinkSupported;
  String get gotIt;
  String get sideActionTitle;
  String get sideActionOpenFeed;
  String get sideActionCreatePin;
  String get sideActionHint;
  String get supportedServices;
  String get pasteLinkFromSupported;
  String get selectTextAndPress;
  String get spoiler;
  String get deleteComment;
  String get deleteCommentQuestion;
  String get comments;
  String get writeAComment;
  String get noCommentsYet;
  String nPhotos(int count);
  String get noPhotoAttached;
  String get unknownLocation;
  String get openInGoogleMaps;
  String get audioFile;
  String get unknownTrack;
  String get noAudioUrl;
  String get cannotPlayAudio;
  String openIn(String name);
  String get tapToOpen;
  String get videoBadge;
  String get updateAvailableTitle;
  String get updateAvailableSubtitle;
  String get updateWhatsNew;
  String get updateButton;
  String get updateLaterButton;
  String get updateRestartButton;
  String get forceUpdateTitle;
  String get forceUpdateBody;
  String get forceUpdateButton;
  String get noteBadge;
  String get youtubeBadge;
  String get photoNotUploaded;
  List<String> get fullMonths;
  String formatDateAt(String month, int day, int year, String time);

  // ── Relationship Status Screen ──
  String get noActiveConnection;
  String get chooseAStatus;
  String get customStatuses;
  String get currentStatus;
  String get notSet;
  String get clearStatus;
  String statusSetTo(String status);
  String failedSetStatus(String e);
  String get statusCleared;
  String failedClearStatus(String e);
  String get customStatusAdded;
  String failedAddStatus(String e);
  String get statusUpdated;
  String failedUpdateStatus(String e);
  String get deleteStatus;
  String deleteStatusConfirm(String label);
  String get statusDeleted;
  String failedDeleteStatus(String e);
  String get editStatus;
  String get emojiLabel;
  String get emojiHint;
  String get labelField;
  String get egLivingTogether;
  String get update;

  // ── Map Picker Screen ──
  String get selectLocationOnMap;
  String get selectedLocation;
  String get selectLocation;
  String get confirm;
  String get gettingAddress;
  String get tapOnMapToSelect;
  String get failedGetCurrentLocation;

  // ── Mood Calendar (extended) ──
  String get averageMood;
  String get great;
  String get good;
  String get okay;
  String get bad;
  String get awful;
  String get notEnoughData;
  String moodRecorded(String label);
  String get noMoodRecorded;
  String get moodScorePrefix;
  List<String> get shortWeekdaysSingleChar;
  List<String> get longWeekdays;

  // ── Timer / Expandable Timer Card ──
  String get noTimers;
  String get createTimer;
  String get editTimer;
  String get timerNameLabel;
  String get egAnniversary;
  String get targetDate;
  String get startDate;
  String get dateFormatHint;
  String get symbolLabel;
  String get countdownMode;
  String get countdownPastDateWarning;
  String get setAsMain;
  String get saveSettings;
  String get deleteTimerQuestion;
  String timerDeleteConfirm(String name);

  // ── Petal Timer Dial ──
  String get yearsLabel;
  String get monthsShortLabel;
  String get daysShortLabel;
  String get hoursLabel;
  String get minLabel;
  String get secLabel;

  // ── Widget Screen (extended) ──
  String get homeScreenWidgets;
  String get addToHomeScreen;
  String get setAsPhotoOfDay;
  String get widgetAddedToHome;
  String failedAddWidget(String e);
  String get daysTogetherStat;
  String get memoriesStat;
  String get drawingsStat;
  String get missYousStat;
  String get daysLeft;
  String get daysElapsed;
  String get noTimersWidget;
  String get photoOfDay;
  String get mine;
  String get onWidget;
  String get randomSource;
  String get ownPhoto;
  String get saveToMemoryLane;
  String get regenerate;
  String get none;
  String yearsAlready(int years);
  String get pairWidgetTitle;
  String get pairWidgetSubtitle;
  String get daysCounterSubtitle;
  String get timerWidgetTitle;
  String get timerWidgetSubtitle;
  String get photoDayRandomSubtitle;
  String get photoDayCustomSubtitle;
  String get photoDayPartnerSubtitle;
  String get moodWidgetSubtitle;
  String get relationshipStatsSubtitle;
  String get daysCounterLabel;
  String get addTimerHint;
  String get noTimersAddHint;
  String get soloTimerBannerTitle;
  String get soloTimerBannerSubtitle;
  String get selectTimerForWidget;
  String get daysShortLeft;
  String get daysShortElapsed;
  String get partnerPhotoWillAppear;
  String get choosePhotoBelow;
  String get randomPhotoFromMemories;
  String get photoSource;
  String get fromMemories;
  String get fromGalleryLabel;
  String get widgetModeMine;
  String get widgetModePartner;
  String get widgetInstances;
  String get widgetNotAddedYet;
  String widgetSlotTitle(int index);
  String get addedWidgetsWillAppearHere;
  String get addSeparateWidgetHint;
  String get widgetDisplaySource;
  String get widgetDisplayPhoto;
  String get noPhotoSelected;

  // ── Profile (extended) ──
  String get exportMemories;
  String get resetMissYouCount;
  String get resetMissYouConfirmTitle;
  String get resetMissYouConfirmBody;
  String get noActiveGroupForExport;
  String get creatingArchive;
  String exportError(String e);
  String get relationshipStats;

  // ── Home Screen (extended) ──
  String get startWithBlankCanvas;
  String get openSavedDrawing;
  String get newPhoto;
  String get titleHint;
  String get descriptionOptionalHint;
  String get setAsWidgetPhoto;

  // ── Mini Mood Calendar (extended) ──
  List<String> get shortWeekdaysUpper;

  // ── Notification Settings ──
  String get notifMissYou;
  String get notifMissYouSub;
  String get notifNewMemory;
  String get notifNewMemorySub;
  String get notifMood;
  String get notifMoodSub;
  String get notifChat;
  String get notifChatSub;
  String get notifDaysTogether;
  String get notifDaysTogetherSub;
  String daysTogetherNotifBody(int days);
  String get daysTogetherNotifTagline;
  String get openSystemSettings;
  String get notifSystemSettingsHint;

  // ── Chat ──
  String get chatTitle;
  String get chatHint;
  String get chatEmpty;
  String get chatEditMessage;
  String get chatDeleteMessage;
  String get chatReply;
  String chatReplyingTo(String name);
  String chatTyping(String name);
  String get chatEdited;
  String get chatDeletedPlaceholder;
  String get chatSendFailed;
  String get chatAttachPin;
  String get chatSave;
  String chatNotifTitle(String name);
  String moodNotifTitle(String name);
  String chatDeleteConfirm(String text);
  /// Разделитель непрочитанных в чате (как в Telegram).
  String get chatNewMessages;
  /// Заголовок-разделитель по дате в чате: «Сегодня»/«Вчера»/«5 июня».
  String chatDateHeader(DateTime day);
  String get chatBgTitle;
  String get chatBgSet;
  String get chatBgChange;
  String get chatBgRemove;
  String chatBgConfirmBody(int price);
  String get chatBgCharged;

  // ── Lock Screen Mood ──
  String get lockScreenMood;
  String get lockScreenMoodSubtitle;
  String get lockScreenMoodToggle;
  String get lockScreenMoodToggleSub;
  String get lockScreenMoodNoMood;
  String get lockScreenMoodSetHint;

  // ── Photo Grid Widget ──
  String get photoGridWidget;
  String get photoGridWidgetSubtitle;
  String get photoGridCount;
  String get photoGridSelectPhotos;
  String get photoGridAddPhoto;
  String get photoGridCountLabel;

  // ── Memory Lane Gallery ──
  String get goToPin;
  String get openPhotoGallery;
  String get allMediaGallery;
  String get loadMore;

  // ── Home screen / photo caption dialog / mascot card ──
  String get previewLabel;
  String get photoSent;
  String get partnerFallback;
  String get captionDestMemories;
  String get captionDestMemoriesSub;
  String get captionDestPairWidget;
  String captionDestPairWidgetSub(String partner);
  String get captionDestPartnerWidget;
  String captionDestPartnerWidgetSub(String partner);
  String get groupMascot;
  String get tapForGallery;
  String get selectMascot;
  String get showLabel;
  String streakLabel(int days);

  // ── Widget screen ──
  String get widgetStreakTitle;
  String get widgetStreakSubtitle;
  String get widgetPetalTimerTitle;
  String get widgetPetalTimerSubtitle;
  String get widgetPhotoTitle;
  String get widgetPhotoSubtitle;
  String get streakTogetherCaps;
  String get daysInARow;
  String get keepItUp;
  String get ourPhotosInsteadOfDrawing;
  String get daysPhotosDescription;
  String unlockForCoins(int price);
  String get showOurPhotos;
  String get partnerNoProfilePhoto;
  String get addYourProfilePhoto;
  String notEnoughCoinsNeed(int price);
  String get daysPhotosDone;
  String get purchaseFailedTryLater;
  String personalPhotosHelp(String partner);
  String get personalPhotosHelpShort;
  String get uploadedPhotosToMemoryLane;
  String partnerSharesPhotosHelp(String partner, int count);
  String partnerNotSharedHelp(String partner);
  String get selectPhotosForPartner;
  String photosUnit(int n);
  String get noPhotosFromPartner;
  String get noPhotosAdded;
  String get onePhotoNoCarousel;
  String photoCountOnUnlock(int count);
  String photoCountInterval(int count, String interval);
  String intervalLabel(int minutes);
  String get partnerPhotoTitle;
  String partnerSharedCountHelp(int count);
  String get partnerSharedOnePhoto;
  String get partnerNotSharedYet;
  String get changePhotosLabel;
  String get onUnlockOption;
  String get byTimeOption;
  String get every15Minutes;
  String get every30Minutes;
  String get everyHourOption;
  String get every3HoursOption;
  String get createPostcardTitle;
  String get createPostcardSubtitle;
  String get whereToSendPhoto;
  String get sendLabel;
  String get widgetPhotoCaption;

  // ── Mascot gallery ──
  String get mascotSaveFailed;
  String get mascotLoadFailed;
  String get transparentBgTitle;
  String get transparentBgBody;
  String get mascotNameTitle;
  String get enterNameHint;
  String get mascotLimitReached;
  String mascotDeactivated(String name);
  String mascotActivated(String name);
  String get rename;
  String get deleteMascotTitle;
  String deleteMascotBody(String name);
  String recordStreakDays(int days);
  String get deactivateLabel;
  String get makeActiveLabel;
  String get editLabel;
  String get exportPng;
  String get groupMascots;
  String mascotsCount(int count, int max);
  String get limitLabel;
  String get mascotsLoadFailedMultiline;
  String get artistCredit;
  String get uploadPhotoTooltip;
  String get drawLabel;
  String get streakBroken;
  String get streakKeepHint;
  String get streakStartHint;
  String get fromUs;
  String recordStreakBadge(int days);

  // ── Mascot draw screen ──
  String get drawSomethingFirst;
  String genericError(String e);
  String get drawMascotTitle;
  String get toolBrush;
  String get toolPencil;
  String get toolMarker;
  String get toolEraser;
  String get toolFill;
  String get toolLine;
  String get toolRect;
  String get toolCircle;
  String get toolTriangle;
  String get fillAction;
  String get resetSize;
  String get undoLabel;
  String get redoLabel;
  String get underlayLabel;
  String get drawHintEdit;
  String get drawHintDraw;
  String get colorLabel;
  String get hueLabel;
  String get saturationLabel;
  String get brightnessLabel;
  String get selectAction;

  // ── Postcard templates ──
  String get pcNamesFallback;
  String get pcLabelNames;
  String get pcLabelDaysCaption;
  String get pcLabelMessage;
  String get pcLabelCaption;
  String get pcLabelPolaroidCaption;
  String get pcLabelMessageAlt;
  String get pcDaysTogether;
  String get pcMsgTogether;
  String get pcDaysOfLove;
  String get pcMsgPolaroid;
  String get pcDaysNearby;
  String get pcMsgBloom;
  String get pcNightsUnderSky;
  String get pcMsgNightSky;

  // ── Photo carousel editor ──
  String get addOneToTenPhotos;
  String photoCountCarousel(int count);
  String get addMorePhotosCarouselHint;
  String get dragToReorder;
  String photoNumber(int n);
  String get mainPhoto;
  String positionNumber(int n);
  String get addMore;
  String get fromDevice;
  String get fromFeed;

  // ── Profile screen ──
  String get cropAvatarTitle;
  String get avatarTitle;
  String get appIconTitle;
  String get appIconUpdateHint;
  String get appIconChangeFailed;
  String get viewAction;
  String get enterDateFormat;
  String yearRange(int first, int last);
  String get enterTimeFormat;
  String get dateHintFormat;
  String get timeHintFormat;
  String get openCalendar;

  // ── Memory Lane screen ──
  String get refreshTooltip;
  String get memoriesMapTooltip;
  String kpRating(String rating);
  String get editLocation;
  String get addLocation;
  String get photoVideoNote;
  String distanceLabel(double meters);
  String get appNotInstalled;
  String get watchTogether;

  // ── Watch Together ──
  String get watchTogetherAdPrompt;
  String get watchAction;
  String get youtubeLinkHint;
  String get startAction;
  String get youtubeLinkInvalid;
  String invitesToWatchTogether(String hostName);
  String get joinAction;
  String get partnerEndedWatchTogether;
  String get videoCannotWatchTogether;
  String get videoEmbedBlockedHint;
  String get chooseAnother;
  String get openOnYoutube;
  String get watchingTogether;
  String get partnerJoined;
  String get waitingForPartner;
  String get syncedPlaying;
  String get syncedPaused;
  String get writeFirstMessage;
  String get messageInputHint;

  // ── Memory photo picker ──
  String get selectOnePhoto;
  String get maxSelected;
  String selectUpToPhotos(int n);
  String get selectPhotosPrompt;
  String addWithCount(int n);
  String get failedToLoadMemories;
  String get noPhotosInMemoryLane;
  String get inWidget;

  // ── Postcard editor ──
  String get postcardTitle;
  String failedToSave(Object e);
  String get changePhoto;
  String get addPhotoFromGallery;
  String get tapAnyTextToEdit;
  String get creating;
  String get sharePostcard;

  // ── Memories map ──
  String get noGeoMemories;
  String get addLocationHint;
  String get placeFallback;
  String memoriesUnit(int n);

  // ── Welcome slides ──
  String get welcomeSlide1Title;
  String get welcomeSlide2Title;
  String get welcomeSlide3Title;

  // ── Memory photo form ──
  String get newEntry;
  String get photoVideo;
  String get optionalTapToSelect;
  String itemsShort(int n);

  // ── Misc widgets ──
  String get dragHint;
  String get addPhoto;
  String get groupMascotBanner;
  String get goToGallery;
  String get hide;
  String coinsPlus(int n);
  String moodScoreLabel(int score, int max);
  List<String> get monthAbbrev;

  // ── Map picker ──
  String get placeOrCoordsHint;
  String get goToCoordinates;

  // ── Misc ──
  String get chatBgSaveFailed;
  String get timeFormatHint;
  String get bookTitleLanguageHint;

  // ── Live location map ──
  String get liveMapTitle;
  String get liveMapEnableCta;
  String get liveMapEnableHint;
  String get liveMapStopCta;
  String get liveMapStopped;
  String get liveMapPermissionDenied;
  String get liveMapWaitingPartner;
  String get liveMapYou;
  String get liveMapCenterMe;
  String get liveMapShowBoth;
  String get liveMapOpenFull;
  String get liveMapNotPaired;
  String get liveLocationServiceTitle;
  String get liveLocationServiceText;
  String get liveLocationJustNow;
  String liveLocationAgo(String value);
  String get unitCm;
  String get unitM;
  String get unitKm;
  String get unitMinShort;
  String get unitHourShort;
  String get unitDayShort;

  // Получение подарка
  String giftFromPartner(String name);
  String get giftAccepted;
  String giftBunnyMisses(int misses);
  String get giftIncomingTitle;
  String giftIncomingCount(int n);
  String get giftNoteHint;
  String get giftNoteSkip;
  String get giftNoteSend;
  String get giftWishHint;
  String get giftWishSend;
  String get giftWishEmpty;
  String giftMutualBonus(int coins);
  String giftSunriseGreeting(String name);
  String get giftAccept;
  String get giftDecline;
  String get giftFlipCoin;
  String get giftFlipYou;
  String get giftFlipPartner;

  // Профиль партнёра
  String get partnerGiftsTitle;
  String get partnerGiftsEmpty;
  String get partnerMissTitle;
  String get partnerMissEmpty;
  String partnerGiftsChip(int count);
  String partnerMissChip(int count);
  String partnerDaysTogether(int days);
  String partnerMissPeak(String weekday);
  String weekdayShort(int weekday);
  String weekdayLong(int weekday);

  // Подарки
  String giftPushBody(String giftName);
  String get giftShopTitle;
  String get giftSent;
  String get giftNotEnoughCoins;
  String get giftNoConnection;
  String get giftFailed;
}

// ══════════════════════════════════════════════════════════════════════════════
// RUSSIAN STRINGS
// ══════════════════════════════════════════════════════════════════════════════

class _RuStrings extends AppStrings {
  const _RuStrings();

  // ── Common ──
  @override
  String get save => 'Сохранить';
  @override
  String get cancel => 'Отмена';
  @override
  String get delete => 'Удалить';
  @override
  String get edit => 'Изменить';
  @override
  String get add => 'Добавить';
  @override
  String get done => 'Готово';
  @override
  String get loading => 'Загрузка...';
  @override
  String get error => 'Ошибка';
  @override
  String get ok => 'OK';
  @override
  String get yes => 'Да';
  @override
  String get no => 'Нет';
  @override
  String get close => 'Закрыть';
  @override
  String get back => 'Назад';
  @override
  String get reset => 'Сбросить';
  @override
  String get clear => 'Очистить';

  // ── Welcome ──
  @override
  String get welcomeTitle1 => 'Это пространство только\nдля ';
  @override
  String get welcomeTitle2 => 'вас двоих';
  @override
  String get welcomeSubtitle => 'Моменты, чувства, связь';
  @override
  String get welcomeFeatureMemories => 'Общие воспоминания, фото и заметки';
  @override
  String get welcomeFeatureMood => 'Настроение, статусы и маленькие ритуалы';
  @override
  String get welcomeFeatureWidgets => 'Таймеры, виджеты и карта ваших мест';
  @override
  String get welcomeStepCreateProfile => '1. Создайте профиль и войдите';
  @override
  String get welcomeStepConnectPartner =>
      '2. Подключите партнёра по ссылке, коду или QR';
  @override
  String get welcomeStepStartTogether =>
      '3. Добавьте первое воспоминание и настройте ваше пространство';
  @override
  String get createAccount => 'Создать аккаунт';
  @override
  String get alreadyHaveAccount => 'Уже есть аккаунт';
  @override
  String get privateSecure => 'ПРИВАТНО И БЕЗОПАСНО';

  // ── Login ──
  @override
  String get welcomeBack => 'С возвращением!';
  @override
  String get loginToAccount => 'Войдите в свой аккаунт';
  @override
  String get signInWithGoogle => 'Войти через Google';
  @override
  String get or => 'или';
  @override
  String get email => 'Email';
  @override
  String get yourEmail => 'Ваш email';
  @override
  String get password => 'Пароль';
  @override
  String get yourPassword => 'Ваш пароль';
  @override
  String get login => 'Войти';
  @override
  String get noAccount => 'Нет аккаунта? ';
  @override
  String get create => 'Создать';
  @override
  String get invalidEmail => 'Введите корректный email';
  @override
  String get enterPassword => 'Введите пароль';
  @override
  String get loginFailed => 'Не удалось войти. Попробуйте ещё раз.';
  @override
  String get profileNotFound => 'Профиль не найден. Зарегистрируйтесь заново.';
  @override
  String get userNotFound => 'Пользователь с таким email не найден';
  @override
  String get wrongPassword => 'Неверный пароль';
  @override
  String get invalidEmailFormat => 'Некорректный email';
  @override
  String get tooManyAttempts => 'Слишком много попыток. Попробуйте позже';
  @override
  String get serverNotResponding => 'Сервер не отвечает. Проверьте интернет.';
  @override
  String get googleNotResponding => 'Google не отвечает. Проверьте интернет.';
  @override
  String loginError(String e) => 'Ошибка входа: $e';
  @override
  String googleLoginError(String e) => 'Ошибка входа через Google: $e';

  // ── Setup ──
  @override
  String get whoAreYou => 'Кто вы?';
  @override
  String get selectGenderForTheme => 'Выберите пол для настройки темы';
  @override
  String get boy => 'Парень';
  @override
  String get girl => 'Девушка';
  @override
  String get continueBtn => 'Продолжить';
  @override
  String get createProfile => 'Создайте профиль';
  @override
  String get signInGoogleOrManual =>
      'Войдите через Google или\nзаполните вручную';
  @override
  String get orManually => 'или вручную';
  @override
  String get name => 'Имя';
  @override
  String get yourName => 'Ваше имя';
  @override
  String get minCharsPassword => 'Минимум 6 символов';
  @override
  String get start => 'Начать';
  @override
  String get alreadyHaveAccountQuestion => 'Уже есть аккаунт? ';
  @override
  String get enterYourName => 'Введите ваше имя';
  @override
  String get enterValidEmail => 'Введите корректный email';
  @override
  String get selectGender => 'Выберите пол';
  @override
  String get passwordMin6 => 'Пароль должен быть минимум 6 символов';
  @override
  String get accountExists => 'Аккаунт существует';
  @override
  String get emailAlreadyRegistered =>
      'Этот email уже зарегистрирован. Хотите войти в существующий аккаунт?';
  @override
  String registrationError(String e) => 'Ошибка регистрации: $e';
  @override
  String get agreeToTermsPrefix => 'Я принимаю ';
  @override
  String get termsOfUse => 'Условия использования';
  @override
  String get agreeToTermsAnd => ' и ';
  @override
  String get privacyPolicyLink => 'Политику конфиденциальности';
  @override
  String get forgotPassword => 'Забыли пароль?';
  @override
  String passwordResetSent(String email) =>
      'Письмо для сброса пароля отправлено на $email. '
      'Проверьте почту и папку «Спам».';
  @override
  String get passwordResetError =>
      'Не удалось отправить письмо. Проверьте email и попробуйте позже.';
  @override
  String get showPassword => 'Показать';
  @override
  String get hidePassword => 'Скрыть';
  @override
  String get min8Chars => 'Минимум 8 символов';
  @override
  String get oneUppercase => '1 заглавная буква';
  @override
  String get oneSpecialChar => '1 спец. символ';
  @override
  String get fullName => 'Полное имя';
  @override
  String get createAccountBtn => 'Создать аккаунт';
  @override
  String get continueWithGoogle => 'Продолжить через Google';
  @override
  String get continueWithApple => 'Продолжить через Apple';
  @override
  String get signInWith => 'Войти через';
  @override
  String get signUpWith => 'Регистрация через';
  @override
  String get rememberMe => 'Запомнить меня';
  @override
  String get alreadyHaveAccountLogin => 'Уже есть аккаунт?';
  @override
  String get passwordRequirements => 'Требования к паролю';

  // ── Home ──
  @override
  String get home => 'Главная';
  @override
  String get widgets => 'Виджеты';
  @override
  String get connect => 'Связь';
  @override
  String get profile => 'Профиль';
  @override
  String get solo => 'Solo';
  @override
  String get waitingForConnection => 'ОЖИДАНИЕ ПОДКЛЮЧЕНИЯ';
  @override
  String daysLabel(String suffix) => 'ДНЕЙ $suffix';
  @override
  String monthsLabel(String suffix) => 'МЕСЯЦЕВ $suffix';
  @override
  String timeLabel(String suffix) => 'ВРЕМЯ $suffix';
  @override
  String get inLove => 'ВЛЮБЛЕНЫ';
  @override
  String get together => 'ВМЕСТЕ';
  @override
  String get days => 'Дни';
  @override
  String get months => 'Месяцы';
  @override
  String get time => 'Время';
  @override
  String get inviteYourPartner => 'Пригласить партнёра';
  @override
  String get shareLinkCodeQr => 'Поделитесь ссылкой, кодом или QR';
  @override
  String get relationshipMemoryLane => 'Лента воспоминаний';
  @override
  String get memoriesWillAppear => 'Воспоминания появятся здесь';
  @override
  String get connectWithPartnerToStart => 'Подключите партнёра, чтобы начать';
  @override
  String partnerIsMood(String name, String mood) => '$name — $mood';
  @override
  String get answerSent => 'Ответ отправлен!';
  @override
  String get dailyReflection => 'Ежедневная рефлексия';
  @override
  String get today => 'СЕГОДНЯ';
  @override
  String get answerPrompt => 'Ответить';
  @override
  String get editAnswer => 'Редакт. ответ';
  @override
  String get clearMood => 'Убрать настроение';
  @override
  String get removeMood => 'Убрать настроение';
  @override
  String get howAreYouFeeling => 'Как вы себя чувствуете?';
  @override
  String get partnerWillSeeMood => 'Партнёр увидит ваше настроение';
  @override
  String get moodTabLabel => 'Настроение';
  @override
  String get ailmentTabLabel => 'Самочувствие';
  @override
  String get ailmentPickerSubtitle => 'Партнёр увидит, что вам нездоровится';
  @override
  String get clearAilment => 'Я здоров(а)';
  @override
  String partnerAilmentBanner(String name, String label) =>
      '$name приболел(а): $label';
  @override
  String moodDateLabel(String dateLabel) => 'Настроение — $dateLabel';
  @override
  String get indicateMoodForDay => 'Укажите настроение для этого дня';
  @override
  String get relationshipStatus => 'Статус отношений';
  @override
  String get chooseHowToConnect => 'Выберите тип связи';
  @override
  String get inLoveStatus => 'Влюблённые';
  @override
  String get perfectForCouples => 'Для романтических пар';
  @override
  String get married => 'Женаты';
  @override
  String get forMarriedPartners => 'Для партнёров в браке';
  @override
  String get friends => 'Друзья';
  @override
  String get connectWithBestFriend => 'Связь с лучшим другом';
  @override
  String get bestBuddies => 'Лучшие друзья';
  @override
  String get forInseparableCompanions => 'Для неразлучных друзей';
  @override
  String get addCustomStatus => 'Добавить свой статус';
  @override
  String get editCustomStatus => 'Редактировать статус';
  @override
  String get addCaption => 'Добавить подпись';
  @override
  String get optionalDescribe => 'Необязательно — опишите момент';
  @override
  String get writeSmth => 'Напишите что-нибудь...';
  @override
  String get skip => 'Пропустить';
  @override
  String get post => 'Отправить';
  @override
  String get posting => 'Отправка...';
  @override
  String get failedUploadPhoto => 'Не удалось загрузить фото';
  @override
  String get memoryNotSaved =>
      'Фото не попало в воспоминания. Проверьте вход и повторите.';
  @override
  String get achievementUnlocked => 'Достижение получено!';
  @override
  String get achievementsTitle => 'Достижения пары';
  @override
  String get achievementDone => 'Получено';
  @override
  String achievementsUnlockedOf(int unlocked, int total) =>
      'Открыто $unlocked из $total';
  @override
  String get markSecret => 'Сделать секретным';
  @override
  String get unmarkSecret => 'Убрать из секретных';
  @override
  String get markedSecret => 'Скрыто в секретные 🔒';
  @override
  String get unmarkedSecret => 'Больше не секретное';
  @override
  String get secretMemories => 'Секретные';
  @override
  String get enterPinTitle => 'Введите PIN';
  @override
  String get setPinTitle => 'Задайте PIN';
  @override
  String get setPinHint =>
      'Минимум 4 цифры. PIN хранится только на этом устройстве.';
  @override
  String get wrongPin => 'Неверный PIN';
  @override
  String get pinTooShort => 'Минимум 4 цифры';
  @override
  String get pinDone => 'Готово';
  @override
  String get timeCapsule => 'Капсула времени';
  @override
  String get capsuleIntro =>
      'Запечатай письмо или фото — оно откроется в выбранный день 💌';
  @override
  String get capsuleLetterHint => 'Напиши письмо в будущее…';
  @override
  String get capsuleAttachPhoto => 'Добавить фото';
  @override
  String get capsuleOpenDate => 'Дата открытия';
  @override
  String get change => 'Изменить';
  @override
  String capsuleOpensIn(int days) =>
      days <= 0 ? 'откроется сегодня' : 'через $days дн.';
  @override
  String get capsulePreset1m => 'через месяц';
  @override
  String get capsulePreset6m => 'через полгода';
  @override
  String get capsulePreset1y => 'через год';
  @override
  String get capsuleSeal => 'Запечатать';
  @override
  String get capsuleNeedsContent => 'Добавь письмо или фото';
  @override
  String get capsuleNeedsFutureDate =>
      'Дата открытия должна быть в будущем';
  @override
  String capsuleOpensOn(String date) => 'Откроется $date';
  @override
  String capsuleFrom(String name) => 'от $name';
  @override
  String capsuleNotReady(String date) => 'Ещё рано 🙈 Откроется $date';
  @override
  String get capsuleAddSub => 'Письмо в будущее';
  @override
  String get capsuleCreated => 'Капсула запечатана 💌';
  @override
  String get capsuleOpenedTitle => 'Капсула времени открылась! 💌';
  @override
  String get capsuleOpenedBody => 'Загляни в ленту воспоминаний';
  @override
  String capsuleOpenedBodyNamed(String title) => '«$title» ждёт тебя в ленте';
  @override
  String get postedToMemoryLane => 'Добавлено в ленту воспоминаний! 📸';
  @override
  String get moodCalendar => 'Календарь настроений';
  @override
  String get seeAll => 'Все';
  @override
  String get addMemory => 'Добавить';
  @override
  String get viewAll => 'Все';

  // ── Widget Screen ──
  @override
  String get widgetsTitle => 'Виджеты';
  @override
  String get resetBtn => 'Сбросить';
  @override
  String get desktopPreview => 'Превью на рабочем столе';
  @override
  String get me => 'Я';
  @override
  String get partner => 'Партнёр';
  @override
  String get noStatus => 'Нет статуса';
  @override
  String get myWidget => 'Мой виджет';
  @override
  String get tapToEdit => 'Нажми, чтобы изменить';
  @override
  String get editBtn => 'Изменить';
  @override
  String widgetOfPartner(String name) => 'Виджет $name';
  @override
  String get emptyYet => 'Пока пусто';
  @override
  String get updated => 'Обновлено';
  @override
  String get live => 'Live';
  @override
  String get mood => 'Настроение';
  @override
  String get status => 'Статус';
  @override
  String get message => 'Сообщение';
  @override
  String get photo => 'Фото';
  @override
  String get photoUploaded => 'Фото загружено';
  @override
  String get widgetPhotoOwnerOnlyHint =>
      'При добавлении выбери, куда отправить: парный виджет, «Фото партнёра», воспоминания';
  @override
  String get music => 'Музыка';
  @override
  String get addBtn => 'Добавить';
  @override
  String get widgetSettings => 'Настройки виджета';
  @override
  String get photoToMemoryLane => 'Фото → Лента воспоминаний';
  @override
  String get autoSavePhotoToMemories =>
      'Автоматически сохранять фото в воспоминания';
  @override
  String get messagestoMemoryLane => 'Сообщения → Лента воспоминаний';
  @override
  String get autoSaveMessages => 'Автоматически сохранять сообщения';
  @override
  String get musicToMemoryLane => 'Музыка → Лента воспоминаний';
  @override
  String get autoSaveTracks => 'Автоматически сохранять треки';
  @override
  String get moodToCalendar => 'Настроение → Календарь';
  @override
  String get autoMarkMoodCalendar =>
      'Автоматически отмечать в календаре настроений';
  @override
  String get connectPartnerForWidgets =>
      'Подключи партнёра, чтобы начать\nобмениваться виджетами';
  @override
  String get chooseMood => 'Выбери настроение';
  @override
  String get statusHint => 'Что у тебя нового?';
  @override
  String get messageHint => 'Напиши что-нибудь приятное...';
  @override
  String get chooseSource => 'Выбери источник';
  @override
  String get camera => 'Камера';
  @override
  String get gallery => 'Галерея';
  @override
  String get musicTitle => 'Музыка';
  @override
  String get trackName => 'Название трека';
  @override
  String get artist => 'Исполнитель';
  @override
  String get linkOptional => 'Ссылка (необязательно)';
  @override
  String get uploadingPhoto => 'Загружаем фото...';
  @override
  String get resetWidget => 'Сбросить виджет?';
  @override
  String get resetWidgetConfirm => 'Все данные твоего виджета будут очищены.';
  @override
  String get notPairedWidgets => 'Виджеты';
  @override
  String get notPairedWidgetsDesc =>
      'Подключи партнёра, чтобы начать\nобмениваться виджетами';

  // ── Profile ──
  @override
  String get user => 'Пользователь';
  @override
  String get noEmail => 'Нет email';
  @override
  String get gender => 'Пол';
  @override
  String get male => 'Мужской';
  @override
  String get female => 'Женский';
  @override
  String get information => 'ИНФОРМАЦИЯ';
  @override
  String get theme => 'Тема';
  @override
  String get relationships => 'ОТНОШЕНИЯ';
  @override
  String get statusLabel => 'Статус';
  @override
  String get partnerLabel => 'Партнёр';
  @override
  String get notSelected => 'Не выбран';
  @override
  String daysTogetherLabel(String days) => '$days дней';
  @override
  String get invitePartnerToCount =>
      'Пригласите партнёра, чтобы начать\nсчитать дни вместе ❤️';
  @override
  String get anniversaryDate => 'Годовщина';
  @override
  String get anniversaryWheelHint =>
      'Для напоминаний. Счётчик «Дни вместе» меняется отдельно — карандашом ✏️ на главном экране';
  @override
  String get firstKissDate => 'Первый поцелуй';
  @override
  String get myBirthday => 'Мой день рождения';
  @override
  String get partnerBirthday => 'День рождения партнёра';
  @override
  String get notifCelebrations => 'Уведомления о праздниках';
  @override
  String get notifCelebrationsHint =>
      'Напомним за день и точно в день годовщины и дня рождения';
  @override
  String get anniversaryTodayTitle => '🎉 С годовщиной!';
  @override
  String get anniversaryTodayBody =>
      'Поздравляем вас с годовщиной вместе! Откройте Togetherly, чтобы отметить этот день.';
  @override
  String get birthdayTodayTitle => '🎂 С днём рождения!';
  @override
  String get birthdayTodayBody =>
      'Сегодня ваш особенный день! Откройте Togetherly, чтобы отметить его вместе.';
  @override
  String get anniversaryTomorrowTitle => '🌹 Завтра годовщина!';
  @override
  String get anniversaryTomorrowBody =>
      'Не забудьте — завтра ваша годовщина. Придумайте что-то особенное!';
  @override
  String get birthdayTomorrowTitle => '🎈 Завтра день рождения!';
  @override
  String get birthdayTomorrowBody =>
      'Завтра ваш день рождения. Откройте Togetherly заранее!';
  @override
  String get celebrationBannerAnniversary => 'С годовщиной! 🎉';
  @override
  String get celebrationBannerBirthday => 'С днём рождения! 🎂';
  @override
  String get daysUntilAnniversary => 'до годовщины';
  @override
  String get daysUntilBirthday => 'до дня рождения';
  @override
  String get inLoveRelType => 'Влюблённые';
  @override
  String get marriedRelType => 'Женаты';
  @override
  String get friendsRelType => 'Друзья';
  @override
  String get bestFriendsRelType => 'Лучшие друзья';
  @override
  String get customStatus => 'Свой статус';
  @override
  String get relationshipType => 'Тип отношений';
  @override
  String get selectPartner => 'Выберите партнёра';
  @override
  String get noConnectedPartners => 'Нет подключённых партнёров';
  @override
  String get settings => 'НАСТРОЙКИ';
  @override
  String get editProfile => 'Редактировать профиль';
  @override
  String get notifications => 'Уведомления';
  @override
  String get privacy => 'Конфиденциальность';
  @override
  String get aboutApp => 'О приложении';
  @override
  String get supportAuthors => 'Поддержать авторов';
  @override
  String get logout => 'Выйти из аккаунта';
  @override
  String get logoutQuestion => 'Выйти?';
  @override
  String get logoutConfirm => 'Вы уверены, что хотите выйти из аккаунта?';
  @override
  String get logoutBtn => 'Выйти';
  @override
  String get deleteAccount => 'Удалить аккаунт';
  @override
  String get deleteAccountQuestion => 'Удалить аккаунт?';
  @override
  String get deleteAccountConfirm =>
      'Аккаунт и все ваши данные будут удалены без возможности восстановления. '
      'Пара будет разорвана. Это действие необратимо.';
  @override
  String get deleteAccountBtn => 'Удалить навсегда';
  @override
  String get deleteAccountReauth =>
      'Для удаления аккаунта войдите заново и повторите.';
  @override
  String get deleteAccountError =>
      'Не удалось удалить аккаунт. Попробуйте ещё раз.';
  @override
  String get chooseColorTheme => 'Выбери цветовую тему';
  @override
  String get themeNamePink => 'Розовая';
  @override
  String get themeNamePurple => 'Фиолетовая';
  @override
  String get themeNameBlue => 'Голубая';
  @override
  String get themeNamePeach => 'Персиковая';
  @override
  String get themeNameSage => 'Шалфейная';
  @override
  String get themeNameMidnight => 'Полуночная';
  @override
  String get themeNameLavender => 'Лавандовая';
  @override
  String get themeNameCherry => 'Вишнёвая';
  @override
  String get themeNameMint => 'Мятная';
  @override
  String get themeNameSunset => 'Закатная';
  @override
  String get themeNameMonochrome => 'Монохром';
  @override
  String get themeNameForest => 'Лесная';
  @override
  String get themeNameOcean => 'Океан';
  @override
  String get themeNameHoney => 'Медовая';
  @override
  String get themeNameLemon => 'Лимонная';
  @override
  String get themeNameSand => 'Песочная';
  @override
  String get themeNameAurora => 'Северное сияние';
  @override
  String get themeNameBordeaux => 'Бордовая';
  @override
  String get themeNameTeal => 'Бирюзовая';
  @override
  String get themeNameNord => 'Нордик';
  @override
  String get themeNameCharcoalTeal => 'Угольная бирюза';
  @override
  String get themeNameCoffee => 'Кофе';
  @override
  String get themeNameForestDark => 'Тёмный лес';
  @override
  String get themeNameGarnet => 'Гранат';
  @override
  String get themeNameDarkHoney => 'Тёмный мёд';
  @override
  String premiumThemeLocked(int price) =>
      'Премиум-тема за $price монет — открой в магазине';
  @override
  String get coinBalance => 'Коины';
  @override
  String get coinShopTitle => 'Магазин Коинов';
  @override
  String get coinShopSubtitle => 'Кастомизация и приятности';
  @override
  String get buyThemeTitle => 'Купить тему?';
  @override
  String buyThemeDescription(String themeName, int price) =>
      'Разблокировать тему «$themeName» за $price монет?';
  @override
  String get buyThemeConfirm => 'Купить';
  @override
  String get notEnoughCoins => 'Недостаточно монет';
  @override
  String get themePurchased => 'Тема разблокирована';
  @override
  String get iconShopTitle => 'Иконки профиля';
  @override
  String get iconShopSubtitle => 'Укрась свой профиль';
  @override
  String get noIconOption => 'Без иконки';
  @override
  String get iconRewardOnly => 'Награда';
  @override
  String get iconRewardHint => 'Эта иконка выдаётся вручную за вклад в проект.';
  @override
  String get iconPurchased => 'Иконка разблокирована';
  @override
  String get watchAdTitle => 'Посмотреть рекламу';
  @override
  String get watchAdSubtitle => 'За просмотр, до 3 раз в день';
  @override
  String get adNotReady => 'Реклама ещё загружается — попробуй через секунду';
  @override
  String get adRewardLimitReached => 'Лимит на сегодня исчерпан — заходи завтра';
  @override
  String get rewardPending => 'Награда зачисляется…';
  @override
  String get coinPacksSectionTitle => 'Купить монеты';
  @override
  String coinPackTitle(int coins) => '$coins монет';
  @override
  String get coinPurchaseSuccess => 'Монеты начислены!';
  @override
  String coinPurchaseSuccessAmount(int coins) => '+$coins монет зачислено';
  @override
  String get coinPurchasePending => 'Платёж обрабатывается…';
  @override
  String get coinPurchaseCancelled => 'Покупка отменена';
  @override
  String get coinPurchaseError => 'Ошибка покупки. Попробуй ещё раз';
  @override
  String get coinStoreUnavailable => 'Магазин недоступен';
  @override
  String get restorePurchasesTitle => 'Восстановить покупки';
  @override
  String get restorePurchasesSuccess => 'Покупки восстановлены';
  @override
  String get restorePurchasesError => 'Не удалось восстановить покупки';
  @override
  String get changesApplyImmediately => 'Изменения применяются сразу';
  @override
  String get dailyBonusTitle => 'Ежедневный вход';
  @override
  String get dailyBonusSubtitle => 'Каждый день при входе';
  @override
  String coinEarned(int amount) => '+$amount монет получено!';
  @override
  String get memoryRewardTitle => 'Добавь воспоминание';
  @override
  String get memoryRewardSubtitle => 'За новое воспоминание, раз в день';
  @override
  String get partnerInviteRewardTitle => 'Пригласи партнёра';
  @override
  String get partnerInviteRewardSubtitle => 'Единоразово при подключении';
  @override
  String get moodStreakRewardTitle => 'Стрик настроения';
  @override
  String get moodStreakRewardSubtitle => 'Оба заполняли 7 дней подряд';
  @override
  String get earnCoinsSection => 'Заработать бесплатно';
  @override
  String get editProfileTitle => 'Редактировать профиль';
  @override
  String get uploading => 'Загрузка...';
  @override
  String get userNotAuthorized => 'Ошибка: пользователь не авторизован';
  @override
  String get failedUploadImage => 'Не удалось загрузить изображение';
  @override
  String get avatarUpdated => 'Аватарка обновлена';
  @override
  String get nameUpdated => 'Имя обновлено';
  @override
  String uploadError(String e) => 'Ошибка загрузки: $e';
  @override
  String get language => 'Язык';
  @override
  String get selectLanguage => 'Выберите язык';
  @override
  String get blobAnimation => 'Blob-анимация';

  // ── Mood Calendar ──
  @override
  String get moodCalendarTitle => 'Календарь настроений';
  @override
  String get moodSettings => 'Настройки настроений';
  @override
  String get moodMultiplePerDay => 'Несколько настроений в день';
  @override
  String get moodMultiplePerDaySubtitle =>
      'Записывать каждое настроение отдельно, а не заменять прежнее';
  @override
  String get zoomIn => 'Увеличить';
  @override
  String get zoomOut => 'Уменьшить';
  @override
  String get week => 'Неделя';
  @override
  String get month => 'Месяц';
  @override
  String get year => 'Год';
  @override
  String get myMood => 'Мои настроения';
  @override
  String partnerMood(String name) => 'Настроения $name';
  @override
  String get moods => 'Настроения';

  // ── Home (continued) ──
  @override
  String get emoji => 'Эмодзи';
  @override
  String get label => 'Название';
  @override
  String get egSoulmates => 'напр., Родные души';
  @override
  String get shareYourThoughts => 'Поделитесь мыслями...';
  @override
  String get draw => 'Рисовать';
  @override
  String get calendar => 'Календарь';
  @override
  String get noMemoriesYet => 'Пока нет воспоминаний';

  // ── Draw Screen ──
  @override
  String get drawTogether => 'Рисуем вместе';
  @override
  String get brush => 'Кисть';
  @override
  String get eraser => 'Ластик';
  @override
  String get panTool => 'Рука';
  @override
  String get fillBg => 'Заливка';
  @override
  String get rotateCanvas => 'Повернуть холст';
  @override
  String get drawLine => 'Линия';
  @override
  String get drawRect => 'Прямоугольник';
  @override
  String get drawCircle => 'Круг';
  @override
  String get drawTriangle => 'Треугольник';
  @override
  String get fillShapes => 'Заливка фигур';
  @override
  String get insertPhoto => 'Вставить фото';
  @override
  String get photoRequiresPartner =>
      'Фото доступно только при совместном рисовании с партнёром';
  @override
  String get photoFromGallery => 'Из галереи';
  @override
  String get photoFromCamera => 'Сделать фото';
  @override
  String get undoAction => 'Отменить';
  @override
  String get redoAction => 'Повторить';
  @override
  String get clearCanvas => 'Очистить';
  @override
  String get clearCanvasConfirm =>
      'Очистить весь холст? Это удалит рисунки обоих.';
  @override
  String get deletePhoto => 'Удалить фото';
  @override
  String get mascotBoyName => 'Пиксик';
  @override
  String get mascotGirlName => 'Пикси';
  @override
  String get mascotSpikyName => 'Спайки';
  @override
  String get mascotLuluName => 'Лулу';
  @override
  String get mascotIskrikName => 'Искрик';
  @override
  String get mascotZhuzhaName => 'Жужа';
  @override
  String get saveDrawing => 'Сохранить';
  @override
  String get shareDrawing => 'Поделиться';
  @override
  String drawingSavedTo(String path) => 'Рисунок сохранён: $path';
  @override
  String get failedToSaveDrawing => 'Не удалось сохранить рисунок';
  @override
  String get failedToShareDrawing => 'Не удалось поделиться рисунком';
  @override
  String get strokeThickness => 'Толщина';
  @override
  String get drawHint =>
      'Начните рисовать! Партнёр увидит ваши штрихи в реальном времени.';
  @override
  String partnerIsDrawing(String name) => '$name рисует…';
  @override
  String get addFirstMemory => 'Добавьте первое воспоминание в Ленту';
  @override
  String get video => 'Видео';
  @override
  String get videoLabel => 'Видео';
  @override
  String get location => 'Локация';
  @override
  String get audio => 'Аудио';
  @override
  List<String> get reflectionQuestions => [
    'Какая маленькая вещь, которую партнёр сделал сегодня, дала вам почувствовать себя ценным?',
    'Какой момент с партнёром заставил вас улыбнуться сегодня?',
    'Что вы восхищаете в партнёре прямо сейчас?',
    'За что в ваших отношениях вы благодарны сегодня?',
    'Какое воспоминание с партнёром вы снова и снова вспоминаете?',
    'Чем партнёр удивил вас в последнее время?',
    'Что делает вашего партнёра уникальным для вас?',
    'Как партнёр поддержал вас сегодня?',
    'Что вы хотите, чтобы партнёр узнал сегодня?',
    'В какое приключение вы хотели бы отправиться вместе?',
    'Какая песня напоминает вам о партнёре и почему?',
    'Что самое лучшее в том, чтобы быть вместе?',
    'Какой маленький добрый поступок партнёра значил больше всего?',
    'Что нового вы узнали о партнёре?',
    'Какая цель у вас общая?',
    'Что вам нравится делать вместе?',
    'Когда вы последний раз чувствовали настоящую связь с партнёром?',
    'Что сделает завтрашний день особенным для обоих?',
    'Какой комплимент вы хотите сделать партнёру сегодня?',
    'Какая привычка партнёра вам втайне нравится?',
  ];

  // ── Draw Gallery / Canvas ──
  @override
  String get palmTool => 'Ладонь';
  @override
  String get drawingMode => 'Режим рисования';
  @override
  String get newCanvas => 'Новый холст';
  @override
  String get myDrawings => 'Мои рисунки';
  @override
  String get untitledCanvas => 'Холст';
  @override
  String get renameCanvas => 'Переименовать';
  @override
  String get deleteCanvas => 'Удалить холст';
  @override
  String get deleteCanvasConfirm =>
      'Удалить этот холст? Это действие необратимо.';
  @override
  String get canvasNameLabel => 'Название холста';
  @override
  String get noDrawingsYet => 'Рисунков пока нет';

  // ── Connect Partner ──
  @override
  String get newGroup => 'Новая';
  @override
  String get waiting => 'Ожидание...';
  @override
  String get deleteGroupConfirm => 'Удалить эту группу?';
  @override
  String get deleteGroupTitle => 'Удалить группу';
  @override
  String get removeGroup => 'Удалить';
  @override
  String get connected => 'Подключены';
  @override
  String groupOf(int count) => 'Группа из $count';
  @override
  String membersCount(int count) => 'УЧАСТНИКИ · $count';
  @override
  String get member => 'Участник';
  @override
  String get online => 'Онлайн';
  @override
  String get offline => 'Не в сети';
  @override
  String get chatOnline => 'в сети';
  @override
  String get chatTypingShort => 'печатает';
  @override
  String get inviteMore => 'Пригласить ещё';
  @override
  String get scanQr => 'Скан QR';
  @override
  String get disconnect => 'Отключиться';
  @override
  String get connectYourPartner => 'Подключите партнёра';
  @override
  String get shareInviteCodeDesc =>
      'Поделитесь кодом приглашения,\nчтобы партнёр присоединился';
  @override
  String get yourInviteCode => 'ВАШ КОД ПРИГЛАШЕНИЯ';
  @override
  String get copy => 'Копия';
  @override
  String get share => 'Поделиться';
  @override
  String get codeCopied => 'Код скопирован!';
  @override
  String shareInviteText(String code, String link) =>
      'Присоединяйся ко мне в Togetherly! Используй код: $code\n\nИли нажми: $link';
  @override
  String get loveAppInvitation => 'Приглашение Togetherly';
  @override
  String get newCodeGenerated => 'Новый код сгенерирован';
  @override
  String get showQr => 'Показать QR';
  @override
  String get haveACode => 'Есть код?';
  @override
  String get connectPartnerBtn => 'Подключить партнёра';
  @override
  String get inviteMoreMembers => 'Пригласить участников';
  @override
  String membersOfMax(int current, int max) => '$current/$max участников';
  @override
  String shareGroupInviteText(String code, String link) =>
      'Присоединяйся к нашей группе в Togetherly! Используй код: $code\n\nИли нажми: $link';
  @override
  String get groupInvitation => 'Приглашение в группу Togetherly';
  @override
  String connectedWithCouple(String name) => 'Вы с $name теперь вместе!';
  @override
  String marriedTo(String name) => 'Вы с $name женаты! 💍';
  @override
  String friendsWith(String name) => 'Вы с $name теперь друзья!';
  @override
  String buddiesWith(String name) => 'Вы с $name теперь лучшие друзья!';
  @override
  String customRelWith(String label, String name) =>
      'Вы с $name теперь $label!';
  @override
  String get joinAnotherGroup => 'Присоединиться к другой группе';
  @override
  String get enterCodeScanQr =>
      'Введите код, сканируйте QR или перейдите по ссылке';
  @override
  String get enterCode => 'Ввести код';
  @override
  String get invalidCodeTryAgain =>
      'Неверный код. Проверьте и попробуйте снова.';
  @override
  String get joinGroup => 'Присоединиться';
  @override
  String get cantInviteSelf => 'Вы не можете пригласить себя!';
  @override
  String get codeNotFound => 'Код не найден или уже использован';
  @override
  String get scanToConnect => 'Сканируйте для подключения';
  @override
  String get scanPartnersQr => 'Сканировать QR партнёра';
  @override
  String get addNewConnection => 'Новое подключение';
  @override
  String get chooseTypeForConnection => 'Выберите тип для нового подключения';
  @override
  String get yourCustomType => 'Ваш тип';
  @override
  String get newConnectionAdded => 'Новое подключение добавлено!';
  @override
  String get deleteConnection => 'Удалить подключение?';
  @override
  String get deleteConnectionDesc =>
      'Это удалит подключение навсегда. Если есть подключённый партнёр, он будет отключён.';
  @override
  String get connectionRemoved => 'Подключение удалено';
  @override
  String get disconnectQuestion => 'Отключиться?';
  @override
  String get disconnectDesc => 'Это сбросит ваш таймер и отключит партнёра.';
  @override
  String get renamePartner => 'Переименовать участника';
  @override
  String get renamePartnerHint =>
      'Имя видно только вам. Это не меняет имя партнёра у него.';
  @override
  String get resetNickname => 'Сбросить';
  @override
  String joinMeLinkText(String link) =>
      'Присоединяйся ко мне в Togetherly! $link';
  @override
  String get custom => 'Свой';
  @override
  String membersCountBracket(int count) => 'УЧАСТНИКИ ($count)';

  // ── Memory Lane ──
  @override
  String get memoryLane => 'Лента воспоминаний';
  @override
  String get addMemoryBtn => 'Добавить';
  @override
  String get pinned => '📌  Закреплено';

  // ── Timer Card ──
  @override
  String get timers => 'Таймеры';
  @override
  String get failedUploadBackground =>
      'Не удалось загрузить фон. Проверьте подключение.';

  // ── Mini Mood Calendar ──
  @override
  String get todayLabel => 'Сегодня';

  // ── Date helpers ──
  @override
  String get todayDate => 'Сегодня';
  @override
  String get yesterday => 'Вчера';
  @override
  List<String> get shortMonths => [
    'янв',
    'фев',
    'мар',
    'апр',
    'май',
    'июн',
    'июл',
    'авг',
    'сен',
    'окт',
    'ноя',
    'дек',
  ];
  @override
  List<String> get shortWeekdays => ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];

  // ── I Miss You / Vibes ──
  @override
  String get iMissYou => 'Я скучаю';
  @override
  String get iMissYouSent => 'Отправлено! 💕';
  @override
  String missYouNotifTitle(String name) => '$name скучает по вам';
  @override
  String get missYouNotifBody => 'Думает о вас и вспоминает 💭';
  @override
  String missYouStreak(int count) => '🔥 $count';
  @override
  String get thinkingOfYou => 'Думаю о тебе';
  @override
  String get wantHug => 'Хочу обнять';
  @override
  String get vibeSent => 'Отправлено ✨';
  @override
  String get customVibe => 'Своё желание...';
  @override
  String get customVibeTitle => 'Своё сообщение';
  @override
  String get customVibeHint => 'Что ты хочешь сказать?';
  @override
  String thinkingOfYouNotifTitle(String name) => '$name думает о тебе 💭';
  @override
  String wantHugNotifTitle(String name) => '$name хочет обнять тебя 🤗';
  @override
  String customVibeNotifTitle(String name) => name;

  // ── Photo Card ──
  @override
  String get sharedAPicture => 'Поделился фото';
  @override
  String kmFromYou(String km) => '$km от вас';
  @override
  String get openInMaps => 'Открыть в картах';
  @override
  String get justNow => 'только что';
  @override
  String minutesAgo(int m) => '$m мин. назад';
  @override
  String hoursAgo(int h) => '$h ч. назад';
  @override
  String daysAgo(int d) => '$d д. назад';

  // ── Memory Lane Feed ──
  @override
  String get sharedAVideo => 'Поделился видео';
  @override
  String get sharedAVideoLink => 'Поделился видео по ссылке';
  @override
  String get sharedAThought => 'Поделился мыслями';
  @override
  String get sharedALocation => 'Отметил локацию';
  @override
  String get sharedMusic => 'Поделился музыкой';
  @override
  String get vibesTo => 'Вайбит под';
  @override
  String get setARoute => 'Маршрут';
  @override
  String get isListening => 'слушает';
  @override
  String get playTrack => 'Включить';
  @override
  String get note => 'Заметка';

  // ── Memory Lane (extended) ──
  @override
  String get noMemoriesYetDesc =>
      'Нажмите «Добавить», чтобы создать\nпервое общее воспоминание';
  @override
  String get unpinMemory => 'Открепить';
  @override
  String get pinMemory => 'Закрепить';
  @override
  String get saveToDevice => 'Сохранить';
  @override
  String get editMemory => 'Редактировать';
  @override
  String get deleteMemory => 'Удалить';
  @override
  String get deleteMemoryQuestion => 'Удалить воспоминание?';
  @override
  String get actionCannotBeUndone => 'Это действие нельзя отменить.';
  @override
  String get editMemoryTitle => 'Редактировать';
  @override
  String get titleOptional => 'Заголовок (необязательно)';
  @override
  String get description => 'Описание...';
  @override
  String get locationName => 'Название места...';
  @override
  String get changeLocationOnMap => 'Изменить место на карте';
  @override
  String get pickLocationOnMap => 'Выбрать место на карте';
  @override
  String get saveChanges => 'Сохранить изменения';
  @override
  String get addMemoryTitle => 'Добавить воспоминание';
  @override
  String get chooseWhatToShare => 'Выберите, чем поделиться';
  @override
  String newMemory(String type) => 'Новое: $type';
  @override
  String get memoryDetails => 'Детали';
  @override
  String get writeYourNote => 'Напишите заметку...';
  @override
  String get descriptionOptional => 'Описание (необязательно)';
  @override
  String get locationNameHint => 'Название места (напр. Парк Горького)';
  @override
  String get locationSet => 'Место выбрано ✓';
  @override
  String get useCurrent => 'Текущее';
  @override
  String get pickOnMap => 'На карте';
  @override
  String get songDetails => 'Детали трека';
  @override
  String get songName => 'Название песни';
  @override
  String get artistsCommaSeparated => 'Исполнители (через запятую)';
  @override
  String get egArtists => 'напр. Drake, The Weeknd';
  @override
  String get source => 'Источник';
  @override
  String get streamingLink => 'Ссылка на стриминг';
  @override
  String get fetched => 'Получено';
  @override
  String get pasteLinkFromService => 'Вставьте ссылку с любого сервиса...';
  @override
  String get autoFetchSongInfo => 'Авто-получение данных по ссылке';
  @override
  String get orDivider => 'ИЛИ';
  @override
  String get fileSelected => 'Файл выбран ✓';
  @override
  String get pickAudioFromDevice => 'Выбрать аудио с устройства';
  @override
  String get uploadingMemory => 'Загружаем воспоминание...';
  @override
  String get failedUploadPhotos =>
      'Не удалось загрузить фото. Убедитесь, что Firebase Storage включён.';
  @override
  String get failedUploadVideo =>
      'Не удалось загрузить видео. Убедитесь, что Firebase Storage включён.';
  @override
  String get memoryAddedSuccess => 'Воспоминание добавлено!';
  @override
  String failedAddMemory(String e) => 'Не удалось добавить: $e';
  @override
  String get noMediaUrl => 'Нет доступной ссылки на медиа';
  @override
  String get downloading => 'Скачиваем...';
  @override
  String get savedToGallery => 'Сохранено в галерею 🖼️';
  @override
  String savedToPath(String path) => 'Сохранено: $path';
  @override
  String downloadFailed(String e) => 'Ошибка скачивания: $e';
  @override
  String failedSelectPhotos(String e) => 'Не удалось выбрать фото: $e';
  @override
  String failedSelectVideo(String e) => 'Не удалось выбрать видео: $e';
  @override
  String get locationServicesDisabled => 'Геолокация отключена';
  @override
  String get locationPermissionDenied => 'Доступ к геолокации запрещён';
  @override
  String get cameraPermissionDenied =>
      'Нет доступа к камере. Разрешите его в настройках приложения.';
  @override
  String get failedGetLocation => 'Не удалось определить местоположение';
  @override
  String get tapToSelectPhotos => 'Нажмите, чтобы выбрать фото';
  @override
  String get tapToSelectVideo => 'Нажмите, чтобы выбрать видео';
  @override
  String get adultContent => 'Контент 18+';
  @override
  String get photoBlurred => 'Фото будет скрыто под блюром';
  @override
  String get fromGallery => 'Из галереи';
  @override
  String get byLink => 'По ссылке';
  @override
  String get videoLink => 'Ссылка на видео';
  @override
  String get books => 'Книги';
  @override
  String get bookSearchHint => 'Название книги или автор';
  @override
  String get searchBooksPrompt => 'Найдите книгу по названию или автору';
  @override
  String get noBooksFound => 'Книги не найдены';
  @override
  String get bookSearchFailed => 'Не удалось найти. Введите вручную';
  @override
  String get bookSearchFailedHint =>
      'Поиск не ответил или книга отсутствует в базе.';
  @override
  String get bookEnterManually => 'Ввести вручную';
  @override
  String get bookManualEntryHint =>
      'Заполните название и автора самостоятельно';
  @override
  String get sharedABook => 'Поделился(-ась) книгой';
  @override
  String get bookAuthorLabel => 'Автор';
  @override
  String get bookAuthorHint => 'Автор';
  @override
  String get bookTitleHint => 'Название книги';
  @override
  String get bookDetails => 'О книге';
  @override
  String get bookReadMore => 'Подробнее';
  @override
  String get bookSearchAgain => 'Искать';
  @override
  String get movies => 'Фильмы и сериалы';
  @override
  String get movieSearchHint => 'Название фильма или сериала';
  @override
  String get searchMoviesPrompt => 'Найдите фильм или сериал по названию';
  @override
  String get noMoviesFound => 'Ничего не найдено';
  @override
  String get movieSearchFailed => 'Не удалось найти. Введите вручную';
  @override
  String get movieSearchFailedHint =>
      'Поиск не ответил или фильм отсутствует в базе.';
  @override
  String get movieEnterManually => 'Ввести вручную';
  @override
  String get movieManualEntryHint =>
      'Заполните название самостоятельно';
  @override
  String get movieNoToken =>
      'Поиск недоступен — впишите название вручную';
  @override
  String get sharedAMovie => 'Поделился(-ась) фильмом';
  @override
  String get movieTitleHint => 'Название';
  @override
  String get movieOriginalTitleHint => 'Оригинальное название';
  @override
  String get movieDetails => 'О фильме';
  @override
  String get movieReadMore => 'Открыть на Кинопоиске';
  @override
  String get movieSearchAgain => 'Искать';
  @override
  String get yourRating => 'Ваша оценка';
  @override
  String get ratingNotRated => 'Без оценки';
  @override
  String get ratingHint => 'Нажмите на цифру, чтобы оценить';
  @override
  String get ratingMasterpiece => 'Шедевр 🔥';
  @override
  String get ratingExcellent => 'Отлично';
  @override
  String get ratingGood => 'Хорошо';
  @override
  String get ratingMixed => 'Так себе';
  @override
  String get ratingBad => 'Плохо';
  @override
  String get ratingAwful => 'Ужасно';
  @override
  String get yourReview => 'Ваш отзыв';
  @override
  String get reviewHint => 'Что вы думаете? Поделитесь впечатлением…';
  @override
  String get memoryDateLabel => 'Когда это было';
  @override
  String get memoryDateNow => 'Сейчас (момент создания)';
  @override
  String get memoryDatePickDate => 'Дата';
  @override
  String get memoryDatePickTime => 'Время';
  @override
  String get memoryDateClear => 'Сбросить';
  @override
  String get fetchData => 'Получить данные';
  @override
  String get supportedPlatformsHint =>
      'Поддерживаются: YouTube, Vimeo, Dailymotion,\nTikTok, Instagram, VK и другие';
  @override
  String get supportedPlatforms => 'Поддерживаемые платформы';
  @override
  String get pasteLinkSupported =>
      'Вставьте ссылку с любой поддерживаемой платформы';
  @override
  String get gotIt => 'Понятно';
  @override
  String get sideActionTitle => 'Кнопка действия';
  @override
  String get sideActionOpenFeed => 'Открывать Ленту →';
  @override
  String get sideActionCreatePin => 'Создавать пин +';
  @override
  String get sideActionHint =>
      'Удерживайте кнопку, чтобы переключать → (открыть Ленту) и + (создать пин)';
  @override
  String get supportedServices => 'Поддерживаемые сервисы';
  @override
  String get pasteLinkFromSupported =>
      'Вставьте ссылку с любого поддерживаемого сервиса';
  @override
  String get selectTextAndPress => 'Выдели текст и нажми';
  @override
  String get spoiler => 'Spoiler';
  @override
  String get deleteComment => 'Удалить комментарий?';
  @override
  String get deleteCommentQuestion => 'Удалить этот комментарий?';
  @override
  String get comments => 'Комментарии';
  @override
  String get writeAComment => 'Написать комментарий…';
  @override
  String get noCommentsYet => 'Нет комментариев — будьте первым!';
  @override
  String nPhotos(int count) => '$count фото';
  @override
  String get noPhotoAttached => 'Фото не прикреплено';
  @override
  String get unknownLocation => 'Неизвестная локация';
  @override
  String get openInGoogleMaps => 'Открыть в Google Картах';
  @override
  String get audioFile => 'Аудиофайл';
  @override
  String get unknownTrack => 'Неизвестный трек';
  @override
  String get noAudioUrl => 'Нет ссылки на аудио';
  @override
  String get cannotPlayAudio => 'Невозможно воспроизвести аудио';
  @override
  String openIn(String name) => 'Открыть в $name';
  @override
  String get tapToOpen => 'Нажмите, чтобы открыть';
  @override
  String get videoBadge => 'ВИДЕО';
  @override
  String get updateAvailableTitle => 'Доступно обновление';
  @override
  String get updateAvailableSubtitle => 'Настоятельно рекомендуем обновиться — иначе некоторые функции Ленты воспоминаний работать не будут';
  @override
  String get updateWhatsNew => ruWhatsNew;
  @override
  String get updateButton => 'Обновить';
  @override
  String get updateLaterButton => 'Позже';
  @override
  String get updateRestartButton => 'Перезапустить и установить';
  @override
  String get forceUpdateTitle => 'Нужно обновить приложение';
  @override
  String get forceUpdateBody =>
      'Вышла новая версия с важными изменениями. Чтобы продолжить пользоваться приложением, обновитесь до актуальной версии.';
  @override
  String get forceUpdateButton => 'Обновить';
  @override
  String get noteBadge => 'ЗАМЕТКА';
  @override
  String get youtubeBadge => 'YouTube';
  @override
  String get photoNotUploaded => 'Фото ещё не загружено';
  @override
  List<String> get fullMonths => [
    '',
    'Январь',
    'Февраль',
    'Март',
    'Апрель',
    'Май',
    'Июнь',
    'Июль',
    'Август',
    'Сентябрь',
    'Октябрь',
    'Ноябрь',
    'Декабрь',
  ];
  @override
  String formatDateAt(String month, int day, int year, String time) =>
      '$day $month $year в $time';

  // ── Relationship Status Screen ──
  @override
  String get noActiveConnection => 'Нет активного подключения';
  @override
  String get chooseAStatus => 'Выберите статус';
  @override
  String get customStatuses => 'Пользовательские статусы';
  @override
  String get currentStatus => 'Текущий статус';
  @override
  String get notSet => 'Не установлен';
  @override
  String get clearStatus => 'Очистить статус';
  @override
  String statusSetTo(String status) => 'Статус: $status';
  @override
  String failedSetStatus(String e) => 'Ошибка установки статуса: $e';
  @override
  String get statusCleared => 'Статус очищен';
  @override
  String failedClearStatus(String e) => 'Ошибка очистки статуса: $e';
  @override
  String get customStatusAdded => 'Статус добавлен';
  @override
  String failedAddStatus(String e) => 'Ошибка добавления статуса: $e';
  @override
  String get statusUpdated => 'Статус обновлён';
  @override
  String failedUpdateStatus(String e) => 'Ошибка обновления статуса: $e';
  @override
  String get deleteStatus => 'Удалить статус';
  @override
  String deleteStatusConfirm(String label) =>
      'Вы уверены, что хотите удалить «$label»?';
  @override
  String get statusDeleted => 'Статус удалён';
  @override
  String failedDeleteStatus(String e) => 'Ошибка удаления статуса: $e';
  @override
  String get editStatus => 'Редактировать статус';
  @override
  String get emojiLabel => 'Эмодзи';
  @override
  String get emojiHint => '💕';
  @override
  String get labelField => 'Название';
  @override
  String get egLivingTogether => 'напр., Живём вместе';
  @override
  String get update => 'Обновить';

  // ── Map Picker Screen ──
  @override
  String get selectLocationOnMap => 'Выберите место на карте';
  @override
  String get selectedLocation => 'Выбранная локация';
  @override
  String get selectLocation => 'Выбрать место';
  @override
  String get confirm => 'Подтвердить';
  @override
  String get gettingAddress => 'Определяем адрес...';
  @override
  String get tapOnMapToSelect => 'Нажмите на карту, чтобы выбрать другое место';
  @override
  String get failedGetCurrentLocation =>
      'Не удалось определить текущее местоположение';

  // ── Mood Calendar (extended) ──
  @override
  String get averageMood => 'Среднее настроение';
  @override
  String get great => 'Отлично';
  @override
  String get good => 'Хорошо';
  @override
  String get okay => 'Нормально';
  @override
  String get bad => 'Плохо';
  @override
  String get awful => 'Ужасно';
  @override
  String get notEnoughData => 'Недостаточно данных для графика';
  @override
  String moodRecorded(String label) => '$label записано!';
  @override
  String get noMoodRecorded => 'Настроение не отмечено';
  @override
  String get moodScorePrefix => 'Оценка';
  @override
  List<String> get shortWeekdaysSingleChar => [
    'П',
    'В',
    'С',
    'Ч',
    'П',
    'С',
    'В',
  ];
  @override
  List<String> get longWeekdays => [
    'Понедельник',
    'Вторник',
    'Среда',
    'Четверг',
    'Пятница',
    'Суббота',
    'Воскресенье',
  ];

  // ── Timer / Expandable Timer Card ──
  @override
  String get noTimers => 'Нет таймеров';
  @override
  String get createTimer => 'Создать таймер';
  @override
  String get editTimer => 'Редактировать таймер';
  @override
  String get timerNameLabel => 'НАЗВАНИЕ';
  @override
  String get egAnniversary => 'напр. Годовщина';
  @override
  String get targetDate => 'ЦЕЛЕВАЯ ДАТА';
  @override
  String get startDate => 'ДАТА НАЧАЛА';
  @override
  String get dateFormatHint => 'дд.мм.гггг';
  @override
  String get symbolLabel => 'СИМВОЛ';
  @override
  String get countdownMode => 'Режим отсчёта';
  @override
  String get countdownPastDateWarning => 'Целевая дата уже прошла — таймер покажет нули. Выберите будущую дату.';
  @override
  String get setAsMain => 'Сделать основным';
  @override
  String get saveSettings => 'СОХРАНИТЬ';
  @override
  String get deleteTimerQuestion => 'Удалить таймер?';
  @override
  String timerDeleteConfirm(String name) => '«$name» будет удалён навсегда.';

  // ── Petal Timer Dial ──
  @override
  String get yearsLabel => 'Лет';
  @override
  String get monthsShortLabel => 'Мес';
  @override
  String get daysShortLabel => 'Дней';
  @override
  String get hoursLabel => 'Час';
  @override
  String get minLabel => 'Мин';
  @override
  String get secLabel => 'Сек';

  // ── Widget Screen (extended) ──
  @override
  String get homeScreenWidgets => 'Виджеты рабочего стола';
  @override
  String get addToHomeScreen => 'Добавить на рабочий стол';
  @override
  String get setAsPhotoOfDay => 'Установлено как фото дня';
  @override
  String get widgetAddedToHome => 'Виджет добавлен на рабочий стол';
  @override
  String failedAddWidget(String e) => 'Не удалось добавить виджет: $e';
  @override
  String get daysTogetherStat => 'Дней вместе';
  @override
  String get memoriesStat => 'Воспоминаний';
  @override
  String get drawingsStat => 'Рисунков';
  @override
  String get missYousStat => 'Скучаю';
  @override
  String get daysLeft => 'дней осталось';
  @override
  String get daysElapsed => 'дней прошло';
  @override
  String get noTimersWidget => 'Нет таймеров';
  @override
  String get photoOfDay => 'Фото дня';
  @override
  String get mine => 'Моё';
  @override
  String get onWidget => 'На виджете';
  @override
  String get randomSource => 'Случайное';
  @override
  String get ownPhoto => 'Своё фото';
  @override
  String get saveToMemoryLane => 'Добавить в ленту воспоминаний';
  @override
  String get regenerate => 'Повторная генерация';
  @override
  String get none => 'Нет';
  @override
  String yearsAlready(int years) {
    String form;
    if (years % 10 == 1 && years % 100 != 11) {
      form = '$years год уже ❤️';
    } else if (years % 10 >= 2 &&
        years % 10 <= 4 &&
        (years % 100 < 10 || years % 100 >= 20)) {
      form = '$years года уже ❤️';
    } else {
      form = '$years лет уже ❤️';
    }
    return form;
  }

  @override
  String get pairWidgetTitle => 'Парный виджет';
  @override
  String get pairWidgetSubtitle => 'Настроение, статус, сообщения и фото';
  @override
  String get daysCounterSubtitle => 'Системный счётчик дней отношений';
  @override
  String get timerWidgetTitle => 'Таймер';
  @override
  String get timerWidgetSubtitle => 'Выберите таймер для виджета';
  @override
  String get photoDayRandomSubtitle => 'Случайное фото из ленты';
  @override
  String get photoDayCustomSubtitle => 'Своё установленное фото';
  @override
  String get photoDayPartnerSubtitle => 'То, чем делится ваш партнёр';
  @override
  String get moodWidgetSubtitle => 'Горизонтальный виджет: моё и партнёра';
  @override
  String get relationshipStatsSubtitle =>
      'Важные цифры: дни, фото, рисунки и «скучаю»';
  @override
  String get daysCounterLabel => 'дней';
  @override
  String get addTimerHint => 'Добавьте таймер в разделе «Таймеры»';
  @override
  String get noTimersAddHint =>
      'Нет таймеров. Добавьте таймер в разделе «Таймеры».';
  @override
  String get soloTimerBannerTitle => 'Можно создать свой таймер';
  @override
  String get soloTimerBannerSubtitle =>
      'Одиночные таймеры и их виджеты доступны даже без добавления пары.';
  @override
  String get selectTimerForWidget => 'Выберите таймер для виджета:';
  @override
  String get daysShortLeft => 'дн. осталось';
  @override
  String get daysShortElapsed => 'дн. прошло';
  @override
  String get partnerPhotoWillAppear =>
      'Фото партнёра появится\nпосле его выбора';
  @override
  String get choosePhotoBelow => 'Выберите фото ниже';
  @override
  String get randomPhotoFromMemories => 'Случайное фото\nиз воспоминаний';
  @override
  String get photoSource => 'Источник фото:';
  @override
  String get fromMemories => 'из воспоминаний';
  @override
  String get fromGalleryLabel => 'из галереи';
  @override
  String get widgetModeMine => 'Мои фото';
  @override
  String get widgetModePartner => 'Фото партнёра';
  @override
  String get widgetInstances => 'Виджеты на рабочем столе';
  @override
  String get widgetNotAddedYet => 'Виджет ещё не добавлен';
  @override
  String widgetSlotTitle(int index) => 'Виджет ${index + 1}';
  @override
  String get addedWidgetsWillAppearHere =>
      'Добавленные фото-виджеты появятся здесь';
  @override
  String get addSeparateWidgetHint =>
      'Добавляйте несколько виджетов: у каждого будет своё фото и свой режим';
  @override
  String get widgetDisplaySource => 'Что показывать на виджете:';
  @override
  String get widgetDisplayPhoto => 'Фото для виджета';
  @override
  String get noPhotoSelected => 'Фото не выбрано';

  // ── Profile (extended) ──
  @override
  String get exportMemories => 'Экспорт воспоминаний';
  @override
  String get resetMissYouCount => 'Сбросить мои нажатия «Скучаю»';
  @override
  String get resetMissYouConfirmTitle => 'Сбросить счётчик?';
  @override
  String get resetMissYouConfirmBody =>
      'Твои нажатия «Я скучаю» обнулятся. Счётчик партнёра останется без изменений.';
  @override
  String get noActiveGroupForExport => 'Нет активной группы для экспорта';
  @override
  String get creatingArchive => 'Создаём архив...\nЭто займёт немного времени.';
  @override
  String exportError(String e) => 'Ошибка при экспорте: $e';
  @override
  String get relationshipStats => 'СТАТИСТИКА ОТНОШЕНИЙ';

  // ── Home Screen (extended) ──
  @override
  String get startWithBlankCanvas => 'Начать с чистого холста';
  @override
  String get openSavedDrawing => 'Открыть сохранённый рисунок';
  @override
  String get newPhoto => 'Новое фото';
  @override
  String get titleHint => 'Заголовок…';
  @override
  String get descriptionOptionalHint => 'Описание (необязательно)…';
  @override
  String get setAsWidgetPhoto => 'Фото дня на виджете';

  // ── Mini Mood Calendar (extended) ──
  @override
  List<String> get shortWeekdaysUpper => [
    'ПН',
    'ВТ',
    'СР',
    'ЧТ',
    'ПТ',
    'СБ',
    'ВС',
  ];

  // ── Notification Settings ──
  @override
  String get notifMissYou => '«Я скучаю»';
  @override
  String get notifMissYouSub => 'Когда партнёр нажимает кнопку «Я скучаю»';
  @override
  String get notifNewMemory => 'Новые воспоминания';
  @override
  String get notifNewMemorySub =>
      'Когда партнёр добавляет в ленту воспоминаний';
  @override
  String get notifMood => 'Настроение партнёра';
  @override
  String get notifMoodSub => 'Когда партнёр обновляет своё настроение';
  @override
  String get notifChat => 'Сообщения в чате';
  @override
  String get notifChatSub => 'Когда партнёр пишет тебе в чат';
  @override
  String get notifDaysTogether => 'Счётчик дней вместе';
  @override
  String get notifDaysTogetherSub =>
      'Постоянный счётчик в шторке уведомлений';
  @override
  String daysTogetherNotifBody(int days) {
    final mod10 = days % 10;
    final mod100 = days % 100;
    final word = (mod10 == 1 && mod100 != 11)
        ? 'день'
        : (mod10 >= 2 && mod10 <= 4 && !(mod100 >= 12 && mod100 <= 14))
            ? 'дня'
            : 'дней';
    return 'Вы вместе уже $days $word ❤️';
  }

  @override
  String get daysTogetherNotifTagline => 'Каждый день вместе — особенный 💕';
  @override
  String get openSystemSettings => 'Системные настройки';
  @override
  String get notifSystemSettingsHint => 'Настройки хранятся на устройстве';

  // ── Chat ──
  @override
  String get chatTitle => 'Чат';
  @override
  String get chatHint => 'Сообщение…';
  @override
  String get chatEmpty => 'Пока нет сообщений.\nНапишите первым 💬';
  @override
  String get chatEditMessage => 'Редактировать';
  @override
  String get chatDeleteMessage => 'Удалить';
  @override
  String get chatReply => 'Ответить';
  @override
  String chatReplyingTo(String name) => 'В ответ $name';
  @override
  String chatTyping(String name) => '$name печатает…';
  @override
  String get chatEdited => 'изменено';
  @override
  String get chatDeletedPlaceholder => 'Сообщение удалено';
  @override
  String get chatSendFailed => 'Не удалось отправить. Попробуйте ещё раз';
  @override
  String get chatAttachPin => 'Прикрепить пин';
  @override
  String get chatSave => 'Сохранить';
  @override
  String chatNotifTitle(String name) => '$name пишет вам 💬';
  @override
  String moodNotifTitle(String name) => '$name сменил(а) настроение';
  @override
  String get chatNewMessages => 'Новые сообщения';
  @override
  String chatDateHeader(DateTime day) {
    final now = DateTime.now();
    final d0 = DateTime(day.year, day.month, day.day);
    final diff = DateTime(now.year, now.month, now.day).difference(d0).inDays;
    if (diff == 0) return 'Сегодня';
    if (diff == 1) return 'Вчера';
    const months = [
      'января', 'февраля', 'марта', 'апреля', 'мая', 'июня',
      'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря',
    ];
    final base = '${day.day} ${months[day.month - 1]}';
    return day.year == now.year ? base : '$base ${day.year}';
  }

  @override
  String chatDeleteConfirm(String text) => 'Удалить это сообщение?';
  @override
  String get chatBgTitle => 'Фон чата';
  @override
  String get chatBgSet => 'Поставить своё фото';
  @override
  String get chatBgChange => 'Сменить фото';
  @override
  String get chatBgRemove => 'Убрать фон';
  @override
  String chatBgConfirmBody(int price) =>
      'Установить своё фото на фон чата за $price 🪙?\n\n'
      'Каждая последующая смена фона тоже стоит $price 🪙.';
  @override
  String get chatBgCharged => 'Фон обновлён';
  @override
  String get lockScreenMood => 'Настроение на экране блокировки';
  @override
  String get lockScreenMoodSubtitle => 'Моё и партнёра — на экране блокировки';
  @override
  String get lockScreenMoodToggle => 'Показывать на экране блокировки';
  @override
  String get lockScreenMoodToggleSub =>
      'Настроение отображается при блокировке телефона';
  @override
  String get lockScreenMoodNoMood => 'Настроение не задано';
  @override
  String get lockScreenMoodSetHint =>
      'Установите настроение в календаре настроений';
  @override
  String get photoGridWidget => 'Сетка фото';
  @override
  String get photoGridWidgetSubtitle => 'Несколько фото из воспоминаний';
  @override
  String get photoGridCount => 'Количество фото';
  @override
  String get photoGridSelectPhotos => 'Выберите фото';
  @override
  String get photoGridAddPhoto => 'Добавить фото';
  @override
  String get photoGridCountLabel => 'фото на виджете';
  @override
  String get goToPin => 'К воспоминанию';
  @override
  String get openPhotoGallery => 'Галерея фото';
  @override
  String get allMediaGallery => 'Все фото и видео';
  @override
  String get loadMore => 'Загрузить ещё';
  @override
  String get previewLabel => 'Предпросмотр';
  @override
  String get photoSent => 'Фото отправлено';
  @override
  String get partnerFallback => 'партнёр';
  @override
  String get captionDestMemories => 'Воспоминания';
  @override
  String get captionDestMemoriesSub => 'Добавить фото в ленту воспоминаний';
  @override
  String get captionDestPairWidget => 'Парный виджет';
  @override
  String captionDestPairWidgetSub(String partner) =>
      'Фото в «Моём виджете» — видно тебе и $partner';
  @override
  String get captionDestPartnerWidget => 'Виджет «Фото партнёра»';
  @override
  String captionDestPartnerWidgetSub(String partner) =>
      'Отдельный виджет с фото для $partner';
  @override
  String get groupMascot => 'Маскот группы';
  @override
  String get tapForGallery => 'Нажмите для галереи';
  @override
  String get selectMascot => 'Выберите маскота';
  @override
  String get showLabel => 'Показать';
  @override
  String streakLabel(int days) {
    String unit;
    if (days % 100 >= 11 && days % 100 <= 14) {
      unit = 'дней';
    } else {
      switch (days % 10) {
        case 1:
          unit = 'день';
          break;
        case 2:
        case 3:
        case 4:
          unit = 'дня';
          break;
        default:
          unit = 'дней';
      }
    }
    return 'Серия: $days $unit';
  }

  // ── Widget screen ──
  @override
  String get widgetStreakTitle => 'Огонёк пары';
  @override
  String get widgetStreakSubtitle => 'Сколько дней подряд вы заходите вместе';
  @override
  String get widgetPetalTimerTitle => 'Лепестковый таймер';
  @override
  String get widgetPetalTimerSubtitle =>
      'Живой циферблат — годы, мес, дни, ч, мин, сек';
  @override
  String get widgetPhotoTitle => 'Фото-виджет';
  @override
  String get widgetPhotoSubtitle => 'Личная карусель: 1–10 фото с автосменой';
  @override
  String get streakTogetherCaps => 'СЕРИЯ ВМЕСТЕ';
  @override
  String get daysInARow => 'дней подряд';
  @override
  String get keepItUp => 'Так держать!';
  @override
  String get ourPhotosInsteadOfDrawing => 'Наши фото вместо рисунка';
  @override
  String get daysPhotosDescription =>
      'Замените нарисованную пару на ваши настоящие аватарки — '
      'на превью и на виджете рабочего стола.';
  @override
  String unlockForCoins(int price) => 'Разблокировать — $price 🪙';
  @override
  String get showOurPhotos => 'Показывать наши фото';
  @override
  String get partnerNoProfilePhoto =>
      'У партнёра нет фото профиля — попросите добавить.';
  @override
  String get addYourProfilePhoto =>
      'Добавьте своё фото профиля, чтобы оно появилось на виджете.';
  @override
  String notEnoughCoinsNeed(int price) =>
      'Недостаточно монет — нужно $price 🪙';
  @override
  String get daysPhotosDone => 'Готово! Ваши фото на виджете 💞';
  @override
  String get purchaseFailedTryLater => 'Не удалось купить — попробуйте позже';
  @override
  String personalPhotosHelp(String partner) =>
      'Личные фото — от 1 до 10 на каждый виджет. С двух фото включается '
      'карусель: смена при разблокировке или по таймеру.\n\nЭти фото видны '
      'только тебе. Чтобы поделиться с $partner, открой «Фото партнёра» → '
      '«Выбрать фото для партнёра».';
  @override
  String get personalPhotosHelpShort =>
      'Личные фото — от 1 до 10 на каждый виджет. С двух фото включается '
      'карусель: смена при разблокировке или по таймеру.';
  @override
  String get uploadedPhotosToMemoryLane =>
      'Загруженные фото попадут в ленту воспоминаний';
  @override
  String partnerSharesPhotosHelp(String partner, int count) =>
      'Этот виджет показывает фото, которыми делится $partner '
      '($count ${photosUnit(count)}). Менять их может только $partner.';
  @override
  String partnerNotSharedHelp(String partner) =>
      '$partner ещё не поделился(ась) фото. Чтобы они здесь появились, '
      '$partner нужно открыть «Фото партнёра» и нажать «Выбрать фото для '
      'партнёра» — обычный «Фото-виджет» виден только владельцу.';
  @override
  String get selectPhotosForPartner => 'Выбрать фото для партнёра';
  @override
  String photosUnit(int n) => 'фото';
  @override
  String get noPhotosFromPartner => 'Нет фото от партнёра';
  @override
  String get noPhotosAdded => 'Фото не добавлены';
  @override
  String get onePhotoNoCarousel => '1 фото · без карусели';
  @override
  String photoCountOnUnlock(int count) => '$count фото · при разблокировке';
  @override
  String photoCountInterval(int count, String interval) =>
      '$count фото · $interval';
  @override
  String intervalLabel(int minutes) {
    switch (minutes) {
      case 15:
        return 'каждые 15 мин';
      case 30:
        return 'каждые 30 мин';
      case 60:
        return 'каждый час';
      case 180:
        return 'каждые 3 часа';
      default:
        return 'каждые $minutes мин';
    }
  }

  @override
  String get partnerPhotoTitle => 'Фото партнёра';
  @override
  String partnerSharedCountHelp(int count) =>
      'Партнёр поделился $count фото — выберите как они будут меняться на '
      'этом виджете.';
  @override
  String get partnerSharedOnePhoto => 'Партнёр поделился 1 фото — без карусели.';
  @override
  String get partnerNotSharedYet => 'Партнёр ещё не поделился фото.';
  @override
  String get changePhotosLabel => 'Менять фото:';
  @override
  String get onUnlockOption => 'При разблокировке';
  @override
  String get byTimeOption => 'По времени';
  @override
  String get every15Minutes => 'Каждые 15 минут';
  @override
  String get every30Minutes => 'Каждые 30 минут';
  @override
  String get everyHourOption => 'Каждый час';
  @override
  String get every3HoursOption => 'Каждые 3 часа';
  @override
  String get createPostcardTitle => 'Создать открытку';
  @override
  String get createPostcardSubtitle =>
      'Сколько дней вы вместе — красиво и со стилем';
  @override
  String get whereToSendPhoto => 'Куда отправить фото?';
  @override
  String get sendLabel => 'Отправить';
  @override
  String get widgetPhotoCaption => '📸 Виджет';

  // ── Mascot gallery ──
  @override
  String get mascotSaveFailed =>
      'Не удалось сохранить маскота. Проверьте соединение.';
  @override
  String get mascotLoadFailed => 'Не удалось загрузить. Проверьте соединение.';
  @override
  String get transparentBgTitle => 'Нужен прозрачный фон';
  @override
  String get transparentBgBody =>
      'Маскот отображается без фона, поэтому загружай PNG-файл с '
      'прозрачностью.\n\nВырежи фон заранее — например, через remove.bg, '
      'Photoshop или Canva.';
  @override
  String get mascotNameTitle => 'Имя маскота';
  @override
  String get enterNameHint => 'Введите имя';
  @override
  String get mascotLimitReached =>
      'Достигнут лимит. Удалите маскота из галереи.';
  @override
  String mascotDeactivated(String name) => '$name деактивирован';
  @override
  String mascotActivated(String name) => '$name теперь активен';
  @override
  String get rename => 'Переименовать';
  @override
  String get deleteMascotTitle => 'Удалить маскота?';
  @override
  String deleteMascotBody(String name) => '«$name» будет удалён навсегда.';
  @override
  String recordStreakDays(int days) => 'Рекорд: $days дн.';
  @override
  String get deactivateLabel => 'Деактивировать';
  @override
  String get makeActiveLabel => 'Сделать активным';
  @override
  String get editLabel => 'Редактировать';
  @override
  String get exportPng => 'Экспортировать PNG';
  @override
  String get groupMascots => 'Маскоты группы';
  @override
  String mascotsCount(int count, int max) => '$count / $max маскотов';
  @override
  String get limitLabel => 'Лимит';
  @override
  String get mascotsLoadFailedMultiline =>
      'Маскоты не загрузились.\nПроверьте соединение.';
  @override
  String get artistCredit => 'Художница — Алёна Гребенева';
  @override
  String get uploadPhotoTooltip => 'Загрузить фото';
  @override
  String get drawLabel => 'Нарисовать';
  @override
  String get streakBroken => 'Серия прервана';
  @override
  String get streakKeepHint =>
      'Заходите каждый день, чтобы не прерывать серию';
  @override
  String get streakStartHint => 'Зайдите сегодня, чтобы начать новую серию';
  @override
  String get fromUs => 'От нас';
  @override
  String recordStreakBadge(int days) => '🏅 $days дн.';

  // ── Mascot draw screen ──
  @override
  String get drawSomethingFirst => 'Нарисуйте что-нибудь сначала';
  @override
  String genericError(String e) => 'Ошибка: $e';
  @override
  String get drawMascotTitle => 'Нарисовать маскота';
  @override
  String get toolBrush => 'Кисть';
  @override
  String get toolPencil => 'Карандаш';
  @override
  String get toolMarker => 'Маркер';
  @override
  String get toolEraser => 'Ластик';
  @override
  String get toolFill => 'Заливка';
  @override
  String get toolLine => 'Линия';
  @override
  String get toolRect => 'Прямоуг.';
  @override
  String get toolCircle => 'Круг';
  @override
  String get toolTriangle => 'Треугол.';
  @override
  String get fillAction => 'Залить';
  @override
  String get resetSize => 'Сбросить размер';
  @override
  String get undoLabel => 'Отмена';
  @override
  String get redoLabel => 'Повтор';
  @override
  String get underlayLabel => 'Подложка';
  @override
  String get drawHintEdit =>
      'Двойной тап — сбросить вид  •  2 пальца — зум/поворот';
  @override
  String get drawHintDraw =>
      'Два пальца быстро — отменить  •  Двойной тап — сбросить вид';
  @override
  String get colorLabel => 'Цвет';
  @override
  String get hueLabel => 'Оттенок';
  @override
  String get saturationLabel => 'Насыщ.';
  @override
  String get brightnessLabel => 'Яркость';
  @override
  String get selectAction => 'Выбрать';

  // ── Postcard templates ──
  @override
  String get pcNamesFallback => 'Мы вместе';
  @override
  String get pcLabelNames => 'Имена';
  @override
  String get pcLabelDaysCaption => 'Подпись к числу';
  @override
  String get pcLabelMessage => 'Послание';
  @override
  String get pcLabelCaption => 'Подпись';
  @override
  String get pcLabelPolaroidCaption => 'Подпись на полароиде';
  @override
  String get pcLabelMessageAlt => 'Сообщение';
  @override
  String get pcDaysTogether => 'дней вместе';
  @override
  String get pcMsgTogether => 'Каждый день с тобой — подарок ❤️';
  @override
  String get pcDaysOfLove => 'дней любви';
  @override
  String get pcMsgPolaroid => 'Наш момент ✨';
  @override
  String get pcDaysNearby => 'дней рядом';
  @override
  String get pcMsgBloom => 'Ты моё любимое приключение 🌸';
  @override
  String get pcNightsUnderSky => 'ночей под одним небом';
  @override
  String get pcMsgNightSky => 'Ты — моя звезда ✨';

  // ── Photo carousel editor ──
  @override
  String get addOneToTenPhotos => 'Добавьте от 1 до 10 фото';
  @override
  String photoCountCarousel(int count) => '$count фото · карусель';
  @override
  String get addMorePhotosCarouselHint =>
      'Добавьте ещё фото, чтобы появилась карусель — фото будут меняться '
      'автоматически.';
  @override
  String get dragToReorder => 'Удерживайте и перетаскивайте, чтобы изменить порядок';
  @override
  String photoNumber(int n) => 'Фото $n';
  @override
  String get mainPhoto => 'Главное';
  @override
  String positionNumber(int n) => 'Позиция $n';
  @override
  String get addMore => 'Добавить ещё';
  @override
  String get fromDevice => 'С устройства';
  @override
  String get fromFeed => 'Из ленты';

  // ── Profile screen ──
  @override
  String get cropAvatarTitle => '✂️  Обрезка аватарки';
  @override
  String get avatarTitle => 'Аватарка';
  @override
  String get appIconTitle => 'Иконка приложения';
  @override
  String get appIconUpdateHint =>
      'Иконка на рабочем столе может обновиться через пару секунд.';
  @override
  String get appIconChangeFailed => 'Не удалось сменить иконку';
  @override
  String get viewAction => 'Посмотреть';
  @override
  String get enterDateFormat => 'Введите дату в формате ДД.ММ.ГГГГ';
  @override
  String yearRange(int first, int last) => 'Год от $first до $last';
  @override
  String get enterTimeFormat => 'Время должно быть в формате ЧЧ:ММ';
  @override
  String get dateHintFormat => 'ДД.ММ.ГГГГ';
  @override
  String get timeHintFormat => 'ЧЧ:ММ';
  @override
  String get openCalendar => 'Открыть календарь';
  @override
  String get refreshTooltip => 'Обновить';
  @override
  String get memoriesMapTooltip => 'Карта воспоминаний';
  @override
  String kpRating(String rating) => 'КП $rating';
  @override
  String get editLocation => 'Изменить геолокацию';
  @override
  String get addLocation => 'Добавить геолокацию';
  @override
  String get photoVideoNote => 'Фото / Видео / Заметка';
  @override
  String distanceLabel(double meters) => meters < 1000
      ? '${meters.round()} м'
      : '${(meters / 1000).toStringAsFixed(1)} км';
  @override
  String get appNotInstalled => 'Приложение не установлено';
  @override
  String get watchTogether => 'Смотреть вместе';
  @override
  String get watchTogetherAdPrompt =>
      'Чтобы открыть совместный просмотр, посмотри короткую рекламу — '
      'поддержишь приложение и получишь коины 🪙';
  @override
  String get watchAction => 'Смотреть';
  @override
  String get youtubeLinkHint => 'Ссылка на YouTube';
  @override
  String get startAction => 'Начать';
  @override
  String get youtubeLinkInvalid => 'Не удалось распознать ссылку YouTube';
  @override
  String invitesToWatchTogether(String hostName) =>
      '$hostName зовёт смотреть вместе';
  @override
  String get joinAction => 'Присоединиться';
  @override
  String get partnerEndedWatchTogether => 'Партнёр завершил совместный просмотр';
  @override
  String get videoCannotWatchTogether => 'Это видео нельзя смотреть вместе';
  @override
  String get videoEmbedBlockedHint =>
      'Это видео нельзя встроить: автор запретил воспроизведение вне YouTube, '
      'либо у ролика возрастное/региональное ограничение. Если видео не '
      'открывается только на одном телефоне — обновите на нём «Android System '
      'WebView» и Chrome в Google Play. Можно открыть ролик прямо на YouTube '
      'или выбрать другое — большинство работает.';
  @override
  String get chooseAnother => 'Выбрать другое';
  @override
  String get openOnYoutube => 'Открыть на YouTube';
  @override
  String get watchingTogether => 'Смотрим вместе';
  @override
  String get partnerJoined => 'Партнёр подключился';
  @override
  String get waitingForPartner => 'Ожидаем партнёра…';
  @override
  String get syncedPlaying => 'Синхронизировано · играет';
  @override
  String get syncedPaused => 'Синхронизировано · пауза';
  @override
  String get writeFirstMessage => 'Напишите первое сообщение 💬';
  @override
  String get messageInputHint => 'Сообщение…';
  @override
  String get selectOnePhoto => 'Выберите 1 фото';
  @override
  String get maxSelected => 'Выбрано максимум';
  @override
  String selectUpToPhotos(int n) => 'Выберите до $n фото';
  @override
  String get selectPhotosPrompt => 'Выберите фото';
  @override
  String addWithCount(int n) => 'Добавить ($n)';
  @override
  String get failedToLoadMemories => 'Не удалось загрузить воспоминания';
  @override
  String get noPhotosInMemoryLane => 'Нет фото в ленте воспоминаний';
  @override
  String get inWidget => 'В виджете';
  @override
  String get postcardTitle => 'Открытка';
  @override
  String failedToSave(Object e) => 'Не удалось сохранить: $e';
  @override
  String get changePhoto => 'Сменить фото';
  @override
  String get addPhotoFromGallery => 'Добавить фото из галереи';
  @override
  String get tapAnyTextToEdit => 'Нажми на любой текст чтобы изменить';
  @override
  String get creating => 'Создаём...';
  @override
  String get sharePostcard => 'Поделиться открыткой';
  @override
  String get noGeoMemories => 'Нет воспоминаний с геолокацией';
  @override
  String get addLocationHint =>
      'Добавьте место к воспоминанию\nчерез долгое нажатие';
  @override
  String get placeFallback => 'Место';
  @override
  String get welcomeSlide1Title => 'Только для\nвас двоих';
  @override
  String get welcomeSlide2Title => 'Фото и\nвоспоминания';
  @override
  String get welcomeSlide3Title => 'Ваш общий\nмир';
  @override
  String get newEntry => 'Новая запись';
  @override
  String get photoVideo => 'Фото/Видео';
  @override
  String get optionalTapToSelect => 'Необязательно — нажмите чтобы выбрать';
  @override
  String itemsShort(int n) => '$n элем.';
  @override
  String get dragHint => 'потяни';
  @override
  String get addPhoto => 'Добавить фото';
  @override
  String get groupMascotBanner => 'Это маскот вашей группы! 🎉';
  @override
  String get goToGallery => 'Перейти в галерею';
  @override
  String get hide => 'Скрыть';
  @override
  String coinsPlus(int n) => '+$n монет';
  @override
  String moodScoreLabel(int score, int max) => '$moodScorePrefix $score из $max';
  @override
  List<String> get monthAbbrev => const [
        'янв', 'фев', 'мар', 'апр', 'мая', 'июн',
        'июл', 'авг', 'сен', 'окт', 'ноя', 'дек',
      ];
  @override
  String get placeOrCoordsHint => 'Место или 55.751, 37.618';
  @override
  String get goToCoordinates => 'Перейти к координатам';
  @override
  String get chatBgSaveFailed => 'Не удалось сохранить фон';
  @override
  String get timeFormatHint => 'чч:мм';
  @override
  String get bookTitleLanguageHint =>
      'Название на английском — можно переписать на русский';
  @override
  String memoriesUnit(int n) {
    if (n % 10 == 1 && n % 100 != 11) return 'воспоминание';
    if (n % 10 >= 2 && n % 10 <= 4 && (n % 100 < 10 || n % 100 >= 20)) {
      return 'воспоминания';
    }
    return 'воспоминаний';
  }

  // ── Live location map ──
  @override
  String get liveMapTitle => 'Где мы';
  @override
  String get liveMapEnableCta => 'Показывать мою геопозицию';
  @override
  String get liveMapEnableHint =>
      'Включите, чтобы видеть друг друга на карте в реальном времени';
  @override
  String get liveMapPermissionDenied =>
      'Нет доступа к геолокации. Разрешите его в настройках телефона.';
  @override
  String get liveMapWaitingPartner => 'Ждём геопозицию партнёра…';
  @override
  String get liveMapYou => 'Вы';
  @override
  String get liveMapCenterMe => 'Ко мне';
  @override
  String get liveMapShowBoth => 'Показать обоих';
  @override
  String get liveMapOpenFull => 'Открыть карту';
  @override
  String get liveMapNotPaired => 'Подключите партнёра, чтобы видеть карту';
  @override
  String get liveMapStopCta => 'Выключить';
  @override
  String get liveMapStopped => 'Геопозиция выключена';
  @override
  String get liveLocationServiceTitle => 'Геопозиция включена';
  @override
  String get liveLocationServiceText => 'Партнёр видит вас на карте «Где мы»';
  @override
  String get liveLocationJustNow => 'только что';
  @override
  String liveLocationAgo(String value) => '$value назад';
  @override
  String get unitCm => 'см';
  @override
  String get unitM => 'м';
  @override
  String get unitKm => 'км';
  @override
  String get unitMinShort => 'мин';
  @override
  String get unitHourShort => 'ч';
  @override
  String get unitDayShort => 'д';

  // Получение подарка
  @override
  String giftFromPartner(String name) => 'Подарок от $name';
  @override
  String get giftAccepted => 'Принято 💛';
  @override
  String giftBunnyMisses(int misses) =>
      misses == 1 ? 'Ускользнул!' : 'Ускользнул ещё раз, лови!';
  @override
  String get giftIncomingTitle => 'Тебе подарок';
  @override
  String giftIncomingCount(int n) => n == 1 ? 'ждёт тебя' : 'ждут тебя: $n';
  @override
  String get giftNoteHint => 'Вложить записку (необязательно)';
  @override
  String get giftNoteSkip => 'Без записки';
  @override
  String get giftNoteSend => 'Отправить';
  @override
  String get giftWishHint => 'Загадай желание';
  @override
  String get giftWishSend => 'Загадать';
  @override
  String get giftWishEmpty => 'Сначала напиши желание';
  @override
  String giftMutualBonus(int coins) => 'Успели вовремя: обоим по $coins';
  @override
  String giftSunriseGreeting(String name) => 'Доброе утро! $name подарил тебе рассвет';
  @override
  String get giftAccept => 'Принимаю';
  @override
  String get giftDecline => 'Не сейчас';
  @override
  String get giftFlipCoin => 'Бросить монетку';
  @override
  String get giftFlipYou => 'Заказываешь ты 🍕';
  @override
  String get giftFlipPartner => 'Заказывает партнёр 🍕';

  // Профиль партнёра
  @override
  String get partnerGiftsTitle => 'Что дарили';
  @override
  String get partnerGiftsEmpty => 'Пока ничего не дарили. Самое время.';
  @override
  String get partnerMissTitle => 'Скучает по дням';
  @override
  String get partnerMissEmpty =>
      'Статистика копится с этого обновления — загляните через недельку.';
  @override
  String partnerGiftsChip(int count) => '🎁 $count';
  @override
  String partnerMissChip(int count) => '💌 $count';
  @override
  String partnerDaysTogether(int days) => 'вместе $days ${_daysWord(days)}';
  @override
  String partnerMissPeak(String weekday) => 'Чаще всего — $weekday';
  @override
  String weekdayShort(int weekday) =>
      const ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'][weekday - 1];
  @override
  String weekdayLong(int weekday) => const [
        'по понедельникам',
        'по вторникам',
        'по средам',
        'по четвергам',
        'по пятницам',
        'по субботам',
        'по воскресеньям',
      ][weekday - 1];

  String _daysWord(int n) {
    final t = n % 100;
    if (t >= 11 && t <= 14) return 'дней';
    switch (n % 10) {
      case 1:
        return 'день';
      case 2:
      case 3:
      case 4:
        return 'дня';
      default:
        return 'дней';
    }
  }

  // Подарки
  @override
  String giftPushBody(String giftName) => 'Прислал подарок: $giftName';
  @override
  String get giftShopTitle => 'Подарки';
  @override
  String get giftSent => 'Подарок отправлен';
  @override
  String get giftNotEnoughCoins => 'Не хватает монет';
  @override
  String get giftNoConnection => 'Нет связи';
  @override
  String get giftFailed => 'Не получилось отправить';
}

class _EnStrings extends AppStrings {
  const _EnStrings();

  // ── Common ──
  @override
  String get save => 'Save';
  @override
  String get cancel => 'Cancel';
  @override
  String get delete => 'Delete';
  @override
  String get edit => 'Edit';
  @override
  String get add => 'Add';
  @override
  String get done => 'Done';
  @override
  String get loading => 'Loading...';
  @override
  String get error => 'Error';
  @override
  String get ok => 'OK';
  @override
  String get yes => 'Yes';
  @override
  String get no => 'No';
  @override
  String get close => 'Close';
  @override
  String get back => 'Back';
  @override
  String get reset => 'Reset';
  @override
  String get clear => 'Clear';

  // ── Welcome ──
  @override
  String get welcomeTitle1 => 'This space is just\nfor the ';
  @override
  String get welcomeTitle2 => 'two of you';
  @override
  String get welcomeSubtitle => 'Moments, feelings, connection';
  @override
  String get welcomeFeatureMemories => 'Shared memories, photos, and notes';
  @override
  String get welcomeFeatureMood => 'Mood tracking, statuses, and daily rituals';
  @override
  String get welcomeFeatureWidgets => 'Timers, widgets, and your places map';
  @override
  String get welcomeStepCreateProfile => '1. Create your profile and sign in';
  @override
  String get welcomeStepConnectPartner =>
      '2. Connect your partner with a link, code, or QR';
  @override
  String get welcomeStepStartTogether =>
      '3. Add your first memory and personalize the space';
  @override
  String get createAccount => 'Create Account';
  @override
  String get alreadyHaveAccount => 'Already have an account';
  @override
  String get privateSecure => 'PRIVATE & SECURE';

  // ── Login ──
  @override
  String get welcomeBack => 'Welcome back!';
  @override
  String get loginToAccount => 'Sign in to your account';
  @override
  String get signInWithGoogle => 'Sign in with Google';
  @override
  String get or => 'or';
  @override
  String get email => 'Email';
  @override
  String get yourEmail => 'Your email';
  @override
  String get password => 'Password';
  @override
  String get yourPassword => 'Your password';
  @override
  String get login => 'Sign In';
  @override
  String get noAccount => 'No account? ';
  @override
  String get create => 'Create';
  @override
  String get invalidEmail => 'Enter a valid email';
  @override
  String get enterPassword => 'Enter your password';
  @override
  String get loginFailed => 'Login failed. Please try again.';
  @override
  String get profileNotFound => 'Profile not found. Please register again.';
  @override
  String get userNotFound => 'No user found with this email';
  @override
  String get wrongPassword => 'Wrong password';
  @override
  String get invalidEmailFormat => 'Invalid email format';
  @override
  String get tooManyAttempts => 'Too many attempts. Try again later';
  @override
  String get serverNotResponding =>
      'Server not responding. Check your internet.';
  @override
  String get googleNotResponding =>
      'Google not responding. Check your internet.';
  @override
  String loginError(String e) => 'Login error: $e';
  @override
  String googleLoginError(String e) => 'Google sign-in error: $e';

  // ── Setup ──
  @override
  String get whoAreYou => 'Who are you?';
  @override
  String get selectGenderForTheme => 'Select gender to customize theme';
  @override
  String get boy => 'Boy';
  @override
  String get girl => 'Girl';
  @override
  String get continueBtn => 'Continue';
  @override
  String get createProfile => 'Create your profile';
  @override
  String get signInGoogleOrManual => 'Sign in with Google or\nfill in manually';
  @override
  String get orManually => 'or manually';
  @override
  String get name => 'Name';
  @override
  String get yourName => 'Your name';
  @override
  String get minCharsPassword => 'At least 6 characters';
  @override
  String get start => 'Start';
  @override
  String get alreadyHaveAccountQuestion => 'Already have an account? ';
  @override
  String get enterYourName => 'Enter your name';
  @override
  String get enterValidEmail => 'Enter a valid email';
  @override
  String get selectGender => 'Select your gender';
  @override
  String get passwordMin6 => 'Password must be at least 6 characters';
  @override
  String get accountExists => 'Account exists';
  @override
  String get emailAlreadyRegistered =>
      'This email is already registered. Would you like to sign in?';
  @override
  String registrationError(String e) => 'Registration error: $e';
  @override
  String get agreeToTermsPrefix => 'I agree to the ';
  @override
  String get termsOfUse => 'Terms of Use';
  @override
  String get agreeToTermsAnd => ' and the ';
  @override
  String get privacyPolicyLink => 'Privacy Policy';
  @override
  String get forgotPassword => 'Forgot password?';
  @override
  String passwordResetSent(String email) =>
      'Password reset email sent to $email. '
      'Check your inbox and spam folder.';
  @override
  String get passwordResetError =>
      "Couldn't send the email. Check the address and try again later.";
  @override
  String get showPassword => 'Show';
  @override
  String get hidePassword => 'Hide';
  @override
  String get min8Chars => 'Minimum 8 characters';
  @override
  String get oneUppercase => '1 uppercase';
  @override
  String get oneSpecialChar => 'At least 1 special character';
  @override
  String get fullName => 'Full Name';
  @override
  String get createAccountBtn => 'Create Account';
  @override
  String get continueWithGoogle => 'Continue with Google';
  @override
  String get continueWithApple => 'Continue with Apple';
  @override
  String get signInWith => 'Sign in with';
  @override
  String get signUpWith => 'Sign up with';
  @override
  String get rememberMe => 'Remember me';
  @override
  String get alreadyHaveAccountLogin => 'Already have an account?';
  @override
  String get passwordRequirements => 'Password requirements';

  // ── Home ──
  @override
  String get home => 'Home';
  @override
  String get widgets => 'Widgets';
  @override
  String get connect => 'Connect';
  @override
  String get profile => 'Profile';
  @override
  String get solo => 'Solo';
  @override
  String get waitingForConnection => 'WAITING FOR CONNECTION';
  @override
  String daysLabel(String suffix) => 'DAYS $suffix';
  @override
  String monthsLabel(String suffix) => 'MONTHS $suffix';
  @override
  String timeLabel(String suffix) => 'TIME $suffix';
  @override
  String get inLove => 'IN LOVE';
  @override
  String get together => 'TOGETHER';
  @override
  String get days => 'Days';
  @override
  String get months => 'Months';
  @override
  String get time => 'Time';
  @override
  String get inviteYourPartner => 'Invite Your Partner';
  @override
  String get shareLinkCodeQr => 'Share a link, code, or QR to connect';
  @override
  String get relationshipMemoryLane => 'Relationship Memory Lane';
  @override
  String get memoriesWillAppear => 'Memories will appear here';
  @override
  String get connectWithPartnerToStart => 'Connect with your partner to start';
  @override
  String partnerIsMood(String name, String mood) => '$name is $mood';
  @override
  String get answerSent => 'Answer sent!';
  @override
  String get dailyReflection => 'Daily Reflection';
  @override
  String get today => 'TODAY';
  @override
  String get answerPrompt => 'Answer Prompt';
  @override
  String get editAnswer => 'Edit Answer';
  @override
  String get clearMood => 'Clear Mood';
  @override
  String get removeMood => 'Remove Mood';
  @override
  String get howAreYouFeeling => 'How are you feeling?';
  @override
  String get partnerWillSeeMood => 'Your partner will see your mood';
  @override
  String get moodTabLabel => 'Mood';
  @override
  String get ailmentTabLabel => 'Health';
  @override
  String get ailmentPickerSubtitle => "Your partner will see you're unwell";
  @override
  String get clearAilment => "I'm fine";
  @override
  String partnerAilmentBanner(String name, String label) =>
      '$name is unwell: $label';
  @override
  String moodDateLabel(String dateLabel) => 'Mood — $dateLabel';
  @override
  String get indicateMoodForDay => 'Indicate your mood for this day';
  @override
  String get relationshipStatus => 'Relationship Status';
  @override
  String get chooseHowToConnect => 'Choose how you want to connect';
  @override
  String get inLoveStatus => 'In Love';
  @override
  String get perfectForCouples => 'Perfect for romantic couples';
  @override
  String get married => 'Married';
  @override
  String get forMarriedPartners => 'For married partners';
  @override
  String get friends => 'Friends';
  @override
  String get connectWithBestFriend => 'Connect with your best friend';
  @override
  String get bestBuddies => 'Best Buddies';
  @override
  String get forInseparableCompanions => 'For inseparable companions';
  @override
  String get addCustomStatus => 'Add Custom Status';
  @override
  String get editCustomStatus => 'Edit Custom Status';
  @override
  String get addCaption => 'Add a caption';
  @override
  String get optionalDescribe => 'Optional — describe this moment';
  @override
  String get writeSmth => 'Write something...';
  @override
  String get skip => 'Skip';
  @override
  String get post => 'Post';
  @override
  String get posting => 'Posting...';
  @override
  String get failedUploadPhoto => 'Failed to upload photo';
  @override
  String get memoryNotSaved =>
      "Photo wasn't added to memories. Check sign-in and try again.";
  @override
  String get achievementUnlocked => 'Achievement unlocked!';
  @override
  String get achievementsTitle => 'Couple achievements';
  @override
  String get achievementDone => 'Unlocked';
  @override
  String achievementsUnlockedOf(int unlocked, int total) =>
      'Unlocked $unlocked of $total';
  @override
  String get markSecret => 'Make secret';
  @override
  String get unmarkSecret => 'Remove from secret';
  @override
  String get markedSecret => 'Hidden as secret 🔒';
  @override
  String get unmarkedSecret => 'No longer secret';
  @override
  String get secretMemories => 'Secret';
  @override
  String get enterPinTitle => 'Enter PIN';
  @override
  String get setPinTitle => 'Set a PIN';
  @override
  String get setPinHint =>
      'At least 4 digits. Stored only on this device.';
  @override
  String get wrongPin => 'Wrong PIN';
  @override
  String get pinTooShort => 'At least 4 digits';
  @override
  String get pinDone => 'Done';
  @override
  String get timeCapsule => 'Time capsule';
  @override
  String get capsuleIntro =>
      'Seal a letter or a photo — it opens on the day you choose 💌';
  @override
  String get capsuleLetterHint => 'Write a letter to the future…';
  @override
  String get capsuleAttachPhoto => 'Add a photo';
  @override
  String get capsuleOpenDate => 'Opens on';
  @override
  String get change => 'Change';
  @override
  String capsuleOpensIn(int days) => days <= 0 ? 'opens today' : 'in $days days';
  @override
  String get capsulePreset1m => '1 month';
  @override
  String get capsulePreset6m => '6 months';
  @override
  String get capsulePreset1y => '1 year';
  @override
  String get capsuleSeal => 'Seal it';
  @override
  String get capsuleNeedsContent => 'Add a letter or a photo';
  @override
  String get capsuleNeedsFutureDate => 'Open date must be in the future';
  @override
  String capsuleOpensOn(String date) => 'Opens $date';
  @override
  String capsuleFrom(String name) => 'from $name';
  @override
  String capsuleNotReady(String date) => 'Not yet 🙈 Opens $date';
  @override
  String get capsuleAddSub => 'A letter to the future';
  @override
  String get capsuleCreated => 'Capsule sealed 💌';
  @override
  String get capsuleOpenedTitle => 'Your time capsule opened! 💌';
  @override
  String get capsuleOpenedBody => 'Take a peek in your memory lane';
  @override
  String capsuleOpenedBodyNamed(String title) =>
      '"$title" is waiting in your feed';
  @override
  String get postedToMemoryLane => 'Posted to Memory Lane! 📸';
  @override
  String get moodCalendar => 'Mood Calendar';
  @override
  String get seeAll => 'See All';
  @override
  String get addMemory => 'Add';
  @override
  String get viewAll => 'View All';

  // ── Widget Screen ──
  @override
  String get widgetsTitle => 'Widgets';
  @override
  String get resetBtn => 'Reset';
  @override
  String get desktopPreview => 'Desktop preview';
  @override
  String get me => 'Me';
  @override
  String get partner => 'Partner';
  @override
  String get noStatus => 'No status';
  @override
  String get myWidget => 'My Widget';
  @override
  String get tapToEdit => 'Tap to edit';
  @override
  String get editBtn => 'Edit';
  @override
  String widgetOfPartner(String name) => '$name\'s Widget';
  @override
  String get emptyYet => 'Empty yet';
  @override
  String get updated => 'Updated';
  @override
  String get live => 'Live';
  @override
  String get mood => 'Mood';
  @override
  String get status => 'Status';
  @override
  String get message => 'Message';
  @override
  String get photo => 'Photo';
  @override
  String get photoUploaded => 'Photo uploaded';
  @override
  String get widgetPhotoOwnerOnlyHint =>
      'When adding, choose where to send: paired widget, “Partner Photo”, memories';
  @override
  String get music => 'Music';
  @override
  String get addBtn => 'Add';
  @override
  String get widgetSettings => 'Widget Settings';
  @override
  String get photoToMemoryLane => 'Photo → Memory Lane';
  @override
  String get autoSavePhotoToMemories => 'Automatically save photos to memories';
  @override
  String get messagestoMemoryLane => 'Messages → Memory Lane';
  @override
  String get autoSaveMessages => 'Automatically save messages';
  @override
  String get musicToMemoryLane => 'Music → Memory Lane';
  @override
  String get autoSaveTracks => 'Automatically save tracks';
  @override
  String get moodToCalendar => 'Mood → Calendar';
  @override
  String get autoMarkMoodCalendar => 'Automatically mark in mood calendar';
  @override
  String get connectPartnerForWidgets =>
      'Connect a partner to start\nexchanging widgets';
  @override
  String get chooseMood => 'Choose mood';
  @override
  String get statusHint => 'What\'s new with you?';
  @override
  String get messageHint => 'Write something nice...';
  @override
  String get chooseSource => 'Choose source';
  @override
  String get camera => 'Camera';
  @override
  String get gallery => 'Gallery';
  @override
  String get musicTitle => 'Music';
  @override
  String get trackName => 'Track name';
  @override
  String get artist => 'Artist';
  @override
  String get linkOptional => 'Link (optional)';
  @override
  String get uploadingPhoto => 'Uploading photo...';
  @override
  String get resetWidget => 'Reset widget?';
  @override
  String get resetWidgetConfirm => 'All your widget data will be cleared.';
  @override
  String get notPairedWidgets => 'Widgets';
  @override
  String get notPairedWidgetsDesc =>
      'Connect a partner to start\nexchanging widgets';

  // ── Profile ──
  @override
  String get user => 'User';
  @override
  String get noEmail => 'No email';
  @override
  String get gender => 'Gender';
  @override
  String get male => 'Male';
  @override
  String get female => 'Female';
  @override
  String get information => 'INFORMATION';
  @override
  String get theme => 'Theme';
  @override
  String get relationships => 'RELATIONSHIPS';
  @override
  String get statusLabel => 'Status';
  @override
  String get partnerLabel => 'Partner';
  @override
  String get notSelected => 'Not selected';
  @override
  String daysTogetherLabel(String days) => '$days days';
  @override
  String get invitePartnerToCount =>
      'Invite a partner to start\ncounting days together ❤️';
  @override
  String get anniversaryDate => 'Anniversary';
  @override
  String get anniversaryWheelHint =>
      'For reminders. The “Days together” counter is set separately — tap the ✏️ on the home screen';
  @override
  String get firstKissDate => 'First Kiss';
  @override
  String get myBirthday => 'My Birthday';
  @override
  String get partnerBirthday => "Partner's Birthday";
  @override
  String get notifCelebrations => 'Celebration Notifications';
  @override
  String get notifCelebrationsHint =>
      "We'll remind you the day before and on the day of anniversaries and birthdays";
  @override
  String get anniversaryTodayTitle => '🎉 Happy Anniversary!';
  @override
  String get anniversaryTodayBody =>
      'Congratulations on your anniversary together! Open Togetherly to celebrate.';
  @override
  String get birthdayTodayTitle => '🎂 Happy Birthday!';
  @override
  String get birthdayTodayBody =>
      "Today is your special day! Open Togetherly to celebrate together.";
  @override
  String get anniversaryTomorrowTitle => '🌹 Anniversary Tomorrow!';
  @override
  String get anniversaryTomorrowBody =>
      "Don't forget — your anniversary is tomorrow. Plan something special!";
  @override
  String get birthdayTomorrowTitle => '🎈 Birthday Tomorrow!';
  @override
  String get birthdayTomorrowBody =>
      'Your birthday is tomorrow. Open Togetherly to get ready!';
  @override
  String get celebrationBannerAnniversary => 'Happy Anniversary! 🎉';
  @override
  String get celebrationBannerBirthday => 'Happy Birthday! 🎂';
  @override
  String get daysUntilAnniversary => 'until anniversary';
  @override
  String get daysUntilBirthday => 'until birthday';
  @override
  String get inLoveRelType => 'In Love';
  @override
  String get marriedRelType => 'Married';
  @override
  String get friendsRelType => 'Friends';
  @override
  String get bestFriendsRelType => 'Best Friends';
  @override
  String get customStatus => 'Custom Status';
  @override
  String get relationshipType => 'Relationship Type';
  @override
  String get selectPartner => 'Select Partner';
  @override
  String get noConnectedPartners => 'No connected partners';
  @override
  String get settings => 'SETTINGS';
  @override
  String get editProfile => 'Edit Profile';
  @override
  String get notifications => 'Notifications';
  @override
  String get privacy => 'Privacy';
  @override
  String get aboutApp => 'About App';
  @override
  String get supportAuthors => 'Support the Authors';
  @override
  String get logout => 'Sign Out';
  @override
  String get logoutQuestion => 'Sign Out?';
  @override
  String get logoutConfirm => 'Are you sure you want to sign out?';
  @override
  String get logoutBtn => 'Sign out';
  @override
  String get deleteAccount => 'Delete account';
  @override
  String get deleteAccountQuestion => 'Delete account?';
  @override
  String get deleteAccountConfirm =>
      'Your account and all your data will be permanently deleted and cannot '
      'be recovered. Your pair will be disconnected. This cannot be undone.';
  @override
  String get deleteAccountBtn => 'Delete permanently';
  @override
  String get deleteAccountReauth =>
      'Please sign in again and retry to delete your account.';
  @override
  String get deleteAccountError =>
      'Could not delete the account. Please try again.';
  @override
  String get chooseColorTheme => 'Choose color theme';
  @override
  String get themeNamePink => 'Pink';
  @override
  String get themeNamePurple => 'Purple';
  @override
  String get themeNameBlue => 'Blue';
  @override
  String get themeNamePeach => 'Peach';
  @override
  String get themeNameSage => 'Sage';
  @override
  String get themeNameMidnight => 'Midnight';
  @override
  String get themeNameLavender => 'Lavender';
  @override
  String get themeNameCherry => 'Cherry';
  @override
  String get themeNameMint => 'Mint';
  @override
  String get themeNameSunset => 'Sunset';
  @override
  String get themeNameMonochrome => 'Monochrome';
  @override
  String get themeNameForest => 'Forest';
  @override
  String get themeNameOcean => 'Ocean';
  @override
  String get themeNameHoney => 'Honey';
  @override
  String get themeNameLemon => 'Lemon';
  @override
  String get themeNameSand => 'Sand';
  @override
  String get themeNameAurora => 'Aurora';
  @override
  String get themeNameBordeaux => 'Bordeaux';
  @override
  String get themeNameTeal => 'Teal';
  @override
  String get themeNameNord => 'Nord';
  @override
  String get themeNameCharcoalTeal => 'Charcoal Teal';
  @override
  String get themeNameCoffee => 'Coffee';
  @override
  String get themeNameForestDark => 'Dark Forest';
  @override
  String get themeNameGarnet => 'Garnet';
  @override
  String get themeNameDarkHoney => 'Dark Honey';
  @override
  String premiumThemeLocked(int price) =>
      'Premium theme — $price coins, unlock it in the Coin shop';
  @override
  String get coinBalance => 'Coins';
  @override
  String get coinShopTitle => 'Coin Shop';
  @override
  String get coinShopSubtitle => 'Customization & treats';
  @override
  String get buyThemeTitle => 'Buy this theme?';
  @override
  String buyThemeDescription(String themeName, int price) =>
      'Unlock the "$themeName" theme for $price coins?';
  @override
  String get buyThemeConfirm => 'Buy';
  @override
  String get notEnoughCoins => 'Not enough coins';
  @override
  String get themePurchased => 'Theme unlocked';
  @override
  String get iconShopTitle => 'Profile Icons';
  @override
  String get iconShopSubtitle => 'Decorate your profile';
  @override
  String get noIconOption => 'No icon';
  @override
  String get iconRewardOnly => 'Reward';
  @override
  String get iconRewardHint => 'This icon is granted manually for contributing to the project.';
  @override
  String get iconPurchased => 'Icon unlocked';
  @override
  String get watchAdTitle => 'Watch an ad';
  @override
  String get watchAdSubtitle => 'Per view, up to 3 a day';
  @override
  String get adNotReady => 'Ad still loading — try again in a second';
  @override
  String get adRewardLimitReached => 'Daily limit reached — come back tomorrow';
  @override
  String get rewardPending => 'Crediting your reward…';
  @override
  String get coinPacksSectionTitle => 'Buy Coins';
  @override
  String coinPackTitle(int coins) => '$coins coins';
  @override
  String get coinPurchaseSuccess => 'Coins added!';
  @override
  String coinPurchaseSuccessAmount(int coins) => '+$coins coins credited';
  @override
  String get coinPurchasePending => 'Payment is being processed…';
  @override
  String get coinPurchaseCancelled => 'Purchase cancelled';
  @override
  String get coinPurchaseError => 'Purchase failed. Please try again';
  @override
  String get coinStoreUnavailable => 'Store unavailable';
  @override
  String get restorePurchasesTitle => 'Restore Purchases';
  @override
  String get restorePurchasesSuccess => 'Purchases restored';
  @override
  String get restorePurchasesError => 'Failed to restore purchases';
  @override
  String get changesApplyImmediately => 'Changes apply immediately';
  @override
  String get dailyBonusTitle => 'Daily login';
  @override
  String get dailyBonusSubtitle => 'Every day on login';
  @override
  String coinEarned(int amount) => '+$amount coins earned!';
  @override
  String get memoryRewardTitle => 'Add a memory';
  @override
  String get memoryRewardSubtitle => 'Add a memory, once a day';
  @override
  String get partnerInviteRewardTitle => 'Invite your partner';
  @override
  String get partnerInviteRewardSubtitle => 'One-time on connection';
  @override
  String get moodStreakRewardTitle => 'Mood streak';
  @override
  String get moodStreakRewardSubtitle => 'Both filled mood 7 days in a row';
  @override
  String get earnCoinsSection => 'Earn for free';
  @override
  String get editProfileTitle => 'Edit Profile';
  @override
  String get uploading => 'Uploading...';
  @override
  String get userNotAuthorized => 'Error: user not authorized';
  @override
  String get failedUploadImage => 'Failed to upload image';
  @override
  String get avatarUpdated => 'Avatar updated';
  @override
  String get nameUpdated => 'Name updated';
  @override
  String uploadError(String e) => 'Upload error: $e';
  @override
  String get language => 'Language';
  @override
  String get selectLanguage => 'Select Language';
  @override
  String get blobAnimation => 'Blob Animation';

  // ── Mood Calendar ──
  @override
  String get moodCalendarTitle => 'Mood Calendar';
  @override
  String get moodSettings => 'Mood settings';
  @override
  String get moodMultiplePerDay => 'Multiple moods per day';
  @override
  String get moodMultiplePerDaySubtitle =>
      'Save each mood separately instead of replacing the previous one';
  @override
  String get zoomIn => 'Zoom In';
  @override
  String get zoomOut => 'Zoom Out';
  @override
  String get week => 'Week';
  @override
  String get month => 'Month';
  @override
  String get year => 'Year';
  @override
  String get myMood => 'My Mood';
  @override
  String partnerMood(String name) => '$name\'s Mood';
  @override
  String get moods => 'Moods';

  // ── Home (continued) ──
  @override
  String get emoji => 'Emoji';
  @override
  String get label => 'Label';
  @override
  String get egSoulmates => 'e.g., Soulmates';
  @override
  String get shareYourThoughts => 'Share your thoughts...';
  @override
  String get draw => 'Draw';
  @override
  String get calendar => 'Calendar';
  @override
  String get noMemoriesYet => 'No memories yet';

  // ── Draw Screen ──
  @override
  String get drawTogether => 'Draw Together';
  @override
  String get brush => 'Brush';
  @override
  String get eraser => 'Eraser';
  @override
  String get panTool => 'Hand';
  @override
  String get fillBg => 'Fill';
  @override
  String get rotateCanvas => 'Rotate Canvas';
  @override
  String get drawLine => 'Line';
  @override
  String get drawRect => 'Rectangle';
  @override
  String get drawCircle => 'Circle';
  @override
  String get drawTriangle => 'Triangle';
  @override
  String get fillShapes => 'Fill Shapes';
  @override
  String get insertPhoto => 'Insert Photo';
  @override
  String get photoRequiresPartner =>
      'Photo sharing is available only when drawing with a partner';
  @override
  String get photoFromGallery => 'From Gallery';
  @override
  String get photoFromCamera => 'Take Photo';
  @override
  String get undoAction => 'Undo';
  @override
  String get redoAction => 'Redo';
  @override
  String get clearCanvas => 'Clear';
  @override
  String get clearCanvasConfirm =>
      'Clear the entire canvas? This removes both users\' drawings.';
  @override
  String get deletePhoto => 'Delete photo';
  @override
  String get mascotBoyName => 'Pixel';
  @override
  String get mascotGirlName => 'Pixie';
  @override
  String get mascotSpikyName => 'Spiky';
  @override
  String get mascotLuluName => 'Lulu';
  @override
  String get mascotIskrikName => 'Sparky';
  @override
  String get mascotZhuzhaName => 'Buzzy';
  @override
  String get saveDrawing => 'Save';
  @override
  String get shareDrawing => 'Share';
  @override
  String drawingSavedTo(String path) => 'Drawing saved to: $path';
  @override
  String get failedToSaveDrawing => 'Failed to save drawing';
  @override
  String get failedToShareDrawing => 'Failed to share drawing';
  @override
  String get strokeThickness => 'Thickness';
  @override
  String get drawHint =>
      'Start drawing! Your partner will see your strokes in real time.';
  @override
  String partnerIsDrawing(String name) => '$name is drawing…';
  @override
  String get addFirstMemory => 'Add your first memory in Memory Lane';
  @override
  String get video => 'Video';
  @override
  String get videoLabel => 'Video';
  @override
  String get location => 'Location';
  @override
  String get audio => 'Audio';
  @override
  List<String> get reflectionQuestions => [
    'What is one small thing your partner did today that made you feel appreciated?',
    'What moment with your partner made you smile today?',
    'What is something you admire about your partner right now?',
    'What is one thing you are grateful for in your relationship today?',
    'What is a memory with your partner you keep coming back to?',
    'What is one way your partner surprised you recently?',
    'What makes your partner unique to you?',
    'How did your partner support you today?',
    'What is one thing you want your partner to know today?',
    'What adventure would you love to go on with your partner?',
    'What song reminds you of your partner and why?',
    'What is the best thing about being with your partner?',
    'What small act of kindness from your partner meant the most lately?',
    'What is something new you have learned about your partner?',
    'What is a goal you both share?',
    'What is one thing you love doing together?',
    'When did you last feel truly connected to your partner?',
    'What would make tomorrow special for both of you?',
    'What compliment do you want to give your partner today?',
    'What is one habit of your partner you secretly adore?',
  ];

  // ── Draw Gallery / Canvas ──
  @override
  String get palmTool => 'Palm';
  @override
  String get drawingMode => 'Drawing Mode';
  @override
  String get newCanvas => 'New Canvas';
  @override
  String get myDrawings => 'My Drawings';
  @override
  String get untitledCanvas => 'Canvas';
  @override
  String get renameCanvas => 'Rename';
  @override
  String get deleteCanvas => 'Delete Canvas';
  @override
  String get deleteCanvasConfirm =>
      'Delete this canvas? This action cannot be undone.';
  @override
  String get canvasNameLabel => 'Canvas name';
  @override
  String get noDrawingsYet => 'No drawings yet';

  // ── Connect Partner ──
  @override
  String get newGroup => 'New';
  @override
  String get waiting => 'Waiting...';
  @override
  String get deleteGroupConfirm => 'Delete this group?';
  @override
  String get deleteGroupTitle => 'Delete Group';
  @override
  String get removeGroup => 'Remove';
  @override
  String get connected => 'Connected';
  @override
  String groupOf(int count) => 'Group of $count';
  @override
  String membersCount(int count) => 'MEMBERS · $count';
  @override
  String get member => 'Member';
  @override
  String get online => 'Online';
  @override
  String get offline => 'Offline';
  @override
  String get chatOnline => 'online';
  @override
  String get chatTypingShort => 'typing';
  @override
  String get inviteMore => 'Invite More';
  @override
  String get scanQr => 'Scan QR';
  @override
  String get disconnect => 'Disconnect';
  @override
  String get connectYourPartner => 'Connect Your Partner';
  @override
  String get shareInviteCodeDesc =>
      'Share your invite code so your\npartner can join this space';
  @override
  String get yourInviteCode => 'YOUR INVITE CODE';
  @override
  String get copy => 'Copy';
  @override
  String get share => 'Share';
  @override
  String get codeCopied => 'Code copied!';
  @override
  String shareInviteText(String code, String link) =>
      'Join me on Togetherly! Use code: $code\n\nOr click: $link';
  @override
  String get loveAppInvitation => 'Togetherly Invitation';
  @override
  String get newCodeGenerated => 'New code generated';
  @override
  String get showQr => 'Show QR';
  @override
  String get haveACode => 'Have a code?';
  @override
  String get connectPartnerBtn => 'Connect Partner';
  @override
  String get inviteMoreMembers => 'Invite More Members';
  @override
  String membersOfMax(int current, int max) => '$current/$max members';
  @override
  String shareGroupInviteText(String code, String link) =>
      'Join our group on Togetherly! Use code: $code\n\nOr click: $link';
  @override
  String get groupInvitation => 'Togetherly Group Invitation';
  @override
  String connectedWithCouple(String name) => "You're connected with $name!";
  @override
  String marriedTo(String name) => "You're married to $name! 💍";
  @override
  String friendsWith(String name) => "You're now friends with $name!";
  @override
  String buddiesWith(String name) => "You're now buddies with $name!";
  @override
  String customRelWith(String label, String name) =>
      "You're now $label with $name!";
  @override
  String get joinAnotherGroup => 'Join Another Group';
  @override
  String get enterCodeScanQr => 'Enter code, scan QR, or use a link';
  @override
  String get enterCode => 'Enter Code';
  @override
  String get invalidCodeTryAgain => 'Invalid code. Please check and try again.';
  @override
  String get joinGroup => 'Join Group';
  @override
  String get cantInviteSelf => "You can't invite yourself!";
  @override
  String get codeNotFound => 'Code not found or already used';
  @override
  String get scanToConnect => 'Scan to Connect';
  @override
  String get scanPartnersQr => "Scan Partner's QR Code";
  @override
  String get addNewConnection => 'Add New Connection';
  @override
  String get chooseTypeForConnection =>
      'Choose the type for your new connection';
  @override
  String get yourCustomType => 'Your custom type';
  @override
  String get newConnectionAdded => 'New connection added!';
  @override
  String get deleteConnection => 'Delete Connection?';
  @override
  String get deleteConnectionDesc =>
      'This will remove this connection permanently. If paired, it will disconnect your partner.';
  @override
  String get connectionRemoved => 'Connection removed';
  @override
  String get disconnectQuestion => 'Disconnect?';
  @override
  String get disconnectDesc =>
      'This will reset your timer and disconnect your partner.';
  @override
  String get renamePartner => 'Rename Member';
  @override
  String get renamePartnerHint =>
      'Only visible to you. This does not change the partner\'s name for them.';
  @override
  String get resetNickname => 'Reset';
  @override
  String joinMeLinkText(String link) => 'Join me on Togetherly! $link';
  @override
  String get custom => 'Custom';
  @override
  String membersCountBracket(int count) => 'MEMBERS ($count)';

  // ── Memory Lane ──
  @override
  String get memoryLane => 'Memory Lane';
  @override
  String get addMemoryBtn => 'Add Memory';
  @override
  String get pinned => '📌  Pinned';

  // ── Timer Card ──
  @override
  String get timers => 'Timers';
  @override
  String get failedUploadBackground =>
      'Failed to upload background. Check your connection.';

  // ── Mini Mood Calendar ──
  @override
  String get todayLabel => 'Today';

  // ── Date helpers ──
  @override
  String get todayDate => 'Today';
  @override
  String get yesterday => 'Yesterday';
  @override
  List<String> get shortMonths => [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  @override
  List<String> get shortWeekdays => [
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
    'Sun',
  ];

  // ── I Miss You / Vibes ──
  @override
  String get iMissYou => 'I miss you';
  @override
  String get iMissYouSent => 'Sent! 💕';
  @override
  String missYouNotifTitle(String name) => '$name misses you';
  @override
  String get missYouNotifBody => 'Thinking about you right now 💭';
  @override
  String missYouStreak(int count) => '🔥 $count';
  @override
  String get thinkingOfYou => 'Thinking of you';
  @override
  String get wantHug => 'Want a hug';
  @override
  String get vibeSent => 'Sent ✨';
  @override
  String get customVibe => 'Custom wish...';
  @override
  String get customVibeTitle => 'Custom message';
  @override
  String get customVibeHint => 'What do you want to say?';
  @override
  String thinkingOfYouNotifTitle(String name) => '$name is thinking of you 💭';
  @override
  String wantHugNotifTitle(String name) => '$name wants to hug you 🤗';
  @override
  String customVibeNotifTitle(String name) => name;

  // ── Photo Card ──
  @override
  String get sharedAPicture => 'Shared a picture';
  @override
  String kmFromYou(String km) => '$km from you';
  @override
  String get openInMaps => 'Open in maps';
  @override
  String get justNow => 'just now';
  @override
  String minutesAgo(int m) => '${m}m ago';
  @override
  String hoursAgo(int h) => '${h}h ago';
  @override
  String daysAgo(int d) => '${d}d ago';

  // ── Memory Lane Feed ──
  @override
  String get sharedAVideo => 'Shared a video';
  @override
  String get sharedAThought => 'Shared a thought';
  @override
  String get sharedALocation => 'Checked in';
  @override
  String get sharedMusic => 'Shared music';
  @override
  String get vibesTo => 'Vibes to';
  @override
  String get setARoute => 'Set a route';
  @override
  String get isListening => 'is listening';
  @override
  String get playTrack => 'Play';
  @override
  String get note => 'Note';
  @override
  String get sharedAVideoLink => 'Shared a video link';

  // ── Memory Lane (extended) ──
  @override
  String get noMemoriesYetDesc =>
      'Tap "Add Memory" to create your first\nshared memory together';
  @override
  String get unpinMemory => 'Unpin memory';
  @override
  String get pinMemory => 'Pin memory';
  @override
  String get saveToDevice => 'Save';
  @override
  String get editMemory => 'Edit memory';
  @override
  String get deleteMemory => 'Delete memory';
  @override
  String get deleteMemoryQuestion => 'Delete memory?';
  @override
  String get actionCannotBeUndone => 'This action cannot be undone.';
  @override
  String get editMemoryTitle => 'Edit Memory';
  @override
  String get titleOptional => 'Title (optional)';
  @override
  String get description => 'Description...';
  @override
  String get locationName => 'Location name...';
  @override
  String get changeLocationOnMap => 'Change Location on Map';
  @override
  String get pickLocationOnMap => 'Pick Location on Map';
  @override
  String get saveChanges => 'Save Changes';
  @override
  String get addMemoryTitle => 'Add Memory';
  @override
  String get chooseWhatToShare => 'Choose what you want to share';
  @override
  String newMemory(String type) => 'New $type';
  @override
  String get memoryDetails => 'Memory Details';
  @override
  String get writeYourNote => 'Write your note...';
  @override
  String get descriptionOptional => 'Description (optional)';
  @override
  String get locationNameHint => 'Location name (e.g. Central Park)';
  @override
  String get locationSet => 'Location set ✓';
  @override
  String get useCurrent => 'Use Current';
  @override
  String get pickOnMap => 'Pick on Map';
  @override
  String get songDetails => 'Song Details';
  @override
  String get songName => 'Song name';
  @override
  String get artistsCommaSeparated => 'Artists (comma separated)';
  @override
  String get egArtists => 'e.g. Drake, The Weeknd';
  @override
  String get source => 'Source';
  @override
  String get streamingLink => 'Streaming Link';
  @override
  String get fetched => 'Fetched';
  @override
  String get pasteLinkFromService => 'Paste link from any service...';
  @override
  String get autoFetchSongInfo => 'Auto-fetch song info from link';
  @override
  String get orDivider => 'OR';
  @override
  String get fileSelected => 'File selected ✓';
  @override
  String get pickAudioFromDevice => 'Pick audio from device';
  @override
  String get uploadingMemory => 'Uploading memory...';
  @override
  String get failedUploadPhotos =>
      'Failed to upload photos. Make sure Firebase Storage is enabled.';
  @override
  String get failedUploadVideo =>
      'Failed to upload video. Make sure Firebase Storage is enabled.';
  @override
  String get memoryAddedSuccess => 'Memory added successfully!';
  @override
  String failedAddMemory(String e) => 'Failed to add memory: $e';
  @override
  String get noMediaUrl => 'No media URL available';
  @override
  String get downloading => 'Downloading...';
  @override
  String get savedToGallery => 'Saved to gallery 🖼️';
  @override
  String savedToPath(String path) => 'Saved to $path';
  @override
  String downloadFailed(String e) => 'Download failed: $e';
  @override
  String failedSelectPhotos(String e) => 'Failed to select photos: $e';
  @override
  String failedSelectVideo(String e) => 'Failed to select video: $e';
  @override
  String get locationServicesDisabled => 'Location services are disabled';
  @override
  String get locationPermissionDenied => 'Location permission denied';
  @override
  String get cameraPermissionDenied =>
      'No camera access. Enable it in the app settings.';
  @override
  String get failedGetLocation => 'Failed to get location';
  @override
  String get tapToSelectPhotos => 'Tap to select photos';
  @override
  String get tapToSelectVideo => 'Tap to select video';
  @override
  String get adultContent => '18+ Content';
  @override
  String get photoBlurred => 'Photo will be blurred';
  @override
  String get fromGallery => 'From gallery';
  @override
  String get byLink => 'By link';
  @override
  String get videoLink => 'Video link';
  @override
  String get books => 'Books';
  @override
  String get bookSearchHint => 'Book title or author';
  @override
  String get searchBooksPrompt => 'Search a book by title or author';
  @override
  String get noBooksFound => 'No books found';
  @override
  String get bookSearchFailed => 'Search failed. Enter manually';
  @override
  String get bookSearchFailedHint =>
      'The search did not respond or the book is not in the database.';
  @override
  String get bookEnterManually => 'Enter manually';
  @override
  String get bookManualEntryHint =>
      'Fill in the title and author yourself';
  @override
  String get sharedABook => 'Shared a book';
  @override
  String get bookAuthorLabel => 'Author';
  @override
  String get bookAuthorHint => 'Author';
  @override
  String get bookTitleHint => 'Book title';
  @override
  String get bookDetails => 'About the book';
  @override
  String get bookReadMore => 'Read more';
  @override
  String get bookSearchAgain => 'Search';
  @override
  String get movies => 'Movies & series';
  @override
  String get movieSearchHint => 'Movie or series title';
  @override
  String get searchMoviesPrompt => 'Search a movie or series by title';
  @override
  String get noMoviesFound => 'Nothing found';
  @override
  String get movieSearchFailed => 'Search failed. Enter manually';
  @override
  String get movieSearchFailedHint =>
      'The search did not respond or the title is not in the database.';
  @override
  String get movieEnterManually => 'Enter manually';
  @override
  String get movieManualEntryHint => 'Fill in the title yourself';
  @override
  String get movieNoToken => 'Search unavailable — enter the title manually';
  @override
  String get sharedAMovie => 'Shared a movie';
  @override
  String get movieTitleHint => 'Title';
  @override
  String get movieOriginalTitleHint => 'Original title';
  @override
  String get movieDetails => 'About';
  @override
  String get movieReadMore => 'Open on Kinopoisk';
  @override
  String get movieSearchAgain => 'Search';
  @override
  String get yourRating => 'Your rating';
  @override
  String get ratingNotRated => 'Not rated';
  @override
  String get ratingHint => 'Tap a number to rate';
  @override
  String get ratingMasterpiece => 'Masterpiece 🔥';
  @override
  String get ratingExcellent => 'Excellent';
  @override
  String get ratingGood => 'Good';
  @override
  String get ratingMixed => 'So-so';
  @override
  String get ratingBad => 'Bad';
  @override
  String get ratingAwful => 'Awful';
  @override
  String get yourReview => 'Your review';
  @override
  String get reviewHint => 'What did you think? Share your impression…';
  @override
  String get memoryDateLabel => 'When was it';
  @override
  String get memoryDateNow => 'Now (at creation)';
  @override
  String get memoryDatePickDate => 'Date';
  @override
  String get memoryDatePickTime => 'Time';
  @override
  String get memoryDateClear => 'Reset';
  @override
  String get fetchData => 'Fetch data';
  @override
  String get supportedPlatformsHint =>
      'Supported: YouTube, Vimeo, Dailymotion,\nTikTok, Instagram, VK and more';
  @override
  String get supportedPlatforms => 'Supported Platforms';
  @override
  String get pasteLinkSupported => 'Paste a link from any supported platform';
  @override
  String get gotIt => 'Got it';
  @override
  String get sideActionTitle => 'Action button';
  @override
  String get sideActionOpenFeed => 'Open the feed →';
  @override
  String get sideActionCreatePin => 'Create a memory +';
  @override
  String get sideActionHint =>
      'Long-press the button to switch between → (open feed) and + (create memory)';
  @override
  String get supportedServices => 'Supported Services';
  @override
  String get pasteLinkFromSupported =>
      'Paste a link from any supported service';
  @override
  String get selectTextAndPress => 'Select text and press';
  @override
  String get spoiler => 'Spoiler';
  @override
  String get deleteComment => 'Delete comment?';
  @override
  String get deleteCommentQuestion => 'Delete this comment?';
  @override
  String get comments => 'Comments';
  @override
  String get writeAComment => 'Write a comment…';
  @override
  String get noCommentsYet => 'No comments yet — be the first!';
  @override
  String nPhotos(int count) => '$count photos';
  @override
  String get noPhotoAttached => 'No photo attached';
  @override
  String get unknownLocation => 'Unknown location';
  @override
  String get openInGoogleMaps => 'Open in Google Maps';
  @override
  String get audioFile => 'Audio file';
  @override
  String get unknownTrack => 'Unknown Track';
  @override
  String get noAudioUrl => 'No audio URL';
  @override
  String get cannotPlayAudio => 'Cannot play this audio';
  @override
  String openIn(String name) => 'Open in $name';
  @override
  String get tapToOpen => 'Tap to open';
  @override
  String get videoBadge => 'VIDEO';
  @override
  String get updateAvailableTitle => 'Update available';
  @override
  String get updateAvailableSubtitle => 'Update is recommended — some Memory Lane features may not work without it';
  @override
  String get updateWhatsNew => enWhatsNew;
  @override
  String get updateButton => 'Update';
  @override
  String get updateLaterButton => 'Later';
  @override
  String get updateRestartButton => 'Restart and install';
  @override
  String get forceUpdateTitle => 'App update required';
  @override
  String get forceUpdateBody =>
      'A new version with important changes is out. Please update to the latest version to keep using the app.';
  @override
  String get forceUpdateButton => 'Update';
  @override
  String get noteBadge => 'NOTE';
  @override
  String get youtubeBadge => 'YouTube';
  @override
  String get photoNotUploaded => 'Photo not uploaded yet';
  @override
  List<String> get fullMonths => [
    '',
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  @override
  String formatDateAt(String month, int day, int year, String time) =>
      '$month $day, $year at $time';

  // ── Relationship Status Screen ──
  @override
  String get noActiveConnection => 'No active connection';
  @override
  String get chooseAStatus => 'Choose a Status';
  @override
  String get customStatuses => 'Custom Statuses';
  @override
  String get currentStatus => 'Current Status';
  @override
  String get notSet => 'Not Set';
  @override
  String get clearStatus => 'Clear Status';
  @override
  String statusSetTo(String status) => 'Status set to: $status';
  @override
  String failedSetStatus(String e) => 'Failed to set status: $e';
  @override
  String get statusCleared => 'Status cleared';
  @override
  String failedClearStatus(String e) => 'Failed to clear status: $e';
  @override
  String get customStatusAdded => 'Custom status added';
  @override
  String failedAddStatus(String e) => 'Failed to add status: $e';
  @override
  String get statusUpdated => 'Status updated';
  @override
  String failedUpdateStatus(String e) => 'Failed to update status: $e';
  @override
  String get deleteStatus => 'Delete Status';
  @override
  String deleteStatusConfirm(String label) =>
      'Are you sure you want to delete "$label"?';
  @override
  String get statusDeleted => 'Status deleted';
  @override
  String failedDeleteStatus(String e) => 'Failed to delete status: $e';
  @override
  String get editStatus => 'Edit Status';
  @override
  String get emojiLabel => 'Emoji';
  @override
  String get emojiHint => '💕';
  @override
  String get labelField => 'Label';
  @override
  String get egLivingTogether => 'e.g., Living Together';
  @override
  String get update => 'Update';

  // ── Map Picker Screen ──
  @override
  String get selectLocationOnMap => 'Select a location on the map';
  @override
  String get selectedLocation => 'Selected location';
  @override
  String get selectLocation => 'Select Location';
  @override
  String get confirm => 'Confirm';
  @override
  String get gettingAddress => 'Getting address...';
  @override
  String get tapOnMapToSelect =>
      'Tap on the map to select a different location';
  @override
  String get failedGetCurrentLocation => 'Failed to get current location';

  // ── Mood Calendar (extended) ──
  @override
  String get averageMood => 'Average Mood';
  @override
  String get great => 'Great';
  @override
  String get good => 'Good';
  @override
  String get okay => 'Okay';
  @override
  String get bad => 'Bad';
  @override
  String get awful => 'Awful';
  @override
  String get notEnoughData => 'Not enough data for chart';
  @override
  String moodRecorded(String label) => '$label recorded!';
  @override
  String get noMoodRecorded => 'No mood recorded';
  @override
  String get moodScorePrefix => 'Rating';
  @override
  List<String> get shortWeekdaysSingleChar => [
    'M',
    'T',
    'W',
    'T',
    'F',
    'S',
    'S',
  ];
  @override
  List<String> get longWeekdays => [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];

  // ── Timer / Expandable Timer Card ──
  @override
  String get noTimers => 'No timers';
  @override
  String get createTimer => 'Create Timer';
  @override
  String get editTimer => 'Edit Timer';
  @override
  String get timerNameLabel => 'NAME';
  @override
  String get egAnniversary => 'e.g. Anniversary';
  @override
  String get targetDate => 'TARGET DATE';
  @override
  String get startDate => 'START DATE';
  @override
  String get dateFormatHint => 'dd.mm.yyyy';
  @override
  String get symbolLabel => 'SYMBOL';
  @override
  String get countdownMode => 'Countdown Mode';
  @override
  String get countdownPastDateWarning => 'Target date has already passed — the timer will show zeros. Please pick a future date.';
  @override
  String get setAsMain => 'Set as Main';
  @override
  String get saveSettings => 'SAVE SETTINGS';
  @override
  String get deleteTimerQuestion => 'Delete Timer?';
  @override
  String timerDeleteConfirm(String name) => '"$name" will be gone forever.';

  // ── Petal Timer Dial ──
  @override
  String get yearsLabel => 'Years';
  @override
  String get monthsShortLabel => 'Months';
  @override
  String get daysShortLabel => 'Days';
  @override
  String get hoursLabel => 'Hours';
  @override
  String get minLabel => 'Min';
  @override
  String get secLabel => 'Sec';

  // ── Widget Screen (extended) ──
  @override
  String get homeScreenWidgets => 'Home Screen Widgets';
  @override
  String get addToHomeScreen => 'Add to Home Screen';
  @override
  String get setAsPhotoOfDay => 'Set as Photo of the Day';
  @override
  String get widgetAddedToHome => 'Widget added to home screen';
  @override
  String failedAddWidget(String e) => 'Failed to add widget: $e';
  @override
  String get daysTogetherStat => 'Days Together';
  @override
  String get memoriesStat => 'Memories';
  @override
  String get drawingsStat => 'Drawings';
  @override
  String get missYousStat => 'Miss Yous';
  @override
  String get daysLeft => 'days left';
  @override
  String get daysElapsed => 'days elapsed';
  @override
  String get noTimersWidget => 'No timers';
  @override
  String get photoOfDay => 'Photo of the Day';
  @override
  String get mine => 'Mine';
  @override
  String get onWidget => 'On widget';
  @override
  String get randomSource => 'Random';
  @override
  String get ownPhoto => 'Own Photo';
  @override
  String get saveToMemoryLane => 'Save to Memory Lane';
  @override
  String get regenerate => 'Regenerate';
  @override
  String get none => 'None';
  @override
  String yearsAlready(int years) => '$years years already ❤️';
  @override
  String get pairWidgetTitle => 'Pair Widget';
  @override
  String get pairWidgetSubtitle => 'Mood, status, messages & photos';
  @override
  String get daysCounterSubtitle => 'Relationship day counter';
  @override
  String get timerWidgetTitle => 'Timer';
  @override
  String get timerWidgetSubtitle => 'Choose a timer for the widget';
  @override
  String get photoDayRandomSubtitle => 'Random photo from Memory Lane';
  @override
  String get photoDayCustomSubtitle => 'Custom set photo';
  @override
  String get photoDayPartnerSubtitle => 'What your partner shares';
  @override
  String get moodWidgetSubtitle => 'Horizontal widget: mine & partner\'s';
  @override
  String get relationshipStatsSubtitle =>
      'Important stats: days, photos, drawings & miss yous';
  @override
  String get daysCounterLabel => 'days';
  @override
  String get addTimerHint => 'Add a timer in the Timers section';
  @override
  String get noTimersAddHint => 'No timers. Add a timer in the Timers section.';
  @override
  String get soloTimerBannerTitle => 'You can create your own timer';
  @override
  String get soloTimerBannerSubtitle =>
      'Solo timers and their widgets are available even without adding a partner.';
  @override
  String get selectTimerForWidget => 'Select timer for widget:';
  @override
  String get daysShortLeft => 'd. left';
  @override
  String get daysShortElapsed => 'd. elapsed';
  @override
  String get partnerPhotoWillAppear =>
      'Partner\'s photo will appear\nafter they choose one';
  @override
  String get choosePhotoBelow => 'Choose a photo below';
  @override
  String get randomPhotoFromMemories => 'Random photo\nfrom memories';
  @override
  String get photoSource => 'Photo source:';
  @override
  String get fromMemories => 'from memories';
  @override
  String get fromGalleryLabel => 'from gallery';
  @override
  String get widgetModeMine => 'My photos';
  @override
  String get widgetModePartner => 'Partner photos';
  @override
  String get widgetInstances => 'Widgets on home screen';
  @override
  String get widgetNotAddedYet => 'Widget not added yet';
  @override
  String widgetSlotTitle(int index) => 'Widget ${index + 1}';
  @override
  String get addedWidgetsWillAppearHere =>
      'Added photo widgets will appear here';
  @override
  String get addSeparateWidgetHint =>
      'Add multiple widgets: each one will have its own photo and mode';
  @override
  String get widgetDisplaySource => 'What to show on widget:';
  @override
  String get widgetDisplayPhoto => 'Widget photo';
  @override
  String get noPhotoSelected => 'No photo selected';

  // ── Profile (extended) ──
  @override
  String get exportMemories => 'Export Memories';
  @override
  String get resetMissYouCount => 'Reset My Miss You Taps';
  @override
  String get resetMissYouConfirmTitle => 'Reset counter?';
  @override
  String get resetMissYouConfirmBody =>
      'Your Miss You taps will be reset to zero. Your partner\'s count stays unchanged.';
  @override
  String get noActiveGroupForExport => 'No active group for export';
  @override
  String get creatingArchive => 'Creating archive...\nThis will take a moment.';
  @override
  String exportError(String e) => 'Error during export: $e';
  @override
  String get relationshipStats => 'RELATIONSHIP STATS';

  // ── Home Screen (extended) ──
  @override
  String get startWithBlankCanvas => 'Start with a blank canvas';
  @override
  String get openSavedDrawing => 'Open a saved drawing';
  @override
  String get newPhoto => 'New Photo';
  @override
  String get titleHint => 'Title…';
  @override
  String get descriptionOptionalHint => 'Description (optional)…';
  @override
  String get setAsWidgetPhoto => 'Set as widget photo';

  // ── Mini Mood Calendar (extended) ──
  @override
  List<String> get shortWeekdaysUpper => [
    'MON',
    'TUE',
    'WED',
    'THU',
    'FRI',
    'SAT',
    'SUN',
  ];

  // ── Notification Settings ──
  @override
  String get notifMissYou => '"Miss You"';
  @override
  String get notifMissYouSub => 'When your partner taps the Miss You button';
  @override
  String get notifNewMemory => 'New Memories';
  @override
  String get notifNewMemorySub => 'When your partner adds to the Memory Lane';
  @override
  String get notifMood => 'Partner Mood';
  @override
  String get notifMoodSub => 'When your partner updates their mood';
  @override
  String get notifChat => 'Chat Messages';
  @override
  String get notifChatSub => 'When your partner messages you';
  @override
  String get notifDaysTogether => 'Days-together counter';
  @override
  String get notifDaysTogetherSub =>
      'Always-on counter in your notification shade';
  @override
  String daysTogetherNotifBody(int days) =>
      "You've been together $days ${days == 1 ? 'day' : 'days'} ❤️";
  @override
  String get daysTogetherNotifTagline => 'Every day together counts 💕';
  @override
  String get openSystemSettings => 'System Settings';
  @override
  String get notifSystemSettingsHint => 'Settings are stored on this device';

  // ── Chat ──
  @override
  String get chatTitle => 'Chat';
  @override
  String get chatHint => 'Message…';
  @override
  String get chatEmpty => 'No messages yet.\nSay hi first 💬';
  @override
  String get chatEditMessage => 'Edit';
  @override
  String get chatDeleteMessage => 'Delete';
  @override
  String get chatReply => 'Reply';
  @override
  String chatReplyingTo(String name) => 'Replying to $name';
  @override
  String chatTyping(String name) => '$name is typing…';
  @override
  String get chatEdited => 'edited';
  @override
  String get chatDeletedPlaceholder => 'Message deleted';
  @override
  String get chatSendFailed => 'Couldn\'t send. Please try again';
  @override
  String get chatAttachPin => 'Attach pin';
  @override
  String get chatSave => 'Save';
  @override
  String chatNotifTitle(String name) => '$name messages you 💬';
  @override
  String moodNotifTitle(String name) => '$name changed their mood';
  @override
  String get chatNewMessages => 'New messages';
  @override
  String chatDateHeader(DateTime day) {
    final now = DateTime.now();
    final d0 = DateTime(day.year, day.month, day.day);
    final diff = DateTime(now.year, now.month, now.day).difference(d0).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    final base = '${months[day.month - 1]} ${day.day}';
    return day.year == now.year ? base : '$base, ${day.year}';
  }

  @override
  String chatDeleteConfirm(String text) => 'Delete this message?';
  @override
  String get chatBgTitle => 'Chat background';
  @override
  String get chatBgSet => 'Set your photo';
  @override
  String get chatBgChange => 'Change photo';
  @override
  String get chatBgRemove => 'Remove background';
  @override
  String chatBgConfirmBody(int price) =>
      'Set your photo as the chat background for $price 🪙?\n\n'
      'Every future change also costs $price 🪙.';
  @override
  String get chatBgCharged => 'Background updated';
  @override
  String get lockScreenMood => 'Lock Screen Mood';
  @override
  String get lockScreenMoodSubtitle => 'Mine & partner\'s on the lock screen';
  @override
  String get lockScreenMoodToggle => 'Show on lock screen';
  @override
  String get lockScreenMoodToggleSub =>
      'Mood is displayed when phone is locked';
  @override
  String get lockScreenMoodNoMood => 'No mood set';
  @override
  String get lockScreenMoodSetHint => 'Set mood in the mood calendar';
  @override
  String get photoGridWidget => 'Photo Grid';
  @override
  String get photoGridWidgetSubtitle => 'Multiple photos from memories';
  @override
  String get photoGridCount => 'Number of photos';
  @override
  String get photoGridSelectPhotos => 'Select photos';
  @override
  String get photoGridAddPhoto => 'Add photo';
  @override
  String get photoGridCountLabel => 'photos on widget';
  @override
  String get goToPin => 'Go to memory';
  @override
  String get openPhotoGallery => 'Photo gallery';
  @override
  String get allMediaGallery => 'All photos & videos';
  @override
  String get loadMore => 'Load more';
  @override
  String get previewLabel => 'Preview';
  @override
  String get photoSent => 'Photo sent';
  @override
  String get partnerFallback => 'partner';
  @override
  String get captionDestMemories => 'Memories';
  @override
  String get captionDestMemoriesSub => 'Add the photo to the memory lane';
  @override
  String get captionDestPairWidget => 'Pair widget';
  @override
  String captionDestPairWidgetSub(String partner) =>
      'Photo in "My widget" — visible to you and $partner';
  @override
  String get captionDestPartnerWidget => 'Partner photo widget';
  @override
  String captionDestPartnerWidgetSub(String partner) =>
      'A separate widget with a photo for $partner';
  @override
  String get groupMascot => 'Group mascot';
  @override
  String get tapForGallery => 'Tap to open gallery';
  @override
  String get selectMascot => 'Choose a mascot';
  @override
  String get showLabel => 'Show';
  @override
  String streakLabel(int days) => 'Streak: $days ${days == 1 ? 'day' : 'days'}';

  // ── Widget screen ──
  @override
  String get widgetStreakTitle => 'Couple streak';
  @override
  String get widgetStreakSubtitle =>
      'How many days in a row you both open the app';
  @override
  String get widgetPetalTimerTitle => 'Petal timer';
  @override
  String get widgetPetalTimerSubtitle =>
      'A living dial — years, months, days, h, min, sec';
  @override
  String get widgetPhotoTitle => 'Photo widget';
  @override
  String get widgetPhotoSubtitle =>
      'Personal carousel: 1–10 photos with auto-rotation';
  @override
  String get streakTogetherCaps => 'STREAK TOGETHER';
  @override
  String get daysInARow => 'days in a row';
  @override
  String get keepItUp => 'Keep it up!';
  @override
  String get ourPhotosInsteadOfDrawing => 'Our photos instead of the drawing';
  @override
  String get daysPhotosDescription =>
      'Replace the drawn couple with your real avatars — '
      'in the preview and on the home screen widget.';
  @override
  String unlockForCoins(int price) => 'Unlock — $price 🪙';
  @override
  String get showOurPhotos => 'Show our photos';
  @override
  String get partnerNoProfilePhoto =>
      'Your partner has no profile photo — ask them to add one.';
  @override
  String get addYourProfilePhoto =>
      'Add your profile photo so it appears on the widget.';
  @override
  String notEnoughCoinsNeed(int price) =>
      'Not enough coins — you need $price 🪙';
  @override
  String get daysPhotosDone => 'Done! Your photos are on the widget 💞';
  @override
  String get purchaseFailedTryLater => 'Purchase failed — try again later';
  @override
  String personalPhotosHelp(String partner) =>
      'Personal photos — 1 to 10 per widget. With two or more photos a '
      'carousel turns on: it changes on unlock or by timer.\n\nThese photos '
      'are visible only to you. To share with $partner, open “Partner photo” → '
      '“Choose photos for partner”.';
  @override
  String get personalPhotosHelpShort =>
      'Personal photos — 1 to 10 per widget. With two or more photos a '
      'carousel turns on: it changes on unlock or by timer.';
  @override
  String get uploadedPhotosToMemoryLane =>
      'Uploaded photos will be added to the memory lane';
  @override
  String partnerSharesPhotosHelp(String partner, int count) =>
      'This widget shows photos shared by $partner '
      '($count ${photosUnit(count)}). Only $partner can change them.';
  @override
  String partnerNotSharedHelp(String partner) =>
      '$partner hasn’t shared any photos yet. For them to appear here, '
      '$partner needs to open “Partner photo” and tap “Choose photos for '
      'partner” — the regular “Photo widget” is visible only to its owner.';
  @override
  String get selectPhotosForPartner => 'Choose photos for partner';
  @override
  String photosUnit(int n) => n == 1 ? 'photo' : 'photos';
  @override
  String get noPhotosFromPartner => 'No photos from partner';
  @override
  String get noPhotosAdded => 'No photos added';
  @override
  String get onePhotoNoCarousel => '1 photo · no carousel';
  @override
  String photoCountOnUnlock(int count) => '$count photos · on unlock';
  @override
  String photoCountInterval(int count, String interval) =>
      '$count photos · $interval';
  @override
  String intervalLabel(int minutes) {
    switch (minutes) {
      case 15:
        return 'every 15 min';
      case 30:
        return 'every 30 min';
      case 60:
        return 'every hour';
      case 180:
        return 'every 3 hours';
      default:
        return 'every $minutes min';
    }
  }

  @override
  String get partnerPhotoTitle => 'Partner photo';
  @override
  String partnerSharedCountHelp(int count) =>
      'Your partner shared $count photos — choose how they rotate on this '
      'widget.';
  @override
  String get partnerSharedOnePhoto =>
      'Your partner shared 1 photo — no carousel.';
  @override
  String get partnerNotSharedYet => 'Your partner hasn’t shared any photos yet.';
  @override
  String get changePhotosLabel => 'Change photos:';
  @override
  String get onUnlockOption => 'On unlock';
  @override
  String get byTimeOption => 'By time';
  @override
  String get every15Minutes => 'Every 15 minutes';
  @override
  String get every30Minutes => 'Every 30 minutes';
  @override
  String get everyHourOption => 'Every hour';
  @override
  String get every3HoursOption => 'Every 3 hours';
  @override
  String get createPostcardTitle => 'Create a postcard';
  @override
  String get createPostcardSubtitle =>
      'How long you’ve been together — beautifully and with style';
  @override
  String get whereToSendPhoto => 'Where to send the photo?';
  @override
  String get sendLabel => 'Send';
  @override
  String get widgetPhotoCaption => '📸 Widget';

  // ── Mascot gallery ──
  @override
  String get mascotSaveFailed =>
      'Couldn’t save the mascot. Check your connection.';
  @override
  String get mascotLoadFailed => 'Couldn’t load. Check your connection.';
  @override
  String get transparentBgTitle => 'Transparent background required';
  @override
  String get transparentBgBody =>
      'The mascot is shown without a background, so upload a PNG file with '
      'transparency.\n\nRemove the background beforehand — for example with '
      'remove.bg, Photoshop or Canva.';
  @override
  String get mascotNameTitle => 'Mascot name';
  @override
  String get enterNameHint => 'Enter a name';
  @override
  String get mascotLimitReached =>
      'Limit reached. Delete a mascot from the gallery.';
  @override
  String mascotDeactivated(String name) => '$name deactivated';
  @override
  String mascotActivated(String name) => '$name is now active';
  @override
  String get rename => 'Rename';
  @override
  String get deleteMascotTitle => 'Delete mascot?';
  @override
  String deleteMascotBody(String name) => '“$name” will be deleted permanently.';
  @override
  String recordStreakDays(int days) => 'Record: $days d.';
  @override
  String get deactivateLabel => 'Deactivate';
  @override
  String get makeActiveLabel => 'Make active';
  @override
  String get editLabel => 'Edit';
  @override
  String get exportPng => 'Export PNG';
  @override
  String get groupMascots => 'Group mascots';
  @override
  String mascotsCount(int count, int max) => '$count / $max mascots';
  @override
  String get limitLabel => 'Limit';
  @override
  String get mascotsLoadFailedMultiline =>
      'Mascots didn’t load.\nCheck your connection.';
  @override
  String get artistCredit => 'Artist — Alyona Grebeneva';
  @override
  String get uploadPhotoTooltip => 'Upload photo';
  @override
  String get drawLabel => 'Draw';
  @override
  String get streakBroken => 'Streak broken';
  @override
  String get streakKeepHint => 'Open the app every day to keep your streak';
  @override
  String get streakStartHint => 'Open the app today to start a new streak';
  @override
  String get fromUs => 'From us';
  @override
  String recordStreakBadge(int days) => '🏅 $days d.';

  // ── Mascot draw screen ──
  @override
  String get drawSomethingFirst => 'Draw something first';
  @override
  String genericError(String e) => 'Error: $e';
  @override
  String get drawMascotTitle => 'Draw a mascot';
  @override
  String get toolBrush => 'Brush';
  @override
  String get toolPencil => 'Pencil';
  @override
  String get toolMarker => 'Marker';
  @override
  String get toolEraser => 'Eraser';
  @override
  String get toolFill => 'Fill';
  @override
  String get toolLine => 'Line';
  @override
  String get toolRect => 'Rect.';
  @override
  String get toolCircle => 'Circle';
  @override
  String get toolTriangle => 'Triangle';
  @override
  String get fillAction => 'Fill';
  @override
  String get resetSize => 'Reset size';
  @override
  String get undoLabel => 'Undo';
  @override
  String get redoLabel => 'Redo';
  @override
  String get underlayLabel => 'Underlay';
  @override
  String get drawHintEdit =>
      'Double tap — reset view  •  2 fingers — zoom/rotate';
  @override
  String get drawHintDraw =>
      'Two fingers quickly — undo  •  Double tap — reset view';
  @override
  String get colorLabel => 'Color';
  @override
  String get hueLabel => 'Hue';
  @override
  String get saturationLabel => 'Sat.';
  @override
  String get brightnessLabel => 'Brightness';
  @override
  String get selectAction => 'Select';

  // ── Postcard templates ──
  @override
  String get pcNamesFallback => 'Together';
  @override
  String get pcLabelNames => 'Names';
  @override
  String get pcLabelDaysCaption => 'Number caption';
  @override
  String get pcLabelMessage => 'Message';
  @override
  String get pcLabelCaption => 'Caption';
  @override
  String get pcLabelPolaroidCaption => 'Polaroid caption';
  @override
  String get pcLabelMessageAlt => 'Message';
  @override
  String get pcDaysTogether => 'days together';
  @override
  String get pcMsgTogether => 'Every day with you is a gift ❤️';
  @override
  String get pcDaysOfLove => 'days of love';
  @override
  String get pcMsgPolaroid => 'Our moment ✨';
  @override
  String get pcDaysNearby => 'days side by side';
  @override
  String get pcMsgBloom => 'You’re my favorite adventure 🌸';
  @override
  String get pcNightsUnderSky => 'nights under one sky';
  @override
  String get pcMsgNightSky => 'You’re my star ✨';

  // ── Photo carousel editor ──
  @override
  String get addOneToTenPhotos => 'Add 1 to 10 photos';
  @override
  String photoCountCarousel(int count) => '$count photos · carousel';
  @override
  String get addMorePhotosCarouselHint =>
      'Add more photos to enable the carousel — photos will rotate '
      'automatically.';
  @override
  String get dragToReorder => 'Hold and drag to reorder';
  @override
  String photoNumber(int n) => 'Photo $n';
  @override
  String get mainPhoto => 'Main';
  @override
  String positionNumber(int n) => 'Position $n';
  @override
  String get addMore => 'Add more';
  @override
  String get fromDevice => 'From device';
  @override
  String get fromFeed => 'From feed';

  // ── Profile screen ──
  @override
  String get cropAvatarTitle => '✂️  Crop avatar';
  @override
  String get avatarTitle => 'Avatar';
  @override
  String get appIconTitle => 'App icon';
  @override
  String get appIconUpdateHint =>
      'The home-screen icon may take a couple of seconds to refresh.';
  @override
  String get appIconChangeFailed => 'Could not change the icon';
  @override
  String get viewAction => 'View';
  @override
  String get enterDateFormat => 'Enter the date as DD.MM.YYYY';
  @override
  String yearRange(int first, int last) => 'Year from $first to $last';
  @override
  String get enterTimeFormat => 'Time must be in HH:MM format';
  @override
  String get dateHintFormat => 'DD.MM.YYYY';
  @override
  String get timeHintFormat => 'HH:MM';
  @override
  String get openCalendar => 'Open calendar';
  @override
  String get refreshTooltip => 'Refresh';
  @override
  String get memoriesMapTooltip => 'Memories map';
  @override
  String kpRating(String rating) => 'KP $rating';
  @override
  String get editLocation => 'Edit location';
  @override
  String get addLocation => 'Add location';
  @override
  String get photoVideoNote => 'Photo / Video / Note';
  @override
  String distanceLabel(double meters) => meters < 1000
      ? '${meters.round()} m'
      : '${(meters / 1000).toStringAsFixed(1)} km';
  @override
  String get appNotInstalled => 'App not installed';
  @override
  String get watchTogether => 'Watch together';
  @override
  String get watchTogetherAdPrompt =>
      'To open watch together, watch a short ad — '
      'support the app and earn coins 🪙';
  @override
  String get watchAction => 'Watch';
  @override
  String get youtubeLinkHint => 'YouTube link';
  @override
  String get startAction => 'Start';
  @override
  String get youtubeLinkInvalid => 'Could not recognize the YouTube link';
  @override
  String invitesToWatchTogether(String hostName) =>
      '$hostName invites you to watch together';
  @override
  String get joinAction => 'Join';
  @override
  String get partnerEndedWatchTogether => 'Partner ended the watch session';
  @override
  String get videoCannotWatchTogether => 'This video can\'t be watched together';
  @override
  String get videoEmbedBlockedHint =>
      'This video can\'t be embedded: the author disabled playback outside '
      'YouTube, or it has an age/region restriction. If it fails on just one '
      'phone, update "Android System WebView" and Chrome from Google Play on '
      'that device. You can open it on YouTube directly or pick another — '
      'most of them work.';
  @override
  String get chooseAnother => 'Choose another';
  @override
  String get openOnYoutube => 'Open on YouTube';
  @override
  String get watchingTogether => 'Watching together';
  @override
  String get partnerJoined => 'Partner joined';
  @override
  String get waitingForPartner => 'Waiting for partner…';
  @override
  String get syncedPlaying => 'Synced · playing';
  @override
  String get syncedPaused => 'Synced · paused';
  @override
  String get writeFirstMessage => 'Write the first message 💬';
  @override
  String get messageInputHint => 'Message…';
  @override
  String get selectOnePhoto => 'Select 1 photo';
  @override
  String get maxSelected => 'Maximum selected';
  @override
  String selectUpToPhotos(int n) => 'Select up to $n ${photosUnit(n)}';
  @override
  String get selectPhotosPrompt => 'Select photos';
  @override
  String addWithCount(int n) => 'Add ($n)';
  @override
  String get failedToLoadMemories => 'Failed to load memories';
  @override
  String get noPhotosInMemoryLane => 'No photos in Memory Lane';
  @override
  String get inWidget => 'On widget';
  @override
  String get postcardTitle => 'Postcard';
  @override
  String failedToSave(Object e) => 'Failed to save: $e';
  @override
  String get changePhoto => 'Change photo';
  @override
  String get addPhotoFromGallery => 'Add photo from gallery';
  @override
  String get tapAnyTextToEdit => 'Tap any text to edit';
  @override
  String get creating => 'Creating...';
  @override
  String get sharePostcard => 'Share postcard';
  @override
  String get noGeoMemories => 'No memories with location';
  @override
  String get addLocationHint => 'Add a place to a memory\nwith a long press';
  @override
  String get placeFallback => 'Place';
  @override
  String get welcomeSlide1Title => 'Just for\nthe two of you';
  @override
  String get welcomeSlide2Title => 'Photos &\nmemories';
  @override
  String get welcomeSlide3Title => 'Your shared\nworld';
  @override
  String get newEntry => 'New entry';
  @override
  String get photoVideo => 'Photo/Video';
  @override
  String get optionalTapToSelect => 'Optional — tap to select';
  @override
  String itemsShort(int n) => '$n items';
  @override
  String get dragHint => 'drag';
  @override
  String get addPhoto => 'Add photo';
  @override
  String get groupMascotBanner => 'This is your group mascot! 🎉';
  @override
  String get goToGallery => 'Go to gallery';
  @override
  String get hide => 'Hide';
  @override
  String coinsPlus(int n) => '+$n ${n == 1 ? 'coin' : 'coins'}';
  @override
  String moodScoreLabel(int score, int max) => '$moodScorePrefix $score of $max';
  @override
  List<String> get monthAbbrev => const [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
      ];
  @override
  String get placeOrCoordsHint => 'Place or 55.751, 37.618';
  @override
  String get goToCoordinates => 'Go to coordinates';
  @override
  String get chatBgSaveFailed => 'Failed to save background';
  @override
  String get timeFormatHint => 'hh:mm';
  @override
  String get bookTitleLanguageHint =>
      'Title may be in English — feel free to edit';
  @override
  String memoriesUnit(int n) => n == 1 ? 'memory' : 'memories';

  // ── Live location map ──
  @override
  String get liveMapTitle => 'Where we are';
  @override
  String get liveMapEnableCta => 'Share my location';
  @override
  String get liveMapEnableHint =>
      'Turn on to see each other on the map in real time';
  @override
  String get liveMapPermissionDenied =>
      'Location access denied. Enable it in your phone settings.';
  @override
  String get liveMapWaitingPartner => 'Waiting for partner\'s location…';
  @override
  String get liveMapYou => 'You';
  @override
  String get liveMapCenterMe => 'Center on me';
  @override
  String get liveMapShowBoth => 'Show both';
  @override
  String get liveMapOpenFull => 'Open map';
  @override
  String get liveMapNotPaired => 'Connect a partner to see the map';
  @override
  String get liveMapStopCta => 'Stop sharing';
  @override
  String get liveMapStopped => 'Location sharing off';
  @override
  String get liveLocationServiceTitle => 'Location sharing on';
  @override
  String get liveLocationServiceText =>
      'Your partner can see you on the “Where we are” map';
  @override
  String get liveLocationJustNow => 'just now';
  @override
  String liveLocationAgo(String value) => '$value ago';
  @override
  String get unitCm => 'cm';
  @override
  String get unitM => 'm';
  @override
  String get unitKm => 'km';
  @override
  String get unitMinShort => 'min';
  @override
  String get unitHourShort => 'h';
  @override
  String get unitDayShort => 'd';

  // Receiving a gift
  @override
  String giftFromPartner(String name) => 'A gift from $name';
  @override
  String get giftAccepted => 'Accepted 💛';
  @override
  String giftBunnyMisses(int misses) =>
      misses == 1 ? 'It slipped away!' : 'Slipped again, catch it!';
  @override
  String get giftIncomingTitle => 'A gift for you';
  @override
  String giftIncomingCount(int n) => n == 1 ? 'is waiting' : '$n are waiting';
  @override
  String get giftNoteHint => 'Add a note (optional)';
  @override
  String get giftNoteSkip => 'No note';
  @override
  String get giftNoteSend => 'Send';
  @override
  String get giftWishHint => 'Make a wish';
  @override
  String get giftWishSend => 'Wish';
  @override
  String get giftWishEmpty => 'Write your wish first';
  @override
  String giftMutualBonus(int coins) => 'Right on time: $coins each';
  @override
  String giftSunriseGreeting(String name) => 'Good morning! $name sent you a sunrise';
  @override
  String get giftAccept => 'Accept';
  @override
  String get giftDecline => 'Not now';
  @override
  String get giftFlipCoin => 'Flip a coin';
  @override
  String get giftFlipYou => 'You order 🍕';
  @override
  String get giftFlipPartner => 'Partner orders 🍕';

  // Partner profile
  @override
  String get partnerGiftsTitle => 'Gifts received';
  @override
  String get partnerGiftsEmpty => 'No gifts yet. Good moment to start.';
  @override
  String get partnerMissTitle => 'Misses you on';
  @override
  String get partnerMissEmpty =>
      'Stats start with this update — come back in a week.';
  @override
  String partnerGiftsChip(int count) => '🎁 $count';
  @override
  String partnerMissChip(int count) => '💌 $count';
  @override
  String partnerDaysTogether(int days) =>
      days == 1 ? 'together 1 day' : 'together $days days';
  @override
  String partnerMissPeak(String weekday) => 'Most often on $weekday';
  @override
  String weekdayShort(int weekday) =>
      const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][weekday - 1];
  @override
  String weekdayLong(int weekday) => const [
        'Mondays',
        'Tuesdays',
        'Wednesdays',
        'Thursdays',
        'Fridays',
        'Saturdays',
        'Sundays',
      ][weekday - 1];

  // Gifts
  @override
  String giftPushBody(String giftName) => 'Sent you a gift: $giftName';
  @override
  String get giftShopTitle => 'Gifts';
  @override
  String get giftSent => 'Gift sent';
  @override
  String get giftNotEnoughCoins => 'Not enough coins';
  @override
  String get giftNoConnection => 'No connection';
  @override
  String get giftFailed => 'Could not send';
}
