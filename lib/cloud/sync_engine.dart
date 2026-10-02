import 'dart:io';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/drift.dart';
import 'package:path_provider/path_provider.dart';

import '../data/database.dart';
import '../data/library.dart' show sortableAuthor, sortableTitle;
import '../storage/local_store.dart';
import 'drive_store.dart';

/// What a sync brought and sent, for the sync screen's progress line.
class SyncReport {
  int newBooks = 0;
  int updatedBooks = 0;
  int notes = 0;
  int uploaded = 0;
  int skippedUploads = 0;
  UploadSkip? uploadSkip;

  String get summary {
    final parts = [
      if (newBooks > 0) '$newBooks new ${newBooks == 1 ? 'book' : 'books'}',
      if (notes > 0) '$notes ${notes == 1 ? 'note' : 'notes'}',
      if (uploaded > 0) '$uploaded uploaded',
    ];
    return parts.isEmpty ? 'Up to date' : parts.join(', ');
  }
}

/// One of the user's devices, as last seen by sync.
class SyncedDevice {
  const SyncedDevice({required this.id, required this.name, this.lastSyncAt, this.isThisDevice = false});

  final String id;
  final String name;
  final DateTime? lastSyncAt;
  final bool isThisDevice;
}

/// A newer reading position from another device.
class RemoteProgress {
  const RemoteProgress({
    required this.deviceName,
    required this.locatorJson,
    required this.percent,
    required this.lastReadAt,
  });

  final String deviceName;
  final String locatorJson;
  final double percent;
  final DateTime lastReadAt;
}

/// Two-way sync between the local database (the source of truth on each device) and
/// Firestore, plus book files to and from the user's Drive.
///
/// Firestore layout under `users/{uid}`: `books/{bookId}`, `collections/{id}`,
/// `bookCollections/{bookId}_{collectionId}`, `annotations/{id}`, `sessions/{id}`,
/// `words/{id}`, `progress/{bookId}_{deviceId}`, `devices/{deviceId}`, and the user
/// document's `settings`. Every record has
/// `updatedAt`, `deviceId` and `deleted`; the newer record wins. Reading progress is kept per
/// device and never overwritten by another.
class SyncEngine {
  SyncEngine({
    required this.db,
    required this.store,
    required this.uid,
    required this.deviceId,
    required this.deviceName,
    this.drive,
    this.uploadLimitBytes,
  });

  final AppDatabase db;
  final LocalStore store;
  final String uid;
  final String deviceId;
  final String deviceName;

  /// Null when Drive isn't available (signed out of Google, or in the background without a
  /// token): records still sync, files wait.
  final DriveStore? drive;
  final int? uploadLimitBytes;

  FirebaseFirestore get _fs => FirebaseFirestore.instance;
  DocumentReference<Map<String, dynamic>> get _user => _fs.collection('users').doc(uid);

  static const limitKey = 'cloud.limitBytes';
  static const limitChangedKey = 'cloud.limitChangedAt';
  static const _pushKey = 'sync.lastPush';

  /// What has been fetched: the newest *server* time seen on a record. Server times are
  /// stamped when a record reaches the cloud, so one sent late (a note made a while before
  /// the sync) is never behind the cursor, as a device-clock time could be.
  static const _cursorKey = 'sync.serverCursor';

  /// Bumped when records must be re-sent and re-fetched in full.
  static const _formatKey = 'sync.format';
  static const _format = 3;

  /// Books whose cover was changed on this device, to upload again.
  static const coverUploadsKey = 'sync.coverUploads';
  static const _network = Duration(seconds: 45);

  DateTime _read(String key) =>
      DateTime.fromMillisecondsSinceEpoch((store.readJson(key) as int?) ?? 0);

