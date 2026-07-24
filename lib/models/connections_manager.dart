import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/analytics_service.dart';
import '../services/pb_data_service.dart';
import '../services/pb_realtime_service.dart';
import '../services/pocketbase_service.dart';
import '../services/offline/offline_reset.dart';
import 'connection.dart';

/// Manages multiple connections/groups
///
/// Перенесён с Firebase на PocketBase: личность — из PB-сессии, обнаружение пар
/// — через живой список «моих групп» (`PbRealtimeService.watchMyGroups`,
/// фильтр `members ~ uid`), данные/запись — через `PbDataService`. Инвайт-коды
/// пока локальные (генерация/приём кода на PB — Фаза 2).
class ConnectionsManager extends ChangeNotifier {
  final List<Connection> _connections = [];
  int _activeConnectionIndex = 0;
  String _preferredPartnerUid = '';
  bool _loading = false;
  StreamSubscription? _groupsSub;
  // Prevents concurrent _startListeningForNewPairs callbacks from racing
  bool _processingPairUpdate = false;

  /// Последнее сообщение сервера/сессии при приёме кода — экран показывает его
  /// вместо generic «код не найден», чтобы реальная причина (истёкшая сессия,
  /// свой код, группа полна) была видна.
  String? lastAcceptMessage;
  // Last known pairing fingerprint — skip callback if the set of groups is same.
  // null = ещё не обрабатывали (первый emit пройдёт даже при пустом списке).
  String? _lastPairKey;

  // ── Идентичность (PocketBase) ──
  String get _uid => PocketBaseService().userId ?? '';
  bool get _loggedIn => PocketBaseService().isLoggedIn;

  // ── Getters ──
  List<Connection> get connections => List.unmodifiable(_connections);
  int get activeConnectionIndex => _activeConnectionIndex;
  Connection? get activeConnection {
    if (_connections.isEmpty) return null;
    if (_activeConnectionIndex >= _connections.length) return null;
    return _connections[_activeConnectionIndex];
  }

  bool get loading => _loading;
  String get preferredPartnerUid => _preferredPartnerUid;

  Future<void> setPreferredPartnerUid(String uid) async {
    _preferredPartnerUid = uid;
    await _saveLocal();
    notifyListeners();
  }

  bool get hasMultipleConnections => _connections.length > 1;

  // ── Initialization ──
  Future<void> init({required String myName}) async {
    _loading = true;
    notifyListeners();

    await _loadLocal();

    // Ensure solo connection exists at index 0 (can't be deleted)
    _ensureSoloConnection();

    // If no connections exist (besides solo), create a default one
    if (_connections.length <= 1) {
      await _createNewConnection();
    }

    // Снимок: в теле есть await'ы (refreshPairStatus), во время которых
    // _connections может перестроиться.
    for (var connection in _connections.toList()) {
      if (_loggedIn &&
          connection.inviteCode.isEmpty &&
          !connection.isSolo) {
        await _ensureServerCode(connection);
      }

      // Only refresh pair status for connections that already have a pairId.
      if (_loggedIn && connection.pairId.isNotEmpty) {
        await connection.refreshPairStatus();
      }
    }

    // Remove stale connections: paired groups that have no partners left.
    await _cleanupStaleConnections();

    await _saveLocal();
    _loading = false;
    notifyListeners();

    // Start listening for real-time pair changes (membership discovery).
    _startListeningForNewPairs();
  }

  // ══════════════════════════════════════════════
  //  ACCEPT CODE — universal entry point
  // ══════════════════════════════════════════════

