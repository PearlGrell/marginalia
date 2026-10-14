import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cloud/account.dart';
import '../data/database.dart';
import '../share/share_service.dart' show ShareService;

/// A book club: friends reading one book, who see each other's shared highlights and notes
/// in the page and talk about them.
///
/// Firestore: `clubs/{code}` (the code is the invitation: unguessable, and clubs can't be
/// listed), with `members/{uid}`, `notes/{annotationId}` and `notes/{id}/comments/{id}`.
/// Each member keeps `users/{uid}/clubs/{code}` to find their clubs. The book is the same
/// file for everyone, so it's matched by its fingerprint.
class Club {
  const Club({
    required this.code,
    required this.name,
    required this.bookId,
    required this.title,
    required this.ownerUid,
  });

  factory Club.fromMap(String code, Map<String, dynamic> m) => Club(
    code: code,
    name: m['name'] as String? ?? 'Book club',
    bookId: m['bookId'] as String? ?? '',
    title: m['title'] as String? ?? '',
    ownerUid: m['ownerUid'] as String? ?? '',
  );

  final String code;
  final String name;
  final String bookId;
  final String title;
  final String ownerUid;

  String get link => 'marginalia://app/club/$code';
}

/// A highlight or note a member shared with a club.
class ClubNote {
  const ClubNote({
    required this.club,
    required this.id,
    required this.authorUid,
    required this.authorName,
    required this.locator,
    this.quote,
    this.note,
    this.chapterTitle,
    this.progression,
    required this.createdAt,
  });