  /// Fills [report] as it goes, so progress can be shown while it runs.
  Future<SyncReport> run({void Function(String step)? onStep, SyncReport? report}) async {
    report ??= SyncReport();
    if (store.readJson(_formatKey) != _format) {
      // Re-send everything with server times and fetch everything once.
      await db.markAllDirty();
      await store.remove(_cursorKey);
      await store.writeJson(_formatKey, _format);
    }
    // Fetch first, so a newer record from another device wins over a stale one here
    // before anything is sent.
    onStep?.call('Fetching your library');
    await _pull(report, onStep);
    onStep?.call('Sending your changes');
    await _push();
    await _checkIn();
    if (drive != null) {
      onStep?.call('Fetching covers');
      await _fetchCovers();
      await _uploadCovers();
      await _upload(report, onStep);
      // Upload ids are changes too.
      await _push();
    }
    return report;
  }

  // ---- Push ----

  Future<void> _push() async {
    final since = _read(_pushKey);
    final startedAt = DateTime.now();
    final writes = <(DocumentReference<Map<String, dynamic>>, Map<String, dynamic>)>[];

    final books = await db.dirtyBooks();
    final collections = await db.dirtyCollections();
    final links = await db.dirtyBookCollections();
    final annotations = await db.dirtyAnnotations();
    final sessions = await db.dirtySessions();
    final words = await db.dirtyWords();

    for (final b in books) {
      writes.add((_user.collection('books').doc(b.id), {..._bookToMap(b), 'syncedAt': FieldValue.serverTimestamp()}));
      if (b.lastOpenedAt case final opened? when opened.isAfter(since) && b.lastLocator != null) {
        writes.add((
          _user.collection('progress').doc('${b.id}_$deviceId'),
          {
            'bookId': b.id,
            'deviceId': deviceId,
            'deviceName': deviceName,
            'locator': b.lastLocator,
            'percent': b.progress,
            'lastReadAt': Timestamp.fromDate(opened),
          },
        ));
      }
    }
    for (final c in collections) {
      writes.add((
        _user.collection('collections').doc(c.id),
        {
          'name': c.name,
          'sortOrder': c.sortOrder,
          'updatedAt': Timestamp.fromDate(c.updatedAt),
          'syncedAt': FieldValue.serverTimestamp(),
          'deviceId': deviceId,
          'deleted': c.deleted,
        },
      ));
    }
    for (final link in links) {
      writes.add((
        _user.collection('bookCollections').doc('${link.bookId}_${link.collectionId}'),
        {
          'bookId': link.bookId,
          'collectionId': link.collectionId,
          'updatedAt': Timestamp.fromDate(link.updatedAt),
          'syncedAt': FieldValue.serverTimestamp(),
          'deviceId': deviceId,
          'deleted': link.deleted,
        },
      ));
    }
    for (final a in annotations) {
      writes.add((
        _user.collection('annotations').doc(a.id),
        {..._annotationToMap(a), 'syncedAt': FieldValue.serverTimestamp()},
      ));
    }
    for (final s in sessions) {
      writes.add((
        _user.collection('sessions').doc(s.id),
        {
          'bookId': s.bookId,
          'deviceName': s.deviceName,
          'startedAt': Timestamp.fromDate(s.startedAt),
          'endedAt': Timestamp.fromDate(s.endedAt),
          'seconds': s.seconds,
          'pages': s.pages,
          'startProgress': s.startProgress,
          'endProgress': s.endProgress,
          'updatedAt': Timestamp.fromDate(s.updatedAt),
          'syncedAt': FieldValue.serverTimestamp(),
          'deviceId': deviceId,
          'deleted': s.deleted,
        },
      ));
    }
    for (final w in words) {
      writes.add((
        _user.collection('words').doc(w.id),
        {
          'word': w.word,
          'language': w.language,
          'partOfSpeech': w.partOfSpeech,
          'definition': w.definition,
          'context': w.context,
          'bookId': w.bookId,
          'createdAt': Timestamp.fromDate(w.createdAt),
          'dueAt': Timestamp.fromDate(w.dueAt),
          'intervalDays': w.intervalDays,
          'ease': w.ease,
          'reps': w.reps,
          'lapses': w.lapses,
          'updatedAt': Timestamp.fromDate(w.updatedAt),
          'syncedAt': FieldValue.serverTimestamp(),
          'deviceId': deviceId,
          'deleted': w.deleted,
        },
      ));
    }

    final settings = store.readJson('reader.preferences');
    final settingsChanged = (store.readJson('settings.changedAt') as int? ?? 0) > since.millisecondsSinceEpoch;
    if (settings != null && settingsChanged) {
      writes.add((
        _user,
        {'settings': settings, 'settingsUpdatedAt': Timestamp.now()},
      ));
    }

    // The Drive upload limit is the account's, not the phone's.
    final limitChanged = (store.readJson(limitChangedKey) as int? ?? 0) > since.millisecondsSinceEpoch;
    if (limitChanged) {
      writes.add((
        _user,
        {
          'uploadLimitBytes': store.readJson(limitKey) as int?,
          'uploadLimitUpdatedAt': Timestamp.now(),
        },
      ));
    }

    // Firestore batches hold up to 500 writes.
    for (var i = 0; i < writes.length; i += 450) {
      final batch = _fs.batch();
      for (final (ref, data) in writes.sublist(i, math.min(i + 450, writes.length))) {
        batch.set(ref, data, SetOptions(merge: true));
      }
      await batch.commit().timeout(_network);
    }
    await db.markSent(
      sentBooks: books,
      sentCollections: collections,
      sentLinks: links,
      sentAnnotations: annotations,
      sentSessions: sessions,
      sentWords: words,
    );
    await store.writeJson(_pushKey, startedAt.millisecondsSinceEpoch);
  }