  /// Accept an invite code and create / join a group (PocketBase).
  /// Works regardless of whether the active connection is already paired.
  /// Returns true on success.
  Future<bool> acceptCodeAndCreateGroup(String code) async {
    code = code.toUpperCase().trim();
    debugPrint('acceptCodeAndCreateGroup: code=$code');

    // Check self-codes across ALL connections
    for (var c in _connections) {
      if (c.isSelfCode(code)) {
        debugPrint('acceptCodeAndCreateGroup: self code, ignoring');
        return false;
      }
    }

    final result = await PbDataService().acceptInviteCode(code, myUid: _uid);
    debugPrint(
      'acceptCodeAndCreateGroup: result=${result['success']}, msg=${result['message']}',
    );
    lastAcceptMessage = result['message'] as String?;
    if (result['success'] != true) return false;

    final pairId = result['pairId'] as String? ?? '';
    if (pairId.isEmpty) return false;

    // Already have this group? (discovery listener might have picked it up)
    final existingConn = _connections.cast<Connection?>().firstWhere(
      (c) => c!.pairId == pairId,
      orElse: () => null,
    );
    if (existingConn != null) {
      _activeConnectionIndex = _connections.indexOf(existingConn);
      await _saveLocal();
      notifyListeners();
      return true;
    }

    // Find first unpaired non-solo connection to reuse, or create new one.
    Connection? target = _connections.cast<Connection?>().firstWhere(
      (c) => !c!.isSolo && !c.isPaired && c.pairId.isEmpty,
      orElse: () => null,
    );
    if (target == null) {
      target = Connection(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        onChanged: _onConnectionChanged,
      );
      _connections.add(target);
    }

    final oldInviteCode = target.inviteCode;

    // Apply data from result
    target.isPaired = true;
    target.pairId = pairId;
    target.partnerName = result['partnerName'] ?? '';
    target.partnerAvatarUrl = result['partnerAvatar'] ?? '';
    target.startDate = result['startDate'] as DateTime? ?? DateTime.now();

    final rtStr = result['relationshipType'] as String?;
    if (rtStr != null) {
      target.relationshipType = RelationshipType.values.firstWhere(
        (e) => e.name == rtStr,
        orElse: () => RelationshipType.couple,
      );
    }
    target.customRelationshipLabel =
        result['customRelationshipLabel'] as String? ?? '';
    target.customRelationshipEmoji =
        result['customRelationshipEmoji'] as String? ?? '';
    final customTypes = result['customRelationshipTypes'] as List<dynamic>?;
    if (customTypes != null) {
      target.customRelationshipTypes = customTypes
          .map(
            (e) => Map<String, String>.from(
              (e as Map).map((k, v) => MapEntry(k.toString(), v.toString())),
            ),
          )
          .toList();
    }
    final membersList = result['members'] as List<dynamic>?;
    if (membersList != null) {
      target.members = membersList
          .map(
            (m) => GroupMember(
              uid: (m as Map)['uid']?.toString() ?? '',
              name: m['name']?.toString() ?? '',
              avatar: m['avatar']?.toString() ?? '',
            ),
          )
          .toList();
    }

    // Fresh group-tied invite code (replaces the used one).
    final newCode = await PbDataService().generateInviteCode(
      ownerUid: _uid,
      groupId: pairId,
      oldCode: oldInviteCode.isNotEmpty ? oldInviteCode : null,
    );
    // Пусто при провале сервера — НЕ раздаём локальный код, которого нет в
    // invite_codes (иначе третий участник получил бы «код не найден»). UI даст
    // перевыпустить; серверный create само-лечит протухший токен.
    target.inviteCode = newCode;

    _activeConnectionIndex = _connections.indexOf(target);
    target.startListening();

    await _saveLocal();
    notifyListeners();
    debugPrint('acceptCodeAndCreateGroup: SUCCESS, paired=$pairId');
    unawaited(AnalyticsService.instance.logPairConnected(groupId: pairId));
    return true;
  }

  /// Check if code is self-code for any connection
  bool isSelfCodeAny(String code) {
    for (var c in _connections) {
      if (c.isSelfCode(code)) return true;
    }
    return false;
  }

