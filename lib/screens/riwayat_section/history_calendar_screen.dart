import 'package:flutter/material.dart';
import '../../config/app_colors.dart';
import '../../config/app_spacing.dart';
import '../../services/db/history_service.dart';
import '../../services/model/history_entry.dart';
import '../../services/db/database_service.dart';
import '../../widgets/app_spinner.dart';

/// Kalender bulanan riwayat absen.
///
/// Widget embedded — dipakai di dalam HistoryScreen (bukan halaman sendiri).
/// Tap tanggal → panggil [onDateSelected] ke parent.
class HistoryCalendarView extends StatefulWidget {
  final String userId;
  final DateTime initialMonth;
  final ValueChanged<DateTime> onDateSelected;

  const HistoryCalendarView({
    super.key,
    required this.userId,
    required this.initialMonth,
    required this.onDateSelected,
  });

  @override
  State<HistoryCalendarView> createState() => _HistoryCalendarViewState();
}

class _HistoryCalendarViewState extends State<HistoryCalendarView> {
  late DateTime _month;

  Map<String, HistoryStatus> _statusByDate = {};
  Set<String> _hariLiburSet = {};
  bool _loading = true;

  static const List<String> _dayLabels = [
    'Sen', 'Sel', 'Rab', 'Kam', 'Jum', 'Sab', 'Min'
  ];

  @override
  void initState() {
    super.initState();
    _month = DateTime(widget.initialMonth.year, widget.initialMonth.month, 1);
    _loadMonth();
  }

  Future<void> _loadMonth() async {
    // Load hari libur (sekali saja, cache kalau sudah ada).
    if (_hariLiburSet.isEmpty) {
      try {
        _hariLiburSet = await DatabaseService.instance.getHariLiburSet();
      } catch (_) {}
    }
    setState(() => _loading = true);
    try {
      final entries = await HistoryService().loadMonth(
        userId: widget.userId,
        month: _month,
      );
      final map = <String, HistoryStatus>{};
      for (final e in entries) {
        map[_dateKey(e.date)] = e.status;
      }
      if (mounted) {
        setState(() {
          _statusByDate = map;
          _loading = false;
        });
      }
    } catch (e) {
      debugPrint("CALENDAR: load error -> $e");
      if (mounted) setState(() => _loading = false);
    }
  }

  void _prevMonth() {
    setState(() => _month = DateTime(_month.year, _month.month - 1, 1));
    _loadMonth();
  }

  void _nextMonth() {
    setState(() => _month = DateTime(_month.year, _month.month + 1, 1));
    _loadMonth();
  }

  String _dateKey(DateTime d) {
    return '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }

  String _monthLabel(DateTime m) {
    const names = [
      'Januari', 'Februari', 'Maret', 'April', 'Mei', 'Juni',
      'Juli', 'Agustus', 'September', 'Oktober', 'November', 'Desember',
    ];
    return '${names[m.month - 1]} ${m.year}';
  }

  @override
  Widget build(BuildContext context) {
    final gutter = AppSpacing.horizontal(context);

    return Padding(
      padding: EdgeInsets.fromLTRB(gutter, 8, gutter, 120),
      child: Column(
        children: [
          _buildMonthHeader(),
          const SizedBox(height: 12),
          _buildDayLabels(),
          const SizedBox(height: 4),
          Expanded(
            child: _loading
                ? const Center(child: AppSpinner())
                : _buildGrid(),
          ),
        ],
      ),
    );
  }

  Widget _buildMonthHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        IconButton(
          onPressed: _prevMonth,
          icon: const Icon(Icons.chevron_left),
          color: AppColors.darkSlate,
        ),
        Text(
          _monthLabel(_month),
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: AppColors.darkSlate,
          ),
        ),
        IconButton(
          onPressed: _nextMonth,
          icon: const Icon(Icons.chevron_right),
          color: AppColors.darkSlate,
        ),
      ],
    );
  }

  Widget _buildDayLabels() {
    final compact = AppSpacing.isCompact(context);
    final fontSize = compact ? 11.0 : 13.0;

    return Row(
      children: _dayLabels.map((label) {
        return Expanded(
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.w600,
                color: AppColors.darkSlate.withValues(alpha: 0.6),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildGrid() {
    final compact = AppSpacing.isCompact(context);
    final aspectRatio = compact ? 0.9 : 0.85;
    final crossSpacing = compact ? 2.0 : 4.0;
    final mainSpacing = compact ? 4.0 : 6.0;

    final firstDay = DateTime(_month.year, _month.month, 1);
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;

    final leadingBlanks = firstDay.weekday - 1;
    final totalCells = leadingBlanks + daysInMonth;

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 7,
        mainAxisSpacing: mainSpacing,
        crossAxisSpacing: crossSpacing,
        childAspectRatio: aspectRatio,
      ),
      itemCount: totalCells,
      itemBuilder: (ctx, i) {
        if (i < leadingBlanks) return const SizedBox.shrink();
        final day = i - leadingBlanks + 1;
        return _buildDayCell(day);
      },
    );
  }

  Widget _buildDayCell(int day) {
    final compact = AppSpacing.isCompact(context);
    final fontSize = compact ? 13.0 : 15.0;

    final date = DateTime(_month.year, _month.month, day);
    final key = _dateKey(date);
    final status = _statusByDate[key];
    final today = _isToday(date);
    final isSunday = date.weekday == DateTime.sunday;
    final isHoliday = _hariLiburSet.contains(key);
    final isRedDay = isSunday || isHoliday;

    final fillColor = status == null ? null : _statusColor(status);
    final hasData = status != null;

    return GestureDetector(
      onTap: hasData ? () => widget.onDateSelected(date) : null,
      child: Container(
        decoration: BoxDecoration(
          color: fillColor ?? Colors.transparent,
          shape: BoxShape.circle,
          border: today
              ? Border.all(color: AppColors.tealMedium, width: 2)
              : null,
        ),
        child: Center(
          child: Text(
            day.toString(),
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w700,
              color: isRedDay
                  ? AppColors.redAlpa
                  : AppColors.darkSlate,
            ),
          ),
        ),
      ),
    );
  }

  bool _isToday(DateTime d) {
    final now = DateTime.now();
    return d.year == now.year && d.month == now.month && d.day == now.day;
  }

  Color _statusColor(HistoryStatus status) {
    switch (status) {
      case HistoryStatus.valid:
        return AppColors.softMint;
      case HistoryStatus.gagal:
        return const Color(0xFFF0B8B8);
      case HistoryStatus.izin:
      case HistoryStatus.sakit:
      case HistoryStatus.pending:
        return const Color(0xFFD5D0C8);
    }
  }
}