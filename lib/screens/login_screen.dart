import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import '../config/app_colors.dart';
import '../config/app_spacing.dart';
import '../services/db/supabase_service.dart';
import '../widgets/loading_overlay.dart';
import '../widgets/app_spinner.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

enum _PermStatus { checking, granted, denied }

class _LoginScreenState extends State<LoginScreen> {
  final _nipController = TextEditingController();
  final _pwController = TextEditingController();
  final _service = SupabaseService();

  bool _loading = false;
  bool _error = false;
  bool _obscurePw = true;
  String? _errorMessage;

  _PermStatus _permStatus = _PermStatus.checking;

  @override
  void initState() {
    super.initState();
    _checkPermissions();
    loadingController.hide();
  }

  Future<void> _checkPermissions() async {
    setState(() => _permStatus = _PermStatus.checking);

    final results = await [
      Permission.camera,
      Permission.locationWhenInUse,
      Permission.notification,
    ].request();

    final allGranted = results.values.every((s) => s.isGranted);

    if (!mounted) return;
    setState(() {
      _permStatus = allGranted ? _PermStatus.granted : _PermStatus.denied;
    });
  }

  Future<void> _openAppSettings() async {
    await openAppSettings();
    await Future.delayed(const Duration(milliseconds: 500));
    if (mounted) await _checkPermissions();
  }

