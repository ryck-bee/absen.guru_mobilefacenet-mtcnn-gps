import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import '../../config/app_colors.dart';
import '../../config/app_spacing.dart';
import '../../services/db/database_service.dart';
import '../../services/db/supabase_service.dart';
import '../../services/model/mobilefacenet_service.dart';
import '../../widgets/loading_overlay.dart';
import 'test_screen.dart';
import '../face_section/face_entry_screen.dart';

class ProfilScreen extends StatefulWidget {
  final List<CameraDescription> cameras;

  const ProfilScreen({super.key, required this.cameras});

  @override
  State<ProfilScreen> createState() => _ProfilScreenState();
}

class _ProfilScreenState extends State<ProfilScreen> {
  String _nama = '-';
  String _nip = '-';
  String _sekolah = '-';
  int _wajahTerdaftar = 0;
  int _wajahDipelajari = 0;
  String _lastSync = '-';
  int _pendingCount = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final user = await DatabaseService.instance.getUser();
      final sekolah = await DatabaseService.instance.getSekolah();
      if (user == null) return;

      final userId = user['user_id'] as String;
      final svc = MobileFaceNetService();
      final terdaftar =
          svc.nonGlassesCountFor(userId) + svc.glassesCountFor(userId);
      final dipelajari =
          await DatabaseService.instance.countLearningEmbeddings(userId);
      final anchor = await DatabaseService.instance.getAnchor();

      int pending = 0;
      pending += await DatabaseService.instance.countPendingAttendance();
      pending += await DatabaseService.instance.countPendingEmbeddings();