  /// Remove connections that are paired but have no partners (orphaned groups).
  /// This handles stale groups created during debug testing sessions where the
  /// group only has the current user as a member.
  Future<void> _cleanupStaleConnections() async {
    final toRemove = <Connection>[];

    // 1) Orphaned groups — paired but no partners left.
    // Снимок: внутри await (leaveGroup), во время которого _connections может
    // перестроиться → иначе «Concurrent modification».
    for (final conn in _connections.toList()) {
      if (conn.isSolo) continue;
      if (!conn.isPaired || conn.pairId.isEmpty) continue;
      if (conn.partners.isNotEmpty) continue;

      debugPrint(
        '_cleanupStaleConnections: removing orphaned group ${conn.pairId}',
      );
      await PbDataService().leaveGroup(conn.pairId, _uid);
      toRemove.add(conn);
    }

    // 2) Duplicate groups — same partner set in another connection. Серверный
    //    детерминированный мердж (mergeDuplicateGroups) — Фаза 2. Пока просто
    //    НЕ показываем второй коннект на тех же партнёров (и не трогаем данные
    //    на сервере): оставляем первый, второй убираем из локального списка.
    final firstConnByPartnerKey = <String, Connection>{};
    for (final conn in List<Connection>.from(_connections)) {
      if (conn.isSolo || toRemove.contains(conn)) continue;
      if (!conn.isPaired || conn.partners.isEmpty) continue;

      final partnerUids = conn.partners.map((p) => p.uid).toList()..sort();
      final partnerKey = partnerUids.join(',');

      final first = firstConnByPartnerKey[partnerKey];
      if (first == null) {
        firstConnByPartnerKey[partnerKey] = conn;
        continue;
      }

      debugPrint(
        '_cleanupStaleConnections: duplicate pair groups '
        '${first.pairId} / ${conn.pairId} — hiding duplicate (merge = Phase 2)',
      );
      // Не диспозим листенер группы у дубликата деструктивно на сервере —
      // только убираем локальную карточку, чтобы не двоилось в UI.
      conn.dispose();
      toRemove.add(conn);
    }

    // 3) Пустые «ожидающие партнёра» дубли — непарные non-solo без pairId.
    //    Ровно один такой нужен (показать инвайт-код и QR), остальные — мусор
    //    от повторных тапов «создать подключение» (баг «создало 5 подключений»).
    //    Оставляем первый, лишние убираем из локального списка.
    Connection? firstEmpty;
    for (final conn in List<Connection>.from(_connections)) {
      if (conn.isSolo || toRemove.contains(conn)) continue;
      if (conn.isPaired || conn.pairId.isNotEmpty) continue;
      if (firstEmpty == null) {
        firstEmpty = conn;
        continue;
      }
      debugPrint(
        '_cleanupStaleConnections: collapsing empty unpaired duplicate',
      );
      conn.dispose();
      toRemove.add(conn);
    }

    for (final conn in toRemove) {
      conn.dispose();
      _connections.remove(conn);
    }

    // Если активным осталось пустое/непарное подключение, а спаренное есть —
    // переключаемся на него (иначе «дни вместе 0» и пустой парный виджет).
    _preferPairedActive();

    if (toRemove.isNotEmpty) {
      // Ensure at least one non-solo connection exists
      if (_connections.where((c) => !c.isSolo).isEmpty) {
        await _createNewConnection();
      }
      // Keep active index in bounds
      if (_activeConnectionIndex >= _connections.length) {
        _activeConnectionIndex =
            _connections.length > 1 ? 1 : _connections.length - 1;
      }
      await _saveLocal();
      notifyListeners();
    }
  }

  /// Если активное подключение пустое/непарное (solo или «ожидает партнёра»),
  /// а спаренное существует — делаем активным первое спаренное. Чинит симптом
  /// «дни вместе 0 / парный виджет пустой», когда пара уже есть на сервере, но
  /// активный индекс указывает на пустышку (после багов с дублями/пассивным
  /// приёмом инвайта).
  void _preferPairedActive() {
    final act = activeConnection;
    final actIsEmpty =
        act == null || act.isSolo || (!act.isPaired && act.pairId.isEmpty);
    if (!actIsEmpty) return;
    final pairedIdx = _connections.indexWhere(
      (c) => !c.isSolo && c.isPaired && c.partners.isNotEmpty,
    );
    if (pairedIdx >= 0) {
      _activeConnectionIndex = pairedIdx;
    }
  }

