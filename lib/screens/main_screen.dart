import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'absen_section/stream_screen.dart';
import 'profile_section/profil_screen.dart';
import '../config/app_colors.dart';
import '../config/app_spacing.dart';
import '../services/db/database_service.dart';
import '../services/db/supabase_service.dart';
import '../services/db/sync_service.dart';
import '../services/net-service/network_monitor.dart';
import '../services/net-service/sync_watchdog.dart';
import '../widgets/bottom_navbar.dart';
import 'riwayat_section/history_screen.dart';

class MainScreen extends StatefulWidget {
  final List<CameraDescription> cameras;

  const MainScreen({super.key, required this.cameras});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 1;

  @override
  void initState() {
    super.initState();

    NetworkMonitor.registerHandler(() {
      SyncWatchdog().notify();
    });
    NetworkMonitor.start();

    _refreshSekolahAndSync();
  }

  @override
  void dispose() {
    NetworkMonitor.stop();
    super.dispose();
  }

  Future<void> _refreshSekolahAndSync() async {
    try {
      final sekolah = await SupabaseService()
          .getSekolah()
          .timeout(const Duration(seconds: 3));

      if (sekolah != null) {
        await DatabaseService.instance.saveSekolah(
          sekolahId: sekolah['id'] as String,
          nama: sekolah['nama'] as String,
          lat: (sekolah['lat'] as num).toDouble(),
          lng: (sekolah['lng'] as num).toDouble(),
          radiusMeters: (sekolah['radius_meters'] as num).toDouble(),
        );
      }
    } catch (e) {
      debugPrint("MAIN: refresh sekolah gagal -> $e");
    }

    SyncService().syncAll().then((r) {
      debugPrint("MAIN: sync result = $r");
      SyncWatchdog().notify();
    });
  }

  @override
  Widget build(BuildContext context) {
    final showCalendarFab = _currentIndex == 2;

    return Scaffold(
      backgroundColor: AppColors.cream,
      extendBody: true,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildTab(0, ProfilScreen(cameras: widget.cameras)),
          _buildTab(
            1,
            StreamScreen(
              cameras: widget.cameras,
              isActive: _currentIndex == 1,
            ),
          ),
          _buildTab(2, HistoryScreen(key: historyScreenKey)),

          // FAB calendar — KANAN (tab riwayat)
          AnimatedPositioned(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeInOut,
            right: showCalendarFab
                ? AppSpacing.horizontal(context)
                : -100,
            bottom: MediaQuery.of(context).padding.bottom + 13,
            child: IgnorePointer(
              ignoring: !showCalendarFab,
              child: Material(
                color: (historyScreenKey.currentState?.showCalendar ?? false)
                    ? AppColors.tealMedium
                    : AppColors.navbarBg,
                shape: const CircleBorder(),
                elevation: 4,
                child: InkWell(
                  onTap: () {
                    historyScreenKey.currentState?.toggleCalendarFromParent();
                    setState(() {});
                  },
                  customBorder: const CircleBorder(),
                  child: SizedBox(
                    width: AppSpacing.fabSize(context),
                    height: AppSpacing.fabSize(context),
                    child: Icon(
                      (historyScreenKey.currentState?.showCalendar ?? false)
                          ? Icons.chevron_left
                          : Icons.calendar_month,
                      color: Colors.white,
                      size: AppSpacing.fabIconSize(context),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: BottomNavbar(
        currentIndex: _currentIndex,
        onTap: (index) {
          setState(() => _currentIndex = index);
        },
      ),
    );
  }

  Widget _buildTab(int index, Widget child) {
    Offset offset;
    if (index == _currentIndex) {
      offset = Offset.zero;
    } else if (index < _currentIndex) {
      offset = const Offset(-1.0, 0.0);
    } else {
      offset = const Offset(1.0, 0.0);
    }

    return AnimatedSlide(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeInOutCubic,
      offset: offset,
      child: IgnorePointer(
        ignoring: _currentIndex != index,
        child: child,
      ),
    );
  }
}