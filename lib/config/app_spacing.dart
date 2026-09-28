import 'package:flutter/material.dart';

/// Gutter horizontal global aplikasi.
///
/// Semua konten horizontal (kotak kamera, card, kalender, FAB) ikut
/// nilai ini. Sumber tunggal — jangan ada magic number lain.
class AppSpacing {
  AppSpacing._();

  /// Persentase gutter dari lebar layar.
  /// 0.075 = 7.5% kiri + 7.5% kanan (total sisa 85% untuk konten).
  static const double gutterFraction = 0.075;

  /// Gutter horizontal dalam pixel, ikut lebar layar device.
  static double horizontal(BuildContext context) {
    return MediaQuery.of(context).size.width * gutterFraction;
  }

    /// Breakpoint: lebar layar di bawah ini dianggap "kecil".
  static const double compactBreakpoint = 350.0;

  /// Skala pengecilan navbar + FAB di layar kecil.
  static const double compactScale = 0.9;

  /// Faktor skala navbar + FAB.
  /// 0.9 kalau layar sempit, 1.0 kalau normal.
  static double navbarScale(BuildContext context) {
    return MediaQuery.of(context).size.width < compactBreakpoint
        ? compactScale
        : 1.0;
  }

  /// Ukuran FAB (56 normal, 50 di layar kecil).
  static double fabSize(BuildContext context) {
    return 56 * navbarScale(context);
  }

  /// Ukuran ikon FAB (24 normal, ~22 di layar kecil).
  static double fabIconSize(BuildContext context) {
    return 24 * navbarScale(context);
  }

  /// True kalau lebar layar < 350dp.
  static bool isCompact(BuildContext context) {
    return MediaQuery.of(context).size.width < compactBreakpoint;
  }
}