  /// Живой список моих групп в PocketBase. Когда партнёр принимает инвайт и
  /// добавляет меня в группу — она приезжает сюда; когда выходит/распускает —
  /// исчезает. Заменяет Firestore user-doc листенер (pairIds).
  void _startListeningForNewPairs() {
    _groupsSub?.cancel();
    if (!_loggedIn) return;

    _groupsSub = PbRealtimeService().watchMyGroups(_uid).listen((recs) async {
      // Skip if the SET of my groups didn't change (group-doc шлёт событие на
      // любое изменение поля — настроение, счётчик; нас интересует членство).
      final ids = recs.map((r) => r.id).toList()..sort();
      final pairKey = ids.join(',');
      if (pairKey == _lastPairKey) return;
      _lastPairKey = pairKey;

      // Prevent concurrent callbacks from racing.
      if (_processingPairUpdate) return;
      _processingPairUpdate = true;
      try {
        await _handlePairUpdate(recs);
      } finally {
        _processingPairUpdate = false;
      }
    }, onError: (e) => debugPrint('_startListeningForNewPairs error: $e'));
  }

  Future<void> _handlePairUpdate(List<RecordModel> recs) async {
    final recById = {for (final r in recs) r.id: r};
    final remotePairIds = recById.keys.toSet();

    // Ищем pairId, которые ещё не привязаны ни к одному connection
    final claimedIds = _connections
        .where((c) => c.pairId.isNotEmpty)
        .map((c) => c.pairId)
        .toSet();

    final myUid = _uid;
    for (var remotePairId in remotePairIds) {
      if (claimedIds.contains(remotePairId)) continue;

      // Pre-check: skip if all this group's partners are already in another
      // connection (duplicate group left by debug sessions). Не трогаем сервер.
      final rec = recById[remotePairId];
      final membersList =
          (rec?.data['members'] as List?)?.map((e) => e.toString()).toList() ??
              const <String>[];
      final newPartnerUids = membersList
          .where((uid) => uid.isNotEmpty && uid != myUid)
          .toSet();

      if (newPartnerUids.isNotEmpty) {
        final existingPartnerUids = _connections
            .where((c) => c.isPaired && c.partners.isNotEmpty)
            .expand((c) => c.partners.map((p) => p.uid))
            .toSet();

        if (newPartnerUids.every((uid) => existingPartnerUids.contains(uid))) {
          debugPrint(
            'Real-time: duplicate group $remotePairId — partners already in '
            'another connection, skipping',
          );
          continue;
        }
      }

      // Нашли новую пару — назначаем первому unpaired non-solo connection.
      bool wasNewlyCreated = false;
      Connection? unpaired = _connections.cast<Connection?>().firstWhere(
        (c) => !c!.isSolo && !c.isPaired && c.pairId.isEmpty,
        orElse: () => null,
      );

      if (unpaired == null) {
        unpaired = Connection(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          onChanged: _onConnectionChanged,
        );
        _connections.add(unpaired);
        wasNewlyCreated = true;
      }

      debugPrint('Real-time: detected new pair $remotePairId');
      await unpaired.claimPair(remotePairId);

      // Validate: a claimed group must have at least one partner besides us.
      if (!unpaired.isPaired || unpaired.partners.isEmpty) {
        debugPrint(
          'Real-time: stale/invalid group $remotePairId (no partners), '
          'cleaning up',
        );
        unpaired.markUnpaired();
        if (wasNewlyCreated) {
          _connections.remove(unpaired);
        }
        continue;
      }

      // Партнёр принял НАШ код — пара «приземлилась» на это подключение, но
      // активным мог оставаться пустой дубль → на главном «дни вместе 0» и
      // пустой парный виджет. Делаем спаренное подключение активным.
      _preferPairedActive();

      await _saveLocal();
      notifyListeners();
      unawaited(
        AnalyticsService.instance.logPairConnected(groupId: remotePairId),
      );
    }

    // Обрабатываем удалённые pairId — партнёр мог выйти/распустить и группа
    // исчезла из моего списка.
    bool removedAny = false;
    for (var connection in _connections) {
      if (connection.pairId.isNotEmpty &&
          !remotePairIds.contains(connection.pairId) &&
          connection.isPaired) {
        debugPrint(
          'Real-time: pairId ${connection.pairId} gone, marking as unpaired',
        );
        connection.markUnpaired();
        removedAny = true;
      }
    }
    if (removedAny) {
      await _saveLocal();
      notifyListeners();
    }
  }

