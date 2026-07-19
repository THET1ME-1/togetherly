import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../services/locale_service.dart';
import '../services/offline/local_store.dart';
import '../services/offline/outbox_service.dart';
import '../services/pb_data_service.dart';
import '../services/pb_realtime_service.dart';
import '../services/pocketbase_service.dart';
import 'relationship_status.dart';

enum RelationshipType {
  couple, // In Love — max 2
  married, // Married — max 2
  friends, // Friends — max 10
  buddies, // Best Buddies — max 10
  custom, // Custom user-defined type
}

/// Info about one group member
class GroupMember {
  final String uid;
  final String name;
  final String avatar;

  const GroupMember({required this.uid, this.name = '', this.avatar = ''});

  Map<String, dynamic> toJson() => {'uid': uid, 'name': name, 'avatar': avatar};

  factory GroupMember.fromJson(Map<String, dynamic> json) => GroupMember(
    uid: json['uid'] ?? '',
    name: json['name'] ?? '',
    avatar: json['avatar'] ?? '',
  );
}

/// Info about a member's mood
class MemberMood {
  final String imagePath;
  final String label;
  final DateTime? updatedAt;

  const MemberMood({this.imagePath = '', this.label = '', this.updatedAt});

  bool get isToday {
    if (updatedAt == null) return false;
    final now = DateTime.now();
    return updatedAt!.year == now.year &&
        updatedAt!.month == now.month &&
        updatedAt!.day == now.day;
  }

  bool get isEmpty => imagePath.isEmpty || !isToday;
  bool get isNotEmpty => imagePath.isNotEmpty && isToday;

  factory MemberMood.fromJson(Map<String, dynamic> json) {
    DateTime? updatedAt;
    final ts = json['updatedAt'];
    if (ts is DateTime) {
      updatedAt = ts;
    }
    return MemberMood(
      imagePath: json['imagePath'] ?? json['emoji'] ?? '',
      label: json['label'] ?? '',
      updatedAt: updatedAt,
    );
  }
}

/// Самочувствие участника («болячки») — что у него болит/нездоровится.
/// В отличие от настроения (которое сбрасывается ежедневно) статус держится,
/// пока его не снимут вручную, но партнёру показывается только пока он
/// «свежий» ([_freshness]) — чтобы забытый статус не висел вечно.
class MemberAilment {
  final String id;
  final String label;
  final String emoji;
  final DateTime? updatedAt;

  const MemberAilment({
    this.id = '',
    this.label = '',
    this.emoji = '',
    this.updatedAt,
  });

  static const Duration _freshness = Duration(days: 7);

  bool get isFresh {
    if (updatedAt == null) return false;
    return DateTime.now().difference(updatedAt!) < _freshness;
  }

  bool get isEmpty => id.isEmpty || !isFresh;
  bool get isNotEmpty => id.isNotEmpty && isFresh;

  factory MemberAilment.fromJson(Map<String, dynamic> json) {
    final ts = json['updatedAt'];
    return MemberAilment(
      id: json['id'] ?? '',
      label: json['label'] ?? '',
      emoji: json['emoji'] ?? '',
      updatedAt: ts is DateTime ? ts : null,
    );
  }
}

/// Represents a single connection/group with 1-9 partners
class Connection {
  final String id;
  bool isPaired; // true if at least 1 partner joined
  bool isSolo; // true if this is the solo (single user) mode
  DateTime? startDate;

  // Legacy single-partner fields (first partner for compat)
  String partnerName;
  String partnerAvatarUrl;

  // Multi-member fields
  List<GroupMember> members; // ALL members including self

  String inviteCode;
  String pairId; // actually groupId
  RelationshipType relationshipType;

  // Custom relationship type fields
  String customRelationshipLabel;
  String customRelationshipEmoji;

  // Custom relationship types list (shared with partner)
  List<Map<String, String>> customRelationshipTypes = [];

  StreamSubscription? _pairSub;
  final Function()? onChanged;

  // ── Идентичность (PocketBase) ──
  // ConnectionsManager/Connection переведены с Firebase на PB: личность берётся
  // из PB-сессии, группа читается/пишется через PbDataService/PbRealtimeService.
  String get _uid => PocketBaseService().userId ?? '';

  /// Группа была распущена партнёром (этот клиент НЕ инициировал удаление).
  /// Менеджер при следующем onChanged уберёт такую связь из локального списка,
  /// чтобы группа исчезла у ОБОИХ, а не висела пустой карточкой у партнёра.
  bool justDisbanded = false;