  Map<String, dynamic> _bookToMap(Book b) => {
    'title': b.title,
    'authors': b.authors,
    'language': b.language,
    'description': b.description,
    // Only ids this device knows: a device that hasn't seen the upload yet must not wipe
    // them. (Removing a file from Drive clears them directly, see clearDriveIds.)
    if (b.driveFileId != null) 'driveFileId': b.driveFileId,
    if (b.driveCoverId != null) 'driveCoverId': b.driveCoverId,
    'coverColor': b.coverColor,
    'fileSize': b.fileSize,
    'source': b.source.name,
    'sourceId': b.sourceId,
    'series': b.series,
    'seriesIndex': b.seriesIndex,
    'tags': b.tags,
    'status': b.status?.name,
    'rating': b.ratingHalves / 2,
    'favorite': b.favorite,
    'addedAt': Timestamp.fromDate(b.addedAt),
    'finishedAt': b.finishedAt == null ? null : Timestamp.fromDate(b.finishedAt!),
    'lastReadAt': b.lastReadAt == null ? null : Timestamp.fromDate(b.lastReadAt!),
    'progress': b.progress,
    'updatedAt': Timestamp.fromDate(b.updatedAt),
    'deviceId': deviceId,
    'deleted': b.deleted,
  };

  Map<String, dynamic> _annotationToMap(Annotation a) => {
    'bookId': a.bookId,
    'type': a.type.name,
    'locator': a.locator,
    'selectedText': a.selectedText,
    'textBefore': a.textBefore,
    'textAfter': a.textAfter,
    'color': a.color,
    'note': a.note,
    'chapterTitle': a.chapterTitle,
    'progression': a.progression,
    'position': a.position,
    'createdAt': Timestamp.fromDate(a.createdAt),
    'updatedAt': Timestamp.fromDate(a.updatedAt),
    'deviceId': deviceId,
    'deleted': a.deleted,
  };

  // ---- Pull ----

