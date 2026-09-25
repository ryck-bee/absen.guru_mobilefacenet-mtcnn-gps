import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'absen_section/stream_screen.dart';
import 'riwayat_section/face_list_screen.dart';
import 'riwayat_section/face_debug_screen.dart';
import 'profile_section/test_screen.dart';
import '../services/db/database_service.dart';
import '../services/db/supabase_service.dart';
import '../services/model/mobilefacenet_service.dart';
import '../services/db/sync_service.dart';
import '../services/monotonic_clock.dart';
import '../services/db/sync_service.dart';
import '../services/net-service/network_monitor.dart';
import '../services/net-service/sync_watchdog.dart';

class MainScreen extends StatefulWidget {
  final List<CameraDescription> cameras;

  const MainScreen({super.key, required this.cameras});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;
  bool _bootstrapping = false;

  @override
  void initState() {
    super.initState();

    // Dengar alarm koneksi dari Android.
    NetworkMonitor.registerHandler(() {
      // Internet baru tersedia → coba sync instan.
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
        debugPrint("BOOTSTRAP: Fetch profile + sekolah dari Supabase");
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

      // Minta izin notifikasi (Android 13+)
      await MonotonicClock.requestNotificationPermission();

      // Selalu load embedding dari SQLite ke memory
      await MobileFaceNetService().loadFromDatabase();

      // Trigger sync di background (tidak block UI)
      // Trigger sync di background (tidak block UI)
      SyncService().syncAll().then((r) {
        debugPrint("BOOTSTRAP: sync result = $r");
        // Cek apakah masih ada pending → aktifkan watchdog.
        SyncWatchdog().notify();
      });

    } catch (e) {
      debugPrint("BOOTSTRAP ERROR: $e");
    } finally {
      if (mounted) setState(() => _bootstrapping = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_bootstrapping) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: [
          StreamScreen(
            cameras: widget.cameras,
            isActive: _currentIndex == 0,
          ),
          FaceListScreen(
            isActive: _currentIndex == 1,
            onFinished: () {
              setState(() {
                _currentIndex = 0;
              });
            },
          ),
          const FaceDebugScreen(),
          TestScreen(cameras: widget.cameras),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        type: BottomNavigationBarType.fixed,
        currentIndex: _currentIndex,
        onTap: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.camera_front),
            label: "Absen",
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.person_add),
            label: "Daftar Wajah",
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.history),
            label: "Riwayat",
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.science),
            label: "Testing",
          ),
        ],
      ),
    );
  }
}