  // Mood data: uid -> MemberMood
  Map<String, MemberMood> memberMoods = {};

  // Ailment ("болячки") data: uid -> MemberAilment
  Map<String, MemberAilment> memberAilments = {};

  // Relationship status
  RelationshipStatus? currentStatus;
  List<RelationshipStatus> customStatuses = [];

  // Celebrations
  DateTime? anniversaryDate;
  DateTime? firstKissDate;
  Map<String, DateTime> memberBirthdays = {};

  Connection({
    required this.id,
    this.isPaired = false,
    this.isSolo = false,
    this.startDate,
    this.partnerName = '',
    this.partnerAvatarUrl = '',
    List<GroupMember>? members,
    this.inviteCode = '',
    this.pairId = '',
    this.relationshipType = RelationshipType.couple,
    this.customRelationshipLabel = '',
    this.customRelationshipEmoji = '',
    this.onChanged,
  }) : members = members ?? [];

  // Firebase Hosting гасится → инвайт-ссылку обслуживает PocketBase-VPS.
  String get inviteLink => 'https://togetherly.duckdns.org/invite/$inviteCode';

  /// Прямой deep link без веб-хоста (для QR).
  String get inviteDeepLink => 'loveapp://invite/$inviteCode';

  /// Max members allowed — always 2 (couples only)
  int get maxMembers => 2;

  /// Can invite more members?
  bool get canInviteMore {
    if (!isPaired) return true; // not yet connected, invite is needed
    return members.length < maxMembers;
  }

  /// All partner members (excluding self)
  List<GroupMember> get partners {
    final myUid = _uid;
    return members.where((m) => m.uid != myUid).toList();
  }

  /// Number of partners (excluding self)
  int get partnerCount => partners.length;

  // ── Counter values ──
  int get daysInLove {
    if (!isPaired || startDate == null) return 0;
    return DateTime.now().difference(startDate!).inDays;
  }

  int get monthsInLove {
    if (!isPaired || startDate == null) return 0;
    final now = DateTime.now();
    int months =
        (now.year - startDate!.year) * 12 + now.month - startDate!.month;
    if (now.day < startDate!.day) months--;
    return months;
  }

  Duration get timeInLove {
    if (!isPaired || startDate == null) return Duration.zero;
    return DateTime.now().difference(startDate!);
  }

  // ── Relationship Type Helpers ──
  String get relationshipLabel {
    final s = LocaleService.current;
    switch (relationshipType) {
      case RelationshipType.couple:
        return s.inLoveStatus;
      case RelationshipType.married:
        return s.married;
      case RelationshipType.friends:
        return s.friends;
      case RelationshipType.buddies:
        return s.bestBuddies;
      case RelationshipType.custom:
        return customRelationshipLabel.isNotEmpty
            ? customRelationshipLabel
            : s.customStatus;
    }
  }

  String get relationshipEmoji {
    switch (relationshipType) {
      case RelationshipType.couple:
        return '❤️';
      case RelationshipType.married:
        return '💍';
      case RelationshipType.friends:
        return '🤝';
      case RelationshipType.buddies:
        return '👯';
      case RelationshipType.custom:
        return customRelationshipEmoji.isNotEmpty
            ? customRelationshipEmoji
            : '✨';
    }
  }

  /// Get my mood
  MemberMood get myMood {
    final m = memberMoods[_uid];
    if (m == null || !m.isToday) return const MemberMood();
    return m;
  }

  /// Get partner's mood (first partner)
  MemberMood get partnerMood {
    final myUid = _uid;
    for (final entry in memberMoods.entries) {
      if (entry.key != myUid && entry.value.isToday) return entry.value;
    }
    return const MemberMood();
  }

  /// Get mood by uid
  MemberMood moodOf(String uid) {
    final m = memberMoods[uid];
    if (m == null) return const MemberMood();
    if (!m.isToday) return const MemberMood();
    return m;
  }

  /// Set my mood
  Future<void> setMood(String imagePath, String label) async {
    if (pairId.isEmpty) return;
    final myUid = _uid;
    memberMoods[myUid] = MemberMood(
      imagePath: imagePath,
      label: label,
      updatedAt: DateTime.now(),
    );
    onChanged?.call();
    final mood = {
      'imagePath': imagePath,
      'label': label,
      'updatedAt': DateTime.now().toIso8601String(),
    };
    // Offline-first: оптимистично в кэш группы + в очередь (досыл при сети).
    await LocalStore.instance
        .patchRecordMapEntry('groups', pairId, 'member_moods', myUid, mood);
    await OutboxService.instance.enqueue(
        'groupSetMemberMood', {'groupId': pairId, 'uid': myUid, 'mood': mood});
  }

