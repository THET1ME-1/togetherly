import 'dart:typed_data';

import '../widgets/storage_image.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart' show Share, XFile;
import '../utils/share_origin.dart';
import 'dart:io';

import '../models/mascot.dart';
import '../services/pb_media_service.dart';
import '../services/level_service.dart';
import '../services/mascot_service.dart';
import '../services/locale_service.dart';
import '../theme/app_theme.dart';
import '../theme/theme_scope.dart';
import '../widgets/active_mascot_widget.dart' show buildMascotAssetImage;
import 'mascot_draw_screen.dart';

class MascotGalleryScreen extends StatefulWidget {
  final MascotService mascotService;
  final AppTheme theme;
  final String myUid;

  const MascotGalleryScreen({
    super.key,
    required this.mascotService,
    required this.theme,
    required this.myUid,
  });

  @override
  State<MascotGalleryScreen> createState() => _MascotGalleryScreenState();
}

class _MascotGalleryScreenState extends State<MascotGalleryScreen> {
  static final Uri _authorTelegramUri = Uri.parse('https://t.me/oke_y_y');

  AppTheme get _t => widget.theme;
  MascotService get _svc => widget.mascotService;

  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _svc.addListener(_onChanged);
  }

  @override
  void dispose() {
    _svc.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  // ── Navigation helpers ───────────────────────────────────────────────────

  Future<void> _openDrawScreen({Mascot? editMascot}) async {
    if (_svc.isGalleryFull && editMascot == null) {
      _showLimitSnack();
      return;
    }

    Uint8List? initialBytes;
    if (editMascot?.imageUrl != null) {
      // Load existing image for re-editing
      try {
        final file = await fetchCachedImageFile(editMascot!.imageUrl!);
        initialBytes = await file.readAsBytes();
      } catch (_) {}
    }

    if (!mounted) return;
    final result = await Navigator.of(context).push<MascotDrawResult>(
      MaterialPageRoute(
        builder: (_) => MascotDrawScreen(
          theme: _t,
          initialName: editMascot?.name,
          initialPngBytes: initialBytes,
          isGalleryFull: _svc.isGalleryFull && editMascot == null,
        ),
        fullscreenDialog: true,
        settings: const RouteSettings(name: '/mascot_draw'),
      ),
    );
    if (result == null || !mounted) return;

    setState(() => _uploading = true);
    try {
      if (editMascot != null && !editMascot.isDefault) {
        await _svc.updateMascotImage(
          mascot: editMascot,
          pngBytes: result.pngBytes,
        );
        await _svc.renameMascot(editMascot, result.name);
      } else {
        final saved = await _svc.uploadAndSaveMascot(
          pngBytes: result.pngBytes,
          name: result.name,
          creatorUid: widget.myUid,
        );
        if (saved == null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(LocaleService.current.mascotSaveFailed),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _importPng() async {
    if (_svc.isGalleryFull) {
      _showLimitSnack();
      return;
    }

    // Show one-time hint about transparent background requirement
    final prefs = await SharedPreferences.getInstance();
    const hintKey = 'mascot_import_hint_shown';
    if (prefs.getBool(hintKey) != true) {
      await prefs.setBool(hintKey, true);
      if (!mounted) return;
      final ok = await _showBgHintSheet();
      if (!ok || !mounted) return;
    }

    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['png'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) return;

    final defaultName = file.name
        .replaceAll(RegExp(r'\.png$', caseSensitive: false), '')
        .replaceAll('_', ' ')
        .replaceAll('-', ' ');

    if (!mounted) return;
    final name = await _showImportNameDialog(defaultName);
    if (name == null || !mounted) return;

    setState(() => _uploading = true);
    try {
      final saved = await _svc.uploadAndSaveMascot(
        pngBytes: bytes,
        name: name,
        creatorUid: widget.myUid,
      );
      if (saved == null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(LocaleService.current.mascotLoadFailed),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<bool> _showBgHintSheet() async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: BoxDecoration(
          color: _t.cardSurface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: EdgeInsets.fromLTRB(
          24, 20, 24, 20 + MediaQuery.of(context).padding.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: _t.primary.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.layers_clear_rounded, color: _t.primary, size: 24),
            ),
            const SizedBox(height: 14),
            Text(
              LocaleService.current.transparentBgTitle,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            Text(
              LocaleService.current.transparentBgBody,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: _t.textSecondary, height: 1.5),
            ),
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).pop(true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _t.primary,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: Text(
                  LocaleService.current.gotIt,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return result == true;
  }

  Future<String?> _showImportNameDialog(String defaultName) async {
    final controller = TextEditingController(text: defaultName);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(LocaleService.current.mascotNameTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              maxLength: 30,
              decoration: InputDecoration(
                hintText: LocaleService.current.enterNameHint,
              ),
              onSubmitted: (_) {
                final n = controller.text.trim();
                if (n.isNotEmpty) Navigator.of(ctx).pop(n);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(LocaleService.current.cancel),
          ),
          TextButton(
            onPressed: () {
              final n = controller.text.trim();
              if (n.isNotEmpty) Navigator.of(ctx).pop(n);
            },
            child: Text(LocaleService.current.add, style: TextStyle(color: _t.primary)),
          ),
        ],
      ),
    );
  }

  void _showLimitSnack() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(LocaleService.current.mascotLimitReached),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ── Mascot actions ───────────────────────────────────────────────────────

  Future<void> _setActive(Mascot mascot) async {
    // Гейт по разблокировке: каталожный маскот может быть «за уровень»/премиум.
    final unlocked = mascot.unlock.isUnlocked(
      level: LevelService.instance.level,
      owned: false, // премиум-покупки подключим позже (ownedFeatures)
    );
    if (!unlocked) {
      final ru = LocaleService.instance.isRussian;
      final msg = mascot.unlock.isPremium
          ? (ru ? 'Премиум-маскот 💎' : 'Premium mascot 💎')
          : (ru
              ? 'Откроется на уровне ${mascot.unlock.requiredLevel}'
              : 'Unlocks at level ${mascot.unlock.requiredLevel}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    final alreadyActive = _svc.state.activeMascotId == mascot.id;
    await _svc.setActive(alreadyActive ? null : mascot.id);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            alreadyActive
                ? LocaleService.current.mascotDeactivated(mascot.localizedName)
                : LocaleService.current.mascotActivated(mascot.localizedName),
          ),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _rename(Mascot mascot) async {
    final controller = TextEditingController(text: mascot.localizedName);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(LocaleService.current.rename),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 30,
          decoration: InputDecoration(
            hintText: LocaleService.current.mascotNameTitle,
          ),
          onSubmitted: (_) => Navigator.of(ctx).pop(controller.text.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(LocaleService.current.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: Text('OK', style: TextStyle(color: _t.primary)),
          ),
        ],
      ),
    );
    if (newName != null && newName.isNotEmpty && newName != mascot.localizedName) {
      await _svc.renameMascot(mascot, newName);
    }
  }

  Future<void> _delete(Mascot mascot) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(LocaleService.current.deleteMascotTitle),
        content: Text(
          LocaleService.current.deleteMascotBody(mascot.localizedName),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(LocaleService.current.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(LocaleService.current.delete,
                style: const TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _svc.deleteMascot(mascot);
    }
  }

  Future<void> _export(Mascot mascot) async {
    // iPad-поповер: origin считаем до async-gap, пока context жив.
    final origin = shareOriginFromContext(context);
    try {
      if (mascot.imageUrl != null) {
        final file = await fetchCachedImageFile(mascot.imageUrl!);
        final tmp = await getTemporaryDirectory();
        final dest = File(
          '${tmp.path}/${mascot.name.replaceAll(' ', '_')}.png',
        );
        await file.copy(dest.path);
        await Share.shareXFiles(
          [XFile(dest.path)],
          text: mascot.localizedName,
          sharePositionOrigin: origin,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(
          SnackBar(content: Text(LocaleService.current.exportError('$e'))),
        );
      }
    }
  }

  Future<void> _share(Mascot mascot) async {
    await _export(mascot);
  }

  Future<void> _openAuthorLink() async {
    await launchUrl(_authorTelegramUri, mode: LaunchMode.externalApplication);
  }

  void _showActions(Mascot mascot) {
    final isActive = _svc.state.activeMascotId == mascot.id;
    final canExport = mascot.imageUrl != null;

    showModalBottomSheet(
      context: context,
      backgroundColor: _t.cardSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: _t.divider,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Row(
                children: [
                  _MascotThumbnail(mascot: mascot, size: 48, service: _svc),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          mascot.localizedName,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (mascot.recordStreak > 0)
                          Text(
                            LocaleService.current
                                .recordStreakDays(mascot.recordStreak),
                            style: TextStyle(
                              fontSize: 13,
                              color: _t.textSecondary,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(),
            _ActionTile(
              icon: isActive
                  ? Icons.check_circle
                  : Icons.radio_button_unchecked,
              label: isActive
                  ? LocaleService.current.deactivateLabel
                  : LocaleService.current.makeActiveLabel,
              color: isActive ? Colors.green : _t.primary,
              onTap: () {
                Navigator.of(ctx).pop();
                _setActive(mascot);
              },
            ),
            if (!mascot.isDefault)
              _ActionTile(
                icon: Icons.edit_outlined,
                label: LocaleService.current.editLabel,
                onTap: () {
                  Navigator.of(ctx).pop();
                  _openDrawScreen(editMascot: mascot);
                },
              ),
            if (!mascot.isDefault)
              _ActionTile(
                icon: Icons.drive_file_rename_outline,
                label: LocaleService.current.rename,
                onTap: () {
                  Navigator.of(ctx).pop();
                  _rename(mascot);
                },
              ),
            if (canExport) ...[
              _ActionTile(
                icon: Icons.download_outlined,
                label: LocaleService.current.exportPng,
                onTap: () {
                  Navigator.of(ctx).pop();
                  _export(mascot);
                },
              ),
              _ActionTile(
                icon: Icons.share_outlined,
                label: LocaleService.current.share,
                onTap: () {
                  Navigator.of(ctx).pop();
                  _share(mascot);
                },
              ),
            ],
            if (!mascot.isDefault)
              _ActionTile(
                icon: Icons.delete_outline,
                label: LocaleService.current.delete,
                color: Colors.red,
                onTap: () {
                  Navigator.of(ctx).pop();
                  _delete(mascot);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final mascots = _svc.mascots;
    final streak = _svc.state.activeStreak;

    return Scaffold(
      backgroundColor: _t.surfaceMuted,
      appBar: AppBar(
        backgroundColor: _t.cardSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(
          LocaleService.current.groupMascots,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        actions: [
          if (_uploading)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          // Streak banner
          _StreakBanner(streak: streak, theme: _t),
          // Gallery count info
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  LocaleService.current
                      .mascotsCount(mascots.length, MascotService.maxMascots),
                  style: TextStyle(fontSize: 13, color: _t.textSecondary),
                ),
                if (_svc.isGalleryFull)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade100,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      LocaleService.current.limitLabel,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.orange,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // Grid
          Expanded(
            child: _svc.isLoading
                ? const Center(child: CircularProgressIndicator())
                : mascots.isEmpty
                ? Center(
                    child: Text(
                      LocaleService.current.mascotsLoadFailedMultiline,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: _t.textMuted),
                    ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 80),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                          childAspectRatio: 0.82,
                        ),
                    itemCount: mascots.length,
                    itemBuilder: (ctx, i) {
                      final m = mascots[i];
                      final isActive = _svc.state.activeMascotId == m.id;
                      return _MascotCard(
                        mascot: m,
                        isActive: isActive,
                        theme: _t,
                        service: _svc,
                        onTap: () => _showActions(m),
                      );
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: InkWell(
                  onTap: _openAuthorLink,
                  borderRadius: BorderRadius.circular(999),
                  child: Ink(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: _t.primary.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: _t.primary.withOpacity(0.18)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.palette_outlined,
                          size: 15,
                          color: _t.primary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          LocaleService.current.artistCredit,
                          style: TextStyle(
                            fontSize: 9,
                            color: _t.primary,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.1,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: _svc.isGalleryFull
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                FloatingActionButton.small(
                  heroTag: 'import_png',
                  onPressed: _uploading ? null : _importPng,
                  backgroundColor: _t.cardSurface,
                  foregroundColor: _t.primary,
                  tooltip: LocaleService.current.uploadPhotoTooltip,
                  child: const Icon(Icons.add_photo_alternate_outlined),
                ),
                const SizedBox(height: 10),
                FloatingActionButton.extended(
                  heroTag: 'draw_mascot',
                  onPressed: _uploading ? null : () => _openDrawScreen(),
                  backgroundColor: _t.primary,
                  foregroundColor: Colors.white,
                  icon: const Icon(Icons.add),
                  label: Text(LocaleService.current.drawLabel),
                ),
              ],
            ),
    );
  }
}

// ── Streak banner ─────────────────────────────────────────────────────────────

class _StreakBanner extends StatelessWidget {
  final int streak;
  final AppTheme theme;

  const _StreakBanner({required this.streak, required this.theme});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: theme.cardSurface,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Text(streak > 0 ? '🔥' : '💤', style: const TextStyle(fontSize: 24)),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                streak > 0
                    ? LocaleService.current.streakLabel(streak)
                    : LocaleService.current.streakBroken,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                ),
              ),
              Text(
                streak > 0
                    ? LocaleService.current.streakKeepHint
                    : LocaleService.current.streakStartHint,
                style: TextStyle(fontSize: 12, color: theme.textSecondary),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Mascot card ───────────────────────────────────────────────────────────────

class _MascotCard extends StatelessWidget {
  final Mascot mascot;
  final bool isActive;
  final AppTheme theme;
  final MascotService service;
  final VoidCallback onTap;

  const _MascotCard({
    required this.mascot,
    required this.isActive,
    required this.theme,
    required this.service,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final locked = !mascot.unlock.isUnlocked(
      level: LevelService.instance.level,
      owned: false,
    );
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color: theme.cardSurface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isActive ? theme.primary : Colors.transparent,
            width: 2.5,
          ),
          boxShadow: [
            BoxShadow(
              color: isActive
                  ? theme.primary.withAlpha(40)
                  : Colors.black.withAlpha(12),
              blurRadius: isActive ? 10 : 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          children: [
            Expanded(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Opacity(
                      opacity: locked ? 0.35 : 1.0,
                      child: _MascotThumbnail(
                        mascot: mascot,
                        size: double.infinity,
                        service: service,
                      ),
                    ),
                  ),
                  if (locked)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withAlpha(140),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.lock_rounded,
                              color: Colors.white, size: 12),
                          const SizedBox(width: 3),
                          Text(
                            mascot.unlock.isPremium
                                ? '💎'
                                : (LocaleService.instance.isRussian
                                    ? 'Ур. ${mascot.unlock.requiredLevel}'
                                    : 'Lv ${mascot.unlock.requiredLevel}'),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (isActive)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Container(
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          color: theme.primary,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.check,
                          color: Colors.white,
                          size: 13,
                        ),
                      ),
                    ),
                  if (mascot.isDefault)
                    Positioned(
                      top: 6,
                      left: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.purple.withAlpha(200),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          LocaleService.current.fromUs,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 8,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Column(
                children: [
                  Text(
                    mascot.localizedName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (mascot.recordStreak > 0)
                    Text(
                      LocaleService.current.recordStreakBadge(mascot.recordStreak),
                      style: TextStyle(
                        fontSize: 10,
                        color: theme.textMuted,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Mascot thumbnail (shared helper) ─────────────────────────────────────────

class _MascotThumbnail extends StatelessWidget {
  final Mascot mascot;
  final double size;
  final MascotService service;

  const _MascotThumbnail({
    required this.mascot,
    required this.size,
    required this.service,
  });

  @override
  Widget build(BuildContext context) {
    // Resolve asset path considering mood state for default mascots
    final asset = service.resolvedAssetForMood(mascot);

    if (asset != null) {
      return buildMascotAssetImage(
        asset,
        width: size,
        height: size,
        fit: BoxFit.contain,
      );
    }
    if (mascot.catalogUrl != null) {
      return CachedNetworkImage(
        imageUrl: mascot.catalogUrl!,
        width: size == double.infinity ? null : size,
        height: size == double.infinity ? null : size,
        fit: BoxFit.contain,
        placeholder: (_, __) => const _PlaceholderBox(),
        errorWidget: (_, __, ___) => const _PlaceholderBox(),
      );
    }
    if (mascot.imageUrl != null) {
      return StorageImage(
        imageUrl: mascot.imageUrl!,
        width: size == double.infinity ? null : size,
        height: size == double.infinity ? null : size,
        fit: BoxFit.contain,
        placeholder: (_, __) => const _PlaceholderBox(),
        errorWidget: (_, __, ___) => const _PlaceholderBox(),
      );
    }
    return const _PlaceholderBox();
  }
}

class _PlaceholderBox extends StatelessWidget {
  const _PlaceholderBox();
  @override
  Widget build(BuildContext context) {
    final t = context.appTheme;
    return Container(
      decoration: BoxDecoration(
        color: t.surfaceMuted,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(Icons.face, color: t.textMuted),
    );
  }
}

// ── Action tile ───────────────────────────────────────────────────────────────

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;
  final VoidCallback onTap;

  const _ActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? context.appTheme.textPrimary;
    return ListTile(
      leading: Icon(icon, color: c, size: 22),
      title: Text(label, style: TextStyle(color: c, fontSize: 15)),
      dense: true,
      onTap: onTap,
    );
  }
}

// ── Tiny helper: fetch cached image file ─────────────────────────────────────

Future<File> fetchCachedImageFile(String url) async {
  final tmp = await getTemporaryDirectory();
  final fileName = url.hashCode.toString();
  final cached = File('${tmp.path}/$fileName.png');
  if (await cached.exists()) return cached;

  // sb://media/... (и gs://) — приватные пути: резолвим в подписанный https URL.
  final resolved = await PbMediaService().resolvePlayable(url);
  final client = HttpClient();
  final req = await client.getUrl(Uri.parse(resolved));
  final res = await req.close();
  final bytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
  await cached.writeAsBytes(bytes);
  client.close();
  return cached;
}
