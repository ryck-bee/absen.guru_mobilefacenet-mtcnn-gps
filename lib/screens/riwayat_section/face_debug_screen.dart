import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import '../../services/model/mobilefacenet_service.dart';
import '../../services/debug_logger.dart';
import '../../services/db/supabase_service.dart';

class FaceDebugScreen extends StatefulWidget {
  const FaceDebugScreen({super.key});

  @override
  State<FaceDebugScreen> createState() => _FaceDebugScreenState();
}

class _FaceDebugScreenState extends State<FaceDebugScreen> {
  bool _sharing = false;

  Future<void> _logout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Logout"),
        content: const Text("Yakin mau logout? Kamu perlu login lagi untuk absen."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("Batal"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Logout", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await SupabaseService().signOut();
      // AuthGate otomatis redirect ke LoginScreen
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Logout gagal: $e")),
      );
    }
  }

  Future<void> _shareLogJson() async {
    setState(() => _sharing = true);
    try {
      final file = await DebugLogger.instance.exportJson();
      if (file == null) {
        _showSnack("Gagal export log.");
        return;
      }
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'application/json')],
          subject: 'Log Absensi Wajah (JSON)',
          text: 'Log export ${DateTime.now().toIso8601String()}',
        ),
      );
    } catch (e) {
      _showSnack("Error: $e");
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _shareLogText() async {
    setState(() => _sharing = true);
    try {
      final file = await DebugLogger.instance.exportText();
      if (file == null) {
        _showSnack("Gagal export log.");
        return;
      }
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'text/plain')],
          subject: 'Log Absensi Wajah (TXT)',
          text: 'Log export ${DateTime.now().toIso8601String()}',
        ),
      );
    } catch (e) {
      _showSnack("Error: $e");
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _clearLogs() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Hapus Semua Log"),
        content: const Text("Semua file log akan dihapus. Lanjutkan?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("Batal"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Hapus", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await DebugLogger.instance.clearAll();
    _showSnack("Log dihapus.");
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final registeredThumbs = MobileFaceNetService().registeredThumbnails;
    final history = MobileFaceNetService().matchHistory;

    return Scaffold(
      appBar: AppBar(
        title: const Text("Riwayat & Debug Wajah"),
        actions: [
          if (_sharing)
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else ...[
            IconButton(
              tooltip: "Share Log JSON",
              icon: const Icon(Icons.data_object),
              onPressed: _shareLogJson,
            ),
            IconButton(
              tooltip: "Share Log TXT",
              icon: const Icon(Icons.share),
              onPressed: _shareLogText,
            ),
          ],
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'clear_history') {
                MobileFaceNetService().clearMatchHistory();
                setState(() {});
              } else if (value == 'clear_logs') {
                await _clearLogs();
              } else if (value == 'logout') {
                await _logout();
              } else if (value == 'refresh') {
                setState(() {});
              }
            },
            itemBuilder: (ctx) => const [
              PopupMenuItem(value: 'refresh', child: Text("Refresh")),
              PopupMenuItem(
                value: 'clear_history',
                child: Text("Hapus Riwayat Percobaan"),
              ),
              PopupMenuItem(
                value: 'clear_logs',
                child: Text("Hapus Semua Log File"),
              ),
              PopupMenuDivider(),
              PopupMenuItem(
                value: 'logout',
                child: Text("Logout", style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            color: Colors.blue.shade50,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("Logger", style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(
                    "Status: ${DebugLogger.instance.isCapturing ? 'Aktif' : 'Mati'}",
                    style: const TextStyle(fontSize: 12),
                  ),
                  Text(
                    "File: ${DebugLogger.instance.activeFilePath ?? '-'}",
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    "Tips: tekan ikon { } untuk share JSON (untuk AI), "
                    "atau ikon share untuk TXT (untuk dibaca manusia).",
                    style: TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          Text(
            "Wajah Terdaftar",
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          const Text(
            "Thumbnail hasil crop+align MTCNN saat pendaftaran.",
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 12),
          if (registeredThumbs.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text("Belum ada wajah terdaftar."),
            )
          else
            ...registeredThumbs.entries.map((entry) {
              final userId = entry.key;
              final thumbs = entry.value;
              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "$userId (${thumbs.length} sampel)",
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 100,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: thumbs.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 8),
                          itemBuilder: (ctx, i) {
                            return ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.memory(
                                thumbs[i],
                                width: 100,
                                height: 100,
                                fit: BoxFit.cover,
                                gaplessPlayback: true,
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          const Divider(height: 32),
          Text(
            "Riwayat Percobaan Absen",
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          if (history.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text("Belum ada percobaan absen yang tercatat."),
            )
          else
            ...history.map((attempt) {
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.memory(
                      attempt.thumbnailPng,
                      width: 56,
                      height: 56,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                    ),
                  ),
                  title: Text(
                    attempt.isMatch
                        ? "Cocok: ${attempt.matchedName}"
                        : "Tidak dikenali",
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: attempt.isMatch ? Colors.green.shade700 : Colors.red.shade700,
                    ),
                  ),
                  subtitle: Text(
                    "Jarak: ${attempt.distance.toStringAsFixed(4)}  •  "
                    "mode: ${attempt.matchMode}  •  "
                    "${attempt.timestamp.hour.toString().padLeft(2, '0')}:"
                    "${attempt.timestamp.minute.toString().padLeft(2, '0')}:"
                    "${attempt.timestamp.second.toString().padLeft(2, '0')}",
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }
}