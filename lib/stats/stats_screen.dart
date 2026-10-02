import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/database.dart';
import '../data/library.dart';
import '../library/book_cover.dart';
import '../theme/tokens.dart';
import 'reading_stats.dart';
import 'recap_card.dart';

final sessionsProvider = StreamProvider<List<ReadingSession>>((ref) => ref.watch(databaseProvider).watchSessions());

enum _Range { week, month, year, all, custom }

/// Time read, pages, streaks and books, for a week, month, year, all time or any dates.
class StatsScreen extends ConsumerStatefulWidget {
  const StatsScreen({super.key});

  @override
  ConsumerState<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends ConsumerState<StatsScreen> {
  _Range _range = _Range.month;
  DateTimeRange? _custom;

  StatsPeriod _period(List<ReadingSession> sessions, DateTime now) => switch (_range) {
    _Range.week => StatsPeriod.week(now),
    _Range.month => StatsPeriod.month(now),
    _Range.year => StatsPeriod.year(now),
    _Range.all => StatsPeriod.allTime(
      sessions.isEmpty ? now : sessions.map((s) => s.startedAt).reduce((a, b) => a.isBefore(b) ? a : b),
      now,
    ),
    _Range.custom => StatsPeriod.range(_custom!.start, _custom!.end),
  };

  Future<void> _pickDates() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: now,
      initialDateRange: _custom ?? DateTimeRange(start: now.subtract(const Duration(days: 13)), end: now),
    );
    if (picked != null) {
      setState(() {
        _custom = picked;
        _range = _Range.custom;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final sessions = ref.watch(sessionsProvider).value ?? const <ReadingSession>[];
    final books = ref.watch(allBooksProvider).value ?? const <String, Book>{};
    final now = DateTime.now();
    final period = _period(sessions, now);
    final stats = ReadingStats.of(sessions, books.values.toList(), period, now: now);
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    Widget rangeChip(String label, _Range range, {VoidCallback? onTap}) => Padding(
      padding: const EdgeInsets.only(right: Space.sm),
      child: ChoiceChip(
        label: Text(label),
        selected: _range == range,
        onSelected: (_) => onTap != null ? onTap() : setState(() => _range = range),
      ),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Your reading')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xxxl),
        children: [
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Space.gutter, vertical: Space.xs),
              children: [
                rangeChip('This week', _Range.week),
                rangeChip('This month', _Range.month),
                rangeChip('This year', _Range.year),
                rangeChip('All time', _Range.all),
                rangeChip(_range == _Range.custom ? period.label : 'Choose dates…', _Range.custom, onTap: _pickDates),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
            child: Text(period.label, style: text.headlineMedium),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
            child: GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: Space.sm,
              crossAxisSpacing: Space.sm,
              childAspectRatio: 1.55,
              children: [
                _Figure(value: formatDuration(stats.seconds), label: 'reading', icon: Icons.schedule),
                _Figure(value: '${stats.pages}', label: stats.pages == 1 ? 'page turned' : 'pages turned', icon: Icons.auto_stories_outlined),
                _Figure(
                  value: '${stats.currentStreak} ${stats.currentStreak == 1 ? 'day' : 'days'}',
                  label: 'streak now · best ${stats.bestStreak}',
                  icon: Icons.local_fire_department_outlined,
                  accent: stats.currentStreak > 0,
                ),
                _Figure(value: '${stats.finished.length}', label: stats.finished.length == 1 ? 'book finished' : 'books finished', icon: Icons.task_alt),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
            child: Text(
              [
                'Read on ${stats.daysRead} of ${math.min(period.days, StatsPeriod.day(now).difference(period.from).inDays + 1).clamp(1, 100000)} days',
                if (stats.sessions > 0) '${stats.sessions} ${stats.sessions == 1 ? 'sitting' : 'sittings'}',
                if (stats.longestSession > 0) 'longest ${formatDuration(stats.longestSession)}',
              ].join(' · '),
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: Space.lg),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            child: SizedBox(height: 180, child: ReadingChart(stats: stats, now: now)),
          ),
          if (stats.topBooks.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, Space.xl, Space.gutter, Space.sm),
              child: Text('BOOKS', style: text.labelSmall),
            ),
            for (final id in stats.topBooks)
              if (books[id] case final book?)
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: Space.gutter),
                  leading: BookCover(book: book, width: 36),
                  title: Text(book.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    [
                      formatDuration(stats.perBook[id]!),
                      if (stats.finished.any((b) => b.id == id)) 'finished',
                    ].join(' · '),
                  ),
                  onTap: () => context.push('/book/$id'),
                ),
          ],
          if (sessions.isEmpty)
            Padding(
              padding: const EdgeInsets.all(Space.gutter),
              child: Text(
                'Your reading time is counted while you turn pages. Stats and streaks appear after your next sitting.',
                style: text.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          const SizedBox(height: Space.xl),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            child: FilledButton.icon(
              icon: const Icon(Icons.auto_awesome_outlined),
              label: Text('Share a recap of ${period.label.toLowerCase().startsWith('this') ? period.label.toLowerCase() : period.label}'),
              onPressed: stats.seconds == 0 && stats.finished.isEmpty ? null : () => showRecapSheet(context, stats, books),
            ),
          ),
        ],
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({required this.value, required this.label, required this.icon, this.accent = false});

  final String value;
  final String label;
  final IconData icon;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 18, color: accent ? scheme.primary : scheme.onSurfaceVariant),
          const SizedBox(height: Space.xs),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value, style: text.titleLarge),
          ),
          Text(label, style: text.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}

