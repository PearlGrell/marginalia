import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:xml/xml.dart';

/// A book in the Project Gutenberg catalog.
class CatalogBook {
  const CatalogBook({required this.id, required this.title, this.author});

  final int id;
  final String title;
  final String? author;

  String get coverUrl => 'https://www.gutenberg.org/cache/epub/$id/pg$id.cover.medium.jpg';
}

class CatalogBookDetail extends CatalogBook {
  const CatalogBookDetail({
    required super.id,
    required super.title,
    super.author,
    this.summary,
    this.subjects = const [],
    this.language,
    this.downloads,
    this.epubUrl,
  });

  final String? summary;
  final List<String> subjects;
  final String? language;
  final int? downloads;
  final String? epubUrl;
}

/// A curated row on the Discover page: a catalog search sorted by popularity.
class Shelf {
  const Shelf(this.title, this.query);

  final String title;

  /// Gutenberg search syntax: `s.` subject, `l.` language; empty for the most popular.
  final String query;
}

const shelves = [
  Shelf('Popular classics', ''),
  Shelf('Adventure', 's.adventure'),
  Shelf('Mystery and detection', 's.detective'),
  Shelf('Science fiction', 's.science fiction'),
  Shelf('Love stories', 's.love stories'),
  Shelf('Horror and the uncanny', 's.horror'),
  Shelf('Poetry', 's.poetry'),
  Shelf("Children's books", 's.juvenile fiction'),
  Shelf('Philosophy', 's.philosophy'),
  Shelf('Humor', 's.humor'),
  Shelf('In French', 'l.fr'),
  Shelf('In German', 'l.de'),
  Shelf('In Spanish', 'l.es'),
];

class CatalogException implements Exception {
  CatalogException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Project Gutenberg's official OPDS catalog. Gutenberg asks apps not to scrape its site; the
/// catalog feeds and its download links are the supported way in. (Gutendex, the JSON mirror
/// the plan named, often takes over a minute to answer.) Responses are cached for a day.
class GutenbergCatalog {
  static const _base = 'https://www.gutenberg.org';
  static const _cacheFor = Duration(hours: 24);
  static const _timeout = Duration(seconds: 25);

  final _client = HttpClient()
    ..userAgent = 'Marginalia/1.0 (Android EPUB reader)'
    ..connectionTimeout = const Duration(seconds: 15);

  Future<List<CatalogBook>> search(String query, {int start = 1}) async {
    final uri = Uri.parse('$_base/ebooks/search.opds/').replace(
      queryParameters: {
        if (query.isNotEmpty) 'query': query,
        'sort_order': 'downloads',
        if (start > 1) 'start_index': '$start',
      },
    );
    final feed = XmlDocument.parse(await _get(uri));
    return [
      for (final entry in feed.findAllElements('entry'))
        if (_bookId(entry) case final id?)
          CatalogBook(
            id: id,
            title: _cleanTitle(entry.getElement('title')?.innerText ?? ''),
            author: _nonEmpty(entry.getElement('content')?.innerText.trim()),
          ),
    ];
  }

  Future<CatalogBookDetail> book(int id) async {
    final feed = XmlDocument.parse(await _get(Uri.parse('$_base/ebooks/$id.opds')));
    final entry = feed.findAllElements('entry').firstWhere(
      (e) => e.getElement('id')?.innerText.startsWith('urn:gutenberg:') ?? false,
      orElse: () => throw CatalogException('This book is not in the catalog.'),
    );
    final paragraphs = [
      for (final p in entry.findAllElements('p'))
        p.innerText.replaceAll(RegExp(r'\s+'), ' ').trim(),
    ];
    String? field(String name) => paragraphs
        .where((p) => p.startsWith('$name:'))
        .map((p) => p.substring(name.length + 1).trim())
        .firstOrNull;

    final epubs = [
      for (final link in entry.findAllElements('link'))
        if (link.getAttribute('type') == 'application/epub+zip') link.getAttribute('href')!,
    ];
    final epub = epubs.where((h) => h.contains('epub3.images')).firstOrNull ??
        epubs.where((h) => h.contains('.images')).firstOrNull ??
        epubs.firstOrNull;

    final author = entry.getElement('author')?.getElement('name')?.innerText;
    return CatalogBookDetail(
      id: id,
      title: _cleanTitle(entry.getElement('title')?.innerText ?? ''),
      author: author == null ? null : _naturalName(author),
      summary: field('Summary')?.replaceAll(' (This is an automatically generated summary.)', ''),
      subjects: [
        for (final c in entry.findAllElements('category'))
          if (c.getAttribute('scheme')?.endsWith('LCSH') ?? false) c.getAttribute('term')!,
      ],
      language: field('Language'),
      downloads: int.tryParse(field('Downloads') ?? ''),
      epubUrl: epub == null ? null : Uri.parse(_base).resolve(epub).toString(),
    );
  }

