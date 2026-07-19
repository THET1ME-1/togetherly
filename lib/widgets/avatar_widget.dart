import 'package:flutter/material.dart';
import '../utils/safe_text.dart';
import 'storage_image.dart';
import '../services/pocketbase_service.dart';
import '../services/pb_auth_service.dart';

/// Unified avatar widget used everywhere a user picture is displayed.
///
/// Resolution order:
///   1. For the current user → PocketBase profile avatarUrl (in-memory, always fresh)
///   2. [liveUrl] — caller-supplied live URL (e.g. from group memberAvatars)
///   3. [fallbackUrl] — snapshot stored inside the memory/comment document
///   4. Initials placeholder built from [name]
///
/// Always uses CachedNetworkImage with an errorWidget — never shows a red cross.
class AvatarWidget extends StatelessWidget {
  final String uid;
  final String? liveUrl;
  final String? fallbackUrl;
  final String? name;
  final double size;
  final Color primary;

  const AvatarWidget({
    super.key,
    required this.uid,
    this.liveUrl,
    this.fallbackUrl,
    this.name,
    required this.size,
    required this.primary,
  });

  String _resolveUrl() {
    if (uid == PocketBaseService().userId) {
      final cached =
          (PbAuthService().currentProfile()?['avatarUrl'] as String?) ?? '';
      if (cached.isNotEmpty) return cached;
    }
    if (liveUrl?.isNotEmpty == true) return liveUrl!;
    if (fallbackUrl?.isNotEmpty == true) return fallbackUrl!;
    return '';
  }

  Widget _placeholder() {
    final initial = (name ?? '').firstGraphemeUpper();
    return Container(
      width: size,
      height: size,
      color: primary.withValues(alpha: 0.15),
      child: Center(
        child: Text(
          initial,
          style: TextStyle(
            fontSize: size * 0.38,
            fontWeight: FontWeight.w700,
            color: primary,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final url = _resolveUrl();
    return ClipOval(
      child: url.isNotEmpty
          ? StorageImage(
              imageUrl: url,
              width: size,
              height: size,
              fit: BoxFit.cover,
              memCacheWidth: (size * 2).toInt(),
              memCacheHeight: (size * 2).toInt(),
              placeholder: (_, __) => _placeholder(),
              errorWidget: (_, __, ___) => _placeholder(),
            )
          : _placeholder(),
    );
  }
}
