import 'package:flutter/material.dart';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:url_launcher/url_launcher.dart';

import '../../models/pair_data.dart';
import '../../services/locale_service.dart';
import '../../services/watch_history_service.dart';
import '../../services/watch_room_service.dart';
import '../../services/watch_videos_service.dart';
import 'together_launcher.dart';
import 'watch_player_screen.dart';
import '../../theme/app_theme.dart';

/// Вход в совместный просмотр.
///
/// Пара уже связана, поэтому код вводить не нужно: комната открывается сама.
/// Код показан тихой строкой — он нужен лишь тому, кто зовёт партнёра в браузер
/// (приложение и сайт держат одну и ту же комнату).
class WatchHomeScreen extends StatefulWidget {
  final PairData pairData;
  final AppTheme theme;

  const WatchHomeScreen({
    super.key,
    required this.pairData,
    required this.theme,
  });

  @override
  State<WatchHomeScreen> createState() => _WatchHomeScreenState();
}

class _WatchHomeScreenState extends State<WatchHomeScreen> {
  String _room = '';
  bool _loading = true;
  List<WatchEntry> _recent = const [];
  List<WatchVideo> _videos = const [];
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _loadRoom();
    _loadRecent();
    _loadVideos();
  }

  Future<void> _loadVideos() async {
    final items = await WatchVideosService.list(widget.pairData.pairId);
    if (!mounted) return;
    setState(() => _videos = items);
  }

  /// Загрузка своего ролика: он ложится к нам, поэтому играет у обоих по
  /// обычной ссылке и синхронизируется секунда в секунду.
  Future<void> _uploadVideo() async {
    final s = LocaleService.current;
    final messenger = ScaffoldMessenger.of(context);

    final picked = await FilePicker.platform.pickFiles(type: FileType.video);
    final path = picked?.files.single.path;
    if (path == null) return;

    final file = File(path);
    if (await file.length() > WatchVideosService.maxBytes) {
      messenger.showSnackBar(SnackBar(
        content: Text(s.watchVideoTooBig),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }

    setState(() => _uploading = true);
    final saved = await WatchVideosService.upload(
      groupId: widget.pairData.pairId,
      file: file,
      title: picked!.files.single.name,
    );
    if (!mounted) return;
    setState(() => _uploading = false);

    if (saved == null) {
      messenger.showSnackBar(SnackBar(
        content: Text(s.error),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }
    await _loadVideos();
  }

  Future<void> _loadRecent() async {
    final items = await WatchHistoryService.recent(widget.pairData.pairId);
    if (!mounted) return;
    setState(() => _recent = items);
  }

  Future<void> _loadRoom() async {
    final room = await WatchRoomService.roomCode(widget.pairData.pairId);
    if (!mounted) return;
    setState(() {
      _room = room;
      _loading = false;
    });
  }

  Future<void> _openOnSite() async {
    if (_room.isEmpty) return;
    await launchUrl(
      Uri.parse(WatchRoomService.siteUrl(_room)),
      mode: LaunchMode.externalApplication,
    );
  }

  Future<void> _copyCode() async {
    if (_room.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: WatchRoomService.siteUrl(_room)));
    if (!mounted) return;
    final s = LocaleService.current;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(s.linkCopied), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = LocaleService.current;
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final partner = widget.pairData.partnerName;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
      children: [
        _Hero(cs: cs, text: text),
        const SizedBox(height: 14),
        _PrimaryCard(
          title: partner.isEmpty
              ? s.watchTogether
              : s.watchWithPartner(partner),
          subtitle: s.watchRoomOpensForBoth,
          note: s.watchAfterShortAd,
          enabled: !_loading && _room.isNotEmpty,
          onTap: _openInApp,
        ),
        const SizedBox(height: 12),
        _TonalCard(
          icon: Icons.open_in_new_rounded,
          title: s.watchOpenOnSite,
          subtitle: s.watchOnSiteHint,
          onTap: _room.isEmpty ? null : _openOnSite,
        ),
        const SizedBox(height: 12),
        _CodeRow(
          code: _room,
          loading: _loading,
          onCopy: _copyCode,
        ),
        const SizedBox(height: 20),
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 10),
          child: Text(
            s.watchOurVideos,
            style: text.labelMedium?.copyWith(
              color: cs.onSurfaceVariant,
              letterSpacing: 1.1,
            ),
          ),
        ),
        SizedBox(
          height: 132,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _videos.length + 1,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (_, i) {
              if (i == _videos.length) {
                return _UploadCard(busy: _uploading, onTap: _uploadVideo);
              }
              final v = _videos[i];
              return _RecentCard(
                entry: WatchEntry(
                  id: v.id,
                  url: v.url,
                  kind: 'memory',
                  title: v.title,
                  thumb: '',
                  seconds: v.seconds,
                ),
                onTap: () => _openNative(v),
              );
            },
          ),
        ),
        if (_recent.isNotEmpty) ...[
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 10),
            child: Text(
              s.watchRecent,
              style: text.labelMedium?.copyWith(
                color: cs.onSurfaceVariant,
                letterSpacing: 1.1,
              ),
            ),
          ),
          SizedBox(
            height: 132,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _recent.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (_, i) => _RecentCard(
                entry: _recent[i],
                onTap: () => _openAgain(_recent[i]),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _openInApp() async {
    if (_room.isEmpty) return;
    await TogetherLauncher.open(context, pairId: widget.pairData.pairId);
    await _loadRecent();
  }

  /// Своё видео играем нативно: кадр рисует само приложение, поэтому пауза и
  /// перемотка мгновенные. Чужие площадки остаются в комнате-браузере.
  Future<void> _openNative(WatchVideo video) async {
    if (_room.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => WatchPlayerScreen(
          room: _room,
          pairId: widget.pairData.pairId,
          url: video.url,
          title: video.title,
        ),
      ),
    );
    await _loadRecent();
  }

  /// Повторный просмотр: включаем ролик сразу, без поиска ссылки.
  Future<void> _openAgain(WatchEntry entry) async {
    if (_room.isEmpty) return;
    if (entry.url.startsWith('file://')) {
      // Свой файл лежит на устройстве, ссылкой его не открыть.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(LocaleService.current.watchPickFileAgain),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    await TogetherLauncher.open(
      context,
      pairId: widget.pairData.pairId,
      videoUrl: entry.url,
    );
    await _loadRecent();
  }
}

class _Hero extends StatelessWidget {
  final ColorScheme cs;
  final TextTheme text;

  const _Hero({required this.cs, required this.text});

  @override
  Widget build(BuildContext context) {
    final s = LocaleService.current;
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 22, 22, 24),
      decoration: BoxDecoration(
        color: cs.primaryContainer,
        borderRadius: BorderRadius.circular(28),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            right: -18,
            bottom: -34,
            child: Text(
              '♥',
              style: TextStyle(
                fontSize: 116,
                height: 1,
                color: cs.onPrimaryContainer.withValues(alpha: 0.14),
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                s.watchHeroTitle,
                style: text.headlineSmall?.copyWith(
                  color: cs.onPrimaryContainer,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: 240,
                child: Text(
                  s.watchHeroText,
                  style: text.bodyMedium?.copyWith(
                    color: cs.onPrimaryContainer.withValues(alpha: 0.86),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PrimaryCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final String note;
  final bool enabled;
  final VoidCallback onTap;

  const _PrimaryCard({
    required this.title,
    required this.subtitle,
    required this.note,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(28),
          child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: cs.primary,
            borderRadius: BorderRadius.circular(28),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: cs.onPrimary.withValues(alpha: 0.22),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.play_arrow_rounded, color: cs.onPrimary, size: 30),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: text.titleMedium?.copyWith(color: cs.onPrimary),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: text.bodySmall?.copyWith(
                        color: cs.onPrimary.withValues(alpha: 0.86),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
                      decoration: BoxDecoration(
                        color: cs.onPrimary.withValues(alpha: 0.22),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        note,
                        style: text.labelSmall?.copyWith(color: cs.onPrimary),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          ),
        ),
      ),
    );
  }
}

class _TonalCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  const _TonalCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(28),
        child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(28),
        ),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: cs.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: cs.onPrimaryContainer, size: 26),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, style: text.titleMedium),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}

class _CodeRow extends StatelessWidget {
  final String code;
  final bool loading;
  final VoidCallback onCopy;

  const _CodeRow({
    required this.code,
    required this.loading,
    required this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    final s = LocaleService.current;
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  s.watchPartnerInBrowser,
                  style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 2),
                Text(
                  loading ? '…' : (code.isEmpty ? '—' : code),
                  style: text.titleLarge?.copyWith(letterSpacing: 1.2),
                ),
              ],
            ),
          ),
          IconButton.filledTonal(
            onPressed: code.isEmpty ? null : onCopy,
            icon: const Icon(Icons.copy_rounded, size: 20),
            tooltip: s.copyLink,
          ),
        ],
      ),
    );
  }
}

