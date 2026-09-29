import 'dart:io';
import 'package:flutter/material.dart';
import '../../config/app_colors.dart';
import '../../config/app_spacing.dart';
import '../../services/db/database_service.dart';
import '../../services/db/history_service.dart';
import '../../services/db/sync_service.dart';
import '../../services/model/history_entry.dart';
import 'history_calendar_screen.dart';

final GlobalKey<HistoryScreenState> historyScreenKey =
    GlobalKey<HistoryScreenState>();

class HistoryScreen extends StatefulWidget {
  final DateTime? initialExpandDate;

  const HistoryScreen({
    super.key,
    this.initialExpandDate,
  });

  @override
  State<HistoryScreen> createState() => HistoryScreenState();
}

class HistoryScreenState extends State<HistoryScreen> {
  final _scrollController = ScrollController();
  final Map<String, GlobalKey> _cardKeys = {};

  List<HistoryEntry> _entries = [];
  DateTime _month = DateTime.now();
  bool _loading = true;
  bool _isOnline = false;
  String? _userId;

  final Set<String> _expandedDates = {};

  @override
  void initState() {
    super.initState();
    if (widget.initialExpandDate != null) {
      _expandedDates.add(_dateKey(widget.initialExpandDate!));
    }
    _init();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    DatabaseService.instance.cleanupExpiredPending().catchError((_) => 0);

    final user = await DatabaseService.instance.getUser();
    if (user == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    _userId = user['user_id'] as String;

    await _checkOnline();
    await _load();

    if (widget.initialExpandDate != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToDate(widget.initialExpandDate!);
      });
    }
  }

  Future<void> _checkOnline() async {
    final online = await SyncService().isServerReachable();
    if (mounted) setState(() => _isOnline = online);
  }

  Future<void> _load() async {
    if (_userId == null) return;
    if (mounted) setState(() => _loading = true);
    try {
      final entries = await HistoryService().loadMonth(
        userId: _userId!,
        month: _month,
      );
      if (mounted) {
        setState(() {
          _entries = entries;
          _loading = false;
        });
      }
    } catch (e) {
      debugPrint("HISTORY: load error -> $e");
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      await SyncService().syncAll();
    } catch (e) {
      debugPrint("HISTORY: sync error -> $e");
    }
    await _checkOnline();
    await _load();
  }

  void _toggleExpand(String dateKey) {
    setState(() {
      if (_expandedDates.contains(dateKey)) {
        _expandedDates.remove(dateKey);
      } else {
        _expandedDates.add(dateKey);
      }
    });
  }

  void _scrollToDate(DateTime date) {
    final key = _cardKeys[_dateKey(date)];
    if (key == null) return;
    final ctx = key.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOutCubic,
      alignment: 0.3,
    );
  }

  bool get showCalendar => _showCalendar;
  bool _showCalendar = false;

  void toggleCalendarFromParent() {
    setState(() => _showCalendar = !_showCalendar);
  }

  Future<void> _onDatePicked(DateTime picked) async {
    setState(() => _showCalendar = false);

    final bedaBulan =
        picked.year != _month.year || picked.month != _month.month;
    if (bedaBulan) {
      setState(() {
        _month = DateTime(picked.year, picked.month, 1);
      });
      await _load();
    }

    setState(() {
      _expandedDates.add(_dateKey(picked));
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToDate(picked);
    });
  }

  String _dateKey(DateTime d) {
    return '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.cream,
      appBar: AppBar(
        title: const Text('Riwayat Absen'),
        backgroundColor: AppColors.cream,
        elevation: 0,
        foregroundColor: AppColors.darkSlate,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: _isOnline ? AppColors.success : AppColors.error,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                InkWell(
                  onTap: _refresh,
                  child: const Icon(Icons.refresh, color: AppColors.darkSlate),
                ),
              ],
            ),
          ),
        ],
      ),
      body: IndexedStack(
        index: _showCalendar ? 1 : 0,
        sizing: StackFit.expand,
        children: [
          _buildBody(),
          _userId == null
              ? const SizedBox.shrink()
              : HistoryCalendarView(
                  userId: _userId!,
                  initialMonth: _month,
                  onDateSelected: _onDatePicked,
                ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_userId == null) {
      return const Center(
        child: Text(
          'User tidak ditemukan.\nSilakan login ulang.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.darkSlate),
        ),
      );
    }
    if (_entries.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Belum ada riwayat absen bulan ini.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.greyLibur),
          ),
        ),
      );
    }

    final gutter = AppSpacing.horizontal(context);
    return ListView.builder(
      controller: _scrollController,
      padding: EdgeInsets.fromLTRB(gutter, 12, gutter, 96),
      itemCount: _entries.length,
      itemBuilder: (ctx, i) {
        final entry = _entries[i];
        final key = _dateKey(entry.date);
        _cardKeys[key] ??= GlobalKey();
        return Padding(
          key: _cardKeys[key],
          padding: const EdgeInsets.only(bottom: 12),
          child: HistoryCard(
            entry: entry,
            expanded: _expandedDates.contains(key),
            onTap: () => _toggleExpand(key),
          ),
        );
      },
    );
  }
}

