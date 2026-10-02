import 'package:flutter/material.dart';
import '../config/app_colors.dart';
import '../widgets/app_spinner.dart';

final ValueNotifier<bool> loadingNotifier = ValueNotifier<bool>(false);

class LoadingController {
  DateTime? _shownAt;
  static const _minVisible = Duration(milliseconds: 800);

  void show() {
    if (loadingNotifier.value) return;
    _shownAt = DateTime.now();
    loadingNotifier.value = true;
  }

  Future<void> hide() async {
    if (!loadingNotifier.value) return;
    final elapsed = DateTime.now().difference(_shownAt ?? DateTime.now());
    if (elapsed < _minVisible) {
      await Future.delayed(_minVisible - elapsed);
    }
    loadingNotifier.value = false;
  }
}

final loadingController = LoadingController();

class LoadingOverlay extends StatelessWidget {
  final Widget child;
  const LoadingOverlay({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        ValueListenableBuilder<bool>(
          valueListenable: loadingNotifier,
          builder: (context, visible, _) {
            // Fade IN instan, fade OUT pakai animasi.
            return AnimatedOpacity(
              duration: visible
                  ? Duration.zero
                  : const Duration(milliseconds: 400),
              opacity: visible ? 1.0 : 0.0,
              child: IgnorePointer(
                ignoring: !visible,
                child: Container(
                  color: AppColors.cream,
                  child: const Center(
                    child: AppSpinner(
                      color: AppColors.tealMedium,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}