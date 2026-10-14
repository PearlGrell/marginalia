import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../storage/local_store.dart';
import '../storage/synced_setting.dart';
import '../theme/tokens.dart';
import 'reading_stats.dart';

/// What the reader means to read: minutes a day and books a year. Null is no goal.
class ReadingGoals {
  const ReadingGoals({this.dailyMinutes, this.yearlyBooks});

  factory ReadingGoals.fromJson(Object? json) {
    final m = json is Map ? json : const {};
    return ReadingGoals(
      dailyMinutes: (m['dailyMinutes'] as num?)?.toInt(),
      yearlyBooks: (m['yearlyBooks'] as num?)?.toInt(),
    );
  }

  final int? dailyMinutes;
  final int? yearlyBooks;

  bool get any => dailyMinutes != null || yearlyBooks != null;

  Map<String, Object?> toJson() => {'dailyMinutes': dailyMinutes, 'yearlyBooks': yearlyBooks};
}

/// The reading goals, which follow the account.
class ReadingGoalsNotifier extends Notifier<ReadingGoals> {
  @override
  ReadingGoals build() => ReadingGoals.fromJson(SyncedSetting.goals.read(ref.read(localStoreProvider)));

  Future<void> set(ReadingGoals goals) async {
    state = goals;
    await SyncedSetting.goals.write(ref.read(localStoreProvider), goals.toJson());
  }
}

final readingGoalsProvider = NotifierProvider<ReadingGoalsNotifier, ReadingGoals>(ReadingGoalsNotifier.new);

/// How far along the goals are at a moment.
class GoalProgress {
  GoalProgress.of(List<ReadingSession> sessions, List<Book> books, this.goals, {required DateTime now})
    : todaySeconds = ReadingStats.of(
        sessions,
        const [],
        StatsPeriod('Today', StatsPeriod.day(now), StatsPeriod.day(now).add(const Duration(days: 1))),
        now: now,
      ).seconds,
      booksThisYear = ReadingStats.of(const [], books, StatsPeriod.year(now), now: now).finished.length,
      yearFraction = _yearFraction(now);

  final ReadingGoals goals;
  final int todaySeconds;
  final int booksThisYear;

  /// How much of the year has gone, 0 to 1.
  final double yearFraction;

  /// Today's minutes against the daily goal (1 is met), or null without one.
  double? get today => goals.dailyMinutes == null ? null : todaySeconds / 60 / math.max(1, goals.dailyMinutes!);

  /// This year's books against the yearly goal (1 is met), or null without one.
  double? get year => goals.yearlyBooks == null ? null : booksThisYear / math.max(1, goals.yearlyBooks!);

  /// Books ahead of (positive) or behind (negative) an even pace through the year.
  double? get booksAhead => goals.yearlyBooks == null ? null : booksThisYear - goals.yearlyBooks! * yearFraction;

  /// "on track", "2 ahead", "1 behind".
  String get pace {
    final ahead = booksAhead;
    if (ahead == null || ahead.abs() < 0.5) return 'on track';
    return ahead > 0 ? '${ahead.round()} ahead' : '${(-ahead).round()} behind';
  }

  static double _yearFraction(DateTime now) {
    final start = DateTime(now.year);
    final end = DateTime(now.year + 1);
    return now.difference(start).inMinutes / end.difference(start).inMinutes;
  }
}

/// Today's minutes and this year's books against the goals, as two rings. With no goals, an
/// invitation to set them.
class GoalsCard extends ConsumerWidget {
  const GoalsCard({super.key, required this.sessions, required this.books});

