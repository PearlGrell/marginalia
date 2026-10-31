import 'package:workmanager/workmanager.dart';

import '../data/database.dart';
import '../stats/streak_reminder.dart';
import '../storage/local_store.dart';
import '../words/review_reminder.dart';
import 'sync_service.dart';

/// Entry point for Android WorkManager, with the app closed (after a reboot too): syncs,
/// gives the evening reading reminder and the words reminder. Book uploads happen here only if Drive access is
/// available without asking.
@pragma('vm:entry-point')
void backgroundSyncDispatcher() {
  Workmanager().executeTask((task, input) async {
    if (task != SyncController.taskName && task != StreakReminder.taskName && task != ReviewReminder.taskName) {
      return true;
    }
    final db = AppDatabase();
    try {
      final store = await LocalStore.open();
      if (task == StreakReminder.taskName) {
        await StreakReminder.run(db, store);
      } else if (task == ReviewReminder.taskName) {
        await ReviewReminder.run(db, store);
      } else {
        await syncOnce(db: db, store: store);
      }
      return true;
    } catch (_) {
      // WorkManager retries with backoff.
      return false;
    } finally {
      await db.close();
    }
  });
}
