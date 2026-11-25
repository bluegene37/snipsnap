// Gene - Nov, 25, 2026: Added date-grouping and 7-day history cutoff utilities for screenshot history tray and archive browser.
import '../models/capture_item.dart';

/// Number of calendar days (inclusive of today) shown in the bottom tray.
const int kRecentHistoryDays = 7;

const List<String> _shortMonths = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

const List<String> _shortWeekdays = <String>[
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
];

/// Returns the local midnight [DateTime] for [dt]'s calendar day.
DateTime calendarDay(DateTime dt) {
  final local = dt.toLocal();
  return DateTime(local.year, local.month, local.day);
}

/// Returns the inclusive local start-of-day cutoff covering [kRecentHistoryDays]
/// calendar days (today plus the previous 6 days).
DateTime recentHistoryCutoff([DateTime? now]) {
  final today = calendarDay(now ?? DateTime.now());
  return today.subtract(const Duration(days: kRecentHistoryDays - 1));
}

/// Stable `YYYY-MM-DD` key for a local calendar day.
String formatDateGroupKey(DateTime day) {
  final d = calendarDay(day);
  final y = d.year.toString().padLeft(4, '0');
  final m = d.month.toString().padLeft(2, '0');
  final dayStr = d.day.toString().padLeft(2, '0');
  return '$y-$m-$dayStr';
}

String _monthDay(DateTime d) => '${_shortMonths[d.month - 1]} ${d.day}';

/// Compact label for horizontal tray date rails (e.g. `Today`, `Yesterday`,
/// `Nov 23`, `Nov 23, 2025`).
String formatDateGroupShortLabel(DateTime day, {DateTime? now}) {
  final d = calendarDay(day);
  final today = calendarDay(now ?? DateTime.now());
  final diff = today.difference(d).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  if (d.year == today.year) return _monthDay(d);
  return '${_monthDay(d)}, ${d.year}';
}

/// Secondary label under [formatDateGroupShortLabel] on tray date rails.
String formatDateGroupSubLabel(DateTime day, {DateTime? now}) {
  final d = calendarDay(day);
  final today = calendarDay(now ?? DateTime.now());
  final diff = today.difference(d).inDays;
  if (diff == 0 || diff == 1) return _monthDay(d);
  return _shortWeekdays[d.weekday - 1];
}

/// Rich section header label for the date-grouped history dialog.
String formatDateGroupLongLabel(DateTime day, {DateTime? now}) {
  final d = calendarDay(day);
  final today = calendarDay(now ?? DateTime.now());
  final diff = today.difference(d).inDays;
  if (diff == 0) return 'Today · ${_monthDay(d)}';
  if (diff == 1) return 'Yesterday · ${_monthDay(d)}';
  final weekday = _shortWeekdays[d.weekday - 1];
  if (d.year == today.year) return '$weekday, ${_monthDay(d)}';
  return '$weekday, ${_monthDay(d)}, ${d.year}';
}

/// Immutable group of captures sharing one local calendar day.
class CaptureDateGroup {
  final DateTime day;
  final String key;
  final String shortLabel;
  final String subLabel;
  final String longLabel;
  final List<CaptureItem> items;

  const CaptureDateGroup({
    required this.day,
    required this.key,
    required this.shortLabel,
    required this.subLabel,
    required this.longLabel,
    required this.items,
  });
}

/// Groups [items] by local calendar day, ordered newest day first while
/// preserving item order within each day.
List<CaptureDateGroup> groupCapturesByDate(
  List<CaptureItem> items, {
  DateTime? now,
}) {
  if (items.isEmpty) return const <CaptureDateGroup>[];

  final buckets = <DateTime, List<CaptureItem>>{};
  for (final item in items) {
    final day = calendarDay(item.createdAt);
    buckets.putIfAbsent(day, () => <CaptureItem>[]).add(item);
  }

  final sortedDays = buckets.keys.toList()..sort((a, b) => b.compareTo(a));
  return [
    for (final day in sortedDays)
      CaptureDateGroup(
        day: day,
        key: formatDateGroupKey(day),
        shortLabel: formatDateGroupShortLabel(day, now: now),
        subLabel: formatDateGroupSubLabel(day, now: now),
        longLabel: formatDateGroupLongLabel(day, now: now),
        items: List<CaptureItem>.unmodifiable(buckets[day]!),
      ),
  ];
}
