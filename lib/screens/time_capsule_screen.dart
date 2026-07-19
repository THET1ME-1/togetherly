import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/memory.dart';
import '../services/capsule_notification_service.dart';
import '../services/locale_service.dart';
import '../services/media_service.dart';
import '../services/memory_repository.dart';
import '../theme/app_theme.dart';
import '../utils/photo_crop.dart';

/// Композер «Капсулы времени»: письмо и/или фото, запечатанные до выбранной даты.
/// Создаёт обычное воспоминание с флагами `sealed`+`openAt` (лента прячет его до
/// даты, затем раскрывает) и планирует локальное уведомление на день открытия.
class TimeCapsuleScreen extends StatefulWidget {
  final AppTheme theme;
  final String pairId;
  final String authorName;
  final String authorAvatar;

  const TimeCapsuleScreen({
    super.key,
    required this.theme,
    required this.pairId,
    required this.authorName,
    required this.authorAvatar,
  });

  @override
  State<TimeCapsuleScreen> createState() => _TimeCapsuleScreenState();
}

class _TimeCapsuleScreenState extends State<TimeCapsuleScreen> {
  final _titleCtrl = TextEditingController();
  final _msgCtrl = TextEditingController();
  String? _photoPath;
  late DateTime _openAt;
  bool _saving = false;

  AppTheme get _t => widget.theme;