  Future<void> _pull(SyncReport report, void Function(String)? onStep) async {
    final since = Timestamp.fromMillisecondsSinceEpoch((store.readJson(_cursorKey) as int?) ?? 0);
    var cursor = since;

    /// A record's change time (for newest-wins), noting its server time for the cursor.
    DateTime seen(Map<String, dynamic> m) {
      final synced = m['syncedAt'] as Timestamp?;
      if (synced != null && synced.compareTo(cursor) > 0) cursor = synced;
      return (m['updatedAt'] as Timestamp).toDate();
    }

    Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> changed(String name) async =>
        (await _user.collection(name).where('syncedAt', isGreaterThan: since).get().timeout(_network)).docs;

    for (final doc in await changed('books')) {
      final m = doc.data();
      final updatedAt = seen(m);
      final local = await db.getBook(doc.id);
      final remoteFileId = m['driveFileId'] as String?;
      final remoteCoverId = m['driveCoverId'] as String?;
      if (local != null && !updatedAt.isAfter(local.updatedAt)) {
        // Older record, but Drive ids are facts: take any this device lacks.
        if ((local.driveFileId == null && remoteFileId != null) ||
            (local.driveCoverId == null && remoteCoverId != null)) {
          await db.setLocalFields(
            doc.id,
            BooksCompanion(
              driveFileId: Value(local.driveFileId ?? remoteFileId),
              driveCoverId: Value(local.driveCoverId ?? remoteCoverId),
            ),
          );
        }
        continue;
      }
      if (local == null && m['deleted'] != true) report.newBooks++;
      if (local != null) report.updatedBooks++;
      // A new cover chosen on another device: drop this one, so the new one is fetched.
      final coverReplaced = local?.driveCoverId != null &&
          m.containsKey('driveCoverId') &&
          remoteCoverId != null &&
          remoteCoverId != local!.driveCoverId;
      if (coverReplaced && local.coverPath != null) {
        final old = File(local.coverPath!);
        if (await old.exists()) await old.delete();
      }
      final remoteReadAt = (m['lastReadAt'] as Timestamp?)?.toDate();
      final remoteIsNewer =
          remoteReadAt != null && (local?.lastReadAt == null || remoteReadAt.isAfter(local!.lastReadAt!));
      final title = m['title'] as String? ?? 'Untitled';
      final authors = ((m['authors'] as List?) ?? const []).cast<String>();
      await db.putBook(
        BooksCompanion(
          id: Value(doc.id),
          title: Value(title),
          authors: Value(authors),
          sortTitle: Value(sortableTitle(title)),
          sortAuthor: Value(sortableAuthor(authors)),
          language: Value(m['language'] as String?),
          description: Value(m['description'] as String?),
          driveFileId: Value(
            m.containsKey('driveFileId') ? remoteFileId : local?.driveFileId,
          ),
          driveCoverId: Value(
            m.containsKey('driveCoverId') ? remoteCoverId : local?.driveCoverId,
          ),
          coverColor: Value((m['coverColor'] as num?)?.toInt()),
          fileSize: Value((m['fileSize'] as num?)?.toInt() ?? 0),
          source: Value(BookSource.values.where((s) => s.name == m['source']).firstOrNull ?? BookSource.import),
          sourceId: Value(m['sourceId'] as String?),
          series: Value(m['series'] as String?),
          seriesIndex: Value((m['seriesIndex'] as num?)?.toDouble()),
          // Records from builds before tags have none: keep this device's.
          tags: Value(
            m['tags'] is List ? (m['tags'] as List).cast<String>() : (local?.tags ?? const []),
          ),
          status: Value(ReadingStatus.values.where((s) => s.name == m['status']).firstOrNull),
          ratingHalves: Value((((m['rating'] as num?) ?? 0) * 2).round()),
          favorite: Value(m['favorite'] == true),
          addedAt: Value((m['addedAt'] as Timestamp?)?.toDate() ?? updatedAt),
          finishedAt: Value((m['finishedAt'] as Timestamp?)?.toDate()),
          updatedAt: Value(updatedAt),
          deleted: Value(m['deleted'] == true),
          // This device's own: file, cover, position.
          filePath: Value(local?.filePath),
          coverPath: Value(coverReplaced ? null : local?.coverPath),
          lastLocator: Value(local?.lastLocator),
          lastOpenedAt: Value(local?.lastOpenedAt),
          // Shared: whichever device read the book last decides "Continue reading" and the
          // percentage shown with it.
          lastReadAt: Value(remoteIsNewer ? remoteReadAt : local?.lastReadAt),
          progress: Value(
            remoteIsNewer ? ((m['progress'] as num?)?.toDouble() ?? 0) : (local?.progress ?? 0),
          ),
        ),
      );
    }

    for (final doc in await changed('collections')) {
      final m = doc.data();
      final updatedAt = seen(m);
      final local = await db.getCollection(doc.id);
      if (local != null && !updatedAt.isAfter(local.updatedAt)) continue;
      await db.putCollection(
        CollectionsCompanion(
          id: Value(doc.id),
          name: Value(m['name'] as String? ?? ''),
          sortOrder: Value((m['sortOrder'] as num?)?.toInt() ?? 0),
          updatedAt: Value(updatedAt),
          deleted: Value(m['deleted'] == true),
        ),
      );
    }

    for (final doc in await changed('bookCollections')) {
      final m = doc.data();
      final updatedAt = seen(m);
      final bookId = m['bookId'] as String;
      final collectionId = m['collectionId'] as String;
      final local = await db.getBookCollection(bookId, collectionId);
      if (local != null && !updatedAt.isAfter(local.updatedAt)) continue;
      await db.putBookCollection(
        BookCollectionsCompanion(
          bookId: Value(bookId),
          collectionId: Value(collectionId),
          updatedAt: Value(updatedAt),
          deleted: Value(m['deleted'] == true),
        ),
      );
    }

    onStep?.call('Fetching collections and notes');
    for (final doc in await changed('annotations')) {
      final m = doc.data();
      final updatedAt = seen(m);
      final local = await db.getAnnotation(doc.id);
      if (local != null && !updatedAt.isAfter(local.updatedAt)) continue;
      if (local == null && m['deleted'] != true) report.notes++;
      await db.putAnnotation(
        AnnotationsCompanion(
          id: Value(doc.id),
          bookId: Value(m['bookId'] as String),
          type: Value(AnnotationType.values.byName(m['type'] as String)),
          locator: Value(m['locator'] as String),
          selectedText: Value(m['selectedText'] as String?),
          textBefore: Value(m['textBefore'] as String?),
          textAfter: Value(m['textAfter'] as String?),
          color: Value(m['color'] as String?),
          note: Value(m['note'] as String?),
          chapterTitle: Value(m['chapterTitle'] as String?),
          progression: Value((m['progression'] as num?)?.toDouble()),
          position: Value((m['position'] as num?)?.toInt()),
          createdAt: Value((m['createdAt'] as Timestamp?)?.toDate() ?? updatedAt),
          updatedAt: Value(updatedAt),
          deleted: Value(m['deleted'] == true),
        ),
      );
    }

    for (final doc in await changed('sessions')) {
      final m = doc.data();
      final updatedAt = seen(m);
      final local = await db.getSession(doc.id);
      if (local != null && !updatedAt.isAfter(local.updatedAt)) continue;
      await db.putSession(
        ReadingSessionsCompanion(
          id: Value(doc.id),
          bookId: Value(m['bookId'] as String),
          deviceName: Value(m['deviceName'] as String?),
          startedAt: Value((m['startedAt'] as Timestamp).toDate()),
          endedAt: Value((m['endedAt'] as Timestamp).toDate()),
          seconds: Value((m['seconds'] as num?)?.toInt() ?? 0),
          pages: Value((m['pages'] as num?)?.toInt() ?? 0),
          startProgress: Value((m['startProgress'] as num?)?.toDouble()),
          endProgress: Value((m['endProgress'] as num?)?.toDouble()),
          updatedAt: Value(updatedAt),
          deleted: Value(m['deleted'] == true),
        ),
      );
    }

    for (final doc in await changed('words')) {
      final m = doc.data();
      final updatedAt = seen(m);
      final local = await db.getWord(doc.id);
      if (local != null && !updatedAt.isAfter(local.updatedAt)) continue;
      await db.putWord(
        WordsCompanion(
          id: Value(doc.id),
          word: Value(m['word'] as String? ?? ''),
          language: Value(m['language'] as String? ?? 'en'),
          partOfSpeech: Value(m['partOfSpeech'] as String?),
          definition: Value(m['definition'] as String?),
          context: Value(m['context'] as String?),
          bookId: Value(m['bookId'] as String?),
          createdAt: Value((m['createdAt'] as Timestamp?)?.toDate() ?? updatedAt),
          dueAt: Value((m['dueAt'] as Timestamp?)?.toDate() ?? updatedAt),
          intervalDays: Value((m['intervalDays'] as num?)?.toDouble() ?? 0),
          ease: Value((m['ease'] as num?)?.toDouble() ?? 2.5),
          reps: Value((m['reps'] as num?)?.toInt() ?? 0),
          lapses: Value((m['lapses'] as num?)?.toInt() ?? 0),
          updatedAt: Value(updatedAt),
          deleted: Value(m['deleted'] == true),
        ),
      );
    }

    onStep?.call('Fetching your settings');
    // Reader settings follow the account.
    final user = await _user.get().timeout(_network);
    final remoteSettings = user.data()?['settings'];
    final remoteAt = (user.data()?['settingsUpdatedAt'] as Timestamp?)?.toDate();
    final localAt = DateTime.fromMillisecondsSinceEpoch(store.readJson('settings.changedAt') as int? ?? 0);
    if (remoteSettings is Map && remoteAt != null && remoteAt.isAfter(localAt)) {
      await store.writeJson('reader.preferences', remoteSettings);
      await store.writeJson('settings.changedAt', remoteAt.millisecondsSinceEpoch);
    }
    final limitAt = (user.data()?['uploadLimitUpdatedAt'] as Timestamp?)?.toDate();
    final localLimitAt = DateTime.fromMillisecondsSinceEpoch(store.readJson(limitChangedKey) as int? ?? 0);
    if (limitAt != null && limitAt.isAfter(localLimitAt)) {
      final limit = (user.data()?['uploadLimitBytes'] as num?)?.toInt();
      if (limit == null) {
        await store.remove(limitKey);
      } else {
        await store.writeJson(limitKey, limit);
      }
      await store.writeJson(limitChangedKey, limitAt.millisecondsSinceEpoch);
    }

    await store.writeJson(_cursorKey, cursor.millisecondsSinceEpoch);
  }

