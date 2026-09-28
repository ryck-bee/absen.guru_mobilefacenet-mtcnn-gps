import 'package:flutter/material.dart';
import '../../config/app_colors.dart';
import '../../services/db/database_service.dart';
import '../../services/db/supabase_service.dart';
import 'test_screen.dart';
import '../riwayat_section/face_list_screen.dart';
import 'package:camera/camera.dart';

class ProfilScreen extends StatelessWidget {
  final List<CameraDescription> cameras;

  const ProfilScreen({super.key, required this.cameras});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>?>(
      future: DatabaseService.instance.getUser(),
      builder: (context, snapshot) {
        final user = snapshot.data;
        final nama = (user?['nama_lengkap'] as String?) ?? '-';
        final nip = (user?['nip'] as String?) ?? '-';
        final role = (user?['role'] as String?) ?? '-';

        return Scaffold(
          backgroundColor: AppColors.cream,
          appBar: AppBar(
            title: const Text('Profil'),
            backgroundColor: AppColors.cream,
            elevation: 0,
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const SizedBox(height: 8),
              Center(
                child: Column(
                  children: [
                    const CircleAvatar(
                      radius: 40,
                      backgroundColor: AppColors.tealMedium,
                      child: Icon(Icons.person, size: 48, color: Colors.white),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      nama,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: AppColors.darkSlate,
                      ),
                    ),
                    Text(
                      'NIP: $nip',
                      style: TextStyle(color: Colors.grey.shade700),
                    ),
                    Text(
                      'Role: $role',
                      style: TextStyle(color: Colors.grey.shade700),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.person_add, color: AppColors.tealMedium),
                title: const Text('Daftar Wajah'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => FaceListScreen(
                        isActive: true,
                        onFinished: () => Navigator.pop(context),
                      ),
                    ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.science, color: AppColors.tealMedium),
                title: const Text('Testing'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => TestScreen(cameras: cameras),
                    ),
                  );
                },
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.logout, color: AppColors.error),
                title: const Text(
                  'Logout',
                  style: TextStyle(color: AppColors.error),
                ),
                onTap: () async {
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Logout'),
                      content: const Text('Yakin mau logout?'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Batal'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text(
                            'Logout',
                            style: TextStyle(color: AppColors.error),
                          ),
                        ),
                      ],
                    ),
                  );
                  if (confirm == true) {
                    await SupabaseService().signOut();
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }
}