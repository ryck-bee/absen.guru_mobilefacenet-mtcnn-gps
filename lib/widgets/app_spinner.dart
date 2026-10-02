import 'package:flutter/material.dart';
import 'package:material3_expressive_loading_indicator/material3_expressive_loading_indicator.dart';

/// Spinner global dengan Material 3 Expressive Loading Indicator.
/// Shape-morphing physics-based — style Android 16/17.
class AppSpinner extends StatelessWidget {
  final double? size;
  final Color? color;

  const AppSpinner({
    super.key,
    this.size,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final indicator = ExpressiveLoadingIndicator(
      color: color,
    );

    if (size == null) return indicator;
    return SizedBox(
      width: size,
      height: size,
      child: FittedBox(
        fit: BoxFit.contain,
        child: indicator,
      ),
    );
  }
}