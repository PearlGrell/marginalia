import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../storage/local_store.dart';
import 'share_service.dart';

/// A highlight or note shared as a link.
class SharedQuote {
  const SharedQuote({
    required this.code,
    required this.quote,
    this.note,
    required this.title,
    required this.authors,
    this.color,
    this.coverColor,
    required this.ownerName,
    required this.createdAt,
  });

  factory SharedQuote.fromMap(String code, Map<String, dynamic> m) => SharedQuote(
    code: code,
    quote: m['quote'] as String? ?? '',
    note: m['note'] as String?,
    title: m['title'] as String? ?? '',
    authors: ((m['authors'] as List?) ?? const []).cast<String>(),
    color: m['color'] as String?,
    coverColor: (m['coverColor'] as num?)?.toInt(),
    ownerName: m['ownerName'] as String? ?? 'Someone',
    createdAt: (m['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
  );

  final String code;
  final String quote;
  final String? note;
  final String title;
  final List<String> authors;

  /// A highlight color name.
  final String? color;
  final int? coverColor;
  final String ownerName;
  final DateTime createdAt;

  String get link => quoteLink(code);
}

String quoteLink(String code) => 'marginalia://app/quote/$code';

/// The text that goes with a shared link: the passage itself, so it reads well anywhere,
/// and the link to open it in Marginalia.
String quoteMessage({required String quote, String? note, required String title, List<String> authors = const [], required String code}) {
  final by = authors.isEmpty ? '' : ', ${authors.join(', ')}';
  final trimmed = quote.trim();
  final short = trimmed.length > 600 ? '${trimmed.substring(0, 600).trimRight()}…' : trimmed;
  return [
    '“$short”',
    '— $title$by',
    if (note != null && note.trim().isNotEmpty) '\n${note.trim()}',
    '\nOpen in Marginalia: ${quoteLink(code)}',
  ].join('\n');
}

/// Highlights and notes shared as links: `quotes/{code}` in Firestore. Like book shares, the
/// unguessable code is the document id; anyone signed in who has it can read that one quote.
class QuoteService {
  QuoteService(this._store);

  final LocalStore _store;
  FirebaseFirestore get _fs => FirebaseFirestore.instance;

  static const _linksKey = 'quotes.byAnnotation';

  Map<String, String> get _links =>
      ((_store.readJson(_linksKey) as Map?) ?? const {}).map((k, v) => MapEntry(k as String, v as String));

  /// The link for [annotation], made once and reused.
  Future<String> linkFor(Annotation annotation, Book book) async {
    final existing = _links[annotation.id];
    if (existing != null) {
      // Keep it current if the note changed since.
      await _fs.collection('quotes').doc(existing).update({'note': annotation.note}).catchError((_) {});
      return existing;
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw ShareException('Sign in under Settings to share links.');
    final code = ShareService.newCode();
    await _fs.collection('quotes').doc(code).set({
      'ownerUid': user.uid,
      'ownerName': user.displayName ?? user.email ?? 'Someone',
      'quote': annotation.selectedText ?? '',
      'note': annotation.note,
      'title': book.title,
      'authors': book.authors,
      'color': annotation.color,
      'coverColor': book.coverColor,
      'createdAt': FieldValue.serverTimestamp(),
    });
    await _store.writeJson(_linksKey, {..._links, annotation.id: code});
    return code;
  }

  Future<SharedQuote> open(String code) async {
    final doc = await _fs.collection('quotes').doc(ShareService.normalizeCode(code)).get();
    final data = doc.data();
    if (data == null) throw ShareException('This link has expired or was taken down.');
    return SharedQuote.fromMap(doc.id, data);
  }

  /// Takes a link down.
  Future<void> revoke(String annotationId) async {
    final code = _links[annotationId];
    if (code == null) return;
    await _fs.collection('quotes').doc(code).delete();
    await _store.writeJson(_linksKey, {..._links}..remove(annotationId));
  }

  bool hasLink(String annotationId) => _links.containsKey(annotationId);
}

final quoteServiceProvider = Provider<QuoteService>((ref) => QuoteService(ref.watch(localStoreProvider)));