/// Карточка недавнего просмотра: обложка, если площадка её отдала, и название.
class _RecentCard extends StatelessWidget {
  final WatchEntry entry;
  final VoidCallback onTap;

  const _RecentCard({required this.entry, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return SizedBox(
      width: 150,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: SizedBox(
                  height: 86,
                  width: 150,
                  child: entry.thumb.isEmpty
                      ? Container(
                          color: cs.surfaceContainerHighest,
                          child: Icon(
                            Icons.play_arrow_rounded,
                            color: cs.onSurfaceVariant,
                            size: 30,
                          ),
                        )
                      : Image.network(
                          entry.thumb,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Container(
                            color: cs.surfaceContainerHighest,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 7),
              Text(
                entry.label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: text.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Кнопка «загрузить своё видео» в конце ленты.
class _UploadCard extends StatelessWidget {
  final bool busy;
  final VoidCallback onTap;

  const _UploadCard({required this.busy, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final s = LocaleService.current;
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return SizedBox(
      width: 150,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: busy ? null : onTap,
          borderRadius: BorderRadius.circular(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                height: 86,
                width: 150,
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: cs.outlineVariant),
                ),
                child: busy
                    ? const Center(
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2.5),
                        ),
                      )
                    : Icon(Icons.add_rounded, color: cs.onSurfaceVariant, size: 30),
              ),
              const SizedBox(height: 7),
              Text(
                busy ? s.watchVideoUploading : s.watchVideoAdd,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