  /// Clear my mood
  Future<void> clearMood() async {
    if (pairId.isEmpty) return;
    memberMoods.remove(_uid);
    onChanged?.call();
    await LocalStore.instance
        .patchRecordMapEntry('groups', pairId, 'member_moods', _uid, null);
    await OutboxService.instance.enqueue(
        'groupSetMemberMood', {'groupId': pairId, 'uid': _uid, 'mood': null});
  }

  /// Моё самочувствие (актуальное).
  MemberAilment get myAilment {
    final a = memberAilments[_uid];
    if (a == null || !a.isFresh) return const MemberAilment();
    return a;
  }

  /// Самочувствие конкретного участника.
  MemberAilment ailmentOf(String uid) {
    final a = memberAilments[uid];
    if (a == null || !a.isFresh) return const MemberAilment();
    return a;
  }

  /// Самочувствие первого партнёра, у которого статус актуален.
  MemberAilment get partnerAilment {
    final myUid = _uid;
    for (final entry in memberAilments.entries) {
      if (entry.key != myUid && entry.value.isFresh) return entry.value;
    }
    return const MemberAilment();
  }

  /// Поставить своё самочувствие.
  Future<void> setAilment(String id, String label, String emoji) async {
    if (pairId.isEmpty) return;
    final myUid = _uid;
    memberAilments[myUid] = MemberAilment(
      id: id,
      label: label,
      emoji: emoji,
      updatedAt: DateTime.now(),
    );
    onChanged?.call();
    final ailment = {
      'id': id,
      'label': label,
      'emoji': emoji,
      'updatedAt': DateTime.now().toIso8601String(),
    };
    await LocalStore.instance.patchRecordMapEntry(
        'groups', pairId, 'member_ailments', myUid, ailment);
    await OutboxService.instance.enqueue('groupSetMemberAilment',
        {'groupId': pairId, 'uid': myUid, 'ailment': ailment});
  }

  /// Снять своё самочувствие («Здоров(а)»).
  Future<void> clearAilment() async {
    if (pairId.isEmpty) return;
    memberAilments.remove(_uid);
    onChanged?.call();
    await LocalStore.instance
        .patchRecordMapEntry('groups', pairId, 'member_ailments', _uid, null);
    await OutboxService.instance.enqueue('groupSetMemberAilment',
        {'groupId': pairId, 'uid': _uid, 'ailment': null});
  }

  void setRelationshipType(
    RelationshipType type, {
    String label = '',
    String emoji = '',
  }) {
    relationshipType = type;
    if (type == RelationshipType.custom) {
      customRelationshipLabel = label;
      customRelationshipEmoji = emoji;
    } else {
      customRelationshipLabel = '';
      customRelationshipEmoji = '';
    }
    // Update in PocketBase
    if (pairId.isNotEmpty) {
      PbDataService().setGroupRelationshipType(
        pairId,
        type: type.name,
        maxMembers: maxMembers,
        customLabel: customRelationshipLabel,
        customEmoji: customRelationshipEmoji,
      );
    }
    onChanged?.call();
  }

  /// Add a custom relationship type to the shared list
  Future<void> addCustomRelationshipType(String label, String emoji) async {
    if (pairId.isEmpty) return;
    final entry = {
      'id': 'crt_${DateTime.now().millisecondsSinceEpoch}',
      'label': label,
      'emoji': emoji,
    };
    customRelationshipTypes.add(entry);
    onChanged?.call();
    await PbDataService().addOrUpdateCustomRelationshipType(pairId, entry);
  }

  /// Update a custom relationship type
  Future<void> updateCustomRelationshipType(
    String id,
    String label,
    String emoji,
  ) async {
    if (pairId.isEmpty) return;
    final idx = customRelationshipTypes.indexWhere((e) => e['id'] == id);
    if (idx == -1) return;
    customRelationshipTypes[idx] = {'id': id, 'label': label, 'emoji': emoji};
    // If currently using this custom type, update label/emoji
    if (relationshipType == RelationshipType.custom &&
        customRelationshipLabel == label) {
      customRelationshipLabel = label;
      customRelationshipEmoji = emoji;
    }
    onChanged?.call();
    await PbDataService().addOrUpdateCustomRelationshipType(pairId, {
      'id': id,
      'label': label,
      'emoji': emoji,
    });
  }

