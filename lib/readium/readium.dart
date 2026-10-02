import 'package:flutter/services.dart';

/// Dart side of the native Readium bridge (see `ReadiumChannel.kt`).
class Readium {
  const Readium();

  static const _channel = MethodChannel('marginalia/readium');

  /// Opens the EPUB at [path] and keeps it open natively until [close] is called.
  Future<PublicationInfo> open(String path) async {
    try {
      final result = await _channel.invokeMapMethod<String, Object?>('open', {'path': path});
      return PublicationInfo.fromMap(result!);
    } on PlatformException catch (e) {
      throw ReadiumException(e.message ?? 'Could not open this book.');
    }
  }

  Future<void> close(String publicationId) =>
      _channel.invokeMethod('close', {'id': publicationId});
}

class ReadiumException implements Exception {
  ReadiumException(this.message);

  final String message;

  @override
  String toString() => message;
}

class PublicationInfo {
  const PublicationInfo({
    required this.id,
    required this.title,
    required this.authors,
    required this.language,
    required this.isRightToLeft,
    required this.toc,
    required this.chapters,
  });

  factory PublicationInfo.fromMap(Map<String, Object?> map) => PublicationInfo(
    id: map['id']! as String,
    title: map['title'] as String? ?? 'Untitled',
    authors: (map['authors'] as List?)?.whereType<String>().toList() ?? const [],
    language: map['language'] as String?,
    isRightToLeft: map['readingProgression'] == 'rtl',
    toc: _tocFromList(map['toc']),
    chapters: [
      for (final c in (map['chapters'] as List?) ?? const [])
        if (c is Map)
          ChapterPositions(
            href: c['href']! as String,
            start: c['start']! as int,
            count: c['count']! as int,
          ),
    ],
  );

  /// Native publication handle, valid until closed.
  final String id;
  final String title;
  final List<String> authors;
  final String? language;
  final bool isRightToLeft;
  final List<TocEntry> toc;

  /// Readium positions per reading-order chapter.
  final List<ChapterPositions> chapters;

  ChapterPositions? chapterFor(String href) {
    final path = href.split('#').first;
    return chapters.where((c) => c.href.split('#').first == path).firstOrNull;
  }
}

/// A chapter's span of Readium positions (about 1,024 characters each).
class ChapterPositions {
  const ChapterPositions({required this.href, required this.start, required this.count});

  final String href;

  /// Its first position number (positions count from 1 through the book).
  final int start;
  final int count;

  int get end => start + count - 1;
}

class TocEntry {
  const TocEntry({required this.title, required this.href, required this.children});

  final String title;
  final String href;
  final List<TocEntry> children;
}

List<TocEntry> _tocFromList(Object? list) => [
  for (final item in (list as List?) ?? const [])
    if (item is Map)
      TocEntry(
        title: item['title'] as String? ?? '',
        href: item['href'] as String,
        children: _tocFromList(item['children']),
      ),
];

/// One place a search found, with the words around it.
class SearchResult {
  const SearchResult({
    required this.locatorJson,
    this.chapter,
    this.before = '',
    required this.match,
    this.after = '',
    this.progression,
  });

  factory SearchResult.fromMap(Map<Object?, Object?> map) => SearchResult(
    locatorJson: map['locator']! as String,
    chapter: map['title'] as String?,
    before: map['before'] as String? ?? '',
    match: map['match'] as String? ?? '',
    after: map['after'] as String? ?? '',
    progression: (map['progression'] as num?)?.toDouble(),
  );

  final String locatorJson;
  final String? chapter;
  final String before;
  final String match;
  final String after;

  /// Through the whole book, 0 to 1.
  final double? progression;
}

/// A footnote's text, shown in a popup rather than jumped to.
class Footnote {
  const Footnote({required this.html, this.href});

  final String html;

  /// Where the note lives in the book, to go and read it in place.
  final String? href;
}

/// The reading position reported by Readium.
class ReaderLocation {
  const ReaderLocation({
    required this.locatorJson,
    required this.href,
    this.title,
    this.progression,
    this.totalProgression,
    this.position,
  });

  factory ReaderLocation.fromMap(Map<Object?, Object?> map) => ReaderLocation(
    locatorJson: map['locator']! as String,
    href: map['href']! as String,
    title: map['title'] as String?,
    progression: (map['progression'] as num?)?.toDouble(),
    totalProgression: (map['totalProgression'] as num?)?.toDouble(),
    position: map['position'] as int?,
  );

  /// Readium Locator JSON; store this to restore the position.
  final String locatorJson;
  final String href;

  /// Title of the current chapter, when known.
  final String? title;

  /// Progression within the current chapter, 0 to 1.
  final double? progression;

  /// Progression within the whole book, 0 to 1.
  final double? totalProgression;
  final int? position;
}