  /// Ensures solo connection exists at index 0 (for single user mode)
  void _ensureSoloConnection() {
    // Check if solo connection already exists
    final existingSolo = _connections.cast<Connection?>().firstWhere(
      (c) => c!.isSolo,
      orElse: () => null,
    );

    if (existingSolo != null) {
      // Лечим повреждённый соло-коннекшн: если у него есть pairId, значит
      // старый баг записал туда партнёрскую группу. Переселяем её в новый
      // нормальный коннекшн, а соло очищаем.
      if (existingSolo.pairId.isNotEmpty || existingSolo.isPaired) {
        final orphanedPairId = existingSolo.pairId;
        final alreadyExists = orphanedPairId.isNotEmpty &&
            _connections.any(
              (c) => !c.isSolo && c.pairId == orphanedPairId,
            );

        if (!alreadyExists && orphanedPairId.isNotEmpty) {
          // Создаём новый нормальный коннекшн и переносим все данные соло
          final rescued = Connection(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            isPaired: existingSolo.isPaired,
            pairId: orphanedPairId,
            startDate: existingSolo.startDate,
            partnerName: existingSolo.partnerName,
            partnerAvatarUrl: existingSolo.partnerAvatarUrl,
            members: List.of(existingSolo.members),
            inviteCode: existingSolo.inviteCode,
            relationshipType: existingSolo.relationshipType,
            onChanged: _onConnectionChanged,
          );
          _connections.add(rescued);
          debugPrint(
            '_ensureSoloConnection: rescued orphaned pairId=$orphanedPairId into new connection',
          );
        }

        // Сбрасываем соло до чистого состояния
        existingSolo.isPaired = false;
        existingSolo.pairId = '';
        existingSolo.startDate = null;
        existingSolo.partnerName = '';
        existingSolo.partnerAvatarUrl = '';
        existingSolo.members.clear();
        existingSolo.inviteCode = '';
        debugPrint('_ensureSoloConnection: reset corrupted solo connection');
      }

      // Move solo to index 0 if not already there
      if (_connections.first != existingSolo) {
        _connections.remove(existingSolo);
        _connections.insert(0, existingSolo);
      }
      return;
    }

    // Create new solo connection
    final soloConnection = Connection(
      id: 'solo',
      isSolo: true,
      onChanged: _onConnectionChanged,
    );

    _connections.insert(0, soloConnection);

    // Adjust active index if needed (if we had active non-solo, keep it offset by 1)
    if (_activeConnectionIndex > 0) {
      _activeConnectionIndex++;
    } else if (_activeConnectionIndex == 0 && _connections.length > 1) {
      // Default to first real connection, not solo
      _activeConnectionIndex = 1;
    }
  }