  /// Delete a custom relationship type
  Future<void> deleteCustomRelationshipType(String id) async {
    if (pairId.isEmpty) return;
    final entry = customRelationshipTypes.firstWhere(
      (e) => e['id'] == id,
      orElse: () => {},
    );
    customRelationshipTypes.removeWhere((e) => e['id'] == id);
    // If currently using this type, revert to couple
    if (relationshipType == RelationshipType.custom &&
        customRelationshipLabel == (entry['label'] ?? '')) {
      setRelationshipType(RelationshipType.couple);
    }
    onChanged?.call();
    await PbDataService().deleteCustomRelationshipType(pairId, id);
  }

  // ── Relationship Status Management ──

  /// Get all available statuses (predefined + custom)
  List<RelationshipStatus> get allStatuses {
    return [...RelationshipStatus.predefinedStatuses, ...customStatuses];
  }

  /// Set the current relationship status
  Future<void> setStatus(RelationshipStatus status) async {
    if (pairId.isEmpty) return;
    currentStatus = status;
    onChanged?.call();
    final json = status.toJson();
    await LocalStore.instance
        .patchRecordFields('groups', pairId, {'current_status': json});
    await OutboxService.instance
        .enqueue('groupSetStatus', {'groupId': pairId, 'status': json});
  }

  /// Clear the current relationship status
  Future<void> clearStatus() async {
    if (pairId.isEmpty) return;
    currentStatus = null;
    onChanged?.call();
    await LocalStore.instance
        .patchRecordFields('groups', pairId, {'current_status': null});
    await OutboxService.instance
        .enqueue('groupSetStatus', {'groupId': pairId, 'status': null});
  }

  /// Add a new custom status
  Future<void> addCustomStatus(String label, String emoji) async {
    if (pairId.isEmpty) return;
    final newStatus = RelationshipStatus(
      id: 'custom_${DateTime.now().millisecondsSinceEpoch}',
      label: label,
      emoji: emoji,
      isPredefined: false,
    );
    customStatuses.add(newStatus);
    onChanged?.call();
    await PbDataService().addOrUpdateCustomStatus(pairId, newStatus.toJson());
  }

  /// Update an existing custom status
  Future<void> updateCustomStatus(
    String statusId,
    String label,
    String emoji,
  ) async {
    if (pairId.isEmpty) return;
    final index = customStatuses.indexWhere((s) => s.id == statusId);
    if (index == -1) return;

    final updatedStatus = RelationshipStatus(
      id: statusId,
      label: label,
      emoji: emoji,
      isPredefined: false,
    );
    customStatuses[index] = updatedStatus;

    // Update current status if it's the one being edited
    if (currentStatus?.id == statusId) {
      currentStatus = updatedStatus;
    }

    onChanged?.call();
    await PbDataService().addOrUpdateCustomStatus(pairId, updatedStatus.toJson());
  }

  /// Delete a custom status
  Future<void> deleteCustomStatus(String statusId) async {
    if (pairId.isEmpty) return;
    customStatuses.removeWhere((s) => s.id == statusId);

    // Clear current status if it's the one being deleted
    if (currentStatus?.id == statusId) {
      currentStatus = null;
    }

    onChanged?.call();
    await PbDataService().deleteCustomStatus(pairId, statusId);
  }

  // ── Actions ──
  /// Принять инвайт-код (создание/вход в группу) — переносится на PocketBase в
  /// Фазе 2 (коллекция invite_codes + серверная сверка). Сейчас единый вход —
  /// `ConnectionsManager.acceptCodeAndCreateGroup`; этот локальный путь не
  /// используется и возвращает false до реализации PB-инвайтов.
  Future<bool> acceptCode(String code) async {
    debugPrint('Connection.acceptCode: PB invite flow not implemented yet');
    return false;
  }

  bool isSelfCode(String code) {
    return code.toUpperCase() == inviteCode.toUpperCase();
  }

  Future<void> unpair() async {
    try {
      if (pairId.isNotEmpty) {
        await PbDataService().unpairGroup(pairId, _uid);
      }
    } catch (e) {
      debugPrint('Unpair failed: $e');
    }

    _pairSub?.cancel();
    isPaired = false;
    startDate = null;
    partnerName = '';
    partnerAvatarUrl = '';
    pairId = '';
    members = [];

    // Свежий серверный код после распада пары (локальный — фолбэк офлайна).
    final code = await PbDataService().generateInviteCode(
      ownerUid: _uid,
      oldCode: inviteCode.isNotEmpty ? inviteCode : null,
    );
    // НЕ подставляем фейковый локальный код при провале серверного создания
    // (его нет в invite_codes → партнёру «код не найден»). Пусто → UI даст
    // перевыпустить; серверный create само-лечит протухший токен (authRefresh).
    inviteCode = code;

    onChanged?.call();
  }

