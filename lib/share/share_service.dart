import 'dart:io';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:path_provider/path_provider.dart';

import '../cloud/account.dart';
import '../cloud/sync_service.dart';
import '../data/database.dart';
import '../data/library.dart';

/// A book inside a share.
class SharedBook {
  const SharedBook({
    required this.bookId,
    required this.title,
    required this.authors,
    required this.fileId,
    this.coverFileId,
    this.coverColor,
    this.fileSize = 0,
  });

  factory SharedBook.fromMap(Map<String, dynamic> m) => SharedBook(
    bookId: m['bookId'] as String,
    title: m['title'] as String? ?? 'Untitled',
    authors: ((m['authors'] as List?) ?? const []).cast<String>(),
    fileId: m['fileId'] as String,
    coverFileId: m['coverFileId'] as String?,
    coverColor: (m['coverColor'] as num?)?.toInt(),
    fileSize: (m['fileSize'] as num?)?.toInt() ?? 0,
  );

  /// The book's fingerprint, so a copy already in the library is recognized.
  final String bookId;
  final String title;
  final List<String> authors;

  /// The shared copy in the sender's Drive, readable by anyone with the link.
  final String fileId;
  final String? coverFileId;
  final int? coverColor;
  final int fileSize;

  String? get coverUrl => coverFileId == null ? null : 'https://drive.google.com/thumbnail?id=$coverFileId&sz=w600';

  Map<String, dynamic> toMap() => {
    'bookId': bookId,
    'title': title,
    'authors': authors,
    'fileId': fileId,
    'coverFileId': coverFileId,
    'coverColor': coverColor,
    'fileSize': fileSize,
  };
}

/// One or more books shared under a code.
class Share {
  const Share({
    required this.code,
    required this.title,
    required this.ownerName,
    required this.books,
    required this.createdAt,
  });