  Future<void> _login() async {
    if (_loading) return;
    if (_permStatus != _PermStatus.granted) return;

    setState(() {
      _loading = true;
      _error = false;
      _errorMessage = null;
    });

    try {
      loadingController.show();
      await _service.signIn(
        identifier: _nipController.text,
        password: _pwController.text,
      );
      // Login sukses → trigger dialog "Simpan password?" di Android
      TextInput.finishAutofillContext();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = true;
          _errorMessage = _parseError(e);
        });
      }
      await loadingController.hide();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _parseError(dynamic e) {
    final msg = e.toString().toLowerCase();
    if (msg.contains('invalid') ||
        msg.contains('credential') ||
        msg.contains('password')) {
      return 'NIP atau Password salah!';
    }
    if (msg.contains('network') ||
        msg.contains('socket') ||
        msg.contains('connection')) {
      return 'Tidak ada koneksi internet.';
    }
    return 'Login gagal. Coba lagi.';
  }

  @override
  Widget build(BuildContext context) {
    final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;
    final keyboardOpen = keyboardHeight > 0;
    final smallShift = keyboardOpen ? 20.0 : 0.0;
    final bigShift = keyboardOpen ? 50.0 : 0.0;
    final gutter = AppSpacing.horizontal(context);

    return Scaffold(
      backgroundColor: AppColors.cream,
      resizeToAvoidBottomInset: false,
      body: Stack(
        fit: StackFit.expand,
        clipBehavior: Clip.none,
        children: [
          AnimatedPositioned(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeInOut,
            left: -60,
            bottom: 220 + smallShift,
            child: _blob(size: 200, color: const Color(0xFFDCC0CA)),
          ),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeInOut,
            right: -70,
            bottom: -20 + bigShift,
            child: _blob(size: 420, color: const Color(0xFFDCC0CA)),
          ),
          Padding(
            padding: EdgeInsets.only(bottom: keyboardHeight),
            child: SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(gutter, 24, gutter, 24),
                child: Center(
                  child: SingleChildScrollView(
                    child: AutofillGroup(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (_error && _errorMessage != null) ...[
                            Text(
                              _errorMessage!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: AppColors.error,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 16),
                          ],
                          const Text(
                            'Selamat Datang!',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 34,
                              fontWeight: FontWeight.w700,
                              color: AppColors.darkSlate,
                              height: 1.15,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Silahkan masukkan NIP dan password\nyang sudah di sediakan!',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 14,
                              color: AppColors.darkSlate.withValues(alpha: 0.7),
                              height: 1.4,
                            ),
                          ),
                          const SizedBox(height: 56),
                          _buildField(
                            controller: _nipController,
                            label: 'NIP',
                            error: _error,
                            autofillHints: const [AutofillHints.username],
                            textInputAction: TextInputAction.next,
                          ),
                          const SizedBox(height: 28),
                          _buildPasswordField(),
                          const SizedBox(height: 40),
                          _buildPermissionState(),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPasswordField() {
    final lineColor = _error ? AppColors.error : AppColors.darkSlate;

    return TextField(
      controller: _pwController,
      obscureText: _obscurePw,
      enabled: !_loading,
      autofillHints: const [AutofillHints.password],
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => _login(),
      style: const TextStyle(
        color: AppColors.darkSlate,
        fontSize: 16,
      ),
      decoration: InputDecoration(
        labelText: 'Password',
        labelStyle: TextStyle(
          color: lineColor,
          fontSize: 14,
        ),
        floatingLabelStyle: TextStyle(
          color: lineColor,
          fontWeight: FontWeight.w600,
        ),
        suffixIcon: IconButton(
          icon: Icon(
            _obscurePw ? Icons.visibility_off : Icons.visibility,
            color: AppColors.hurufSecondary,
            size: 40,
          ),
          onPressed: () => setState(() => _obscurePw = !_obscurePw),
        ),
        enabledBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: lineColor, width: 1.5),
        ),
        focusedBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: lineColor, width: 2),
        ),
        disabledBorder: UnderlineInputBorder(
          borderSide: BorderSide(
            color: lineColor.withValues(alpha: 0.4),
            width: 1.5,
          ),
        ),
      ),
    );
  }

  Widget _buildPermissionState() {
    switch (_permStatus) {
      case _PermStatus.checking:
        return const Column(
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: AppSpinner(
                size: 26,
                color: AppColors.tealMedium,
              ),
            ),
            SizedBox(height: 12),
            Text(
              'Menyiapkan izin...',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: AppColors.hurufSecondary,
              ),
            ),
          ],
        );

      case _PermStatus.denied:
        return Column(
          children: [
            const Text(
              'Aplikasi butuh izin Kamera, Lokasi, dan Notifikasi\nuntuk berfungsi.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: AppColors.error,
                fontWeight: FontWeight.w600,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            Center(
              child: SizedBox(
                width: 240,
                height: 52,
                child: ElevatedButton(
                  onPressed: _openAppSettings,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.maroon,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text(
                    'Buka Pengaturan HP',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );

      case _PermStatus.granted:
        return Center(
          child: SizedBox(
            width: 240,
            height: 52,
            child: ElevatedButton(
              onPressed: _loading ? null : _login,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.tealMedium,
                foregroundColor: Colors.white,
                disabledBackgroundColor:
                    AppColors.tealMedium.withValues(alpha: 0.5),
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: _loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: AppSpinner(
                        size: 26,
                        color: Colors.white,
                      ),
                    )
                  : const Text(
                      'Login',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
            ),
          ),
        );
    }
  }

  Widget _blob({required double size, required Color color}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
    );
  }

  Widget _buildField({
    required TextEditingController controller,
    required String label,
    bool obscure = false,
    bool error = false,
    ValueChanged<String>? onSubmitted,
    Iterable<String>? autofillHints,
    TextInputAction? textInputAction,
  }) {
    final lineColor = error ? AppColors.error : AppColors.darkSlate;

    return TextField(
      controller: controller,
      obscureText: obscure,
      enabled: !_loading,
      onSubmitted: onSubmitted,
      autofillHints: autofillHints,
      textInputAction: textInputAction,
      style: const TextStyle(
        color: AppColors.darkSlate,
        fontSize: 16,
      ),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(
          color: lineColor,
          fontSize: 14,
        ),
        floatingLabelStyle: TextStyle(
          color: lineColor,
          fontWeight: FontWeight.w600,
        ),
        enabledBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: lineColor, width: 1.5),
        ),
        focusedBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: lineColor, width: 2),
        ),
        disabledBorder: UnderlineInputBorder(
          borderSide: BorderSide(
            color: lineColor.withValues(alpha: 0.4),
            width: 1.5,
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _nipController.dispose();
    _pwController.dispose();
    super.dispose();
  }
}