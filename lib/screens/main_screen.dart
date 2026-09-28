import 'dart:async';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'absen_section/stream_screen.dart';
import 'profile_section/profil_screen.dart';
import '../config/app_colors.dart';
import '../services/db/database_service.dart';
import '../services/db/supabase_service.dart';
import '../services/db/sync_service.dart';
import '../services/model/mobilefacenet_service.dart';
import '../services/net-service/network_monitor.dart';
import '../services/net-service/sync_watchdog.dart';
import '../widgets/bottom_navbar.dart';

class MainScreen extends StatefulWidget {
  final List<CameraDescription> cameras;

  const MainScreen({super.key, required this.cameras});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 1; // Default Absen (index 1)
  bool _bootstrapping = false;

  @override
  void initState() {
    super.initState();

    NetworkMonitor.registerHandler(() {
      SyncWatchdog().notify();
    });
    NetworkMonitor.start();

    _bootstrapSession();
  }

  @override
  void dispose() {
    NetworkMonitor.stop();
    super.dispose();
  }

  Future<void> _bootstrapSession() async {
    setState(() => _bootstrapping = true);

    try {
      final dbUser = await DatabaseService.instance.getUser();

      if (dbUser == null) {
        debugPrint("BOOTSTRAP: Fetch profile + sekolah dari Supabase (first time)");
        final profile = await SupabaseService().getProfile();
        final sekolah = await SupabaseService().getSekolah();

        if (profile == null) {
          debugPrint("BOOTSTRAP ERROR: profile null");
          return;
        }
        if (sekolah == null) {
          debugPrint("BOOTSTRAP ERROR: sekolah null");
          return;
        }

        await DatabaseService.instance.saveUser(
          userId: profile['id'] as String,
          nip: (profile['nip'] as String?) ?? '',
          namaLengkap: (profile['nama_lengkap'] as String?) ?? 'Tanpa Nama',
          role: (profile['role'] as String?) ?? 'guru',
          sekolahId: profile['sekolah_id'] as String?,
        );

        await DatabaseService.instance.saveSekolah(
          sekolahId: sekolah['id'] as String,
          nama: sekolah['nama'] as String,
          lat: (sekolah['lat'] as num).toDouble(),
          lng: (sekolah['lng'] as num).toDouble(),
          radiusMeters: (sekolah['radius_meters'] as num).toDouble(),
        );

        debugPrint("BOOTSTRAP: Data tersimpan. "
            "user=${profile['nip']}, "
            "sekolah=${sekolah['nama']}, "
            "radius=${sekolah['radius_meters']}m");
      } else {
        debugPrint("BOOTSTRAP: User sudah ada (${dbUser['nama_lengkap']})");
      }

      await MobileFaceNetService().loadFromDatabase();

      if (mounted) setState(() => _bootstrapping = false);

      _refreshSekolahAndSync();

    } catch (e) {
      debugPrint("BOOTSTRAP ERROR: $e");
      if (mounted) setState(() => _bootstrapping = false);
    }
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
        debugPrint("BOOTSTRAP: sekolah di-refresh dari Supabase, "
            "radius=${sekolah['radius_meters']}m");
      }
    } catch (e) {
      debugPrint("BOOTSTRAP: refresh sekolah gagal (offline?) -> $e");
    }

    SyncService().syncAll().then((r) {
      debugPrint("BOOTSTRAP: sync result = $r");
      SyncWatchdog().notify();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_bootstrapping) {
      return const Scaffold(
        backgroundColor: AppColors.cream,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.cream,
      extendBody: true,
      body: IndexedStack(
        index: _currentIndex,
        children: [
          ProfilScreen(cameras: widget.cameras),
          StreamScreen(
            cameras: widget.cameras,
            isActive: _currentIndex == 1,
          ),
          const _RiwayatPlaceholder(),
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
}

/// Placeholder sementara untuk tab Riwayat.
/// Nanti diganti dengan layar riwayat absen + kalender.
class _RiwayatPlaceholder extends StatelessWidget {
  const _RiwayatPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppColors.cream,
      body: Center(
        child: Text(
          'Riwayat absen\n(segera hadir)',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.darkSlate),
        ),
      ),
    );
  }
}