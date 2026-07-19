import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../models/user_data.dart';
import '../services/locale_service.dart';
import 'setup_screen.dart';
import 'login_screen.dart';

class WelcomeScreen extends StatefulWidget {
  final UserData userData;
  const WelcomeScreen({super.key, required this.userData});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  final _ctrl = PageController();
  int _page = 0;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = LocaleService.current;

    final slides = [
      _Slide(
        icon: Icons.favorite_rounded,
        title: s.welcomeSlide1Title,
        subtitle: s.welcomeSubtitle,
        bg: const [Color(0xFFEADBFF), Color(0xFFF3ECFF), Color(0xFFE6E0FF)],
        card: const [Color(0xFFB98CFF), Color(0xFF9B6BFF)],
        glow: const Color(0xFF9B6BFF),
      ),
      _Slide(
        icon: Icons.photo_library_rounded,
        title: s.welcomeSlide2Title,
        subtitle: s.welcomeFeatureMemories,
        bg: const [Color(0xFFFFEAD9), Color(0xFFFFF4EC), Color(0xFFFFE9E4)],
        card: const [Color(0xFFFFB07A), Color(0xFFFF8A5B)],
        glow: const Color(0xFFFF8A5B),
      ),
      _Slide(
        icon: Icons.auto_awesome_rounded,
        title: s.welcomeSlide3Title,
        subtitle: '${s.welcomeFeatureMood} · ${s.welcomeFeatureWidgets}',
        bg: const [Color(0xFFFFE4EC), Color(0xFFFFF1F4), Color(0xFFFCE9FF)],
        card: const [Color(0xFFFF8FA3), Color(0xFFFF6B9D)],
        glow: const Color(0xFFFF6B9D),
      ),
    ];

    final slide = slides[_page];

    return Scaffold(
      body: AnimatedContainer(
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeInOut,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: slide.bg,
            stops: const [0.0, 0.5, 1.0],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // ── Кнопка «Пропустить» ──
              SizedBox(
                height: 48,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: AnimatedOpacity(
                    opacity: _page < slides.length - 1 ? 1 : 0,
                    duration: const Duration(milliseconds: 250),
                    child: Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: TextButton(
                        onPressed: _page < slides.length - 1
                            ? () => _ctrl.animateToPage(
                                  slides.length - 1,
                                  duration: const Duration(milliseconds: 500),
                                  curve: Curves.easeInOut,
                                )
                            : null,
                        child: Text(
                          s.skip,
                          style: GoogleFonts.rubik(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Colors.black.withValues(alpha: 0.35),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              // ── Слайды ──
              Expanded(
                child: PageView.builder(
                  controller: _ctrl,
                  onPageChanged: (i) => setState(() => _page = i),
                  itemCount: slides.length,
                  itemBuilder: (_, i) => _buildSlide(slides[i]),
                ),
              ),

              // ── Dot-индикаторы ──
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(slides.length, (i) {
                  final active = _page == i;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOut,
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: active ? 26 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: active
                          ? slide.glow
                          : Colors.black.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  );
                }),
              ),

              const SizedBox(height: 30),

              // ── Кнопки ──
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Column(
                  children: [
                    _PrimaryBtn(
                      label: s.createAccount,
                      gradient: slide.card,
                      glow: slide.glow,
                      onTap: () => _navigate(context, setup: true),
                    ),
                    const SizedBox(height: 6),
                    _GhostBtn(
                      label: s.alreadyHaveAccount,
                      onTap: () => _navigate(context, setup: false),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 8),
              Text(
                s.privateSecure,
                style: GoogleFonts.rubik(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Colors.black.withValues(alpha: 0.25),
                  letterSpacing: 2.5,
                ),
              ),
              const SizedBox(height: 18),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSlide(_Slide slide) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 36),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // ── Иконка ──
          Icon(
            slide.icon,
            size: 120,
            color: slide.glow,
          ),

          const SizedBox(height: 44),

          // ── Заголовок ──
          Text(
            slide.title,
            style: GoogleFonts.rubik(
              fontSize: 36,
              fontWeight: FontWeight.w800,
              color: const Color(0xFF2B2230),
              height: 1.12,
              letterSpacing: -0.8,
            ),
            textAlign: TextAlign.center,
          ),

          const SizedBox(height: 16),

          // ── Подзаголовок ──
          Text(
            slide.subtitle,
            style: GoogleFonts.rubik(
              fontSize: 15,
              fontWeight: FontWeight.w400,
              color: const Color(0xFF2B2230).withValues(alpha: 0.5),
              height: 1.5,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Future<void> _navigate(BuildContext context, {required bool setup}) async {
    await widget.userData.markWelcomeSeen();
    if (!context.mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, _, _) => setup
            ? SetupScreen(userData: widget.userData)
            : LoginScreen(userData: widget.userData),
        transitionsBuilder: (_, anim, _, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 400),
      ),
    );
  }
}

// ── Данные слайда ─────────────────────────────────────────────────────────────

class _Slide {
  final IconData icon;
  final String title;
  final String subtitle;
  final List<Color> bg;
  final List<Color> card;
  final Color glow;

  const _Slide({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.bg,
    required this.card,
    required this.glow,
  });
}

// ── Кнопки ───────────────────────────────────────────────────────────────────

class _PrimaryBtn extends StatelessWidget {
  final String label;
  final List<Color> gradient;
  final Color glow;
  final VoidCallback onTap;
  const _PrimaryBtn({
    required this.label,
    required this.gradient,
    required this.glow,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: 58,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: gradient,
        ),
        borderRadius: BorderRadius.circular(32),
        boxShadow: [
          BoxShadow(
            color: glow.withValues(alpha: 0.4),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(32),
          onTap: onTap,
          child: Center(
            child: Text(
              label,
              style: GoogleFonts.rubik(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GhostBtn extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _GhostBtn({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: TextButton(
        onPressed: onTap,
        child: Text(
          label,
          style: GoogleFonts.rubik(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: const Color(0xFF2B2230).withValues(alpha: 0.55),
          ),
        ),
      ),
    );
  }
}