  /// Downloads a book's EPUB to a temporary file, reporting progress from 0 to 1.
  Future<File> download(CatalogBookDetail book, {void Function(double)? onProgress}) async {
    final url = book.epubUrl;
    if (url == null) throw CatalogException('No EPUB edition of this book.');
    try {
      final request = await _client.getUrl(Uri.parse(url)).timeout(_timeout);
      final response = await request.close().timeout(_timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw CatalogException('Download failed (${response.statusCode}).');
      }
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/gutenberg-${book.id}.epub');
      final sink = file.openWrite();
      final total = response.contentLength;
      var received = 0;
      await for (final chunk in response.timeout(_timeout)) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }
      await sink.close();
      return file;
    } on CatalogException {
      rethrow;
    } catch (_) {
      throw CatalogException("The download didn't finish. Check your connection.");
    }
  }

  /// Forgets cached catalog answers, so the next request goes to Gutenberg.
  Future<void> clearCache() async {
    final dir = Directory('${(await getTemporaryDirectory()).path}/gutenberg');
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  Future<String> _get(Uri uri) async {
    final cacheDir = Directory('${(await getTemporaryDirectory()).path}/gutenberg');
    await cacheDir.create(recursive: true);
    final key = base64Url.encode(utf8.encode(uri.toString())).replaceAll('=', '');
    final name = key.length > 120 ? key.substring(key.length - 120) : key;
    final cached = File('${cacheDir.path}/$name');
    if (await cached.exists() &&
        DateTime.now().difference(await cached.lastModified()) < _cacheFor) {
      return cached.readAsString();
    }
    try {
      final request = await _client.getUrl(uri).timeout(_timeout);
      final response = await request.close().timeout(_timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw CatalogException('The catalog answered ${response.statusCode}.');
      }
      final body = await response.transform(utf8.decoder).join().timeout(_timeout);
      await cached.writeAsString(body);
      return body;
    } catch (e) {
      // Offline or slow: an older copy is better than nothing.
      if (await cached.exists()) return cached.readAsString();
      if (e is CatalogException) rethrow;
      throw CatalogException("Can't reach Project Gutenberg. Check your connection.");
    }
  }

  static int? _bookId(XmlElement entry) {
    final id = entry.getElement('id')?.innerText ?? '';
    final match = RegExp(r'/ebooks/(\d+)\.opds$').firstMatch(id);
    return match == null ? null : int.parse(match.group(1)!);
  }

  static String? _nonEmpty(String? s) => s == null || s.isEmpty ? null : s;

  /// Gutenberg marks non-English titles "(French)" and so on; the shelf says that already.
  static String _cleanTitle(String title) =>
      title.replaceAll(RegExp(r'\s*\((English|French|German|Spanish)\)$'), '').trim();

  /// "Melville, Herman" → "Herman Melville".
  static String _naturalName(String name) {
    final parts = name.split(', ');
    return parts.length == 2 ? '${parts[1]} ${parts[0]}' : name;
  }
}

final gutenbergProvider = Provider<GutenbergCatalog>((ref) => GutenbergCatalog());

final shelfProvider = FutureProvider.family<List<CatalogBook>, String>(
  (ref, query) => ref.watch(gutenbergProvider).search(query),
);

final catalogBookProvider = FutureProvider.family<CatalogBookDetail, int>(
  (ref, id) => ref.watch(gutenbergProvider).book(id),
);
