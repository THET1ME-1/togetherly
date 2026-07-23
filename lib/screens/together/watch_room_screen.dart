import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:share_plus/share_plus.dart';

import '../../services/locale_service.dart';
import '../../services/watch_history_service.dart';
import '../../services/watch_room_service.dart';

/// Комната совместного просмотра.
///
/// Внутри крутится тот же движок, что на сайте: один канал Centrifugo, один
/// набор сообщений. Поэтому приложение и браузер попадают в одну комнату, а
/// починки источников приезжают сюда сами, без отдельной работы.
class WatchRoomScreen extends StatefulWidget {
  /// Код комнаты пары (выдаёт сервер по связи, вводить его не нужно).
  final String room;

  /// Ссылка на видео, если просмотр начали с карточки воспоминания.
  final String? videoUrl;

  /// Пара, чью историю просмотров пополняем.
  final String pairId;

  const WatchRoomScreen({
    super.key,
    required this.room,
    required this.pairId,
    this.videoUrl,
  });

  @override
  State<WatchRoomScreen> createState() => _WatchRoomScreenState();
}

class _WatchRoomScreenState extends State<WatchRoomScreen> {
  InAppWebViewController? _web;
  bool _loading = true;

  String get _url => WatchRoomService.siteUrl(widget.room);

  /// Подставляет ссылку в комнату и включает видео за человека — так переход
  /// «из ленты сразу к просмотру» не требует ручного копирования.
  Future<void> _applyVideo() async {
    final url = widget.videoUrl;
    if (url == null || url.isEmpty || _web == null) return;
    final safe = url.replaceAll("'", r"\'");
    await _web!.evaluateJavascript(source: """
      (function () {
        var link = document.querySelector('#link');
        var apply = document.querySelector('#apply');
        if (!link || !apply) return;
        link.value = '$safe';
        apply.click();
      })();
    """);
  }

  Future<void> _share() async {
    await Share.share(_url);
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _url));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(LocaleService.current.linkCopied),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = LocaleService.current;
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: Text(widget.room, style: const TextStyle(letterSpacing: 1.4)),
        centerTitle: true,
        actions: [
          IconButton(
            onPressed: _copy,
            icon: const Icon(Icons.copy_rounded),
            tooltip: s.copyLink,
          ),
          IconButton(
            onPressed: _share,
            icon: const Icon(Icons.ios_share_rounded),
            tooltip: s.copyLink,
          ),
        ],
      ),
      body: Stack(
        children: [
          InAppWebView(
            initialUrlRequest: URLRequest(url: WebUri(_url)),
            initialSettings: InAppWebViewSettings(
              // Видео должно запускаться командой партнёра, а не только пальцем.
              mediaPlaybackRequiresUserGesture: false,
              allowsInlineMediaPlayback: true,
              javaScriptEnabled: true,
              transparentBackground: true,
              supportZoom: false,
            ),
            onWebViewCreated: (c) {
              _web = c;
              // Комната сама сообщает, что включили: иначе приложение не знает,
              // что происходит внутри встроенного браузера.
              c.addJavaScriptHandler(
                handlerName: 'watchSource',
                callback: (args) {
                  final info = (args.isNotEmpty && args.first is Map)
                      ? Map<String, dynamic>.from(args.first as Map)
                      : const <String, dynamic>{};
                  unawaited(WatchHistoryService.remember(
                    groupId: widget.pairId,
                    url: (info['url'] ?? '').toString(),
                    kind: (info['kind'] ?? '').toString(),
                    title: (info['title'] ?? '').toString(),
                    thumb: (info['thumb'] ?? '').toString(),
                  ));
                  return null;
                },
              );
            },
            onLoadStop: (c, _) async {
              if (mounted) setState(() => _loading = false);
              await _applyVideo();
            },
          ),
          if (_loading)
            const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}