  /// Marks this connection as unpaired locally (remote event: partner left).
  /// Does NOT write to the server — the partner already did that.
  void markUnpaired() {
    _pairSub?.cancel();
    _pairSub = null;
    isPaired = false;
    startDate = null;
    partnerName = '';
    partnerAvatarUrl = '';
    pairId = '';
    members = [];
    onChanged?.call();
  }

  Future<void> regenerateCode() async {
    final code = await PbDataService().generateInviteCode(
      ownerUid: _uid,
      groupId: isPaired && pairId.isNotEmpty ? pairId : null,
      oldCode: inviteCode.isNotEmpty ? inviteCode : null,
    );
    // НЕ подставляем фейковый локальный код при провале серверного создания
    // (его нет в invite_codes → партнёру «код не найден»). Пусто → UI даст
    // перевыпустить; серверный create само-лечит протухший токен (authRefresh).
    inviteCode = code;
    onChanged?.call();
  }

  /// Generate a group-specific invite code (for adding more members)
  Future<String> generateInviteForGroup() async {
    if (pairId.isEmpty) return inviteCode;
    final code = await PbDataService().generateInviteCode(
      ownerUid: _uid,
      groupId: pairId,
      oldCode: inviteCode.isNotEmpty ? inviteCode : null,
    );
    if (code.isNotEmpty) {
      inviteCode = code;
      onChanged?.call();
    }
    return inviteCode;
  }

  /// Called when real-time listener detects a new pairId
  Future<void> claimPair(String newPairId) async {
    if (isSolo) return; // solo-connection никогда не должен становиться парным
    if (isPaired || pairId.isNotEmpty) return;
    pairId = newPairId;
    await refreshPairStatus();
    // Перевыпускаем код как привязанный к группе: иначе оставшийся unpaired-код
    // мог бы спарить третьего (accept «у владельца есть группа» создал бы вторую).
    final code = await PbDataService().generateInviteCode(
      ownerUid: _uid,
      groupId: pairId,
      oldCode: inviteCode.isNotEmpty ? inviteCode : null,
    );
    if (code.isNotEmpty) {
      inviteCode = code;
      onChanged?.call();
    }
  }

  Future<void> refreshPairStatus() async {
    if (pairId.isNotEmpty) {
      // Всегда тянем свежую группу из PocketBase на старте — покрывает случай,
      // когда SharedPreferences держит устаревший `members` от прошлой версии
      // (первопричина фантомного «Group of 3»).
      try {
        final pairData = await PbDataService().loadPairMapById(pairId, _uid);
        if (pairData != null) {
          _applyPairData(pairData);
        }
      } catch (e) {
        debugPrint('Pair refresh by id failed: $e');
      }
      _listenToPair();
      onChanged?.call();
      return;
    }

    try {
      final pairData = await PbDataService().loadPairMapForUser(_uid);
      if (pairData != null) {
        pairId = pairData['pairId'] ?? '';
        _applyPairData(pairData);
        _listenToPair();
      }
    } catch (e) {
      debugPrint('Pair refresh failed: $e');
    }
    onChanged?.call();
  }

