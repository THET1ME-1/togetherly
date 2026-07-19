import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:path_provider/path_provider.dart';

/// Нормализует EXIF-ориентацию (включая зеркальность фронтальной камеры),
/// затем открывает редактор кадрирования.
/// Возвращает путь к готовому файлу или null если пользователь отменил.
Future<String?> cropPhoto(
  String sourcePath, {
  Color accentColor = const Color(0xFFE91E8C),
}) async {
  // Сначала убираем EXIF-зеркальность: бакём все трансформации в пиксели
  final normalized = await _normalizeOrientation(sourcePath);
  final workPath = normalized ?? sourcePath;

  // Нативный кроппер может кинуть PlatformException (отмена через системный
  // диалог, нехватка памяти, пересоздание активити) — это не краш приложения,
  // трактуем как «не выбрали фото».
  CroppedFile? cropped;
  try {
    cropped = await ImageCropper().cropImage(
      sourcePath: workPath,
      compressFormat: ImageCompressFormat.jpg,
      compressQuality: 88,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: 'Редактировать фото',
          toolbarColor: const Color(0xFF1A1A2E),
          toolbarWidgetColor: Colors.white,
          statusBarLight: false,
          backgroundColor: const Color(0xFF111111),
          activeControlsWidgetColor: accentColor,
          cropFrameColor: accentColor,
          cropGridColor: Colors.white24,
          dimmedLayerColor: const Color(0xCC0D0D1A),
          lockAspectRatio: false,
          initAspectRatio: CropAspectRatioPreset.original,
          aspectRatioPresets: [
            CropAspectRatioPreset.original,
            CropAspectRatioPreset.square,
            CropAspectRatioPreset.ratio4x3,
            CropAspectRatioPreset.ratio16x9,
          ],
        ),
        IOSUiSettings(
          title: 'Редактировать',
          doneButtonTitle: 'Готово',
          cancelButtonTitle: 'Отмена',
          aspectRatioLockEnabled: false,
          resetAspectRatioEnabled: true,
          rotateButtonsHidden: false,
          hidesNavigationBar: false,
          aspectRatioPresets: [
            CropAspectRatioPreset.original,
            CropAspectRatioPreset.square,
            CropAspectRatioPreset.ratio4x3,
            CropAspectRatioPreset.ratio16x9,
          ],
        ),
      ],
    );
  } catch (e) {
    debugPrint('cropPhoto: cropImage failed: $e');
    cropped = null;
  }

  // Удаляем временный нормализованный файл если он был создан
  if (normalized != null && normalized != sourcePath) {
    try {
      await File(normalized).delete();
    } catch (_) {}
  }

  return cropped?.path;
}

/// Применяет EXIF-трансформации (поворот + зеркальность) к пикселям
/// и возвращает путь к нормализованному файлу без EXIF.
Future<String?> _normalizeOrientation(String sourcePath) async {
  try {
    final tempDir = await getTemporaryDirectory();
    final target =
        '${tempDir.path}/${DateTime.now().millisecondsSinceEpoch}_norm.jpg';
    final result = await FlutterImageCompress.compressAndGetFile(
      sourcePath,
      target,
      quality: 95,
      autoCorrectionAngle: true,
      keepExif: false,
    );
    return result?.path;
  } catch (_) {
    return null;
  }
}
