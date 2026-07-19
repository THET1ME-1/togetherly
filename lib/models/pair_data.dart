import 'dart:async';
import 'package:flutter/foundation.dart';
import 'connections_manager.dart';
import 'connection.dart';
import '../services/nickname_service.dart';

// Re-export for convenience
export 'connection.dart'
    show RelationshipType, GroupMember, MemberMood, MemberAilment;

/// Wrapper around ConnectionsManager for backward compatibility
/// Delegates to the active connection
class PairData extends ChangeNotifier {
  final ConnectionsManager _manager = ConnectionsManager();

  ConnectionsManager get manager => _manager;

  Connection? get _active => _manager.activeConnection;

  // ── Getters ──
  bool get isPaired => _active?.isPaired ?? false;
  bool get isSolo => _active?.isSolo ?? false;
  DateTime? get startDate => _active?.startDate;
  String get myName => 'You';
  String get partnerName => _active?.partnerName ?? '';
  String get partnerAvatarUrl => _active?.partnerAvatarUrl ?? '';
  String get inviteCode => _active?.inviteCode ?? '';

  /// UID первого партнёра (для хранения псевдонима)
  String get partnerUid => _active?.partners.firstOrNull?.uid ?? '';

  /// Отображаемое имя партнёра: псевдоним (если задан) или реальное имя
  String get partnerDisplayName =>
      NicknameService.instance.resolve(partnerUid, partnerName);

  /// Отображаемое имя участника группы: псевдоним или реальное
  String displayNameOf(GroupMember member) =>
      NicknameService.instance.resolve(member.uid, member.name);

  /// Сохранить локальный псевдоним для участника
  Future<void> setNickname(String uid, String nickname) async {
    await NicknameService.instance.set(uid, nickname);
    notifyListeners();
  }

  /// Удалить псевдоним (вернуть настоящее имя)
  Future<void> clearNickname(String uid) async {
    await NicknameService.instance.clear(uid);
    notifyListeners();
  }

  String get pairId => _active?.pairId ?? '';
  bool get loading => _manager.loading;
  RelationshipType get relationshipType =>
      _active?.relationshipType ?? RelationshipType.couple;

  // Firebase Hosting выключается вместе с проектом → инвайт-ссылку теперь
  // обслуживает PocketBase-VPS (pb_hooks/invite_web.pb.js: лендинг + assetlinks).
  String get inviteLink => 'https://togetherly.duckdns.org/invite/$inviteCode';

  /// Прямой deep link без веб-хоста: партнёр сканирует QR камерой → сразу в
  /// приложение (App Links-верификация не нужна, работает офлайн от Firebase).
  String get inviteDeepLink => 'loveapp://invite/$inviteCode';

  // ── Multi-member getters ──
  List<GroupMember> get members => _active?.members ?? [];
  List<GroupMember> get partners => _active?.partners ?? [];
  int get partnerCount => _active?.partnerCount ?? 0;
  int get maxMembers => _active?.maxMembers ?? 2;
  bool get canInviteMore => _active?.canInviteMore ?? false;

  // ── Counter values ──
  int get daysInLove => _active?.daysInLove ?? 0;
  int get monthsInLove => _active?.monthsInLove ?? 0;
  Duration get timeInLove => _active?.timeInLove ?? Duration.zero;

  // ── Relationship Type Helpers ──
  String get relationshipLabel => _active?.relationshipLabel ?? 'In Love';
  String get relationshipEmoji => _active?.relationshipEmoji ?? '❤️';
  String get relationshipStatusId => _active?.currentStatus?.id ?? '';

  // ── Mood ──
  MemberMood get myMood => _active?.myMood ?? const MemberMood();
  MemberMood get partnerMood => _active?.partnerMood ?? const MemberMood();
  MemberMood moodOf(String uid) => _active?.moodOf(uid) ?? const MemberMood();

  Future<void> setMood(String imagePath, String label) async {
    if (_active == null) return;
    await _active!.setMood(imagePath, label);
    notifyListeners();
  }

  Future<void> clearMood() async {
    if (_active == null) return;
    await _active!.clearMood();
    notifyListeners();
  }

  // ── Самочувствие («болячки») ──
  MemberAilment get myAilment => _active?.myAilment ?? const MemberAilment();
  MemberAilment get partnerAilment =>
      _active?.partnerAilment ?? const MemberAilment();
  MemberAilment ailmentOf(String uid) =>
      _active?.ailmentOf(uid) ?? const MemberAilment();

  Future<void> setAilment(String id, String label, String emoji) async {
    if (_active == null) return;
    await _active!.setAilment(id, label, emoji);
    notifyListeners();
  }

  Future<void> clearAilment() async {
    if (_active == null) return;
    await _active!.clearAilment();
    notifyListeners();
  }

  void setRelationshipType(
    RelationshipType type, {
    String label = '',
    String emoji = '',
  }) {
    _active?.setRelationshipType(type, label: label, emoji: emoji);
    notifyListeners();
  }

  // ── Custom Relationship Types ──
  List<Map<String, String>> get customRelationshipTypes =>
      _active?.customRelationshipTypes ?? [];

  Future<void> addCustomRelationshipType(String label, String emoji) async {
    if (_active == null) return;
    await _active!.addCustomRelationshipType(label, emoji);
    notifyListeners();
  }

  Future<void> updateCustomRelationshipType(
    String id,
    String label,
    String emoji,
  ) async {
    if (_active == null) return;
    await _active!.updateCustomRelationshipType(id, label, emoji);
    notifyListeners();
  }

  Future<void> deleteCustomRelationshipType(String id) async {
    if (_active == null) return;
    await _active!.deleteCustomRelationshipType(id);
    notifyListeners();
  }

  // ── Инициализация ──
  Future<void> init({required String myName}) async {
    await NicknameService.instance.init();
    _manager.addListener(_onManagerChanged);
    await _manager.init(myName: myName);
    notifyListeners();
  }

  void _onManagerChanged() {
    notifyListeners();
  }

  // ── Actions ──
  void setMyName(String name) {
    // Not used anymore, kept for compatibility
    notifyListeners();
  }

  /// Принять код партнёра — создаёт/вступает в группу через Firestore.
  /// Работает независимо от того, есть ли уже активная группа.
  Future<bool> acceptCode(String code) async {
    final result = await _manager.acceptCodeAndCreateGroup(code);
    if (result) notifyListeners();
    return result;
  }

  /// Свой ли код? Проверяет по ВСЕМ connections.
  bool isSelfCode(String code) {
    return _manager.isSelfCodeAny(code);
  }

  /// Разорвать пару
  Future<void> unpair() async {
    if (_active == null) return;
    await _active!.unpair();
    notifyListeners();
  }

  /// Перегенерация кода
  Future<void> regenerateCode() async {
    if (_active == null) return;
    await _active!.regenerateCode();
    notifyListeners();
  }

  /// Generate group invite code (for adding more members)
  Future<String> generateGroupInvite() async {
    if (_active == null) return '';
    return await _active!.generateInviteForGroup();
  }

  @override
  void dispose() {
    _manager.removeListener(_onManagerChanged);
    _manager.dispose();
    super.dispose();
  }
}
