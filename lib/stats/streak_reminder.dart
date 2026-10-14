import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:workmanager/workmanager.dart';

import '../data/database.dart';
import '../storage/local_store.dart';
import '../storage/synced_setting.dart';
import 'reading_goals.dart';
import 'reading_stats.dart';

/// The evening nudge: at the chosen time, if nothing has been read today and there's a
/// streak (or a daily goal) to keep, a notification says so. Nothing on days already read.
///
/// It runs as WorkManager one-off tasks, each scheduling the next day's, so it fires near
/// the chosen time without exact alarms.
class StreakReminder {
  const StreakReminder({required this.enabled, required this.minuteOfDay});

  factory StreakReminder.fromJson(Object? json) {
    final m = json is Map ? json : const {};
    return StreakReminder(
      enabled: m['enabled'] == true,
      minuteOfDay: (m['minuteOfDay'] as num?)?.toInt() ?? defaultMinute,
    );
  }

  static const key = 'reminder.streak';
  static const taskName = 'streak-reminder';
  static const _uniqueName = 'marginalia-streak-reminder';
  static const defaultMinute = 20 * 60;

  final bool enabled;

  /// When to remind, in minutes after midnight.
  final int minuteOfDay;

  TimeOfDay get time => TimeOfDay(hour: minuteOfDay ~/ 60, minute: minuteOfDay % 60);

  Map<String, Object?> toJson() => {'enabled': enabled, 'minuteOfDay': minuteOfDay};

  /// The next time to check, after [now].
  DateTime nextAfter(DateTime now) {
    var at = DateTime(now.year, now.month, now.day, minuteOfDay ~/ 60, minuteOfDay % 60);
    if (!at.isAfter(now)) at = DateTime(now.year, now.month, now.day + 1, minuteOfDay ~/ 60, minuteOfDay % 60);
    return at;
  }

  /// Schedules the next check (or cancels it when off).
  Future<void> schedule({DateTime? now}) async {
    if (!enabled) return Workmanager().cancelByUniqueName(_uniqueName);
    final from = now ?? DateTime.now();
    await Workmanager().registerOneOffTask(
      _uniqueName,
      taskName,
      initialDelay: nextAfter(from).difference(from),
      existingWorkPolicy: ExistingWorkPolicy.replace,
    );
  }

  /// What to say at [now], or null when there's nothing to keep (already read today, no
  /// streak and no goal).
  static String? message(List<ReadingSession> sessions, ReadingGoals goals, {required DateTime now}) {
    final today = StatsPeriod.day(now);
    final todaySeconds = ReadingStats.of(
      sessions,
      const [],
      StatsPeriod('Today', today, today.add(const Duration(days: 1))),
      now: now,
    ).seconds;
    if (todaySeconds >= ReadingStats.streakMinimum) {
      final goal = goals.dailyMinutes;
      if (goal == null || todaySeconds >= goal * 60) return null;
      final left = goal - todaySeconds ~/ 60;
      return '$left more ${left == 1 ? 'minute' : 'minutes'} to reach today\'s goal.';
    }
    final (streak, _) = ReadingStats.streaks(sessions, now);
    if (streak > 0) {
      return 'Your $streak-day streak ends at midnight. A few pages keeps it going.';
    }
    if (goals.dailyMinutes case final goal?) return 'Nothing read yet today. $goal minutes is your goal.';
    return null;
  }

  /// The background task: notifies if there's something to keep, then schedules tomorrow's.
  static Future<void> run(AppDatabase db, LocalStore store) async {
    final reminder = StreakReminder.fromJson(store.readJson(key));
    if (!reminder.enabled) return;
    final now = DateTime.now();
    final text = message(await db.allSessions(), ReadingGoals.fromJson(SyncedSetting.goals.read(store)), now: now);
    if (text != null) {
      final notifications = FlutterLocalNotificationsPlugin();
      await notifications.initialize(
        settings: const InitializationSettings(android: AndroidInitializationSettings('@drawable/ic_launcher_monochrome')),
      );
      await notifications.show(
        id: 7,
        title: 'Time to read?',
        body: text,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'reminders',
            'Reading reminders',
            channelDescription: 'An evening nudge to keep your reading streak',
            importance: Importance.defaultImportance,
          ),
        ),
      );
    }
    await reminder.schedule(now: now.add(const Duration(minutes: 1)));
  }
}

class StreakReminderNotifier extends Notifier<StreakReminder> {
  @override
  StreakReminder build() => StreakReminder.fromJson(ref.read(localStoreProvider).readJson(StreakReminder.key));

  /// Turns the reminder on or off, or moves it, asking to show notifications when turned on.
  Future<void> set(StreakReminder reminder) async {
    if (reminder.enabled && !state.enabled) {
      final android = FlutterLocalNotificationsPlugin()
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await android?.requestNotificationsPermission();
    }
    state = reminder;
    await ref.read(localStoreProvider).writeJson(StreakReminder.key, reminder.toJson());
    await reminder.schedule();
  }
}

final streakReminderProvider = NotifierProvider<StreakReminderNotifier, StreakReminder>(StreakReminderNotifier.new);
