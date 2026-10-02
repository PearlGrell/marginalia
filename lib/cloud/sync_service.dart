import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart' show Value;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:workmanager/workmanager.dart';

import '../data/database.dart';
import '../data/library.dart';
import '../reader/reader_preferences.dart';
import '../storage/local_store.dart';
import 'account.dart';
import 'drive_store.dart';
import 'sync_engine.dart';

/// This device's id and name, as other devices see it.
Future<(String, String)> deviceIdentity(LocalStore store) async {
  var id = store.readJson('device.id') as String?;
  if (id == null) {
    final random = math.Random.secure();
    id = List.generate(12, (_) => random.nextInt(36).toRadixString(36)).join();
    await store.writeJson('device.id', id);
  }
  var name = store.readJson('device.name') as String?;
  if (name == null) {
    try {
      name = await const MethodChannel('marginalia/device').invokeMethod<String>('deviceName');
      if (name != null) await store.writeJson('device.name', name);
    } catch (_) {
      // In a background isolate: use the stored name, or a generic one.
    }
  }
  return (id, name ?? 'Android device');
}

/// Runs one sync for the signed-in user. Shared by the app and background work.
Future<SyncReport?> syncOnce({
  required AppDatabase db,
  required LocalStore store,
  bool promptForDrive = false,
  void Function(String)? onStep,
  SyncReport? report,
}) async {
  if (!await ensureCloud()) return null;
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return null;
  final (deviceId, deviceName) = await deviceIdentity(store);
  onStep?.call('Connecting to your Google Drive');
  final client = await driveClientFor(prompt: promptForDrive);
  if (client == null) onStep?.call('Drive unavailable: syncing library only');
  final engine = SyncEngine(
    db: db,
    store: store,
    uid: user.uid,
    deviceId: deviceId,
    deviceName: deviceName,
    drive: client == null ? null : DriveStore(client),
    uploadLimitBytes: store.readJson(uploadLimitKey) as int?,
  );
  try {
    return await engine.run(onStep: onStep, report: report);
  } finally {
    client?.close();
  }
}

class SyncStatus {
  const SyncStatus({
    this.running = false,
    this.step,
    this.steps = const [],
    this.live,
    this.report,
    this.lastSyncedAt,
    this.error,
  });

  final bool running;
  final String? step;

  /// Steps of the sync under way (or just finished), in order; the last is the current one.
  final List<String> steps;

  /// What the sync under way has brought and sent so far.
  final SyncReport? live;
  final SyncReport? report;
  final DateTime? lastSyncedAt;
  final String? error;
}

/// Sync in the app: on opening, after reading, on demand; plus background work scheduling.
const uploadLimitKey = SyncEngine.limitKey;

/// The user's own cap on book files in Drive, or null for no limit. It belongs to the
/// account: a change goes out with the next sync and applies on every device.
class UploadLimit extends Notifier<int?> {
  @override
  int? build() => ref.read(localStoreProvider).readJson(uploadLimitKey) as int?;

  Future<void> set(int? bytes) async {
    final store = ref.read(localStoreProvider);
    if (bytes == null) {
      await store.remove(uploadLimitKey);
    } else {
      await store.writeJson(uploadLimitKey, bytes);
    }
    await store.writeJson(SyncEngine.limitChangedKey, DateTime.now().millisecondsSinceEpoch);
    state = bytes;
    await ref.read(syncProvider.notifier).scheduleSoon();
  }
}

final uploadLimitProvider = NotifierProvider<UploadLimit, int?>(UploadLimit.new);

class SyncController extends Notifier<SyncStatus> {
  static const _lastKey = 'sync.lastCompleted';
  static const _periodic = 'marginalia-sync-periodic';
  static const _soon = 'marginalia-sync-soon';
  static const taskName = 'sync';

  final _downloads = <String, Future<String?>>{};

  @override
  SyncStatus build() {
    final last = ref.read(localStoreProvider).readJson(_lastKey) as int?;
    return SyncStatus(
      lastSyncedAt: last == null ? null : DateTime.fromMillisecondsSinceEpoch(last),
    );
  }

  bool get _signedIn => ref.read(accountProvider).signedIn;

