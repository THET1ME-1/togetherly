import 'dart:io';
import '../widgets/storage_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../utils/safe_launch.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pocketbase/pocketbase.dart';
import '../utils/safe_pick.dart';
import 'package:image_cropper/image_cropper.dart';
import '../models/user_data.dart';
import '../services/pb_auth_service.dart';
import '../services/pb_data_service.dart';
import '../services/pb_media_service.dart';
import '../services/pocketbase_service.dart';
import 'home_screen.dart';
import 'login_screen.dart';
import 'welcome_screen.dart';
import '../services/locale_service.dart';
import '../theme/theme_scope.dart';
import '../widgets/auth_widgets.dart';


class SetupScreen extends StatefulWidget {
  final UserData userData;
  const SetupScreen({super.key, required this.userData});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen>
    with SingleTickerProviderStateMixin {
  // Step: 0 = gender, 1 = registration
  int _step = 0;
  Gender? _selectedGender;
  bool _isLoading = false;

  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  String _avatarUrl = '';
  XFile? _selectedAvatarFile; // Локальный файл для загрузки после регистрации
  bool _agreeToTerms = false;

  // Ссылки на юридические документы (раздаются с нашего сервера, pb_public).
  static final Uri _termsUri = Uri.parse('https://togetherly.day/terms');
  static final Uri _privacyUri =
      Uri.parse('https://togetherly.day/privacy-policy');
  final _termsRecognizer = TapGestureRecognizer();
  final _privacyRecognizer = TapGestureRecognizer();

  late AnimationController _fadeController;
  late Animation<double> _fadeAnim;

  // OAuth: PB authWithOAuth2 зависает, если закрыть окно провайдера крестиком
  // (нет сигнала отмены). Ловим возврат в приложение и снимаем спиннер.
  AppLifecycleListener? _lifecycle;
  bool _oauthInFlight = false;

  // Colors based on gender
  Color get _accent {
    if (_selectedGender == Gender.male) return const Color(0xFF7898BF);
    return const Color(0xFFFF7E8B);
  }

  Color get _accentLight {
    if (_selectedGender == Gender.male) return const Color(0xFFEAF2FA);
    return const Color(0xFFFEEAF1);
  }

  String get _bgImageUrl {
    if (_selectedGender == Gender.male) {
      return 'https://firebasestorage.googleapis.com/v0/b/togetherly-d4856.firebasestorage.app/o/wallpapers%2Fblue-background.webp?alt=media';
    }
    return 'https://firebasestorage.googleapis.com/v0/b/togetherly-d4856.firebasestorage.app/o/wallpapers%2Fpink-background.webp?alt=media';
  }

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _fadeAnim = CurvedAnimation(parent: _fadeController, curve: Curves.easeOut);
    _fadeController.forward();
    _lifecycle = AppLifecycleListener(onResume: _onOAuthResume);
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _fadeController.dispose();
    _termsRecognizer.dispose();
    _privacyRecognizer.dispose();
    super.dispose();
  }

