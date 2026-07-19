import 'package:flutter/material.dart';

/// M3 Expressive circular loading indicator.
///
/// Recommended replacement for indeterminate three-dot loaders.
/// https://m3.material.io/components/progress-indicators/overview
class M3LoadingDots extends StatelessWidget {
  final Color color;
  final double dotSize;
  final double gap;

  const M3LoadingDots({
    super.key,
    required this.color,
    this.dotSize = 20,
    this.gap = 0,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: dotSize,
      height: dotSize,
      child: CircularProgressIndicator(
        strokeWidth: dotSize * 0.2,
        color: color,
        strokeCap: StrokeCap.round,
      ),
    );
  }
}

/// Full-page centered M3 loading indicator.
class M3PageLoading extends StatelessWidget {
  final Color color;

  const M3PageLoading({super.key, required this.color});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: M3LoadingDots(color: color, dotSize: 36),
    );
  }
}
