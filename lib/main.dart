import 'package:absensi_wajah/services/monotonic_clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:uuid/uuid.dart';
import 'screens/main_screen.dart';
import 'screens/login_screen.dart';
import 'screens/face_section/face_entry_screen.dart';
import 'services/model/mobilefacenet_service.dart';
import 'services/db/supabase_service.dart';
import 'services/debug_logger.dart';
import 'config/supabase_config.dart';
import 'config/app_colors.dart';
import 'services/db/database_service.dart';
import 'widgets/loading_overlay.dart';

List<CameraDescription> cameras = [];

// ============================================================
// GLOBAL DEVICE INFO
// ============================================================
String gDeviceId = '';
String gAndroidId = '';
String gDeviceModel = '';
String gDeviceBrand = '';
String gDeviceAndroid = '';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await DebugLogger.instance.init();

  final originalDebugPrint = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    DebugLogger.instance.append(message);
    originalDebugPrint(message, wrapWidth: wrapWidth);
  };

  debugPrint("=== App started ===");

  final up = await MonotonicClock.elapsedRealtimeMs();
  debugPrint("TEST MONOTONIC: uptime = $up ms");

  // Device info — sekali ambil
  try {
    final info = await DeviceInfoPlugin().androidInfo;
    gDeviceModel = info.model;
    gDeviceBrand = info.brand;
    gDeviceAndroid = info.version.release;
    gAndroidId = ''; // v13 tidak punya androidId — pakai fallback UUID di bawah

    debugPrint(
        "DEVICE: model=$gDeviceModel brand=$gDeviceBrand android=$gDeviceAndroid androidId=$gAndroidId");
  } catch (e) {
    debugPrint("DEVICE INFO ERROR: $e");
  }

  try {
    await Supabase.initialize(
      url: SupabaseConfig.url,
      anonKey: SupabaseConfig.anonKey,
    );
    debugPrint("SUPABASE: Initialized");
  } catch (e) {
    debugPrint("SUPABASE ERROR: $e");
  }

  try {
    await DatabaseService.instance.init();
    debugPrint("DB: Initialized");
  } catch (e) {
    debugPrint("DB ERROR: $e");
  }

  // Fallback: kalau androidId null (custom OS / AOSP), pakai UUID lokal.
  try {
    if (gAndroidId.isEmpty) {
      final existing = await DatabaseService.instance.getDeviceLocal();
      final savedId = existing?['android_id'] as String?;
      if (savedId != null && savedId.isNotEmpty) {
        gAndroidId = savedId;
        debugPrint("DEVICE: fallback androidId dari lokal = $gAndroidId");
      } else {
        gAndroidId = const Uuid().v4();
        await DatabaseService.instance.saveDeviceLocal(
          deviceId: null,
          androidId: gAndroidId,
          model: gDeviceModel,
          brand: gDeviceBrand,
          androidVersion: gDeviceAndroid,
          registered: false,
        );
        debugPrint("DEVICE: fallback androidId baru = $gAndroidId");
      }
    }
  } catch (e) {
    debugPrint("DEVICE FALLBACK ERROR: $e");
  }

  try {
    cameras = await availableCameras();
    debugPrint("Kamera tersedia: ${cameras.length}");
  } catch (e) {
    debugPrint("Gagal mengambil daftar kamera: $e");
  }

  await MobileFaceNetService().init();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Absensi Wajah',
      debugShowCheckedModeBanner: false,
      color: AppColors.cream,
      theme: ThemeData(
        fontFamily: 'Quicksand',
        useMaterial3: true,
        scaffoldBackgroundColor: AppColors.cream,
        colorScheme: const ColorScheme.light(
          primary: AppColors.tealMedium,
          onPrimary: Colors.white,
          secondary: AppColors.tealMedium,
          onSecondary: Colors.white,
          surface: AppColors.cream,
          onSurface: AppColors.darkSlate,
          error: AppColors.error,
          onError: Colors.white,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          foregroundColor: AppColors.darkSlate,
          elevation: 0,
          systemOverlayStyle: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: Brightness.dark,
            statusBarBrightness: Brightness.light,
          ),
        ),
        dialogTheme: const DialogThemeData(
          backgroundColor: AppColors.cream,
          surfaceTintColor: Colors.transparent,
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: AppColors.cream,
          surfaceTintColor: Colors.transparent,
        ),
        snackBarTheme: const SnackBarThemeData(
          backgroundColor: AppColors.darkSlate,
          contentTextStyle: TextStyle(color: Colors.white),
        ),
        cardTheme: const CardThemeData(
          color: AppColors.creamDark,
          surfaceTintColor: Colors.transparent,
        ),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return AppColors.tealMedium;
            }
            return null;
          }),
          trackColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return AppColors.tealMedium.withOpacity(0.5);
            }
            return null;
          }),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.tealMedium,
            foregroundColor: Colors.white,
            elevation: 0,
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.tealMedium,
            side: const BorderSide(color: AppColors.tealMedium, width: 1.5),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(foregroundColor: AppColors.tealMedium),
        ),
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: {
            TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
            TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          },
        ),
      ),
      builder: (context, child) {
        return LoadingOverlay(child: child ?? const SizedBox.shrink());
      },
      home: const AuthGate(),
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: Supabase.instance.client.auth.onAuthStateChange,
      builder: (context, snapshot) {
        final session = Supabase.instance.client.auth.currentSession;
        if (session != null) return const AuthRouter();
        return const LoginScreen();
      },
    );
  }
}