  Future<SyncReport?> syncNow({bool promptForDrive = false}) async {
    if (!_signedIn || state.running) return null;
    final steps = <String>[];
    final live = SyncReport();
    void step(String s) {
      // Upload progress replaces itself rather than piling up.
      if (steps.isNotEmpty && steps.last.startsWith('Uploading') && s.startsWith('Uploading')) {
        steps.removeLast();
      }
      steps.add(s);
      state = SyncStatus(
        running: true,
        step: s,
        steps: [...steps],
        live: live,
        lastSyncedAt: state.lastSyncedAt,
      );
    }

    step('Starting');
    try {
      final report = await syncOnce(
        db: ref.read(databaseProvider),
        store: ref.read(localStoreProvider),
        promptForDrive: promptForDrive,
        onStep: step,
        report: live,
      ).timeout(const Duration(minutes: 10));
      final now = DateTime.now();
      await ref.read(localStoreProvider).writeJson(_lastKey, now.millisecondsSinceEpoch);
      // Settings and the upload limit may have arrived from another device.
      ref.invalidate(readerPreferencesProvider);
      ref.invalidate(uploadLimitProvider);
      state = SyncStatus(report: report, steps: [...steps], lastSyncedAt: now);
      return report;
    } on TimeoutException {
      state = SyncStatus(
        steps: [...steps],
        lastSyncedAt: state.lastSyncedAt,
        error: "Sync timed out. Check your connection; it'll try again later.",
      );
      return null;
    } catch (e) {
      state = SyncStatus(steps: [...steps], lastSyncedAt: state.lastSyncedAt, error: "Couldn't sync: $e");
      return null;
    }
  }

  /// Background sync every 6 hours on any network while the battery isn't low.
  Future<void> schedulePeriodic() => Workmanager().registerPeriodicTask(
    _periodic,
    taskName,
    frequency: const Duration(hours: 6),
    constraints: Constraints(networkType: NetworkType.connected, requiresBatteryNotLow: true),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
  );

  /// A sync shortly after the reader stops making changes; each call pushes it back, so
  /// a reading session goes out as one batch.
  Future<void> scheduleSoon() async {
    if (!_signedIn) return;
    await Workmanager().registerOneOffTask(
      _soon,
      taskName,
      initialDelay: const Duration(seconds: 30),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingWorkPolicy.replace,
    );
  }

  Future<void> cancelBackground() async {
    await Workmanager().cancelByUniqueName(_periodic);
    await Workmanager().cancelByUniqueName(_soon);
  }

  /// The local path of [book]'s EPUB, downloading it from Drive the first time it's opened
  /// on this device. Two requests for one book share one download.
  Future<String?> ensureFile(Book book, {void Function(double)? onProgress}) async {
    final path = book.filePath;
    if (path != null && await File(path).exists()) return path;
    final fileId = book.driveFileId;
    if (fileId == null) return null;
    return _downloads[book.id] ??= _download(book, fileId, onProgress).whenComplete(
      () => _downloads.remove(book.id),
    );
  }

  Future<String?> _download(Book book, String fileId, void Function(double)? onProgress) async {
    final client = await driveClientFor(prompt: true);
    if (client == null) return null;
    try {
      // The app cache: clearing it in Android settings frees the space; notes stay.
      final dir = Directory('${(await getApplicationCacheDirectory()).path}/books');
      final target = File('${dir.path}/${book.id}.epub');
      await DriveStore(client).download(
        fileId,
        target,
        expectedBytes: book.fileSize,
        onProgress: onProgress,
      );
      await ref.read(databaseProvider).setLocalFields(
        book.id,
        BooksCompanion(filePath: Value(target.path)),
      );
      return target.path;
    } finally {
      client.close();
    }
  }

  /// Starts [bookId] over here and drops other devices' positions in it.
  Future<void> startOver(String bookId, {required bool annotations}) async {
    await ref.read(databaseProvider).resetReading(bookId, removeAnnotations: annotations);
    final user = FirebaseAuth.instance.currentUser;
    if (!_signedIn || user == null) return;
    final store = ref.read(localStoreProvider);
    final (deviceId, deviceName) = await deviceIdentity(store);
    try {
      await SyncEngine(
        db: ref.read(databaseProvider),
        store: store,
        uid: user.uid,
        deviceId: deviceId,
        deviceName: deviceName,
      ).forgetProgress(bookId);
    } catch (_) {
      // Offline: the prompt on other devices may still offer their old place.
    }
    await scheduleSoon();
  }