// ============================================================
// CARD SATU HARI
// ============================================================
class HistoryCard extends StatefulWidget {
  final HistoryEntry entry;
  final bool expanded;
  final VoidCallback onTap;

  const HistoryCard({
    super.key,
    required this.entry,
    required this.expanded,
    required this.onTap,
  });

  @override
  State<HistoryCard> createState() => _HistoryCardState();
}

class _HistoryCardState extends State<HistoryCard>
    with SingleTickerProviderStateMixin {
  static const _animDuration = Duration(milliseconds: 260);

  late final AnimationController _controller;
  late final Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: _animDuration,
      value: widget.expanded ? 1.0 : 0.0,
    );
    _animation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void didUpdateWidget(covariant HistoryCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expanded != oldWidget.expanded) {
      if (widget.expanded) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Color get _cardColor {
    switch (widget.entry.status) {
      case HistoryStatus.valid:
        return AppColors.tealMedium;
      case HistoryStatus.pending:
        return const Color(0xFF4A4A4A);
      case HistoryStatus.gagal:
      case HistoryStatus.izin:
      case HistoryStatus.sakit:
        return AppColors.maroon;
    }
  }

  String get _title {
    switch (widget.entry.status) {
      case HistoryStatus.valid:
        return 'Absen Valid';
      case HistoryStatus.pending:
        return 'Absen Pending';
      case HistoryStatus.gagal:
        return 'Absen Gagal';
      case HistoryStatus.izin:
        return 'Izin';
      case HistoryStatus.sakit:
        return 'Sakit';
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _cardColor,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.12),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildThumbnail(),
            const SizedBox(width: 12),
            Expanded(child: _buildInfo()),
          ],
        ),
      ),
    );
  }

  Widget _buildThumbnail() {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, _) {
        final t = _animation.value;
        final w = 48 + (80 - 48) * t;
        final h = 48 + (107 - 48) * t;
        return SizedBox(
          width: w,
          height: h,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: _buildThumbnailContent(),
          ),
        );
      },
    );
  }

  Widget _buildInfo() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Flexible(
              child: Text(
                _title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              _formatDateShort(widget.entry.date),
              style: TextStyle(
                color: Colors.white.withOpacity(0.8),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        _buildExtras(),
      ],
    );
  }

  Widget _buildExtras() {
    final entry = widget.entry;
    final rows = <Widget>[];

    if (entry.recordedAt != null) {
      rows.add(_infoRow('Jam', _formatTime(entry.recordedAt!)));
    }
    if (entry.status == HistoryStatus.pending && entry.expiresAt != null) {
      rows.add(_infoRow('Kadaluarsa', _formatDateShort(entry.expiresAt!)));
    }
    if (entry.distanceMeters != null) {
      rows.add(_infoRow('Jarak GPS', '${entry.distanceMeters!.round()} m'));
    }
    if (entry.matchDistance != null) {
      rows.add(_infoRow('Match', entry.matchDistance!.toStringAsFixed(4)));
    }
    if (entry.failedCount > 0) {
      rows.add(_infoRow('Percobaan gagal', '${entry.failedCount}×'));
    }
    if (entry.status == HistoryStatus.pending) {
      rows.add(Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Text(
          'Diharapkan mencari koneksi internet sebelum kadaluarsa.',
          style: TextStyle(
            color: Colors.white.withOpacity(0.7),
            fontSize: 11,
            fontStyle: FontStyle.italic,
          ),
        ),
      ));
    }

    if (rows.isEmpty) return const SizedBox.shrink();

    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return ClipRect(
          child: Align(
            alignment: Alignment.topLeft,
            heightFactor: _animation.value,
            child: child,
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: rows,
        ),
      ),
    );
  }

  Widget _buildThumbnailContent() {
    final path = widget.entry.photoPath;
    if (path != null) {
      final file = File(path);
      if (file.existsSync()) {
        return Image.file(
          file,
          fit: BoxFit.cover,
          alignment: Alignment.center,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => _buildEmptyThumbnail(),
        );
      }
    }
    return _buildEmptyThumbnail();
  }

  Widget _buildEmptyThumbnail() {
    return Container(
      color: Colors.black.withOpacity(0.25),
      child: const Center(
        child: Icon(
          Icons.person_off,
          color: Colors.white54,
          size: 24,
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withOpacity(0.75),
              fontSize: 12,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  String _formatDateShort(DateTime d) {
    final yy = (d.year % 100).toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '$dd/$mm/$yy';
  }

  String _formatTime(DateTime d) {
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }
}