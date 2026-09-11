import 'dart:async';

import 'package:flutter/material.dart';

/// Loader callback. Given the inclusive [from] and [to] of a visible
/// month, returns the set of dates within that range that have a
/// journal entry. The dialog calls this on mount and again on every
/// month-nav; results are cached per month so re-paging doesn't
/// refetch.
typedef EntryDateLoader = Future<Set<DateTime>> Function(
  DateTime from,
  DateTime to,
);

/// Modal calendar with per-day "has-entry" red dots. Hand-rolled to
/// avoid a calendar package dependency. Returns the selected DateTime
/// via Navigator.pop, or null if cancelled / barrier-dismissed.
///
/// [initialDate] is selected on open; [firstDate] / [lastDate] clamp
/// month nav and grey out out-of-range day cells. [loadEntryDates]
/// resolves which days in a visible month get a red dot — it's
/// invoked once per fresh month; failures degrade silently to "no
/// dots" rather than blocking selection.
Future<DateTime?> showJournalCalendarPicker({
  required BuildContext context,
  required DateTime initialDate,
  required DateTime firstDate,
  required DateTime lastDate,
  required EntryDateLoader loadEntryDates,
}) {
  return showDialog<DateTime>(
    context: context,
    barrierColor: Colors.black54,
    builder: (ctx) => _JournalCalendarDialog(
      initialDate: initialDate,
      firstDate: firstDate,
      lastDate: lastDate,
      loadEntryDates: loadEntryDates,
    ),
  );
}

class _JournalCalendarDialog extends StatefulWidget {
  const _JournalCalendarDialog({
    required this.initialDate,
    required this.firstDate,
    required this.lastDate,
    required this.loadEntryDates,
  });
  final DateTime initialDate;
  final DateTime firstDate;
  final DateTime lastDate;
  final EntryDateLoader loadEntryDates;

  @override
  State<_JournalCalendarDialog> createState() => _JournalCalendarDialogState();
}

class _JournalCalendarDialogState extends State<_JournalCalendarDialog> {
  // 40px day cells with 4px gap → 7 cols + 6 gaps = 304px grid width.
  // Stored as doubles so layout calculations stay in one place.
  static const double _cellSize = 40;
  static const double _cellGap = 4;
  static const int _cols = 7;
  static const double _gridWidth = _cellSize * _cols + _cellGap * (_cols - 1);