  @override
  void initState() {
    super.initState();
    // По умолчанию — через полгода.
    final now = DateTime.now();
    _openAt = DateTime(now.year, now.month + 6, now.day, 9);
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _msgCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = LocaleService.current;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        elevation: 0,
        iconTheme: IconThemeData(color: _t.textPrimary),
        title: Text(
          s.timeCapsule,
          style:
              TextStyle(color: _t.textPrimary, fontWeight: FontWeight.w800),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
          children: [
            _hero(s),
            const SizedBox(height: 24),
            _field(_titleCtrl, s.titleHint, maxLength: 60),
            const SizedBox(height: 12),
            _field(_msgCtrl, s.capsuleLetterHint, maxLines: 6, maxLength: 800),
            const SizedBox(height: 16),
            _photoRow(s),
            const SizedBox(height: 16),
            _openDateCard(s),
            const SizedBox(height: 24),
            _sealButton(s),
          ],
        ),
      ),
    );
  }

  Widget _hero(AppStrings s) {
    return Column(
      children: [
        Container(
          width: 96,
          height: 96,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [_t.primary, _t.primaryLight],
            ),
            boxShadow: [
              BoxShadow(
                color: _t.primary.withValues(alpha: 0.35),
                blurRadius: 22,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          alignment: Alignment.center,
          child: const Text('💌', style: TextStyle(fontSize: 46)),
        ),
        const SizedBox(height: 14),
        Text(
          s.capsuleIntro,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            height: 1.35,
            color: _t.textSecondary,
          ),
        ),
      ],
    );
  }

  Widget _field(TextEditingController c, String hint,
      {int maxLines = 1, int? maxLength}) {
    return TextField(
      controller: c,
      maxLines: maxLines,
      maxLength: maxLength,
      textCapitalization: TextCapitalization.sentences,
      style: TextStyle(color: _t.textPrimary),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: _t.textMuted),
        filled: true,
        fillColor: _t.surfaceMuted,
        counterText: '',
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
    );
  }

  Widget _photoRow(AppStrings s) {
    if (_photoPath != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          children: [
            Image.file(
              File(_photoPath!),
              width: double.infinity,
              height: 180,
              fit: BoxFit.cover,
            ),
            Positioned(
              top: 8,
              right: 8,
              child: GestureDetector(
                onTap: () => setState(() => _photoPath = null),
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: const BoxDecoration(
                    color: Colors.black54,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.close_rounded,
                      color: Colors.white, size: 18),
                ),
              ),
            ),
          ],
        ),
      );
    }
    return GestureDetector(
      onTap: _pickPhoto,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 18),
        decoration: BoxDecoration(
          color: _t.surfaceMuted,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _t.divider),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add_photo_alternate_rounded, color: _t.primary),
            const SizedBox(width: 8),
            Text(
              s.capsuleAttachPhoto,
              style: TextStyle(
                color: _t.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _openDateCard(AppStrings s) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _t.cardSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _t.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.lock_clock_rounded, color: _t.primary, size: 20),
              const SizedBox(width: 8),
              Text(
                s.capsuleOpenDate,
                style: TextStyle(
                  color: _t.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: _pickDate,
                child: Text(s.change),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            _fmtDate(_openAt),
            style: TextStyle(
              color: _t.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w800,
            ),
          ),
          Text(
            s.capsuleOpensIn(_daysUntil()),
            style: TextStyle(color: _t.textMuted, fontSize: 12.5),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              _preset(s.capsulePreset1m, _addMonths(1)),
              _preset(s.capsulePreset6m, _addMonths(6)),
              _preset(s.capsulePreset1y, _addMonths(12)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _preset(String label, DateTime date) {
    final selected = _sameDay(date, _openAt);
    return GestureDetector(
      onTap: () => setState(() => _openAt = date),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? _t.primary.withValues(alpha: 0.12)
              : _t.surfaceMuted,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? _t.primary : _t.divider,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? _t.primary : _t.textSecondary,
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
        ),
      ),
    );
  }

  Widget _sealButton(AppStrings s) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: _saving ? null : _seal,
        icon: _saving
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white),
              )
            : const Icon(Icons.lock_rounded, size: 18),
        label: Text(
          s.capsuleSeal,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: _t.primary,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 15),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    );
  }

  // ── Actions ────────────────────────────────────────────────────────────────
  Future<void> _pickPhoto() async {
    final picker = ImagePicker();
    final XFile? x = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 88,
      maxWidth: 1920,
      maxHeight: 1920,
    );
    if (x == null) return;
    final cropped = await cropPhoto(x.path, accentColor: _t.primary);
    if (!mounted) return;
    setState(() => _photoPath = cropped ?? x.path);
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _openAt.isAfter(now) ? _openAt : now.add(const Duration(days: 1)),
      firstDate: now.add(const Duration(days: 1)),
      lastDate: DateTime(now.year + 10, now.month, now.day),
    );
    if (picked == null || !mounted) return;
    setState(() => _openAt = DateTime(picked.year, picked.month, picked.day, 9));
  }

  Future<void> _seal() async {
    final msg = _msgCtrl.text.trim();
    if (msg.isEmpty && _photoPath == null) {
      _snack(LocaleService.current.capsuleNeedsContent, error: true);
      return;
    }
    if (!_openAt.isAfter(DateTime.now())) {
      _snack(LocaleService.current.capsuleNeedsFutureDate, error: true);
      return;
    }
    setState(() => _saving = true);
    try {
      String? imageUrl;
      var type = MemoryType.text;
      if (_photoPath != null) {
        final ts = DateTime.now().millisecondsSinceEpoch;
        final ext = _photoPath!.split('.').last;
        imageUrl = await MediaService()
            .uploadFile(_photoPath!, 'memories/${widget.pairId}/capsule_$ts.$ext');
        if (imageUrl == null) {
          if (mounted) {
            setState(() => _saving = false);
            _snack(LocaleService.current.failedUploadPhoto, error: true);
          }
          return;
        }
        type = MemoryType.photo;
      }
      final title = _titleCtrl.text.trim();
      final created = await MemoryRepository().add(
        groupId: widget.pairId,
        authorName: widget.authorName,
        authorAvatar: widget.authorAvatar,
        type: type,
        imageUrl: imageUrl,
        title: title.isEmpty ? null : title,
        caption: msg.isEmpty ? null : msg,
        sealed: true,
        openAt: _openAt,
      );
      // Уведомление планируем в фоне — не держим закрытие экрана на платформенном
      // вызове (мог зависнуть на запросе разрешения → композер «крутился»).
      if (created != null) {
        unawaited(CapsuleNotificationService.instance
            .schedule(created.id, _openAt, capsuleTitle: title));
      }
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        _snack('Error: $e', error: true);
      }
    }
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      behavior: SnackBarBehavior.floating,
      backgroundColor: error ? Colors.orange : _t.primary,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ));
  }

  // ── Helpers ──────────────────────────────────────────────────────────────
  DateTime _addMonths(int m) {
    final now = DateTime.now();
    return DateTime(now.year, now.month + m, now.day, 9);
  }

  int _daysUntil() => _openAt.difference(DateTime.now()).inDays;

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
}