  /// Выдать связи серверный инвайт-код (с локальным фолбэком при офлайне).
  /// Вызывается только когда кода ещё нет — старый код не передаём (не плодим
  /// удаления). Привязка к группе, если связь уже парная.
  Future<void> _ensureServerCode(Connection c) async {
    final code = await PbDataService().generateInviteCode(
      ownerUid: _uid,
      groupId: c.pairId.isNotEmpty ? c.pairId : null,
    );
    c.inviteCode = code.isNotEmpty ? code : Connection.generateLocalCode();
  }

  // ── Connection Management ──
  Future<Connection> _createNewConnection() async {
    final newConnection = Connection(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      onChanged: _onConnectionChanged,
    );

    _connections.add(newConnection);
    await _saveLocal();
    notifyListeners();
    return newConnection;
  }

  Future<Connection> addNewConnection({
    RelationshipType type = RelationshipType.friends,
    String customLabel = '',
    String customEmoji = '',
  }) async {
    // Идемпотентность: если уже есть пустое (непарное, без партнёра, без
    // pairId) подключение — переиспользуем его вместо создания нового. Иначе
    // повторные вызовы (ретрай/двойной тап) плодили по несколько пустых
    // «ожидающих партнёра» подключений → «создало 5 подключений».
    final existing = _connections.cast<Connection?>().firstWhere(
          (c) => !c!.isSolo && !c.isPaired && c.pairId.isEmpty,
          orElse: () => null,
        );
    if (existing != null) {
      existing.relationshipType = type;
      if (type == RelationshipType.custom) {
        existing.customRelationshipLabel = customLabel;
        existing.customRelationshipEmoji = customEmoji;
      }
      if (_loggedIn && existing.inviteCode.isEmpty) {
        await _ensureServerCode(existing);
      }
      _activeConnectionIndex = _connections.indexOf(existing);
      await _saveLocal();
      notifyListeners();
      return existing;
    }

    final connection = await _createNewConnection();
    connection.relationshipType = type;
    if (type == RelationshipType.custom) {
      connection.customRelationshipLabel = customLabel;
      connection.customRelationshipEmoji = customEmoji;
    }

    // Always generate a fresh unique invite code for the new connection.
    if (_loggedIn) {
      await _ensureServerCode(connection);
    }

    // Auto-switch to the new connection
    _activeConnectionIndex = _connections.length - 1;

    await _saveLocal();
    notifyListeners();
    return connection;
  }

  Future<void> removeConnection(String connectionId) async {
    final index = _connections.indexWhere((c) => c.id == connectionId);
    if (index == -1) return;

    // Can't remove solo connection
    if (_connections[index].isSolo) return;

    // Can't remove the last connection
    if (_connections.length == 1) return;

    final connection = _connections[index];

    // Unpair if paired
    if (connection.isPaired) {
      await connection.unpair();
    }

    connection.dispose();
    // Удаляем по объекту, а не по индексу: за время `await unpair()` listener
    // мог изменить _connections, и захваченный index устарел бы.
    _connections.remove(connection);

    // Adjust active index if needed
    if (_activeConnectionIndex >= _connections.length) {
      _activeConnectionIndex =
          _connections.isEmpty ? 0 : _connections.length - 1;
    }

    await _saveLocal();
    notifyListeners();
  }

  /// Единый обработчик изменений любой связи. Помимо сохранения/нотификации
  /// убирает связи, помеченные [Connection.justDisbanded] — т.е. группы,
  /// распущенные ПАРТНЁРОМ: так группа исчезает у обоих, а не висит пустой
  /// карточкой у того, кто не нажимал «Удалить».
  void _onConnectionChanged() {
    _removeDisbandedConnections();
    _saveLocal();
    notifyListeners();
  }

  /// Удаляет из локального списка связи, распущенные партнёром (solo не трогаем).
  void _removeDisbandedConnections() {
    final disbanded =
        _connections.where((c) => c.justDisbanded && !c.isSolo).toList();
    if (disbanded.isEmpty) return;
    for (final c in disbanded) {
      c.dispose();
      _connections.remove(c);
    }
    if (_activeConnectionIndex >= _connections.length) {
      _activeConnectionIndex =
          _connections.isEmpty ? 0 : _connections.length - 1;
    }
  }

