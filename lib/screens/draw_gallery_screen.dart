import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/canvas_meta.dart';
import '../models/pair_data.dart';
import '../models/user_data.dart';
import '../services/canvas_storage_service.dart';
import '../services/locale_service.dart';
import '../theme/app_theme.dart';
import '../widgets/common/app_dialog.dart';
import '../widgets/common/m3_loading.dart';
import 'draw_screen.dart';

/// Gallery of saved drawings.  Shows a 2-column card grid with thumbnail
/// preview, canvas name and date.  A prominent "New Canvas" card is always
/// pinned at the top-left.
class DrawGalleryScreen extends StatefulWidget {
  final UserData userData;
  final PairData pairData;
  final AppTheme theme;

  const DrawGalleryScreen({
    super.key,
    required this.userData,
    required this.pairData,
    required this.theme,
  });

  @override
  State<DrawGalleryScreen> createState() => _DrawGalleryScreenState();
}

class _DrawGalleryScreenState extends State<DrawGalleryScreen> {
  final CanvasStorageService _storage = CanvasStorageService.instance;
  List<CanvasMeta> _canvases = [];
  bool _loading = true;

  String get _uid => widget.userData.uid;
  String get _groupId => widget.pairData.pairId;
  bool get _isPaired => _groupId.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _load();