  factory Share.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final m = doc.data()!;
    return Share(
      code: doc.id,
      title: m['title'] as String? ?? '',
      ownerName: m['ownerName'] as String? ?? 'Someone',
      books: [for (final b in (m['books'] as List? ?? const [])) SharedBook.fromMap(Map<String, dynamic>.from(b as Map))],
      createdAt: (m['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  final String code;

  /// The book's title, or the collection's name.
  final String title;
  final String ownerName;
  final List<SharedBook> books;
  final DateTime createdAt;

  String get link => 'marginalia://app/share/$code';
}

class ShareException implements Exception {
  ShareException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Sharing books with friends and family.
///
/// A shared copy of each book goes into a "Marginalia shared" folder in the sender's own
/// Drive, readable by anyone with the link; `shares/{code}` in Firestore lists them. The
/// code is the document id and is unguessable: anyone signed in who knows it can open the
/// share, but shares can't be listed or searched. Stopping a share deletes the copies.
class ShareService {
  ShareService(this._ref);

  final Ref _ref;
  FirebaseFirestore get _fs => FirebaseFirestore.instance;

  static const _folderName = 'Marginalia shared';
  static const _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  User get _user {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw ShareException('Sign in under Settings to share books.');
    return user;
  }

  static String newCode() {
    final random = math.Random.secure();
    final chars = List.generate(12, (_) => _alphabet[random.nextInt(_alphabet.length)]).join();
    return '${chars.substring(0, 4)}-${chars.substring(4, 8)}-${chars.substring(8)}';
  }

  static String normalizeCode(String input) {
    final clean = input
        .trim()
        .toUpperCase()
        .replaceAll(RegExp(r'^MARGINALIA://APP/(SHARE|QUOTE)/'), '')
        .replaceAll(RegExp('[^A-Z0-9]'), '');
    if (clean.length != 12) return clean;
    return '${clean.substring(0, 4)}-${clean.substring(4, 8)}-${clean.substring(8)}';
  }

  /// Shares [books] under one code, titled [title]. Returns the share.
  Future<Share> create(List<Book> books, {required String title, void Function(String)? onStep}) async {
    final user = _user;
    final client = await driveClientFor(prompt: true, scopes: AccountController.shareScopes);
    if (client == null) throw ShareException('Allow Marginalia to save shared copies in your Drive.');
    final api = drive.DriveApi(client);
    try {
      final folder = await _folder(api);
      final shared = <SharedBook>[];
      for (final (i, book) in books.indexed) {
        onStep?.call('Copying ${i + 1} of ${books.length}: ${book.title}');
        final path = await _ref.read(syncProvider.notifier).ensureFile(book);
        if (path == null) throw ShareException("“${book.title}” isn't on this phone or in your Drive.");
        final fileId = await _upload(api, folder, File(path), '${book.title}.epub', 'application/epub+zip');
        String? coverId;
        if (book.coverPath case final cover? when await File(cover).exists()) {
          coverId = await _upload(api, folder, File(cover), '${book.title} (cover).jpg', 'image/jpeg');
        }
        shared.add(
          SharedBook(
            bookId: book.id,
            title: book.title,
            authors: book.authors,
            fileId: fileId,
            coverFileId: coverId,
            coverColor: book.coverColor,
            fileSize: book.fileSize,
          ),
        );
      }
      final code = newCode();
      await _fs.collection('shares').doc(code).set({
        'ownerUid': user.uid,
        'ownerName': user.displayName ?? user.email ?? 'Someone',
        'title': title,
        'books': [for (final b in shared) b.toMap()],
        'createdAt': FieldValue.serverTimestamp(),
      });
      return Share(
        code: code,
        title: title,
        ownerName: user.displayName ?? 'You',
        books: shared,
        createdAt: DateTime.now(),
      );
    } finally {
      client.close();
    }
  }

  Future<String> _folder(drive.DriveApi api) async {
    final found = await api.files.list(
      q: "name = '$_folderName' and mimeType = 'application/vnd.google-apps.folder' and trashed = false",
      $fields: 'files(id)',
      pageSize: 1,
    );
    final existing = found.files?.firstOrNull?.id;
    if (existing != null) return existing;
    final created = await api.files.create(
      drive.File(name: _folderName, mimeType: 'application/vnd.google-apps.folder'),
      $fields: 'id',
    );
    return created.id!;
  }

  Future<String> _upload(drive.DriveApi api, String folder, File file, String name, String type) async {
    final created = await api.files.create(
      drive.File(name: name, parents: [folder]),
      uploadMedia: drive.Media(file.openRead(), await file.length(), contentType: type),
      uploadOptions: drive.ResumableUploadOptions(),
      $fields: 'id',
    );
    await api.permissions.create(drive.Permission(type: 'anyone', role: 'reader'), created.id!);
    return created.id!;
  }

  /// The shares this user has made, newest first.
  Stream<List<Share>> mine() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return Stream.value(const []);
    return _fs
        .collection('shares')
        .where('ownerUid', isEqualTo: user.uid)
        .snapshots()
        .map((q) => [for (final d in q.docs) Share.fromDoc(d)]..sort((a, b) => b.createdAt.compareTo(a.createdAt)));
  }

  /// Stops sharing: the copies in Drive and the code go.
  Future<void> revoke(Share share) async {
    final client = await driveClientFor(prompt: true, scopes: AccountController.shareScopes);
    if (client != null) {
      final api = drive.DriveApi(client);
      for (final b in share.books) {
        for (final id in [b.fileId, b.coverFileId].whereType<String>()) {
          try {
            await api.files.delete(id);
          } catch (_) {
            // Already gone.
          }
        }
      }
      client.close();
    }
    await _fs.collection('shares').doc(share.code).delete();
  }

  /// Opens a share from its code and keeps it under "Shared with you".
  Future<Share> redeem(String input) async {
    final user = _user;
    final code = normalizeCode(input);
    final doc = await _fs.collection('shares').doc(code).get();
    if (!doc.exists) throw ShareException('No share has that code. It may have been stopped.');
    await _fs.collection('users').doc(user.uid).collection('received').doc(code).set({
      'code': code,
      'addedAt': FieldValue.serverTimestamp(),
    });
    return Share.fromDoc(doc);
  }

  /// Shares opened on this account, newest first; stopped ones drop out.
  Future<List<Share>> received() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return const [];
    final codes = await _fs
        .collection('users')
        .doc(user.uid)
        .collection('received')
        .orderBy('addedAt', descending: true)
        .get();
    final shares = <Share>[];
    for (final c in codes.docs) {
      final doc = await _fs.collection('shares').doc(c.id).get();
      if (doc.exists) shares.add(Share.fromDoc(doc));
    }
    return shares;
  }

  Future<void> forget(Share share) async {
    final user = _user;
    await _fs.collection('users').doc(user.uid).collection('received').doc(share.code).delete();
  }

  Future<Share?> open(String code) async {
    final doc = await _fs.collection('shares').doc(normalizeCode(code)).get();
    return doc.exists ? Share.fromDoc(doc) : null;
  }

  /// Downloads a shared book (its public copy) into the library. Returns its library id.
  Future<String> addToLibrary(Share share, SharedBook book, {void Function(double)? onProgress}) async {
    final temp = File('${(await getTemporaryDirectory()).path}/shared-${book.bookId}.epub');
    final client = HttpClient()..userAgent = 'Marginalia/1.0 (Android EPUB reader)';
    try {
      final request = await client.getUrl(
        Uri.parse('https://drive.usercontent.google.com/download?id=${book.fileId}&export=download&confirm=t'),
      );
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw ShareException("This book couldn't be downloaded (it may no longer be shared).");
      }
      final sink = temp.openWrite();
      final total = response.contentLength > 0 ? response.contentLength : book.fileSize;
      var received = 0;
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }
      await sink.close();
    } finally {
      client.close();
    }
    final id = await _ref
        .read(libraryImporterProvider.notifier)
        .importDownloaded(temp, source: BookSource.shared, sourceId: share.code);
    await _ref.read(syncProvider.notifier).scheduleSoon();
    return id;
  }
}

final shareServiceProvider = Provider<ShareService>(ShareService.new);

final mySharesProvider = StreamProvider<List<Share>>((ref) {
  ref.watch(accountProvider.select((a) => a.account?.uid));
  return ref.watch(shareServiceProvider).mine();
});

final receivedSharesProvider = FutureProvider<List<Share>>((ref) {
  ref.watch(accountProvider.select((a) => a.account?.uid));
  return ref.watch(shareServiceProvider).received();
});

final shareProvider = FutureProvider.family<Share?, String>(
  (ref, code) => ref.watch(shareServiceProvider).open(code),
);