  /// The latest position on another device, if it's newer than this one's.
  Future<RemoteProgress?> newerProgressElsewhere(String bookId, DateTime? localLastRead) async {
    final docs = await _user.collection('progress').where('bookId', isEqualTo: bookId).get().timeout(_network);
    RemoteProgress? best;
    for (final doc in docs.docs) {
      final m = doc.data();
      if (m['deviceId'] == deviceId) continue;
      final at = (m['lastReadAt'] as Timestamp).toDate();
      if (localLastRead != null && !at.isAfter(localLastRead)) continue;
      if (best == null || at.isAfter(best.lastReadAt)) {
        best = RemoteProgress(
          deviceName: m['deviceName'] as String? ?? 'another device',
          locatorJson: m['locator'] as String,
          percent: (m['percent'] as num?)?.toDouble() ?? 0,
          lastReadAt: at,
        );
      }
    }
    return best;
  }

  // ---- Devices ----

  /// Records that this device synced, for the list of devices.
  Future<void> _checkIn() => _user
      .collection('devices')
      .doc(deviceId)
      .set({
        'name': deviceName,
        'platform': 'android',
        'lastSyncAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true))
      .timeout(_network);

  Future<List<SyncedDevice>> devices() async {
    final docs = await _user.collection('devices').get().timeout(_network);
    return [
      for (final doc in docs.docs)
        SyncedDevice(
          id: doc.id,
          name: doc.data()['name'] as String? ?? 'Android device',
          lastSyncAt: (doc.data()['lastSyncAt'] as Timestamp?)?.toDate(),
          isThisDevice: doc.id == deviceId,
        ),
    ]..sort((a, b) => (b.lastSyncAt ?? DateTime(0)).compareTo(a.lastSyncAt ?? DateTime(0)));
  }

  /// Takes a device off the list, with its reading positions. Its notes and changes stay.
  Future<void> forgetDevice(String id) async {
    final progress = await _user.collection('progress').where('deviceId', isEqualTo: id).get().timeout(_network);
    final batch = _fs.batch();
    for (final doc in progress.docs) {
      batch.delete(doc.reference);
    }
    batch.delete(_user.collection('devices').doc(id));
    await batch.commit().timeout(_network);
  }

  /// After a book's file is removed from Drive: clears its ids in the cloud too.
  Future<void> clearDriveIds(String bookId) => _user
      .collection('books')
      .doc(bookId)
      .update({
        // Present but empty means removed; absent means "this device doesn't know".
        'driveFileId': null,
        'driveCoverId': null,
        'updatedAt': Timestamp.now(),
        'syncedAt': FieldValue.serverTimestamp(),
      })
      .timeout(_network);

  /// Forgets every device's position in a book (after starting it over).
  Future<void> forgetProgress(String bookId) async {
    final docs = await _user.collection('progress').where('bookId', isEqualTo: bookId).get().timeout(_network);
    final batch = _fs.batch();
    for (final doc in docs.docs) {
      batch.delete(doc.reference);
    }
    await batch.commit().timeout(_network);
  }

  // ---- Files ----

  Future<void> _fetchCovers() async {
    final drive = this.drive!;
    final dir = Directory('${(await getApplicationCacheDirectory()).path}/covers');
    await dir.create(recursive: true);
    for (final b in await db.allBooks()) {
      if (b.deleted || b.driveCoverId == null) continue;
      if (b.coverPath != null && await File(b.coverPath!).exists()) continue;
      final target = File('${dir.path}/${b.id}_${b.driveCoverId!.hashCode.toUnsigned(32)}.jpg');
      try {
        await drive.download(b.driveCoverId!, target);
        await db.setLocalFields(b.id, BooksCompanion(coverPath: Value(target.path)));
      } catch (_) {
        // Try again next sync.
      }
    }
  }

  /// Covers changed here (see [coverUploadsKey]): uploaded under a new name, so other
  /// devices see the id change and fetch it.
  Future<void> _uploadCovers() async {
    final drive = this.drive!;
    final pending = ((store.readJson(coverUploadsKey) as List?) ?? const []).cast<String>().toList();
    for (final id in [...pending]) {
      final b = await db.getBook(id);
      final cover = b?.coverPath;
      // Not in the cloud yet: the book's upload takes the cover with it.
      if (b != null && !b.deleted && b.driveFileId != null && cover != null && await File(cover).exists()) {
        final coverId = await drive.upload(
          File(cover),
          '${b.id}-${DateTime.now().millisecondsSinceEpoch}.jpg',
          'image/jpeg',
        );
        if (b.driveCoverId case final old? when old != coverId) {
          try {
            await drive.delete(old);
          } catch (_) {
            // Already gone.
          }
        }
        await db.updateBook(b.id, BooksCompanion(driveCoverId: Value(coverId)));
      }
      pending.remove(id);
      await store.writeJson(coverUploadsKey, pending);
    }
  }

  Future<void> _upload(SyncReport report, void Function(String)? onStep) async {
    final drive = this.drive!;
    final books = await db.booksToUpload();
    for (final (i, b) in books.indexed) {
      onStep?.call('Uploading ${i + 1} of ${books.length}: ${b.title}');
      final file = File(b.filePath!);
      if (!await file.exists()) continue;
      final skip = await drive.canUpload(b.fileSize, limitBytes: uploadLimitBytes);
      if (skip != null) {
        report.skippedUploads++;
        report.uploadSkip = skip;
        continue;
      }
      final fileId = await drive.upload(file, '${b.id}.epub', 'application/epub+zip');
      String? coverId;
      if (b.coverPath case final cover? when await File(cover).exists()) {
        coverId = await drive.upload(File(cover), '${b.id}.jpg', 'image/jpeg');
      }
      await db.updateBook(
        b.id,
        BooksCompanion(driveFileId: Value(fileId), driveCoverId: Value(coverId)),
      );
      report.uploaded++;
    }
  }

  // ---- Account removal ----

  /// Deletes everything this account keeps in Firestore.
  Future<void> deleteAllRemote() async {
    for (final name in [
      'books', 'collections', 'bookCollections', 'annotations', 'progress', 'sessions', 'words', 'devices', //
    ]) {
      while (true) {
        final page = await _user.collection(name).limit(400).get();
        if (page.docs.isEmpty) break;
        final batch = _fs.batch();
        for (final doc in page.docs) {
          batch.delete(doc.reference);
        }
        await batch.commit();
      }
    }
    await _user.delete();
    await store.remove(_pushKey);
    await store.remove(_cursorKey);
  }
}
