import 'package:workmanager/workmanager.dart';

import '../data/database.dart';
import '../storage/local_store.dart';
import 'sync_service.dart';

/// Entry point for Android WorkManager: syncs with the app closed, after a reboot too.
/// Book uploads happen here only if Drive access is available without asking.
@pragma('vm:entry-point')
void backgroundSyncDispatcher() {
  Workmanager().executeTask((task, input) async {
    if (task != SyncController.taskName) return true;
    final db = AppDatabase();
    try {
      final store = await LocalStore.open();
      await syncOnce(db: db, store: store);
      return true;
    } catch (_) {
      // WorkManager retries with backoff.
      return false;
    } finally {
      await db.close();
    }
  });
}