  /// Takes a book's file out of Drive (the book stays in the library, on this phone).
  Future<bool> removeFromDrive(Book book) async {
    final client = await driveClientFor(prompt: true);
    if (client == null) return false;
    try {
      final drive = DriveStore(client);
      for (final id in [book.driveFileId, book.driveCoverId].whereType<String>()) {
        await drive.delete(id);
      }
      await ref.read(databaseProvider).setLocalFields(
        book.id,
        const BooksCompanion(driveFileId: Value(null), driveCoverId: Value(null)),
      );
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        final store = ref.read(localStoreProvider);
        final (deviceId, deviceName) = await deviceIdentity(store);
        await SyncEngine(
          db: ref.read(databaseProvider),
          store: store,
          uid: user.uid,
          deviceId: deviceId,
          deviceName: deviceName,
        ).clearDriveIds(book.id);
      }
      return true;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  /// Every book in the cloud that isn't on this phone.
  Future<int> downloadAll() async {
    final books = await ref.read(databaseProvider).allBooks();
    var count = 0;
    for (final book in books) {
      if (book.deleted || book.driveFileId == null) continue;
      if (book.filePath != null && await File(book.filePath!).exists()) continue;
      if (await ensureFile(book) != null) count++;
    }
    return count;
  }

  SyncEngine? _engineWithoutDrive(String deviceId, String deviceName) {
    final user = FirebaseAuth.instance.currentUser;
    if (!_signedIn || user == null) return null;
    return SyncEngine(
      db: ref.read(databaseProvider),
      store: ref.read(localStoreProvider),
      uid: user.uid,
      deviceId: deviceId,
      deviceName: deviceName,
    );
  }

  /// The account's devices, most recently synced first.
  Future<List<SyncedDevice>> devices() async {
    final (deviceId, deviceName) = await deviceIdentity(ref.read(localStoreProvider));
    return await _engineWithoutDrive(deviceId, deviceName)?.devices() ?? const [];
  }

  Future<void> forgetDevice(String id) async {
    final (deviceId, deviceName) = await deviceIdentity(ref.read(localStoreProvider));
    await _engineWithoutDrive(deviceId, deviceName)?.forgetDevice(id);
  }

  /// A new cover for [book] goes up with the next sync.
  Future<void> coverChanged(String bookId) async {
    final store = ref.read(localStoreProvider);
    final pending = ((store.readJson(SyncEngine.coverUploadsKey) as List?) ?? const []).cast<String>().toSet()
      ..add(bookId);
    await store.writeJson(SyncEngine.coverUploadsKey, pending.toList());
    await scheduleSoon();
  }

  /// Frees this phone's copy of a book that's in the cloud; it downloads again when opened.
  Future<bool> removeLocalCopy(Book book) async {
    final path = book.filePath;
    if (book.driveFileId == null || path == null) return false;
    final file = File(path);
    if (await file.exists()) await file.delete();
    await ref.read(databaseProvider).setLocalFields(book.id, const BooksCompanion(filePath: Value(null)));
    return true;
  }

  Future<RemoteProgress?> newerProgressElsewhere(Book book) async {
    if (!_signedIn) return null;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;
    final store = ref.read(localStoreProvider);
    final (deviceId, deviceName) = await deviceIdentity(store);
    final engine = SyncEngine(
      db: ref.read(databaseProvider),
      store: store,
      uid: user.uid,
      deviceId: deviceId,
      deviceName: deviceName,
    );
    try {
      return await engine
          .newerProgressElsewhere(book.id, book.lastOpenedAt)
          .timeout(const Duration(seconds: 4));
    } catch (_) {
      return null;
    }
  }

  /// Removes the account's library, notes and files from the cloud. Books on this phone stay.
  Future<void> deleteCloudData() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final store = ref.read(localStoreProvider);
    final (deviceId, deviceName) = await deviceIdentity(store);
    final client = await driveClientFor(prompt: true);
    if (client != null) {
      await DriveStore(client).deleteAll();
      client.close();
    }
    await SyncEngine(
      db: ref.read(databaseProvider),
      store: store,
      uid: user.uid,
      deviceId: deviceId,
      deviceName: deviceName,
    ).deleteAllRemote();
    await cancelBackground();
  }
}

final syncProvider = NotifierProvider<SyncController, SyncStatus>(SyncController.new);
