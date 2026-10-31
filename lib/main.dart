import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:workmanager/workmanager.dart';

import 'app.dart';
import 'cloud/background_sync.dart';
import 'stats/streak_reminder.dart';
import 'storage/local_store.dart';
import 'words/review_reminder.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Draw behind the status and navigation bars; screens pad themselves with SafeArea.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  // Phones stay upright; tablets (shortest side 600dp and up) can turn.
  final display = WidgetsBinding.instance.platformDispatcher.displays.first;
  if (display.size.shortestSide / display.devicePixelRatio < 600) {
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  }
  final store = await LocalStore.open();
  // Background work: syncing (with cloud set up) and the reading reminder.
  await Workmanager().initialize(backgroundSyncDispatcher);
  // Keep the reminders' next checks in place (WorkManager drops one-off work on some updates).
  await StreakReminder.fromJson(store.readJson(StreakReminder.key)).schedule();
  await ReviewReminder.fromJson(store.readJson(ReviewReminder.key)).schedule();
  runApp(
    ProviderScope(
      overrides: [localStoreProvider.overrideWithValue(store)],
      child: const MarginaliaApp(),
    ),
  );
}