  final List<ReadingSession> sessions;
  final List<Book> books;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goals = ref.watch(readingGoalsProvider);
    final scheme = Theme.of(context).colorScheme;
    if (!goals.any) {
      return Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          icon: const Icon(Icons.flag_outlined),
          label: const Text('Set a reading goal'),
          onPressed: () => editGoals(context, ref),
        ),
      );
    }
    final progress = GoalProgress.of(sessions, books, goals, now: DateTime.now());
    return InkWell(
      borderRadius: BorderRadius.circular(Radii.lg),
      onTap: () => editGoals(context, ref),
      child: Container(
        padding: const EdgeInsets.all(Space.md),
        decoration: BoxDecoration(
          color: scheme.surfaceContainer,
          borderRadius: BorderRadius.circular(Radii.lg),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(
          children: [
            if (progress.today case final today?)
              Expanded(
                child: _Ring(
                  value: today,
                  big: '${(progress.todaySeconds / 60).floor()}',
                  small: 'of ${goals.dailyMinutes} min today',
                ),
              ),
            if (progress.year case final year?)
              Expanded(
                child: _Ring(
                  value: year,
                  big: '${progress.booksThisYear}',
                  small: 'of ${goals.yearlyBooks} books this year, ${progress.pace}',
                ),
              ),
            Icon(Icons.edit_outlined, size: 18, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

class _Ring extends StatelessWidget {
  const _Ring({required this.value, required this.big, required this.small});

  final double value;
  final String big;
  final String small;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final done = value >= 1;
    return Row(
      children: [
        SizedBox(
          width: 52,
          height: 52,
          child: Stack(
            alignment: Alignment.center,
            children: [
              SizedBox.expand(
                child: CircularProgressIndicator(
                  value: value.clamp(0.0, 1.0),
                  strokeWidth: 5,
                  backgroundColor: scheme.outlineVariant,
                  color: done ? scheme.tertiary : scheme.primary,
                  strokeCap: StrokeCap.round,
                ),
              ),
              done ? Icon(Icons.check, color: scheme.tertiary) : Text(big, style: text.titleMedium),
            ],
          ),
        ),
        const SizedBox(width: Space.sm),
        Expanded(child: Text(done ? '$big $small' : small, style: text.bodySmall, maxLines: 3)),
      ],
    );
  }
}

/// Sets the daily minutes and yearly books.
Future<void> editGoals(BuildContext context, WidgetRef ref) async {
  final result = await showDialog<ReadingGoals>(
    context: context,
    builder: (context) => _GoalsDialog(initial: ref.read(readingGoalsProvider)),
  );
  if (result != null) await ref.read(readingGoalsProvider.notifier).set(result);
}

class _GoalsDialog extends StatefulWidget {
  const _GoalsDialog({required this.initial});

  final ReadingGoals initial;

  @override
  State<_GoalsDialog> createState() => _GoalsDialogState();
}

class _GoalsDialogState extends State<_GoalsDialog> {
  late int? _minutes = widget.initial.dailyMinutes;
  late int? _books = widget.initial.yearlyBooks;

  static const _minuteSteps = [5, 10, 15, 20, 30, 45, 60, 90, 120];

  void _stepMinutes(int by) => setState(() {
    final at = _minutes == null ? -1 : _minuteSteps.indexWhere((m) => m >= _minutes!);
    final next = at + by;
    _minutes = next < 0 ? null : _minuteSteps[next.clamp(0, _minuteSteps.length - 1)];
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    Widget row(String label, String value, {VoidCallback? less, VoidCallback? more}) => Row(
      children: [
        Expanded(child: Text(label, style: text.bodyLarge)),
        IconButton(icon: const Icon(Icons.remove), onPressed: less),
        SizedBox(width: 80, child: Text(value, textAlign: TextAlign.center, style: text.titleMedium)),
        IconButton(icon: const Icon(Icons.add), onPressed: more),
      ],
    );
    return AlertDialog(
      title: const Text('Reading goals'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          row(
            'Every day',
            _minutes == null ? 'Off' : '$_minutes min',
            less: _minutes == null ? null : () => _stepMinutes(-1),
            more: _minutes == _minuteSteps.last ? null : () => _stepMinutes(1),
          ),
          row(
            'This year',
            _books == null ? 'Off' : '$_books books',
            less: _books == null ? null : () => setState(() => _books = _books! <= 1 ? null : _books! - 1),
            more: () => setState(() => _books = (_books ?? 11) + 1),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, ReadingGoals(dailyMinutes: _minutes, yearlyBooks: _books)),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