      String lastSync = '-';
      if (anchor != null && anchor['updated_at'] != null) {
        final dt = DateTime.tryParse(anchor['updated_at'] as String);
        if (dt != null) {
          final diff = DateTime.now().difference(dt);
          if (diff.inMinutes < 60) {
            lastSync = '${diff.inMinutes} menit lalu';
          } else if (diff.inHours < 24) {
            lastSync = '${diff.inHours} jam lalu';
          } else {
            lastSync = '${diff.inDays} hari lalu';
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _nama = (user['nama_lengkap'] as String?) ?? '-';
        _nip = (user['nip'] as String?) ?? '-';
        _sekolah = (sekolah?['nama'] as String?) ?? '-';
        _wajahTerdaftar = terdaftar;
        _wajahDipelajari = dipelajari;
        _lastSync = lastSync;
        _pendingCount = pending;
      });
    } catch (e) {
      debugPrint("PROFILE: error -> $e");
    }
  }

  Future<void> _openFaceEntry() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FaceEntryScreen(onFinished: () => Navigator.pop(context)),
      ),
    );
    await _load();
  }

  void _openTest() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => TestScreen(cameras: widget.cameras)),
    );
  }

  Future<void> _logout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Keluar Akun'),
        content: const Text(
          'Keluar akan menghapus data wajah & absen di HP ini. Lanjutkan?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Keluar',
              style: TextStyle(color: AppColors.error),
            ),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    loadingController.show();
    await SupabaseService().signOut();
    await DatabaseService.instance.clearAll();
    MobileFaceNetService().clearAllUsers();
  }

  @override
  Widget build(BuildContext context) {
    final gutter = AppSpacing.horizontal(context);
    final compact = AppSpacing.isCompact(context);

    final padCard = compact ? 18.0 : 24.0;
    final gapCard = compact ? 18.0 : 28.0;
    final fontTitle = compact ? 17.0 : 20.0;
    final fontBody = compact ? 13.0 : 14.0;
    final fontButton = compact ? 13.0 : 14.0;
    final iconPerson = compact ? 40.0 : 52.0;
    final iconChevron = compact ? 20.0 : 22.0;
    final radius = compact ? 12.0 : 16.0;
    final buttonHeight = compact ? 52.0 : 64.0;
    final bodyBottomPad = compact ? 78.0 : 100.0;

    return Scaffold(
      backgroundColor: AppColors.cream,
      appBar: AppBar(
        title: const Text('Pengaturan'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: AppColors.darkSlate,
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(gutter, 16, gutter, 120),
        children: [
          _buildIdentitasCard(
            padCard: padCard,
            fontTitle: fontTitle,
            fontBody: fontBody,
            iconPerson: iconPerson,
            radius: radius,
          ),
          SizedBox(height: gapCard),
          _buildWajahCard(
            padCard: padCard,
            bodyBottomPad: bodyBottomPad,
            buttonHeight: buttonHeight,
            fontBody: fontBody,
            fontButton: fontButton,
            iconChevron: iconChevron,
            radius: radius,
          ),
          SizedBox(height: gapCard),
          _buildSistemCard(
            padCard: padCard,
            bodyBottomPad: bodyBottomPad,
            buttonHeight: buttonHeight,
            fontBody: fontBody,
            fontButton: fontButton,
            iconChevron: iconChevron,
            radius: radius,
          ),
        ],
      ),
    );
  }

  Widget _buildIdentitasCard({
    required double padCard,
    required double fontTitle,
    required double fontBody,
    required double iconPerson,
    required double radius,
  }) {
    return Container(
      padding: EdgeInsets.all(padCard),
      decoration: BoxDecoration(
        color: const Color(0xFFC5D9D3),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _nama,
                  style: TextStyle(
                    fontSize: fontTitle,
                    fontWeight: FontWeight.w700,
                    color: AppColors.darkSlate,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _sekolah,
                  style: TextStyle(
                    fontSize: fontBody,
                    color: AppColors.hurufSecondary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'NIP. $_nip',
                  style: TextStyle(
                    fontSize: fontBody,
                    color: AppColors.hurufSecondary,
                  ),
                ),
              ],
            ),
          ),
          Icon(Icons.person_outline, size: iconPerson, color: AppColors.darkSlate),
        ],
      ),
    );
  }

  Widget _buildWajahCard({
    required double padCard,
    required double bodyBottomPad,
    required double buttonHeight,
    required double fontBody,
    required double fontButton,
    required double iconChevron,
    required double radius,
  }) {
    return Stack(
      children: [
        Container(
          width: double.infinity,
          padding: EdgeInsets.fromLTRB(padCard, padCard, padCard, bodyBottomPad),
          decoration: BoxDecoration(
            color: const Color(0xFFCDD9D6),
            borderRadius: BorderRadius.circular(radius),
          ),
          child: Column(
            children: [
              Text(
                'Wajah Terdaftar : $_wajahTerdaftar',
                style: TextStyle(fontSize: fontBody, color: AppColors.darkSlate),
              ),
              const SizedBox(height: 6),
              Text(
                'Wajah Dipelajari : $_wajahDipelajari',
                style: TextStyle(fontSize: fontBody, color: AppColors.darkSlate),
              ),
            ],
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: GestureDetector(
            onTap: _openFaceEntry,
            behavior: HitTestBehavior.opaque,
            child: Container(
              height: buttonHeight,
              decoration: BoxDecoration(
                color: const Color(0xFFA4D5C9),
                borderRadius: BorderRadius.circular(radius),
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: padCard),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Daftar Wajah',
                      style: TextStyle(
                        fontSize: fontButton,
                        fontWeight: FontWeight.w700,
                        color: AppColors.darkSlate,
                      ),
                    ),
                    Icon(
                      Icons.chevron_right,
                      size: iconChevron,
                      color: AppColors.darkSlate,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSistemCard({
    required double padCard,
    required double bodyBottomPad,
    required double buttonHeight,
    required double fontBody,
    required double fontButton,
    required double iconChevron,
    required double radius,
  }) {
    return Stack(
      children: [
        Container(
          width: double.infinity,
          padding: EdgeInsets.fromLTRB(padCard, padCard, padCard, bodyBottomPad),
          decoration: BoxDecoration(
            color: const Color(0xFFD9D9D9),
            borderRadius: BorderRadius.circular(radius),
          ),
          child: Column(
            children: [
              Text(
                'Terakhir Sinkron : $_lastSync',
                style: TextStyle(fontSize: fontBody, color: AppColors.darkSlate),
              ),
              const SizedBox(height: 6),
              Text(
                'Data Pending : $_pendingCount',
                style: TextStyle(fontSize: fontBody, color: AppColors.darkSlate),
              ),
            ],
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: GestureDetector(
            onTap: _logout,
            behavior: HitTestBehavior.opaque,
            child: Container(
              height: buttonHeight,
              decoration: BoxDecoration(
                color: const Color(0xFFDB5F5C),
                borderRadius: BorderRadius.circular(radius),
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: padCard),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Keluar Akun',
                      style: TextStyle(
                        fontSize: fontButton,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    Icon(
                      Icons.chevron_right,
                      size: iconChevron,
                      color: Colors.white,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}