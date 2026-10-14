import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:workmanager/workmanager.dart';

import 'app.dart';
import 'cloud/background_sync.dart';
import 'stats/streak_reminder.dart';
import 'storage/local_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Draw behind the status and navigation bars; screens pad themselves with SafeArea.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  final store = await LocalStore.open();
  // Background work: syncing (with cloud set up) and the reading reminder.
  await Workmanager().initialize(backgroundSyncDispatcher);
  // Keep the reminder's next check in place (WorkManager drops one-off work on some updates).
  await StreakReminder.fromJson(store.readJson(StreakReminder.key)).schedule();
  runApp(
    ProviderScope(
      overrides: [localStoreProvider.overrideWithValue(store)],
      child: const MarginaliaApp(),
    ),
  );
}