  factory ClubNote.fromDoc(String club, DocumentSnapshot<Map<String, dynamic>> doc) {
    final m = doc.data() ?? const {};
    return ClubNote(
      club: club,
      id: doc.id,
      authorUid: m['authorUid'] as String? ?? '',
      authorName: m['authorName'] as String? ?? 'Someone',
      locator: m['locator'] as String? ?? '{}',
      quote: m['quote'] as String?,
      note: m['note'] as String?,
      chapterTitle: m['chapterTitle'] as String?,
      progression: (m['progression'] as num?)?.toDouble(),
      createdAt: (m['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  final String club;
  final String id;
  final String authorUid;
  final String authorName;

  /// Readium Locator JSON.
  final String locator;
  final String? quote;
  final String? note;
  final String? chapterTitle;
  final double? progression;
  final DateTime createdAt;

  /// The id it's drawn under in the page, told apart from the reader's own highlights.
  String get decorationId => '${ClubNote.prefix}$club:$id';

  static const prefix = 'club:';

  /// (club code, note id) from a [decorationId], or null for the reader's own.
  static (String, String)? parseDecorationId(String id) {
    if (!id.startsWith(prefix)) return null;
    final rest = id.substring(prefix.length);
    final at = rest.indexOf(':');
    return at < 0 ? null : (rest.substring(0, at), rest.substring(at + 1));
  }
}

class ClubComment {
  const ClubComment({required this.id, required this.authorUid, required this.authorName, required this.text, required this.createdAt});

  final String id;
  final String authorUid;
  final String authorName;
  final String text;
  final DateTime createdAt;
}

class ClubException implements Exception {
  ClubException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Each member's color in the page, the same on every phone.
Color memberColor(String uid) {
  const palette = [
    Color(0xFF3B82F6), Color(0xFF10B981), Color(0xFFF59E0B), Color(0xFFEC4899), //
    Color(0xFF8B5CF6), Color(0xFF14B8A6), Color(0xFFEF4444), Color(0xFF84CC16),
  ];
  final hash = utf8.encode(uid).fold<int>(0, (h, c) => (h * 31 + c) & 0x7fffffff);
  return palette[hash % palette.length];
}

class ClubService {
  const ClubService();

  // Firebase is only there when the cloud is set up (and never in tests).
  bool get _ready => Firebase.apps.isNotEmpty;
  FirebaseFirestore get _fs => FirebaseFirestore.instance;
  FirebaseAuth get _auth => FirebaseAuth.instance;

  User get _user {
    final user = _ready ? _auth.currentUser : null;
    if (user == null) throw ClubException('Sign in under Settings to read with friends.');
    return user;
  }

  String get _name => _user.displayName ?? _user.email ?? 'A reader';

  DocumentReference<Map<String, dynamic>> _club(String code) => _fs.collection('clubs').doc(code);

  DocumentReference<Map<String, dynamic>> _mine(String uid, String code) =>
      _fs.collection('users').doc(uid).collection('clubs').doc(code);

  /// Starts a club around [book], with this reader in it.
  Future<Club> create(Book book, {required String name}) async {
    final user = _user;
    final code = ShareService.newCode();
    final club = Club(code: code, name: name, bookId: book.id, title: book.title, ownerUid: user.uid);
    await _club(code).set({
      'name': name,
      'bookId': book.id,
      'title': book.title,
      'authors': book.authors,
      'ownerUid': user.uid,
      'ownerName': _name,
      'createdAt': FieldValue.serverTimestamp(),
    });
    await _join(club);
    return club;
  }

  /// The club with [input] as its code (or link), without joining.
  Future<Club> find(String input) async {
    _user;
    final code = normalizeClubCode(input);
    final doc = await _club(code).get();
    if (!doc.exists) throw ClubException('No club has that code. It may have closed.');
    return Club.fromMap(code, doc.data()!);
  }

  Future<void> join(Club club) => _join(club);

  Future<void> _join(Club club) async {
    final user = _user;
    await _club(club.code).collection('members').doc(user.uid).set({
      'name': _name,
      'joinedAt': FieldValue.serverTimestamp(),
    });
    await _mine(user.uid, club.code).set({
      'name': club.name,
      'bookId': club.bookId,
      'title': club.title,
      'ownerUid': club.ownerUid,
      'joinedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Leaves [club] (its owner closes it for everyone).
  Future<void> leave(Club club) async {
    final user = _user;
    if (club.ownerUid == user.uid) {
      await _club(club.code).delete();
    } else {
      await _club(club.code).collection('members').doc(user.uid).delete();
    }
    await _mine(user.uid, club.code).delete();
  }

  /// The clubs this reader is in.
  Stream<List<Club>> mine() {
    final user = _ready ? _auth.currentUser : null;
    if (user == null) return Stream.value(const []);
    return _fs
        .collection('users')
        .doc(user.uid)
        .collection('clubs')
        .snapshots()
        .map((q) => [for (final d in q.docs) Club.fromMap(d.id, d.data())]);
  }

  Stream<List<({String uid, String name})>> members(String code) => _club(code)
      .collection('members')
      .snapshots()
      .map((q) => [for (final d in q.docs) (uid: d.id, name: d.data()['name'] as String? ?? 'A reader')]);

  Stream<List<ClubNote>> notes(String code) => _club(code)
      .collection('notes')
      .snapshots()
      .map((q) => [for (final d in q.docs) ClubNote.fromDoc(code, d)]..sort((a, b) => b.createdAt.compareTo(a.createdAt)));

  Stream<List<ClubComment>> comments(String code, String noteId) => _club(code)
      .collection('notes')
      .doc(noteId)
      .collection('comments')
      .orderBy('createdAt')
      .snapshots()
      .map(
        (q) => [
          for (final d in q.docs)
            ClubComment(
              id: d.id,
              authorUid: d.data()['authorUid'] as String? ?? '',
              authorName: d.data()['authorName'] as String? ?? 'Someone',
              text: d.data()['text'] as String? ?? '',
              createdAt: (d.data()['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
            ),
        ],
      );

  /// Shares [annotation] (as it is now) with [club]; again to update it.
  Future<void> share(Club club, Annotation annotation) async {
    final user = _user;
    await _club(club.code).collection('notes').doc(annotation.id).set({
      'authorUid': user.uid,
      'authorName': _name,
      'locator': annotation.locator,
      'quote': annotation.selectedText,
      'note': annotation.note,
      'chapterTitle': annotation.chapterTitle,
      'progression': annotation.progression,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> unshare(Club club, String annotationId) =>
      _club(club.code).collection('notes').doc(annotationId).delete();

  Future<void> comment(String code, String noteId, String text) async {
    final user = _user;
    await _club(code).collection('notes').doc(noteId).collection('comments').add({
      'authorUid': user.uid,
      'authorName': _name,
      'text': text.trim(),
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  String? get myUid => _ready ? _auth.currentUser?.uid : null;
}

/// A club code from what was typed or pasted (the code, or its link).
String normalizeClubCode(String input) {
  final clean = input
      .trim()
      .toUpperCase()
      .replaceAll(RegExp(r'^MARGINALIA://APP/CLUB/'), '')
      .replaceAll(RegExp('[^A-Z0-9]'), '');
  if (clean.length != 12) return clean;
  return '${clean.substring(0, 4)}-${clean.substring(4, 8)}-${clean.substring(8)}';
}

final clubServiceProvider = Provider<ClubService>((ref) => const ClubService());

final myClubsProvider = StreamProvider<List<Club>>((ref) {
  // Again on signing in or out.
  ref.watch(accountProvider.select((a) => a.account?.uid));
  return ref.watch(clubServiceProvider).mine();
});

/// The clubs reading [bookId].
final clubsForBookProvider = Provider.family<List<Club>, String>(
  (ref, bookId) => [
    for (final c in ref.watch(myClubsProvider).value ?? const <Club>[])
      if (c.bookId == bookId) c,
  ],
);

final clubNotesProvider = StreamProvider.family<List<ClubNote>, String>(
  (ref, code) => ref.watch(clubServiceProvider).notes(code),
);

/// What other members of [bookId]'s clubs have shared, to draw in its pages.
final othersNotesProvider = Provider.family<List<ClubNote>, String>((ref, bookId) {
  final me = ref.watch(clubServiceProvider).myUid;
  return [
    for (final club in ref.watch(clubsForBookProvider(bookId)))
      for (final note in ref.watch(clubNotesProvider(club.code)).value ?? const <ClubNote>[])
        if (note.authorUid != me) note,
  ];
});
