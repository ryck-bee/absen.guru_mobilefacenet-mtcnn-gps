import 'package:flutter/material.dart';
import '../config/app_colors.dart';
import '../config/app_spacing.dart';

class BottomNavbar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  const BottomNavbar({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });

  // Nilai dasar (layar normal).
  static const double _baseWidth = 170;
  static const double _baseHeight = 50;
  static const double _baseBallSize = 57;
  static const double _baseIconSize = 24;
  static const int _itemCount = 3;

  @override
  Widget build(BuildContext context) {
    final scale = AppSpacing.navbarScale(context);
    final navbarWidth = _baseWidth * scale;
    final navbarHeight = _baseHeight * scale;
    final ballSize = _baseBallSize * scale;
    final iconSize = _baseIconSize * scale;

    final slotWidth = navbarWidth / _itemCount;
    final ballTop = (navbarHeight - ballSize) / 2;

    double ballLeft(int index) {
      return (index * slotWidth) + (slotWidth - ballSize) / 2;
    }

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: SizedBox(
            width: navbarWidth,
            height: navbarHeight,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: navbarWidth,
                  height: navbarHeight,
                  decoration: BoxDecoration(
                    color: AppColors.navbarBg,
                    borderRadius: BorderRadius.circular(navbarHeight / 2),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.2),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                ),
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutCubic,
                  left: ballLeft(currentIndex),
                  top: ballTop,
                  child: Container(
                    width: ballSize,
                    height: ballSize,
                    decoration: BoxDecoration(
                      color: AppColors.tealMedium,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: AppColors.cream,
                        width: 2,
                      ),
                    ),
                  ),
                ),
                Row(
                  children: [
                    _buildTab(0, Icons.settings, iconSize, navbarHeight),
                    _buildTab(1, Icons.camera_alt, iconSize, navbarHeight),
                    _buildTab(2, Icons.history, iconSize, navbarHeight),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTab(
    int index,
    IconData icon,
    double iconSize,
    double navbarHeight,
  ) {
    final isActive = currentIndex == index;

    return Expanded(
      child: GestureDetector(
        onTap: () => onTap(index),
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          height: navbarHeight,
          child: Center(
            child: Icon(
              icon,
              size: iconSize,
              color: isActive
                  ? AppColors.navbarIconActive
                  : AppColors.navbarIconInactive,
            ),
          ),
        ),
      ),
    );
  }
}