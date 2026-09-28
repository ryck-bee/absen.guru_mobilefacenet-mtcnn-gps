import 'package:absensi_wajah/services/monotonic_clock.dart';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'screens/main_screen.dart';
import 'screens/login_screen.dart';
import 'services/model/mobilefacenet_service.dart';
import 'services/debug_logger.dart';
import 'config/supabase_config.dart';
import 'services/db/database_service.dart';

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Init logger
  await DebugLogger.instance.init();

  // 2. Override debugPrint
  final originalDebugPrint = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    DebugLogger.instance.append(message);
    originalDebugPrint(message, wrapWidth: wrapWidth);
  };

  debugPrint("=== App started ===");

  final up = await MonotonicClock.elapsedRealtimeMs();
  debugPrint("TEST MONOTONIC: uptime = $up ms");

  // 3a. Init Supabase
  try {
    await Supabase.initialize(
      url: SupabaseConfig.url,
      anonKey: SupabaseConfig.anonKey,
    );
    debugPrint("SUPABASE: Initialized");
  } catch (e) {
    debugPrint("SUPABASE ERROR: $e");
  }
  
  // 3b. Init SQLite lokal
  try {
    await DatabaseService.instance.init();
    debugPrint("DB: Initialized");
  } catch (e) {
    debugPrint("DB ERROR: $e");
  }

  // 4. Init kamera
  try {
    cameras = await availableCameras();
    debugPrint("Kamera tersedia: ${cameras.length}");
  } catch (e) {
    debugPrint("Gagal mengambil daftar kamera: $e");
  }

  // 5. Init model
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
      theme: ThemeData(
        fontFamily: 'Quicksand',
        primarySwatch: Colors.blue,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const AuthGate(),
    );
  }
}

/// Widget yang menentukan: tampil LoginScreen atau MainScreen
/// berdasarkan session Supabase.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: Supabase.instance.client.auth.onAuthStateChange,
      builder: (context, snapshot) {
        final session = Supabase.instance.client.auth.currentSession;

        if (session != null) {
          return MainScreen(cameras: cameras);
        }
        return const LoginScreen();
      },
    );
  }
}