  static const _monthNames = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];

  // 1st-of-month for the currently-visible month.
  late DateTime _visibleMonth;
  late DateTime _selected;

  // Per-month "days with entries" cache. Key is 'YYYY-MM', value is
  // the set of day numbers (1..31) in that month with an entry. An
  // empty set is a CACHED "we fetched and found none" — distinct
  // from missing, which means "not yet fetched".
  final Map<String, Set<int>> _entryDaysByMonth = {};
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _selected = _dateOnly(widget.initialDate);
    _visibleMonth = DateTime(_selected.year, _selected.month, 1);
    unawaited(_fetchMonth(_visibleMonth));
  }

  String _monthKey(DateTime m) =>
      '${m.year}-${m.month.toString().padLeft(2, '0')}';

  Future<void> _fetchMonth(DateTime monthStart) async {
    final key = _monthKey(monthStart);
    if (_entryDaysByMonth.containsKey(key)) return;
    setState(() => _loading = true);
    try {
      final lastDay = DateTime(monthStart.year, monthStart.month + 1, 0);
      final dates = await widget.loadEntryDates(monthStart, lastDay);
      if (!mounted) return;
      _entryDaysByMonth[key] = dates
          .where((d) =>
              d.year == monthStart.year && d.month == monthStart.month)
          .map((d) => d.day)
          .toSet();
    } catch (_) {
      // Calendar should still work if the fetch fails — just no dots.
      if (mounted) _entryDaysByMonth[key] = <int>{};
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _stepMonth(int delta) {
    final candidate =
        DateTime(_visibleMonth.year, _visibleMonth.month + delta, 1);
    setState(() => _visibleMonth = candidate);
    unawaited(_fetchMonth(candidate));
  }

  DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  bool _isToday(DateTime d) {
    final n = DateTime.now();
    return d.year == n.year && d.month == n.month && d.day == n.day;
  }

  bool _canStepBack() {
    final prev =
        DateTime(_visibleMonth.year, _visibleMonth.month - 1, 1);
    final firstMonth =
        DateTime(widget.firstDate.year, widget.firstDate.month, 1);
    return !prev.isBefore(firstMonth);
  }

  bool _canStepForward() {
    final next =
        DateTime(_visibleMonth.year, _visibleMonth.month + 1, 1);
    final lastMonth =
        DateTime(widget.lastDate.year, widget.lastDate.month, 1);
    return !next.isAfter(lastMonth);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF252525),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _monthHeader(),
            const SizedBox(height: 4),
            _weekdayHeader(),
            const SizedBox(height: 6),
            _dayGrid(),
            const SizedBox(height: 8),
            _footer(),
          ],
        ),
      ),
    );
  }

  Widget _monthHeader() {
    final canBack = _canStepBack();
    final canForward = _canStepForward();
    return SizedBox(
      width: _gridWidth,
      child: Row(
        children: [
          _navButton(
            icon: Icons.chevron_left,
            tooltip: 'Previous month',
            enabled: canBack,
            onTap: () => _stepMonth(-1),
          ),
          Expanded(
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${_monthNames[_visibleMonth.month - 1]} '
                    '${_visibleMonth.year}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Tiny spinner during a fresh month fetch so the
                  // user knows the dots are still coming.
                  if (_loading)
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white38,
                      ),
                    ),
                ],
              ),
            ),
          ),
          _navButton(
            icon: Icons.chevron_right,
            tooltip: 'Next month',
            enabled: canForward,
            onTap: () => _stepMonth(1),
          ),
        ],
      ),
    );
  }

  Widget _navButton({
    required IconData icon,
    required String tooltip,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return IconButton(
      icon: Icon(icon),
      color: Colors.white,
      disabledColor: Colors.white24,
      tooltip: tooltip,
      onPressed: enabled ? onTap : null,
    );
  }

  Widget _weekdayHeader() {
    // Sunday-start; matches DateTime.weekday % 7 leading-blank math
    // used in [_dayGrid].
    const labels = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];
    return SizedBox(
      width: _gridWidth,
      child: Row(
        children: [
          for (int i = 0; i < labels.length; i++) ...[
            if (i > 0) const SizedBox(width: _cellGap),
            SizedBox(
              width: _cellSize,
              child: Center(
                child: Text(
                  labels[i],
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _dayGrid() {
    final firstOfMonth = _visibleMonth;
    // DateTime.weekday: Mon=1..Sun=7. We want Sunday=0 column, so the
    // leading-blank count is weekday % 7.
    final leading = firstOfMonth.weekday % 7;
    final daysInMonth =
        DateTime(_visibleMonth.year, _visibleMonth.month + 1, 0).day;
    final entrySet =
        _entryDaysByMonth[_monthKey(_visibleMonth)] ?? const <int>{};

    return SizedBox(
      width: _gridWidth,
      child: GridView.count(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisCount: _cols,
        mainAxisSpacing: _cellGap,
        crossAxisSpacing: _cellGap,
        childAspectRatio: 1,
        children: List.generate(42, (i) {
          final dayNum = i - leading + 1;
          if (dayNum < 1 || dayNum > daysInMonth) {
            return const SizedBox.shrink();
          }
          return _dayCell(dayNum, entrySet.contains(dayNum));
        }),
      ),
    );
  }

  Widget _dayCell(int day, bool hasEntry) {
    final date = DateTime(_visibleMonth.year, _visibleMonth.month, day);
    final disabled =
        date.isBefore(widget.firstDate) || date.isAfter(widget.lastDate);
    final isSelected = date == _selected;
    final isToday = _isToday(date);

    return Material(
      color: Colors.transparent,
      child: InkResponse(
        onTap: disabled ? null : () => setState(() => _selected = date),
        radius: _cellSize * 0.5,
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isSelected ? const Color(0xFF2196F3) : null,
            border: !isSelected && isToday
                ? Border.all(color: const Color(0xFFF2B33D), width: 1.5)
                : null,
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Text(
                '$day',
                style: TextStyle(
                  color: disabled
                      ? Colors.white24
                      : isSelected
                          ? Colors.white
                          : Colors.white,
                  fontSize: 14,
                  fontWeight:
                      isSelected ? FontWeight.w700 : FontWeight.normal,
                ),
              ),
              // Red dot — the whole reason this picker exists. Hidden
              // when the day is selected (the blue circle already
              // says "this one"; a dot inside it is noise).
              if (hasEntry && !isSelected)
                const Positioned(
                  bottom: 4,
                  child: _EntryDot(),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _footer() {
    return SizedBox(
      width: _gridWidth,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Colors.white70),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, _selected),
            child: const Text(
              'OK',
              style: TextStyle(
                color: Color(0xFF2196F3),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EntryDot extends StatelessWidget {
  const _EntryDot();
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 4,
      height: 4,
      decoration: const BoxDecoration(
        color: Color(0xFFFF5F57),
        shape: BoxShape.circle,
      ),
    );
  }
}