  void _applyPairData(Map<String, dynamic> data) {
    isPaired = true;
    startDate = data['startDate'] as DateTime?;
    partnerName = data['partnerName'] ?? '';
    partnerAvatarUrl = data['partnerAvatar'] ?? '';

    // Parse relationship type
    final rtStr = data['relationshipType'] as String?;
    if (rtStr != null) {
      relationshipType = RelationshipType.values.firstWhere(
        (e) => e.name == rtStr,
        orElse: () => RelationshipType.couple,
      );
    }
    customRelationshipLabel = data['customRelationshipLabel'] as String? ?? '';
    customRelationshipEmoji = data['customRelationshipEmoji'] as String? ?? '';

    // Parse custom relationship types list
    final crtList = data['customRelationshipTypes'] as List<dynamic>?;
    if (crtList != null) {
      customRelationshipTypes = crtList
          .map(
            (e) => Map<String, String>.from(
              (e as Map).map((k, v) => MapEntry(k.toString(), v.toString())),
            ),
          )
          .toList();
    } else {
      customRelationshipTypes = [];
    }

    // Parse members
    final membersList = data['members'] as List<dynamic>?;
    if (membersList != null) {
      members = membersList
          .map(
            (m) => GroupMember(
              uid: (m as Map)['uid'] ?? '',
              name: m['name'] ?? '',
              avatar: m['avatar'] ?? '',
            ),
          )
          .toList();
    }

    // Parse moods
    final moodsMap = data['memberMoods'] as Map<String, dynamic>?;
    if (moodsMap != null) {
      memberMoods = moodsMap.map(
        (uid, value) => MapEntry(
          uid,
          MemberMood.fromJson(Map<String, dynamic>.from(value as Map)),
        ),
      );
    } else {
      memberMoods = {};
    }

    // Parse ailments
    final ailmentsMap = data['memberAilments'] as Map<String, dynamic>?;
    if (ailmentsMap != null) {
      memberAilments = ailmentsMap.map(
        (uid, value) => MapEntry(
          uid,
          MemberAilment.fromJson(Map<String, dynamic>.from(value as Map)),
        ),
      );
    } else {
      memberAilments = {};
    }

    // Parse current status
    final statusData = data['currentStatus'] as Map<String, dynamic>?;
    if (statusData != null) {
      currentStatus = RelationshipStatus.fromJson(statusData);
    } else {
      currentStatus = null;
    }

    // Parse custom statuses
    final customStatusesList = data['customStatuses'] as List<dynamic>?;
    if (customStatusesList != null) {
      customStatuses = customStatusesList
          .map(
            (s) => RelationshipStatus.fromJson(
              Map<String, dynamic>.from(s as Map),
            ),
          )
          .toList();
    } else {
      customStatuses = [];
    }
  }

  /// Public wrapper to start real-time listening on this connection's pair
  void startListening() => _listenToPair();

  void _listenToPair() {
    _pairSub?.cancel();
    if (pairId.isEmpty) return;

    // PB SSE: живой group-док. Запись приходит и при disbanded=true — трактуем
    // её как «группы нет» (распущена), как делал Firestore-листенер.
    _pairSub = PbRealtimeService().watchGroup(pairId).listen((rec) {
      if (rec == null || rec.data['disbanded'] == true) {
        _handlePairSnapshot(null);
      } else {
        _handlePairSnapshot(PbDataService.groupRecordToPairMap(rec, _uid));
      }
    }, onError: (e) => debugPrint('_listenToPair error: $e'));
  }