  /// Вернулись из in-app браузера. Если OAuth-вход не завершился (юзер отменил) —
  /// снимаем бесконечную загрузку. На успехе `_oauthInFlight` уже сброшен.
  void _onOAuthResume() {
    if (!_oauthInFlight) return;
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted && _oauthInFlight) {
        setState(() {
          _isLoading = false;
          _oauthInFlight = false;
        });
      }
    });
  }

  void _goToStep(int step) {
    _fadeController.reverse().then((_) {
      setState(() => _step = step);
      _fadeController.forward();
    });
  }

  /// Универсальный OAuth-вход: google / apple / yandex / vk / facebook.
  Future<void> _oauthSignIn(String provider) =>
      _handleOAuth(() => PbAuthService().signInWithOAuth2(provider));

  /// Общий обработчик OAuth-входа (Google/Apple) через PocketBase. Есть профиль
  /// с полом → домой; нет → дозаполняем профиль (пол из выбранного) и домой.
  Future<void> _handleOAuth(Future<RecordModel?> Function() signIn) async {
    setState(() => _isLoading = true);
    _oauthInFlight = true;
    try {
      final auth = PbAuthService();
      final user = await signIn();
      _oauthInFlight = false;
      if (user != null) {
        // Профиль из записи users PB (camelCase — как раньше Firestore).
        final profile = auth.currentProfile();

        if (profile != null &&
            profile['displayName'] != null &&
            profile['gender'] != null) {
          // Уже есть профиль — авто-вход и на главную.
          final displayName = profile['displayName'] as String;
          final email = profile['email'] as String? ?? '';
          final avatarUrl = profile['avatarUrl'] as String? ?? '';
          final genderStr = profile['gender'] as String;
          final gender = genderStr == 'male' ? Gender.male : Gender.female;

          await widget.userData.register(
            displayName: displayName,
            email: email,
            gender: gender,
            avatarUrl: avatarUrl,
            isReturningUser: true, // не обнулять данные пары
          );

          if (!mounted) return;
          Navigator.of(context).pushReplacement(
            PageRouteBuilder(
              pageBuilder: (_, _, _) => HomeScreen(userData: widget.userData),
              transitionsBuilder: (_, animation, _, child) =>
                  FadeTransition(opacity: animation, child: child),
              transitionDuration: const Duration(milliseconds: 400),
            ),
          );
        } else {
          // Новый OAuth-юзер — дозаполняем профиль (пол из выбранного шага) и домой.
          final displayName = (profile?['displayName'] as String?) ?? '';
          final email = (profile?['email'] as String?) ?? '';
          final avatarUrl = (profile?['avatarUrl'] as String?) ?? '';
          final gender = _selectedGender ?? Gender.female;
          final uid = auth.currentUid ?? '';

          // Профиль в записи users PB (пол/имя/аватар).
          if (uid.isNotEmpty) {
            await PbDataService().updateUserProfile(uid, {
              'displayName': displayName,
              'gender': gender == Gender.male ? 'male' : 'female',
              if (avatarUrl.isNotEmpty) 'avatarUrl': avatarUrl,
            });
          }

          await widget.userData.register(
            displayName: displayName,
            email: email,
            gender: gender,
            avatarUrl: avatarUrl,
          );

          if (!mounted) return;
          Navigator.of(context).pushReplacement(
            PageRouteBuilder(
              pageBuilder: (_, _, _) => HomeScreen(userData: widget.userData),
              transitionsBuilder: (_, animation, _, child) =>
                  FadeTransition(opacity: animation, child: child),
              transitionDuration: const Duration(milliseconds: 400),
            ),
          );
        }
      } else {
        if (mounted) setState(() => _isLoading = false);
      }
    } catch (e) {
      _oauthInFlight = false;
      if (mounted) {
        setState(() => _isLoading = false);
        final errorMsg = e.toString();
        if (errorMsg.contains('TimeoutException')) {
          _showError(LocaleService.current.serverNotResponding);
        } else {
          _showError(LocaleService.current.googleLoginError(errorMsg));
        }
      }
    }
  }

  Future<void> _completeSetup() async {
    final name = _nameController.text.trim();
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (name.isEmpty) {
      _showError(LocaleService.current.enterYourName);
      return;
    }
    if (email.isEmpty || !email.contains('@')) {
      _showError(LocaleService.current.enterValidEmail);
      return;
    }
    if (_selectedGender == null) {
      _showError(LocaleService.current.selectGender);
      return;
    }

    setState(() => _isLoading = true);

    try {
      final auth = PbAuthService();

      // Если пользователь не залогинен (ввёл данные вручную), создаём аккаунт
      if (!auth.isLoggedIn) {
        // Проверяем пароль только для ручной регистрации: 8 символов +
        // заглавная буква + спецсимвол (те же правила, что индикаторы под полем).
        final pwdOk = password.length >= 8 &&
            password.contains(RegExp(r'[A-Z]')) &&
            password.contains(RegExp(r'[!@#\$%^&*(),.?":{}|<>]'));
        if (!pwdOk) {
          _showError(
            '${LocaleService.current.min8Chars}, '
            '${LocaleService.current.oneUppercase}, '
            '${LocaleService.current.oneSpecialChar}',
          );
          if (mounted) setState(() => _isLoading = false);
          return;
        }
        await auth.signUpWithEmail(
          email: email,
          password: password,
          displayName: name,
        );
      }

      final userId = PocketBaseService().userId ?? '';

      // Загружаем аватарку, если выбрана → media-коллекция PB (ссылка pb://).
      String finalAvatarUrl = _avatarUrl;
      if (_selectedAvatarFile != null && userId.isNotEmpty) {
        final bytes = await _selectedAvatarFile!.readAsBytes();
        final ext = _selectedAvatarFile!.path.split('.').last;
        final uploadedUrl = await PbMediaService().uploadBytes(
          bytes,
          'profile.$ext',
          uid: userId,
          kind: 'avatar',
        );
        if (uploadedUrl != null) {
          finalAvatarUrl = uploadedUrl;
        }
      }

      // Профиль в записи users PB (пол/имя/аватар). signUpWithEmail создаёт
      // запись с display_name; пол и аватар проставляем здесь.
      if (userId.isNotEmpty) {
        await PbDataService().updateUserProfile(userId, {
          'displayName': name,
          'gender': _selectedGender == Gender.male ? 'male' : 'female',
          if (finalAvatarUrl.isNotEmpty) 'avatarUrl': finalAvatarUrl,
        });
      }

      // Регистрируем пользователя в приложении
      await widget.userData.register(
        displayName: name,
        email: email,
        gender: _selectedGender!,
        avatarUrl: finalAvatarUrl,
      );

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => HomeScreen(userData: widget.userData),
          transitionsBuilder: (_, animation, __, child) =>
              FadeTransition(opacity: animation, child: child),
          transitionDuration: const Duration(milliseconds: 400),
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        final errorMsg = e.toString();
        final s = LocaleService.current;
        // Проверяем, не существует ли уже аккаунт с таким email.
        // PB при дубле email кидает validation_not_unique в теле ответа.
        if (errorMsg.contains('email-already-in-use') ||
            errorMsg.contains('validation_not_unique') ||
            errorMsg.contains('already exists')) {
          _showEmailExistsDialog();
        } else if (errorMsg.contains('TimeoutException') ||
            errorMsg.contains('network-request-failed') ||
            errorMsg.contains('internal-error') ||
            errorMsg.contains('timeout')) {
          // Частый кейс из России: нестабильное/VPN-соединение. Понятный текст
          // вместо сырого исключения — и сервис уже сделал ретраи.
          _showError(s.serverNotResponding);
        } else if (errorMsg.contains('weak-password')) {
          _showError(s.passwordMin6);
        } else if (errorMsg.contains('invalid-email')) {
          _showError(s.invalidEmailFormat);
        } else if (errorMsg.contains('too-many-requests')) {
          _showError(s.tooManyAttempts);
        } else {
          _showError(s.registrationError(errorMsg));
        }
      }
    }
  }

  void _showEmailExistsDialog() {
    final t = context.appTheme;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          LocaleService.current.accountExists,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        content: Text(LocaleService.current.emailAlreadyRegistered),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(
              LocaleService.current.cancel,
              style: TextStyle(color: t.textSecondary),
            ),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              Navigator.of(context).pushReplacement(
                PageRouteBuilder(
                  pageBuilder: (_, __, ___) =>
                      LoginScreen(userData: widget.userData),
                  transitionsBuilder: (_, animation, __, child) =>
                      FadeTransition(opacity: animation, child: child),
                  transitionDuration: const Duration(milliseconds: 300),
                ),
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: _accent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: Text(LocaleService.current.login),
          ),
        ],
      ),
    );
  }

  void _showError(String msg) {
    if (!mounted) return;
    // maybeOf + mounted: зовётся из catch после async-гэпа, когда экран мог быть
    // снят с дерева → ScaffoldMessenger.of даёт `!` по null. См. Bugsink TypeError.
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.red.shade400,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      ),
    );
  }

  Future<void> _pickAvatar() async {
    final picker = ImagePicker();
    final XFile? image = await safePick(
      () => picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 90,
        maxWidth: 1024,
        maxHeight: 1024,
      ),
    );

    if (image == null || !mounted) return;

    // Обрезаем до круга (аватарка). Нативный кроппер может кинуть
    // PlatformException — это не краш, трактуем как отмену.
    CroppedFile? croppedFile;
    try {
      croppedFile = await ImageCropper().cropImage(
        sourcePath: image.path,
        compressQuality: 90,
        uiSettings: [
          AndroidUiSettings(
            cropStyle: CropStyle.circle,
            toolbarTitle: LocaleService.current.cropAvatarTitle,
            toolbarColor: const Color(0xFF1A1A2E),
            toolbarWidgetColor: Colors.white,
            statusBarColor: const Color(0xFF1A1A2E),
            backgroundColor: const Color(0xFF0D0D1A),
            activeControlsWidgetColor: _accent,
            cropFrameColor: _accent,
            cropGridColor: Colors.transparent,
            dimmedLayerColor: const Color(0xCC0D0D1A),
            showCropGrid: false,
            lockAspectRatio: true,
            initAspectRatio: CropAspectRatioPreset.square,
            hideBottomControls: false,
          ),
          IOSUiSettings(
            cropStyle: CropStyle.circle,
            title: LocaleService.current.avatarTitle,
            doneButtonTitle: LocaleService.current.done,
            cancelButtonTitle: LocaleService.current.cancel,
            aspectRatioLockEnabled: true,
            resetAspectRatioEnabled: false,
            rotateButtonsHidden: false,
            hidesNavigationBar: true,
          ),
        ],
      );
    } catch (e) {
      debugPrint('_pickAvatar: cropImage failed: $e');
      croppedFile = null;
    }

    if (croppedFile == null || !mounted) return;

    // Сохраняем локально для превью и последующей загрузки после регистрации.
    // Путь забираем в локальную final — внутри замыкания setState промоушен
    // nullable-локали не работает.
    final croppedPath = croppedFile.path;
    setState(() {
      _selectedAvatarFile = XFile(croppedPath);
      _avatarUrl = ''; // Очищаем URL, так как показываем локальный файл
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 500),
            child: StorageImage(
              key: ValueKey(_bgImageUrl),
              imageUrl: _bgImageUrl,
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
              placeholder: (_, __) => ColoredBox(
                  color: theme.isDark
                      ? theme.surfaceMuted
                      : const Color(0xFFFFF0EA)),
              errorWidget: (_, __, ___) => ColoredBox(
                  color: theme.isDark
                      ? theme.surfaceMuted
                      : const Color(0xFFFFF0EA)),
            ),
          ),
          SafeArea(
            child: FadeTransition(
              opacity: _fadeAnim,
              child: _step == 0 ? _buildGenderStep() : _buildRegistrationStep(),
            ),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  STEP 1: GENDER SELECTION
  // ═══════════════════════════════════════════════════
  Widget _buildGenderStep() {
    final theme = context.appTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 36),
      child: Column(
        children: [
          const SizedBox(height: 12),
          // Back button
          Align(
            alignment: Alignment.centerLeft,
            child: GestureDetector(
              onTap: () {
                Navigator.of(context).pushReplacement(
                  PageRouteBuilder(
                    pageBuilder: (_, __, ___) =>
                        WelcomeScreen(userData: widget.userData),
                    transitionsBuilder: (_, animation, __, child) =>
                        FadeTransition(opacity: animation, child: child),
                    transitionDuration: const Duration(milliseconds: 400),
                  ),
                );
              },
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.isDark
                      ? theme.cardSurface
                      : Colors.white.withOpacity(0.7),
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: theme.isDark
                          ? theme.cardBorder
                          : Colors.grey.shade200),
                ),
                child: Icon(
                  Icons.arrow_back_rounded,
                  color: theme.textSecondary,
                  size: 20,
                ),
              ),
            ),
          ),
          const Spacer(flex: 2),
          // Icon
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: _accentLight.withOpacity(0.8),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.wc_rounded, color: _accent, size: 36),
          ),
          const SizedBox(height: 32),
          Text(
            LocaleService.current.whoAreYou,
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w800,
              color: theme.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            LocaleService.current.selectGenderForTheme,
            style: TextStyle(fontSize: 15, color: theme.textMuted),
          ),
          const SizedBox(height: 48),
          // Gender cards
          Row(
            children: [
              Expanded(child: _genderCard(Gender.male)),
              const SizedBox(width: 16),
              Expanded(child: _genderCard(Gender.female)),
            ],
          ),
          const Spacer(flex: 2),
          // Continue button
          AnimatedOpacity(
            opacity: _selectedGender != null ? 1.0 : 0.4,
            duration: const Duration(milliseconds: 200),
            child: SizedBox(
              width: double.infinity,
              height: 58,
              child: ElevatedButton(
                onPressed: _selectedGender != null ? () => _goToStep(1) : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accent,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor:
                      theme.isDark ? theme.divider : Colors.grey.shade300,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(32),
                  ),
                  elevation: 12,
                  shadowColor: _accent.withOpacity(0.4),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      LocaleService.current.continueBtn,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Icon(Icons.arrow_forward_rounded, size: 20),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 36),
        ],
      ),
    );
  }

  Widget _genderCard(Gender gender) {
    final theme = context.appTheme;
    final isSelected = _selectedGender == gender;
    final isMale = gender == Gender.male;
    final color = isMale ? const Color(0xFF7898BF) : const Color(0xFFFF7E8B);
    final bgColor = isMale ? const Color(0xFFEAF2FA) : const Color(0xFFFEEAF1);
    final icon = isMale ? Icons.male_rounded : Icons.female_rounded;
    final label = isMale
        ? LocaleService.current.boy
        : LocaleService.current.girl;

    return GestureDetector(
      onTap: () => setState(() => _selectedGender = gender),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(vertical: 32),
        decoration: BoxDecoration(
          color: isSelected
              ? bgColor
              : (theme.isDark
                  ? theme.cardSurface
                  : Colors.white.withOpacity(0.7)),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: isSelected
                ? color.withOpacity(0.4)
                : (theme.isDark ? theme.cardBorder : Colors.grey.shade200),
            width: isSelected ? 2.5 : 1,
          ),
          boxShadow: isSelected
              ? theme.accentGlow(
                  color,
                  opacity: 0.15,
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                )
              : [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.03),
                    blurRadius: 12,
                  ),
                ],
        ),
        child: Column(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: isSelected
                    ? color.withOpacity(0.15)
                    : (theme.isDark
                        ? theme.surfaceMuted
                        : Colors.grey.shade100),
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                size: 36,
                color: isSelected ? color : theme.textMuted,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              label,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: isSelected ? color : theme.textSecondary,
              ),
            ),
            const SizedBox(height: 4),
            AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              width: 24,
              height: 3,
              decoration: BoxDecoration(
                color: isSelected ? color : Colors.transparent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  STEP 2: REGISTRATION
  // ═══════════════════════════════════════════════════
  Widget _buildRegistrationStep() {
    final s = LocaleService.current;
    final t = context.appTheme;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Column(
      children: [
        // ── Кнопка «назад» поверх фона ──
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: GestureDetector(
              onTap: () => _goToStep(0),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: t.isDark
                      ? t.cardSurface
                      : Colors.white.withOpacity(0.75),
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: t.isDark
                          ? t.cardBorder
                          : Colors.white.withOpacity(0.6)),
                ),
                child: Icon(Icons.arrow_back_rounded,
                    color: t.isDark ? t.textSecondary : Colors.grey.shade800,
                    size: 20),
              ),
            ),
          ),
        ),
        const SizedBox(height: 18),
        // ── Белая карточка с формой (как в референсе) ──
        Expanded(
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: t.cardSurface,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(34)),
            ),
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsets.fromLTRB(28, 30, 28, 28 + bottomInset),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Text(
                      s.createAccountBtn,
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        color: t.textPrimary,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 22),
                  Center(child: _avatarPicker()),
                  const SizedBox(height: 24),
                  AuthField(
                    controller: _nameController,
                    label: s.fullName,
                    hint: s.yourName,
                    accent: _accent,
                  ),
                  const SizedBox(height: 18),
                  AuthField(
                    controller: _emailController,
                    label: s.email,
                    hint: 'your@email.com',
                    accent: _accent,
                    keyboardType: TextInputType.emailAddress,
                    inputFormatters: [
                      FilteringTextInputFormatter.deny(RegExp(r'[а-яёА-ЯЁ]')),
                    ],
                  ),
                  const SizedBox(height: 18),
                  AuthField(
                    controller: _passwordController,
                    label: s.password,
                    hint: s.yourPassword,
                    accent: _accent,
                    isPassword: true,
                    textInputAction: TextInputAction.done,
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 14),
                  _buildPasswordChecks(),
                  const SizedBox(height: 18),
                  _termsCheckbox(s),
                  const SizedBox(height: 24),
                  _signUpButton(s),
                  const SizedBox(height: 26),
                  AuthSocialRow(
                    label: s.signUpWith,
                    onGoogle:
                        _isLoading ? null : () => _oauthSignIn('google'),
                    onYandex:
                        _isLoading ? null : () => _oauthSignIn('yandex'),
                    onApple: Platform.isIOS
                        ? (_isLoading ? null : () => _oauthSignIn('apple'))
                        : null,
                  ),
                  const SizedBox(height: 28),
                  // Already have an account? Sign In
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        '${s.alreadyHaveAccountLogin} ',
                        style: TextStyle(
                            fontSize: 14, color: t.textSecondary),
                      ),
                      GestureDetector(
                        onTap: _isLoading ? null : _goToLogin,
                        child: Text(
                          s.login,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: _accent,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _goToLogin() {
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, _, _) => LoginScreen(userData: widget.userData),
        transitionsBuilder: (_, animation, _, child) =>
            FadeTransition(opacity: animation, child: child),
        transitionDuration: const Duration(milliseconds: 300),
      ),
    );
  }

  Widget _avatarPicker() {
    return GestureDetector(
      onTap: _pickAvatar,
      child: Stack(
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _accentLight,
              border: Border.all(color: _accent.withOpacity(0.2), width: 3),
            ),
            child: _selectedAvatarFile != null
                ? ClipOval(
                    child: Image.file(
                      File(_selectedAvatarFile!.path),
                      fit: BoxFit.cover,
                    ),
                  )
                : _avatarUrl.isNotEmpty
                    ? ClipOval(
                        child: StorageImage(
                          imageUrl: _avatarUrl,
                          fit: BoxFit.cover,
                          errorWidget: (context, url, error) => Icon(
                            Icons.person_rounded,
                            color: _accent.withOpacity(0.5),
                            size: 36,
                          ),
                        ),
                      )
                    : Icon(
                        Icons.person_rounded,
                        color: _accent.withOpacity(0.5),
                        size: 36,
                      ),
          ),
          Positioned(
            bottom: 0,
            right: 0,
            child: Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: _accent,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
              child: const Icon(
                Icons.camera_alt_rounded,
                color: Colors.white,
                size: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _termsCheckbox(AppStrings s) {
    final t = context.appTheme;
    return GestureDetector(
      onTap: () => setState(() => _agreeToTerms = !_agreeToTerms),
      behavior: HitTestBehavior.opaque,
      child: Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: _agreeToTerms ? _accent : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: _agreeToTerms ? _accent : t.textMuted,
                width: 2,
              ),
            ),
            child: _agreeToTerms
                ? const Icon(Icons.check_rounded, size: 16, color: Colors.white)
                : null,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: s.agreeToTermsPrefix),
                  TextSpan(
                    text: s.termsOfUse,
                    style: TextStyle(
                      color: _accent,
                      decoration: TextDecoration.underline,
                      decorationColor: _accent,
                    ),
                    recognizer: _termsRecognizer
                      ..onTap = () => safeLaunchUrl(_termsUri),
                  ),
                  TextSpan(text: s.agreeToTermsAnd),
                  TextSpan(
                    text: s.privacyPolicyLink,
                    style: TextStyle(
                      color: _accent,
                      decoration: TextDecoration.underline,
                      decorationColor: _accent,
                    ),
                    recognizer: _privacyRecognizer
                      ..onTap = () => safeLaunchUrl(_privacyUri),
                  ),
                ],
              ),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: t.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _signUpButton(AppStrings s) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton(
        onPressed: (_isLoading || !_agreeToTerms) ? null : _completeSetup,
        style: ElevatedButton.styleFrom(
          backgroundColor: _accent,
          foregroundColor: Colors.white,
          disabledBackgroundColor: _accent.withOpacity(0.4),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          elevation: 8,
          shadowColor: _accent.withOpacity(0.4),
        ),
        child: _isLoading
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Colors.white,
                ),
              )
            : Text(
                s.createAccountBtn,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
      ),
    );
  }

  /// Живые индикаторы требований к паролю (8 символов + заглавная + спецсимвол).
  /// Те же правила, что проверяет _completeSetup перед регистрацией.
  Widget _buildPasswordChecks() {
    final pwd = _passwordController.text;
    final s = LocaleService.current;
    return Wrap(
      spacing: 12,
      runSpacing: 6,
      children: [
        _passwordCheckRow(s.min8Chars, pwd.length >= 8),
        _passwordCheckRow(s.oneUppercase, pwd.contains(RegExp(r'[A-Z]'))),
        _passwordCheckRow(
          s.oneSpecialChar,
          pwd.contains(RegExp(r'[!@#\$%^&*(),.?":{}|<>]')),
        ),
      ],
    );
  }

  Widget _passwordCheckRow(String label, bool passed) {
    final t = context.appTheme;
    final color = passed ? const Color(0xFF4CAF50) : t.textMuted;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          passed ? Icons.check_circle_rounded : Icons.circle_outlined,
          size: 16,
          color: color,
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: color,
          ),
        ),
      ],
    );
  }

}
