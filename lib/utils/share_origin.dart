import 'package:flutter/material.dart';

/// Прямоугольник-якорь для share-поповера на iPad.
///
/// На iPad системный `UIActivityViewController` показывается как popover и
/// ТРЕБУЕТ точку привязки (`sharePositionOrigin`). Без неё share_plus не
/// открывает лист — на планшете кнопка «Поделиться» выглядит неработающей
/// (реджект App Store 2.1(a): «Unresponsive share button»). На iPhone параметр
/// игнорируется, так что безопасно передавать всегда.
///
/// Вызывать СИНХРОННО, до пересечения async-gap: после `await` `context` может
/// стать невалидным (экран/диалог закрыт), и `findRenderObject` вернёт мусор.
Rect shareOriginFromContext(BuildContext context) {
  final box = context.findRenderObject() as RenderBox?;
  if (box != null && box.hasSize) {
    return box.localToGlobal(Offset.zero) & box.size;
  }
  // Фолбэк: центр экрана — origin обязан быть ненулевым, иначе popover не
  // к чему прицепить и лист не появится.
  final size = MediaQuery.maybeOf(context)?.size ?? const Size(400, 800);
  return Rect.fromCenter(
    center: Offset(size.width / 2, size.height / 2),
    width: 1,
    height: 1,
  );
}