  /// Обработка живого снимка группы (map в форме старого Firestore-парсера или
  /// null = группа распущена/удалена). Логика идентична прежнему onData.
  void _handlePairSnapshot(Map<String, dynamic>? data) {
    if (data == null) {
      // Group was deleted or disbanded
      debugPrint('_listenToPair: group deleted');
      isPaired = false;
      pairId = '';
      partnerName = '';
      partnerAvatarUrl = '';
      startDate = null;
      members = [];
      // Партнёр распустил группу — помечаем связь на удаление из локального
      // списка (менеджер уберёт её в onChanged), чтобы группа исчезла у обоих,
      // а не осталась пустой карточкой. Сервер НЕ трогаем: disband — мягкое
      // удаление (группа остаётся восстановимой при повторном коннекте).
      justDisbanded = true;
      onChanged?.call();
      return;
    }

    partnerName = data['partnerName'] ?? partnerName;
    partnerAvatarUrl = data['partnerAvatar'] ?? partnerAvatarUrl;
    startDate = data['startDate'] as DateTime? ?? startDate;

    // Update members
    final membersList = data['members'] as List<dynamic>?;
    if (membersList != null) {
      final newMembers = membersList
          .map(
            (m) => GroupMember(
              uid: (m as Map)['uid'] ?? '',
              name: m['name'] ?? '',
              avatar: m['avatar'] ?? '',
            ),
          )
          .toList();

      // Check if we're still in the group
      final myUid = _uid;
      final imInGroup = newMembers.any((m) => m.uid == myUid);

      if (!imInGroup) {
        // I've been removed from the group (shouldn't happen, but handle it)
        debugPrint('_listenToPair: removed from group');
        isPaired = false;
        pairId = '';
        partnerName = '';
        partnerAvatarUrl = '';
        startDate = null;
        members = [];
        onChanged?.call();
        return;
      }

      members = newMembers;

      // Diagnostic: log when the group is over capacity. Indicates the
      // "phantom member" bug — same person occupying multiple uid slots.
      // Серверная чистка фантомов — Фаза 2 (нет PB-аналога
      // cleanupPhantomMembersInGroup); пока только диагностика.
      if (newMembers.length > maxMembers) {
        final dump = newMembers.map((m) => '${m.uid}=${m.name}').join(', ');
        debugPrint(
          '_listenToPair($pairId): OVERSIZED group — '
          '${newMembers.length} members, maxMembers=$maxMembers, myUid=$myUid, '
          'partners=${newMembers.where((m) => m.uid != myUid).length}. '
          'Members: [$dump]',
        );
      }

      // If all partners left (only me remaining), mark as unpaired and disband
      // the orphan group (иначе оно вернётся в discovery: members~me).
      final partnersCount = members.where((m) => m.uid != myUid).length;
      if (partnersCount == 0 && isPaired) {
        debugPrint('_listenToPair: all partners left, marking as unpaired');
        final staleId = pairId;
        isPaired = false;
        partnerName = '';
        partnerAvatarUrl = '';
        startDate = null;
        pairId = '';
        members = [];
        _pairSub?.cancel();
        _pairSub = null;
        if (staleId.isNotEmpty) {
          unawaited(PbDataService().leaveGroup(staleId, myUid));
        }
      }
    }

    // Update relationship type
    final rtStr = data['relationshipType'] as String?;
    if (rtStr != null) {
      relationshipType = RelationshipType.values.firstWhere(
        (e) => e.name == rtStr,
        orElse: () => RelationshipType.couple,
      );
    }
    customRelationshipLabel =
        data['customRelationshipLabel'] as String? ?? customRelationshipLabel;
    customRelationshipEmoji =
        data['customRelationshipEmoji'] as String? ?? customRelationshipEmoji;

    // Update custom relationship types list
    final crtList = data['customRelationshipTypes'] as List<dynamic>?;
    if (crtList != null) {
      customRelationshipTypes = crtList
          .map(
            (e) => Map<String, String>.from(
              (e as Map).map((k, v) => MapEntry(k.toString(), v.toString())),
            ),
          )
          .toList();
    } else {
      customRelationshipTypes = [];
    }

    // Update moods
    final moodsMap = data['memberMoods'] as Map<String, dynamic>?;
    if (moodsMap != null) {
      memberMoods = moodsMap.map(
        (uid, value) => MapEntry(
          uid,
          MemberMood.fromJson(Map<String, dynamic>.from(value as Map)),
        ),
      );
    } else {
      memberMoods = {};
    }

    // Update ailments
    final ailmentsMap = data['memberAilments'] as Map<String, dynamic>?;
    if (ailmentsMap != null) {
      memberAilments = ailmentsMap.map(
        (uid, value) => MapEntry(
          uid,
          MemberAilment.fromJson(Map<String, dynamic>.from(value as Map)),
        ),
      );
    } else {
      memberAilments = {};
    }

    // Update status
    final statusData = data['currentStatus'] as Map<String, dynamic>?;
    if (statusData != null) {
      currentStatus = RelationshipStatus.fromJson(statusData);
    } else {
      currentStatus = null;
    }

    // Update custom statuses
    final customStatusesList = data['customStatuses'] as List<dynamic>?;
    if (customStatusesList != null) {
      customStatuses = customStatusesList
          .map(
            (s) => RelationshipStatus.fromJson(
              Map<String, dynamic>.from(s as Map),
            ),
          )
          .toList();
    } else {
      customStatuses = [];
    }

    // Update celebration dates (mapper already converts ISO→DateTime).
    // Preserve-on-empty: перезаписываем ТОЛЬКО непустыми значениями — иначе
    // частичное/устаревшее чтение (или realtime без этих полей) обнулит уже
    // показанные даты. Легитимной «очистки» даты нет: пикеры всегда ставят
    // непустое, member_birthdays клиент не пишет вовсе.
    final anniv = data['anniversaryDate'] as DateTime?;
    if (anniv != null) anniversaryDate = anniv;
    final fk = data['firstKissDate'] as DateTime?;
    if (fk != null) firstKissDate = fk;
    final bdRaw = data['memberBirthdays'] as Map<String, dynamic>?;
    if (bdRaw != null) {
      final parsed = <String, DateTime>{};
      for (final entry in bdRaw.entries) {
        if (entry.value is DateTime) {
          parsed[entry.key] = entry.value as DateTime;
        }
      }
      if (parsed.isNotEmpty) memberBirthdays = parsed;
    }

    onChanged?.call();
  }

  void dispose() {
    _pairSub?.cancel();
  }