    // Start real-time sync for paired users
    if (_isPaired) {
      _storage.onRemoteChange = _onRemoteChange;
      _storage.startListening(uid: _uid, groupId: _groupId);
      // Push existing local canvases to Firebase (idempotent)
      _storage.pushAllToFirebase(_uid, _groupId);
    }
  }

  @override
  void dispose() {
    _storage.onRemoteChange = null;
    _storage.stopListening();
    super.dispose();
  }

  void _onRemoteChange() {
    if (mounted) _load();
  }

  Future<void> _load() async {
    final list = await _storage.getCanvases(_uid, groupId: _groupId);
    if (mounted) {
      setState(() {
        _canvases = list;
        _loading = false;
      });
    }
  }

  // ── Actions ─────────────────────────────────────────────────────────────

  Future<void> _openCanvas(CanvasMeta meta) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DrawScreen(
          userData: widget.userData,
          pairData: widget.pairData,
          theme: widget.theme,
          canvasId: meta.id,
          canvasName: meta.name,
        ),
        fullscreenDialog: true,
        settings: const RouteSettings(name: '/draw'),
      ),
    );
    // Reload after returning so thumbnails are refreshed.
    _load();
  }

  Future<void> _createNewCanvas() async {
    final s = LocaleService.current;
    // Prompt for a name.
    final name = await _showNameDialog(
      title: s.newCanvas,
      initial: '${s.untitledCanvas} ${_canvases.length + 1}',
    );
    if (name == null || !mounted) return;

    final meta = await _storage.createCanvas(
      _uid,
      name: name.trim().isEmpty
          ? '${s.untitledCanvas} ${_canvases.length + 1}'
          : name.trim(),
      groupId: _groupId,
    );

    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DrawScreen(
          userData: widget.userData,
          pairData: widget.pairData,
          theme: widget.theme,
          canvasId: meta.id,
          canvasName: meta.name,
        ),
        fullscreenDialog: true,
        settings: const RouteSettings(name: '/draw'),
      ),
    );
    _load();
  }

  Future<void> _renameCanvas(CanvasMeta meta) async {
    final s = LocaleService.current;
    final name = await _showNameDialog(
      title: s.renameCanvas,
      initial: meta.name,
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    await _storage.renameCanvas(_uid, meta.id, name.trim(), groupId: _groupId);
    _load();
  }

  Future<void> _deleteCanvas(CanvasMeta meta) async {
    final s = LocaleService.current;
    final confirmed = await AppDialog.confirm(
      context,
      title: s.deleteCanvas,
      message: s.deleteCanvasConfirm,
      confirmLabel: s.delete,
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await _storage.deleteCanvas(_uid, meta.id, groupId: _groupId);
    _load();
  }

  Future<String?> _showNameDialog({
    required String title,
    required String initial,
  }) async {
    final s = LocaleService.current;
    final controller = TextEditingController(text: initial);
    controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: initial.length,
    );

    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: s.canvasNameLabel,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(s.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: Text(s.done),
          ),
        ],
      ),
    );
  }

  void _showContextMenu(BuildContext ctx, CanvasMeta meta) {
    final s = LocaleService.current;
    showModalBottomSheet(
      context: ctx,
      backgroundColor: widget.theme.cardSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: widget.theme.divider,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline_rounded),
              title: Text(s.renameCanvas),
              onTap: () {
                Navigator.pop(ctx);
                _renameCanvas(meta);
              },
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline_rounded,
                color: Colors.red.shade400,
              ),
              title: Text(
                s.deleteCanvas,
                style: TextStyle(color: Colors.red.shade400),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _deleteCanvas(meta);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final s = LocaleService.current;
    final t = widget.theme;

    return Scaffold(
      backgroundColor: t.surfaceMuted,
      appBar: AppBar(
        backgroundColor: t.cardSurface,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          s.myDrawings,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton.icon(
              onPressed: _createNewCanvas,
              icon: Icon(Icons.add_rounded, color: t.primary, size: 20),
              label: Text(
                s.newCanvas,
                style: TextStyle(color: t.primary, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
      body: _loading
          ? Center(child: M3LoadingDots(color: t.primaryLight))
          : _canvases.isEmpty
          ? _buildEmpty(s, t)
          : _buildGrid(s, t),
    );
  }

  Widget _buildEmpty(AppStrings s, AppTheme t) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: t.primaryLight,
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.brush_rounded, size: 36, color: t.primary),
          ),
          const SizedBox(height: 20),
          Text(
            s.noDrawingsYet,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: t.textSecondary,
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _createNewCanvas,
            icon: const Icon(Icons.add_rounded),
            label: Text(s.newCanvas),
            style: FilledButton.styleFrom(
              backgroundColor: t.primary,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGrid(AppStrings s, AppTheme t) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: GridView.builder(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 0.82,
        ),
        itemCount: _canvases.length,
        itemBuilder: (ctx, i) => _buildCard(ctx, _canvases[i], t),
      ),
    );
  }

  Widget _buildCard(BuildContext ctx, CanvasMeta meta, AppTheme t) {
    return GestureDetector(
      onTap: () => _openCanvas(meta),
      onLongPress: () => _showContextMenu(ctx, meta),
      child: Container(
        decoration: BoxDecoration(
          color: t.cardSurface,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Thumbnail ──────────────────────────────────
            Expanded(
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(18),
                ),
                child: _buildThumbnail(meta, t),
              ),
            ),
            // ── Info strip ─────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    meta.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _formatDate(meta.updatedAt),
                    style: TextStyle(fontSize: 11, color: t.textMuted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildThumbnail(CanvasMeta meta, AppTheme t) {
    if (meta.previewBase64 != null) {
      try {
        final bytes = base64Decode(meta.previewBase64!);
        return Image.memory(
          Uint8List.fromList(bytes),
          fit: BoxFit.cover,
          width: double.infinity,
        );
      } catch (_) {}
    }
    // Placeholder when no preview exists yet.
    return Container(
      width: double.infinity,
      color: t.surfaceMuted,
      child: Center(
        child: Icon(
          Icons.brush_rounded,
          size: 36,
          color: t.primary.withValues(alpha: 0.35),
        ),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) {
      // Today – show time
      final h = dt.hour.toString().padLeft(2, '0');
      final m = dt.minute.toString().padLeft(2, '0');
      return '$h:$m';
    }
    if (diff.inDays == 1) return LocaleService.current.yesterday;
    if (diff.inDays < 7) {
      final weekdays = LocaleService.current.shortWeekdays;
      return weekdays[dt.weekday - 1];
    }
    final months = LocaleService.current.shortMonths;
    return '${dt.day} ${months[dt.month - 1]}';
  }
}