enum _AuthStage { loading, error, faceEntry, main }

class AuthRouter extends StatefulWidget {
  const AuthRouter({super.key});

  @override
  State<AuthRouter> createState() => _AuthRouterState();
}

class _AuthRouterState extends State<AuthRouter> {
  _AuthStage _stage = _AuthStage.loading;
  String? _errorMsg;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      var user = await DatabaseService.instance.getUser();

      if (user == null) {
        final profile = await SupabaseService().getProfile();
        final sekolah = await SupabaseService().getSekolah();

        if (profile == null || sekolah == null) {
          if (mounted) {
            setState(() {
              _stage = _AuthStage.error;
              _errorMsg = 'Data profil / sekolah tidak ditemukan di server.';
            });
            await loadingController.hide();
          }
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
        user = await DatabaseService.instance.getUser();
      }

      await MobileFaceNetService().loadFromDatabase();

      final userId = user?['user_id'] as String?;
      final hasFace =
          userId != null && MobileFaceNetService().hasUser(userId);

      if (!mounted) return;
      setState(() {
        _stage = hasFace ? _AuthStage.main : _AuthStage.faceEntry;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await loadingController.hide();
      });
    } catch (e) {
      debugPrint("AUTH ROUTER: bootstrap error -> $e");
      if (mounted) {
        setState(() {
          _stage = _AuthStage.error;
          _errorMsg = 'Gagal memuat data. Cek koneksi lalu coba lagi.';
        });
        await loadingController.hide();
      }
    }
  }

  Future<void> _retry() async {
    setState(() {
      _stage = _AuthStage.loading;
      _errorMsg = null;
    });
    loadingController.show();
    await _bootstrap();
  }

  Future<void> _logout() async {
    await SupabaseService().signOut();
    await DatabaseService.instance.clearAll();
    MobileFaceNetService().clearAllUsers();
  }

  void _onFaceEntryFinished() {
    loadingController.show();
    setState(() => _stage = _AuthStage.main);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await loadingController.hide();
    });
  }

  @override
  Widget build(BuildContext context) {
    switch (_stage) {
      case _AuthStage.loading:
        return const Scaffold(
          backgroundColor: AppColors.cream,
          body: Center(child: CircularProgressIndicator()),
        );

      case _AuthStage.error:
        return Scaffold(
          backgroundColor: AppColors.cream,
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _errorMsg ?? 'Terjadi kesalahan.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: AppColors.darkSlate,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 20),
                  ElevatedButton(
                    onPressed: _retry,
                    child: const Text('Coba Lagi'),
                  ),
                  TextButton(
                    onPressed: _logout,
                    child: const Text('Keluar'),
                  ),
                ],
              ),
            ),
          ),
        );

      case _AuthStage.faceEntry:
        return FaceEntryScreen(onFinished: _onFaceEntryFinished);

      case _AuthStage.main:
        return MainScreen(cameras: cameras);
    }
  }
}