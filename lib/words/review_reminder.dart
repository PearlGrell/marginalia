import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:workmanager/workmanager.dart';

import '../data/database.dart';
import '../storage/local_store.dart';

/// The words reminder: once a day at the chosen time, if words saved from books are due for
/// review, a notification says how many. Tapping it opens the review. Nothing on days with
/// nothing due.
///
/// Like the streak reminder, it runs as WorkManager one-off tasks, each scheduling the next
/// day's.
class ReviewReminder {
  const ReviewReminder({required this.enabled, required this.minuteOfDay});

  factory ReviewReminder.fromJson(Object? json) {
    final m = json is Map ? json : const {};
    return ReviewReminder(
      enabled: m['enabled'] == true,
      minuteOfDay: (m['minuteOfDay'] as num?)?.toInt() ?? defaultMinute,
    );
  }

  static const key = 'reminder.words';
  static const taskName = 'words-reminder';
  static const _uniqueName = 'marginalia-words-reminder';
  static const defaultMinute = 9 * 60;

  /// The notification's payload: what tapping it opens.
  static const payload = 'words-review';

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

  /// What to say about [due] words, or null when none are due.
  static String? message(List<VocabularyWord> due) {
    if (due.isEmpty) return null;
    final sample = [for (final w in due.take(3)) w.word].join(', ');
    final more = due.length > 3 ? ' and ${due.length - 3} more' : '';
    return due.length == 1
        ? '“${due.first.word}” is ready for review. A minute keeps it.'
        : '${due.length} words are ready for review: $sample$more.';
  }

  /// The background task: notifies if words are due, then schedules tomorrow's.
  static Future<void> run(AppDatabase db, LocalStore store) async {
    final reminder = ReviewReminder.fromJson(store.readJson(key));
    if (!reminder.enabled) return;
    final now = DateTime.now();
    final text = message(await db.dueWords(now));
    if (text != null) {
      final notifications = FlutterLocalNotificationsPlugin();
      await notifications.initialize(
        settings: const InitializationSettings(android: AndroidInitializationSettings('@drawable/ic_launcher_monochrome')),
      );
      await notifications.show(
        id: 8,
        title: 'Words to review',
        body: text,
        payload: payload,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'words',
            'Word reviews',
            channelDescription: 'A daily nudge when words you saved are due for review',
            importance: Importance.defaultImportance,
          ),
        ),
      );
    }
    await reminder.schedule(now: now.add(const Duration(minutes: 1)));
  }
}

class ReviewReminderNotifier extends Notifier<ReviewReminder> {
  @override
  ReviewReminder build() => ReviewReminder.fromJson(ref.read(localStoreProvider).readJson(ReviewReminder.key));

  /// Turns the reminder on or off, or moves it, asking to show notifications when turned on.
  Future<void> set(ReviewReminder reminder) async {
    if (reminder.enabled && !state.enabled) {
      final android = FlutterLocalNotificationsPlugin()
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await android?.requestNotificationsPermission();
    }
    state = reminder;
    await ref.read(localStoreProvider).writeJson(ReviewReminder.key, reminder.toJson());
    await reminder.schedule();
  }
}

final reviewReminderProvider = NotifierProvider<ReviewReminderNotifier, ReviewReminder>(ReviewReminderNotifier.new);

/// Whether the app was opened (or brought back) by tapping the words reminder, and listens
/// for taps while it runs: [open] is called for each.
Future<void> listenForReviewTaps(void Function() open) async {
  final notifications = FlutterLocalNotificationsPlugin();
  try {
    await notifications.initialize(
      settings: const InitializationSettings(android: AndroidInitializationSettings('@drawable/ic_launcher_monochrome')),
      onDidReceiveNotificationResponse: (response) {
        if (response.payload == ReviewReminder.payload) open();
      },
    );
    final launch = await notifications.getNotificationAppLaunchDetails();
    if (launch != null && launch.didNotificationLaunchApp && launch.notificationResponse?.payload == ReviewReminder.payload) {
      open();
    }
  } on Exception {
    // In tests, where there's no plugin.
  }
}
