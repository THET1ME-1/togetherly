import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../services/locale_service.dart';
import '../models/postcard_template.dart';

class PostcardCard extends StatelessWidget {
  final PostcardTemplateId templateId;
  final int days;
  final List<PostcardTextBlock> blocks;
  final bool isEditing;
  final void Function(String blockId)? onBlockTap;

  // Polaroid-specific
  final String? polaroidImagePath;
  final Alignment polaroidAlignment;
  final VoidCallback? onSelectPhoto;
  final void Function(Alignment)? onAlignmentChanged;
  final GlobalKey? polaroidCaptureKey;

  const PostcardCard({
    super.key,
    required this.templateId,
    required this.days,
    required this.blocks,
    this.isEditing = false,
    this.onBlockTap,
    this.polaroidImagePath,
    this.polaroidAlignment = Alignment.center,
    this.onSelectPhoto,
    this.onAlignmentChanged,
    this.polaroidCaptureKey,
  });

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: switch (templateId) {
        PostcardTemplateId.together => _TogetherCard(
          days: days,
          blocks: blocks,
          isEditing: isEditing,
          onBlockTap: onBlockTap,
        ),
        PostcardTemplateId.polaroid => _PolaroidCard(
          days: days,
          blocks: blocks,
          isEditing: isEditing,
          onBlockTap: onBlockTap,
          imagePath: polaroidImagePath,
          imageAlignment: polaroidAlignment,
          onSelectPhoto: onSelectPhoto,
          onAlignmentChanged: onAlignmentChanged,
          captureKey: polaroidCaptureKey,
        ),
        PostcardTemplateId.bloom => _BloomCard(
          days: days,
          blocks: blocks,
          isEditing: isEditing,
          onBlockTap: onBlockTap,
        ),
        PostcardTemplateId.nightSky => _NightSkyCard(
          days: days,
          blocks: blocks,
          isEditing: isEditing,
          onBlockTap: onBlockTap,
        ),
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared helper: wraps a text widget with an edit tap region when editing
// ─────────────────────────────────────────────────────────────────────────────

Widget _editable({
  required PostcardTextBlock block,
  required bool isEditing,
  required void Function(String)? onTap,
  required Widget child,
  Color highlightColor = Colors.white,
}) {
  if (!isEditing) return child;
  return GestureDetector(
    onTap: () => onTap?.call(block.id),
    child: Container(
      decoration: BoxDecoration(
        color: highlightColor.withOpacity(0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: highlightColor.withOpacity(0.45), width: 1),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: child,
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Template 1 — Together (romantic minimalist)
// ─────────────────────────────────────────────────────────────────────────────

class _TogetherCard extends StatelessWidget {
  final int days;
  final List<PostcardTextBlock> blocks;
  final bool isEditing;
  final void Function(String)? onBlockTap;

  const _TogetherCard({
    required this.days,
    required this.blocks,
    required this.isEditing,
    required this.onBlockTap,
  });

  PostcardTextBlock _b(String id) => blocks.firstWhere(
    (b) => b.id == id,
    orElse: () => PostcardTextBlock(id: id, label: id, text: ''),
  );

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFFF0F3), Color(0xFFFFD6E0), Color(0xFFFFB3C6)],
        ),
      ),
      child: Stack(
        children: [
          // Decorative hearts
          const Positioned(
            top: 18,
            left: 22,
            child: Text('♡', style: TextStyle(fontSize: 28, color: Color(0x33FF6B81))),
          ),
          const Positioned(
            top: 40,
            right: 18,
            child: Text('♡', style: TextStyle(fontSize: 18, color: Color(0x22FF6B81))),
          ),
          const Positioned(
            bottom: 28,
            left: 16,
            child: Text('♡', style: TextStyle(fontSize: 16, color: Color(0x22FF6B81))),
          ),
          const Positioned(
            bottom: 18,
            right: 24,
            child: Text('♡', style: TextStyle(fontSize: 24, color: Color(0x33FF6B81))),
          ),
          // Content
          Positioned.fill(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                _editable(
                  block: _b('names'),
                  isEditing: isEditing,
                  onTap: onBlockTap,
                  highlightColor: const Color(0xFFFF6B81),
                  child: Text(
                    _b('names').text,
                    style: GoogleFonts.rubik(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFFAD4560),
                      letterSpacing: 2,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  days.toString(),
                  style: GoogleFonts.rubik(
                    fontSize: 96,
                    fontWeight: FontWeight.w900,
                    color: const Color(0xFFFF6B81),
                    height: 1,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 4),
                _editable(
                  block: _b('days_label'),
                  isEditing: isEditing,
                  onTap: onBlockTap,
                  highlightColor: const Color(0xFFFF6B81),
                  child: Text(
                    _b('days_label').text,
                    style: GoogleFonts.rubik(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: const Color(0xFFCC4A66),
                      letterSpacing: 1.5,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 28),
                _editable(
                  block: _b('message'),
                  isEditing: isEditing,
                  onTap: onBlockTap,
                  highlightColor: const Color(0xFFFF6B81),
                  child: Text(
                    _b('message').text,
                    style: GoogleFonts.rubik(
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                      color: const Color(0xFFAD4560),
                      fontStyle: FontStyle.italic,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Template 2 — Polaroid
// ─────────────────────────────────────────────────────────────────────────────

class _PolaroidCard extends StatelessWidget {
  final int days;
  final List<PostcardTextBlock> blocks;
  final bool isEditing;
  final void Function(String)? onBlockTap;
  final String? imagePath;
  final Alignment imageAlignment;
  final VoidCallback? onSelectPhoto;
  final void Function(Alignment)? onAlignmentChanged;
  final GlobalKey? captureKey;

  const _PolaroidCard({
    required this.days,
    required this.blocks,
    required this.isEditing,
    required this.onBlockTap,
    this.imagePath,
    this.imageAlignment = Alignment.center,
    this.onSelectPhoto,
    this.onAlignmentChanged,
    this.captureKey,
  });

  PostcardTextBlock _b(String id) => blocks.firstWhere(
    (b) => b.id == id,
    orElse: () => PostcardTextBlock(id: id, label: id, text: ''),
  );

  // Фото/градиент без фиксированной высоты — для экспорта (заполняет Expanded)
  Widget _buildPhotoContent({bool topRadius = false}) {
    final radius = topRadius
        ? const BorderRadius.vertical(top: Radius.circular(4))
        : BorderRadius.zero;

    if (imagePath != null) {
      return ClipRRect(
        borderRadius: radius,
        child: GestureDetector(
          onPanUpdate: isEditing && onAlignmentChanged != null
              ? (d) {
                  final nx = (imageAlignment.x - d.delta.dx / 120).clamp(-1.0, 1.0);
                  final ny = (imageAlignment.y - d.delta.dy / 120).clamp(-1.0, 1.0);
                  onAlignmentChanged!(Alignment(nx, ny));
                }
              : null,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // cacheWidth ограничивает декод исходного фото ~1080px. Без него
              // фото из галереи декодилось в натуральном разрешении (12 Мп ≈
              // 48 МБ битмап) → при рендере открытки в PNG ловили OutOfMemory
              // на слабых устройствах («не удалось сохранить»).
              Image.file(File(imagePath!),
                  fit: BoxFit.cover,
                  alignment: imageAlignment,
                  cacheWidth: 1080),
              Positioned(
                bottom: 0, left: 0, right: 0,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Colors.black.withOpacity(0.55)],
                    ),
                  ),
                  padding: const EdgeInsets.fromLTRB(16, 28, 16, 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        days.toString(),
                        style: GoogleFonts.rubik(
                          fontSize: 72, fontWeight: FontWeight.w900,
                          color: Colors.white, height: 1,
                          shadows: const [Shadow(color: Colors.black26, blurRadius: 12)],
                        ),
                      ),
                      _editable(
                        block: _b('days_label'), isEditing: isEditing, onTap: onBlockTap,
                        child: Text(
                          _b('days_label').text,
                          style: GoogleFonts.rubik(
                            fontSize: 12, fontWeight: FontWeight.w500,
                            color: Colors.white.withOpacity(0.85), letterSpacing: 1.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // Drag hint — скрывается при экспорте (isEditing = false)
              if (isEditing)
                Positioned(
                  top: 8, left: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.45),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.open_with_rounded,
                            color: Colors.white, size: 11),
                        const SizedBox(width: 4),
                        Text(LocaleService.current.dragHint,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 10)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    // Нет фото — градиентный плейсхолдер
    return ClipRRect(
      borderRadius: radius,
      child: GestureDetector(
        onTap: isEditing ? onSelectPhoto : null,
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFFFB347), Color(0xFFFF6B9D), Color(0xFFC44B8A)],
            ),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Positioned(
                top: 12, right: 14,
                child: Text('📷',
                  style: TextStyle(fontSize: 20, color: Colors.white.withOpacity(0.6))),
              ),
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isEditing) ...[
                      const Icon(Icons.add_photo_alternate_rounded, color: Colors.white, size: 34),
                      const SizedBox(height: 6),
                      Text(LocaleService.current.addPhoto,
                        style: GoogleFonts.rubik(
                          fontSize: 12, color: Colors.white.withOpacity(0.9),
                          fontWeight: FontWeight.w500)),
                      const SizedBox(height: 16),
                    ],
                    Text(days.toString(),
                      style: GoogleFonts.rubik(
                        fontSize: 80, fontWeight: FontWeight.w900,
                        color: Colors.white, height: 1,
                        shadows: [Shadow(color: Colors.black.withOpacity(0.2), blurRadius: 8)])),
                    _editable(
                      block: _b('days_label'), isEditing: isEditing, onTap: onBlockTap,
                      child: Text(_b('days_label').text,
                        style: GoogleFonts.rubik(
                          fontSize: 13, fontWeight: FontWeight.w500,
                          color: Colors.white.withOpacity(0.85), letterSpacing: 1.5))),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomStrip() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        children: [
          _editable(
            block: _b('names'), isEditing: isEditing, onTap: onBlockTap,
            highlightColor: const Color(0xFFFF6B9D),
            child: Text(_b('names').text,
              style: GoogleFonts.rubik(fontSize: 14, fontWeight: FontWeight.w700,
                color: const Color(0xFF333333)),
              textAlign: TextAlign.center),
          ),
          const SizedBox(height: 6),
          _editable(
            block: _b('message'), isEditing: isEditing, onTap: onBlockTap,
            highlightColor: const Color(0xFFFF6B9D),
            child: Text(_b('message').text,
              style: GoogleFonts.rubik(fontSize: 12, fontWeight: FontWeight.w400,
                color: Colors.grey.shade500, fontStyle: FontStyle.italic),
              textAlign: TextAlign.center),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final frame = Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(4),
        boxShadow: isEditing
            ? [
                BoxShadow(
                  color: Colors.black.withOpacity(0.12),
                  blurRadius: 20,
                  offset: const Offset(0, 6),
                ),
              ]
            : null,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 185,
            child: _buildPhotoContent(topRadius: true),
          ),
          _buildBottomStrip(),
        ],
      ),
    );

    // Бежевый фон + рамка поляроида всегда одинаковые.
    // captureKey прикреплён к RepaintBoundary вокруг рамки —
    // экспорт захватывает только её, без фона.
    return Container(
      color: const Color(0xFFFFF8EF),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: captureKey != null
              ? RepaintBoundary(key: captureKey, child: frame)
              : frame,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Template 3 — Bloom (floral / soft)
// ─────────────────────────────────────────────────────────────────────────────

class _BloomCard extends StatelessWidget {
  final int days;
  final List<PostcardTextBlock> blocks;
  final bool isEditing;
  final void Function(String)? onBlockTap;

  const _BloomCard({
    required this.days,
    required this.blocks,
    required this.isEditing,
    required this.onBlockTap,
  });

  PostcardTextBlock _b(String id) => blocks.firstWhere(
    (b) => b.id == id,
    orElse: () => PostcardTextBlock(id: id, label: id, text: ''),
  );

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [Color(0xFFFFF5E4), Color(0xFFFFE4E1), Color(0xFFE8D5F5)],
        ),
      ),
      child: Stack(
        children: [
          // Blob decorations
          Positioned.fill(child: CustomPaint(painter: _BlobPainter())),
          // Flower corner decorations
          const Positioned(top: 12, left: 14, child: Text('🌸', style: TextStyle(fontSize: 26))),
          const Positioned(bottom: 12, right: 14, child: Text('🌸', style: TextStyle(fontSize: 22))),
          const Positioned(top: 14, right: 12, child: Text('🌷', style: TextStyle(fontSize: 18))),
          const Positioned(bottom: 14, left: 12, child: Text('🌷', style: TextStyle(fontSize: 16))),
          // Central frosted card
          Center(
            child: Container(
              width: double.infinity,
              margin: const EdgeInsets.all(36),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.78),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withOpacity(0.9), width: 1.5),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFE8A4C9).withOpacity(0.2),
                    blurRadius: 20,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _editable(
                    block: _b('names'),
                    isEditing: isEditing,
                    onTap: onBlockTap,
                    highlightColor: const Color(0xFFD48BC0),
                    child: Text(
                      _b('names').text,
                      style: GoogleFonts.rubik(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFFB06090),
                        letterSpacing: 1.5,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    days.toString(),
                    style: GoogleFonts.rubik(
                      fontSize: 82,
                      fontWeight: FontWeight.w900,
                      color: const Color(0xFFD48BC0),
                      height: 1,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 4),
                  _editable(
                    block: _b('days_label'),
                    isEditing: isEditing,
                    onTap: onBlockTap,
                    highlightColor: const Color(0xFFD48BC0),
                    child: Text(
                      _b('days_label').text,
                      style: GoogleFonts.rubik(
                        fontSize: 13,
                        fontWeight: FontWeight.w400,
                        color: const Color(0xFFB06090),
                        letterSpacing: 1.2,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _editable(
                    block: _b('message'),
                    isEditing: isEditing,
                    onTap: onBlockTap,
                    highlightColor: const Color(0xFFD48BC0),
                    child: Text(
                      _b('message').text,
                      style: GoogleFonts.rubik(
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                        color: const Color(0xFF9A5070),
                        fontStyle: FontStyle.italic,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BlobPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final blobs = [
      (Offset(0, 0), 90.0, const Color(0x30F4A4C8)),
      (Offset(size.width, size.height), 100.0, const Color(0x30C9A4F4)),
      (Offset(size.width * 0.15, size.height * 0.75), 70.0, const Color(0x28F4CCA4)),
      (Offset(size.width * 0.85, size.height * 0.2), 65.0, const Color(0x25A4C4F4)),
    ];
    for (final (center, radius, color) in blobs) {
      canvas.drawCircle(center, radius, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

// ─────────────────────────────────────────────────────────────────────────────
// Template 4 — Night Sky
// ─────────────────────────────────────────────────────────────────────────────

class _NightSkyCard extends StatelessWidget {
  final int days;
  final List<PostcardTextBlock> blocks;
  final bool isEditing;
  final void Function(String)? onBlockTap;

  const _NightSkyCard({
    required this.days,
    required this.blocks,
    required this.isEditing,
    required this.onBlockTap,
  });

  PostcardTextBlock _b(String id) => blocks.firstWhere(
    (b) => b.id == id,
    orElse: () => PostcardTextBlock(id: id, label: id, text: ''),
  );

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1A1A2E), Color(0xFF16213E), Color(0xFF0F3460)],
        ),
      ),
      child: Stack(
        children: [
          Positioned.fill(child: CustomPaint(painter: _StarsPainter())),
          const Positioned(top: 22, right: 26, child: Text('🌙', style: TextStyle(fontSize: 28))),
          const Positioned(bottom: 22, left: 20, child: Text('⭐', style: TextStyle(fontSize: 14))),
          const Positioned(top: 60, left: 16, child: Text('✦', style: TextStyle(fontSize: 12, color: Color(0x80FFD700)))),
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _editable(
                    block: _b('names'),
                    isEditing: isEditing,
                    onTap: onBlockTap,
                    child: Text(
                      _b('names').text,
                      style: GoogleFonts.rubik(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Colors.white.withOpacity(0.7),
                        letterSpacing: 2.5,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    days.toString(),
                    style: GoogleFonts.rubik(
                      fontSize: 96,
                      fontWeight: FontWeight.w900,
                      color: const Color(0xFFFFD700),
                      height: 1,
                      shadows: const [
                        Shadow(color: Color(0x80FFD700), blurRadius: 24),
                        Shadow(color: Color(0x40FFD700), blurRadius: 48),
                      ],
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 6),
                  _editable(
                    block: _b('days_label'),
                    isEditing: isEditing,
                    onTap: onBlockTap,
                    child: Text(
                      _b('days_label').text,
                      style: GoogleFonts.rubik(
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                        color: Colors.white.withOpacity(0.5),
                        letterSpacing: 1.5,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 24),
                  _editable(
                    block: _b('message'),
                    isEditing: isEditing,
                    onTap: onBlockTap,
                    child: Text(
                      _b('message').text,
                      style: GoogleFonts.rubik(
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                        color: Colors.white.withOpacity(0.85),
                        fontStyle: FontStyle.italic,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StarsPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rng = math.Random(7); // deterministic seed
    final paint = Paint();
    for (int i = 0; i < 70; i++) {
      final x = rng.nextDouble() * size.width;
      final y = rng.nextDouble() * size.height;
      final r = rng.nextDouble() * 1.8 + 0.4;
      final opacity = rng.nextDouble() * 0.6 + 0.3;
      paint.color = Colors.white.withOpacity(opacity);
      canvas.drawCircle(Offset(x, y), r, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}