  Future<void> switchToConnection(int index) async {
    if (index < 0 || index >= _connections.length) return;
    _activeConnectionIndex = index;

    // Generate invite code if the connection doesn't have one.
    final connection = _connections[index];
    if (connection.inviteCode.isEmpty && !connection.isSolo && _loggedIn) {
      await _ensureServerCode(connection);
    }

    await _saveLocal();
    notifyListeners();
  }

  Future<void> switchToNextConnection() async {
    if (_connections.length <= 1) return;
    _activeConnectionIndex = (_activeConnectionIndex + 1) % _connections.length;

    // Generate invite code if the connection doesn't have one.
    final connection = _connections[_activeConnectionIndex];
    if (connection.inviteCode.isEmpty && !connection.isSolo && _loggedIn) {
      await _ensureServerCode(connection);
    }

    await _saveLocal();
    notifyListeners();
  }

  /// Switch to solo mode (single user, no group)
  Future<void> switchToSolo() async {
    // Find solo connection index
    final soloIndex = _connections.indexWhere((c) => c.isSolo);
    if (soloIndex == -1) return;

    _activeConnectionIndex = soloIndex;
    await _saveLocal();
    notifyListeners();
    debugPrint('ConnectionsManager: switched to solo mode');
  }

  /// Check if currently in solo mode
  bool get isSoloMode {
    if (_connections.isEmpty) return false;
    if (_activeConnectionIndex >= _connections.length) return false;
    return _connections[_activeConnectionIndex].isSolo;
  }

  // ── Persistence ──
  Future<void> _saveLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final connectionsJson = _connections.map((c) => c.toJson()).toList();
      await prefs.setString('connections', jsonEncode(connectionsJson));
      await prefs.setInt('activeConnectionIndex', _activeConnectionIndex);
      await prefs.setString('preferredPartnerUid', _preferredPartnerUid);
    } catch (e) {
      debugPrint('Failed to save connections: $e');
    }
  }

  Future<void> _loadLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Check if stored uid matches current PocketBase uid
      final storedUid = prefs.getString('uid') ?? '';
      final currentUid = _uid;

      // If uids don't match, clear all connection data
      if (storedUid.isNotEmpty &&
          currentUid.isNotEmpty &&
          storedUid != currentUid) {
        debugPrint(
          'UID mismatch: stored=$storedUid, current=$currentUid. Clearing connections.',
        );
        await clearAllData();
        await resetOfflineState(); // сменился пользователь → чистим и офлайн-кэш
        return;
      }

      final connectionsStr = prefs.getString('connections');
      if (connectionsStr != null) {
        final List<dynamic> connectionsJson = jsonDecode(connectionsStr);
        _connections.clear();
        for (var json in connectionsJson) {
          final connection =
              Connection.fromJson(json, _onConnectionChanged);
          _connections.add(connection);
        }
      }

      _activeConnectionIndex = prefs.getInt('activeConnectionIndex') ?? 0;
      _preferredPartnerUid = prefs.getString('preferredPartnerUid') ?? '';

      // Ensure valid index
      if (_activeConnectionIndex >= _connections.length) {
        _activeConnectionIndex = 0;
      }
    } catch (e) {
      debugPrint('Failed to load connections: $e');
    }
  }

  /// Clear all connection data from SharedPreferences
  Future<void> clearAllData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('connections');
      await prefs.remove('activeConnectionIndex');
      await prefs.remove('preferredPartnerUid');
      _connections.clear();
      _activeConnectionIndex = 0;
      _preferredPartnerUid = '';
      notifyListeners();
      debugPrint('Cleared all connection data');
    } catch (e) {
      debugPrint('Failed to clear connection data: $e');
    }
  }

  @override
  void dispose() {
    _groupsSub?.cancel();
    for (var connection in _connections) {
      connection.dispose();
    }
    super.dispose();
  }
}