/// Bars of reading time: a bar a day for up to two months, otherwise a bar a month.
class ReadingChart extends StatelessWidget {
  const ReadingChart({super.key, required this.stats, required this.now, this.color, this.labelColor, this.labels = true});

  final ReadingStats stats;
  final DateTime now;
  final Color? color;
  final Color? labelColor;
  final bool labels;

  /// (label, seconds, is now) per bar.
  List<(String, int, bool)> bars() {
    final period = stats.period;
    final today = StatsPeriod.day(now);
    if (period.days <= 62) {
      final days = <(String, int, bool)>[];
      for (var d = period.from; d.isBefore(period.to); d = DateTime(d.year, d.month, d.day + 1)) {
        days.add(('${d.day}', stats.perDay[d] ?? 0, d == today));
      }
      return days;
    }
    final months = <(String, int, bool)>[];
    for (var m = DateTime(period.from.year, period.from.month); m.isBefore(period.to); m = DateTime(m.year, m.month + 1)) {
      final next = DateTime(m.year, m.month + 1);
      var seconds = 0;
      stats.perDay.forEach((day, s) {
        if (!day.isBefore(m) && day.isBefore(next)) seconds += s;
      });
      const names = ['J', 'F', 'M', 'A', 'M', 'J', 'J', 'A', 'S', 'O', 'N', 'D'];
      months.add((names[m.month - 1], seconds, m.year == now.year && m.month == now.month));
    }
    return months;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CustomPaint(
      size: Size.infinite,
      painter: _ChartPainter(
        bars: bars(),
        color: color ?? scheme.primary,
        faint: (color ?? scheme.primary).withValues(alpha: 0.25),
        labelColor: labelColor ?? scheme.onSurfaceVariant,
        grid: (labelColor ?? scheme.onSurfaceVariant).withValues(alpha: 0.18),
        labels: labels,
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({
    required this.bars,
    required this.color,
    required this.faint,
    required this.labelColor,
    required this.grid,
    required this.labels,
  });

  final List<(String, int, bool)> bars;
  final Color color;
  final Color faint;
  final Color labelColor;
  final Color grid;
  final bool labels;

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) return;
    final labelHeight = labels ? 18.0 : 0.0;
    final top = labels ? 16.0 : 0.0;
    final chart = Rect.fromLTRB(0, top, size.width, size.height - labelHeight);
    final most = bars.map((b) => b.$2).fold(0, math.max);
    final scale = most == 0 ? 1.0 : most.toDouble();

    // The top line, labelled with the most read in a bar.
    canvas.drawLine(chart.topLeft, chart.topRight, Paint()..color = grid..strokeWidth = 1);
    canvas.drawLine(chart.bottomLeft, chart.bottomRight, Paint()..color = grid..strokeWidth = 1);
    if (labels && most > 0) {
      _text(canvas, formatDuration(most), Offset(chart.right, 0), align: TextAlign.right);
    }

    final slot = chart.width / bars.length;
    final width = math.max(1.5, math.min(22.0, slot * 0.62));
    final every = (bars.length / 8).ceil();
    for (final (i, (label, seconds, isNow)) in bars.indexed) {
      final x = chart.left + slot * i + (slot - width) / 2;
      final h = seconds == 0 ? 0.0 : math.max(2.0, chart.height * seconds / scale);
      if (h > 0) {
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            Rect.fromLTWH(x, chart.bottom - h, width, h),
            topLeft: Radius.circular(math.min(3, width / 2)),
            topRight: Radius.circular(math.min(3, width / 2)),
          ),
          Paint()..color = isNow || bars.length <= 12 ? color : (seconds > 0 ? color.withValues(alpha: 0.85) : faint),
        );
      }
      if (labels && (i % every == 0 || isNow)) {
        _text(canvas, label, Offset(x + width / 2, chart.bottom + 4), align: TextAlign.center, bold: isNow);
      }
    }
  }

  void _text(Canvas canvas, String s, Offset at, {required TextAlign align, bool bold = false}) {
    final painter = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(fontFamily: FontFamilies.ui, fontSize: 10, color: labelColor, fontWeight: bold ? FontWeight.w700 : null),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final dx = switch (align) {
      TextAlign.right => at.dx - painter.width,
      TextAlign.center => at.dx - painter.width / 2,
      _ => at.dx,
    };
    painter.paint(canvas, Offset(dx, at.dy));
  }

  @override
  bool shouldRepaint(_ChartPainter old) => old.bars != bars || old.color != color;
}