  // ── Helpers ──
  static String generateLocalCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rng = Random(DateTime.now().microsecondsSinceEpoch);
    return List.generate(6, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  // ── Serialization ──
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'isPaired': isPaired,
      'isSolo': isSolo,
      'startDate': startDate?.toIso8601String(),
      'partnerName': partnerName,
      'partnerAvatarUrl': partnerAvatarUrl,
      'members': members.map((m) => m.toJson()).toList(),
      'inviteCode': inviteCode,
      'pairId': pairId,
      'relationshipType': relationshipType.name,
      'customRelationshipLabel': customRelationshipLabel,
      'customRelationshipEmoji': customRelationshipEmoji,
      // Праздничные даты кэшируем локально, иначе на холодном старте с
      // неудачным/медленным чтением группы (мёртвая сессия/оффлайн) они
      // единственные из полей пары пропадают из UI.
      'anniversaryDate': anniversaryDate?.toIso8601String(),
      'firstKissDate': firstKissDate?.toIso8601String(),
      'memberBirthdays': memberBirthdays
          .map((k, v) => MapEntry(k, v.toIso8601String())),
    };
  }

  static Connection fromJson(
    Map<String, dynamic> json,
    Function()? onChanged,
  ) {
    // Sanity guard against the "Group of 3" bug. Old builds could persist a
    // members list that contains: an entry with an empty uid, duplicates of
    // the same uid, or more entries than a couple should have. Restoring such
    // a list as-is lets the bug survive across uninstalls (via Android Auto
    // Backup) and across restarts. Drop empties + dedupe by uid; if the
    // cleaned list still overflows maxMembers (=2), zero it out so the
    // real-time listener repopulates from authoritative data.
    final rawMembers = (json['members'] as List<dynamic>?)
        ?.map((m) => GroupMember.fromJson(Map<String, dynamic>.from(m)))
        .toList();
    final List<GroupMember> membersList;
    if (rawMembers == null) {
      membersList = [];
    } else {
      final seen = <String>{};
      final cleaned = <GroupMember>[];
      for (final m in rawMembers) {
        if (m.uid.isEmpty) continue;
        if (!seen.add(m.uid)) continue;
        cleaned.add(m);
      }
      const localMaxMembers = 2;
      if (cleaned.length > localMaxMembers) {
        debugPrint(
          'Connection.fromJson(${json['id']}): members overflow '
          '(${cleaned.length} > $localMaxMembers) — clearing local cache, '
          'will refetch from PocketBase. Cached uids: '
          '${cleaned.map((m) => m.uid).toList()}',
        );
        membersList = [];
      } else if (cleaned.length != rawMembers.length) {
        debugPrint(
          'Connection.fromJson(${json['id']}): pruned '
          '${rawMembers.length - cleaned.length} bad member entry(ies) '
          '(empties/duplicates)',
        );
        membersList = cleaned;
      } else {
        membersList = cleaned;
      }
    }

    return Connection(
        id: json['id'] ?? '',
        isPaired: json['isPaired'] ?? false,
        isSolo: json['isSolo'] ?? false,
        startDate: json['startDate'] != null
            ? DateTime.tryParse(json['startDate'])
            : null,
        partnerName: json['partnerName'] ?? '',
        partnerAvatarUrl: json['partnerAvatarUrl'] ?? '',
        members: membersList,
        inviteCode: json['inviteCode'] ?? '',
        pairId: json['pairId'] ?? '',
        relationshipType: RelationshipType.values.firstWhere(
          (e) => e.name == json['relationshipType'],
          orElse: () => RelationshipType.couple,
        ),
        customRelationshipLabel: json['customRelationshipLabel'] ?? '',
        customRelationshipEmoji: json['customRelationshipEmoji'] ?? '',
        onChanged: onChanged,
      )
      ..customRelationshipTypes =
          (json['customRelationshipTypes'] as List<dynamic>?)
              ?.map(
                (e) => Map<String, String>.from(
                  (e as Map).map(
                    (k, v) => MapEntry(k.toString(), v.toString()),
                  ),
                ),
              )
              .toList() ??
          []
      ..anniversaryDate = json['anniversaryDate'] != null
          ? DateTime.tryParse(json['anniversaryDate'])
          : null
      ..firstKissDate = json['firstKissDate'] != null
          ? DateTime.tryParse(json['firstKissDate'])
          : null
      ..memberBirthdays = _birthdaysFromJson(json['memberBirthdays']);
  }

  static Map<String, DateTime> _birthdaysFromJson(dynamic raw) {
    if (raw is! Map) return {};
    final out = <String, DateTime>{};
    raw.forEach((k, v) {
      final d = v is String ? DateTime.tryParse(v) : null;
      if (d != null) out[k.toString()] = d;
    });
    return out;
  }
}
