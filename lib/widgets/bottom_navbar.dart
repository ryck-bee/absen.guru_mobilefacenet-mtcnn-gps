import 'package:flutter/material.dart';
import '../config/app_colors.dart';

class BottomNavbar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  const BottomNavbar({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });

  static const double _navbarWidth = 170;
  static const double _navbarHeight = 50;
  static const double _ballSize = 57;
  static const int _itemCount = 3;

  double get _slotWidth => _navbarWidth / _itemCount;

  double _ballLeft(int index) {
    return (index * _slotWidth) + (_slotWidth - _ballSize) / 2;
  }

  @override
  Widget build(BuildContext context) {
    final ballTop = (_navbarHeight - _ballSize) / 2;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: SizedBox(
            width: _navbarWidth,
            height: _navbarHeight,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // Background navbar
                Container(
                  width: _navbarWidth,
                  height: _navbarHeight,
                  decoration: BoxDecoration(
                    color: AppColors.navbarBg,
                    borderRadius: BorderRadius.circular(_navbarHeight / 2),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.2),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                ),

                // Bulatan aktif (geser horizontal)
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutCubic,
                  left: _ballLeft(currentIndex),
                  top: ballTop,
                  child: Container(
                    width: _ballSize,
                    height: _ballSize,
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

                // Ikon
                Row(
                  children: [
                    _buildTab(0, Icons.settings),
                    _buildTab(1, Icons.camera_alt),
                    _buildTab(2, Icons.history),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTab(int index, IconData icon) {
    final isActive = currentIndex == index;

    return Expanded(
      child: GestureDetector(
        onTap: () => onTap(index),
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          height: _navbarHeight,
          child: Center(
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 250),
              style: const TextStyle(),
              child: Icon(
                icon,
                size: 24,
                color: isActive
                    ? Colors.white
                    : AppColors.navbarIconInactive,
              ),
            ),
          ),
        ),
      ),
    );
  }
}