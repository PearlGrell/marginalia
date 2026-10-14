import '../readium/readium.dart';

/// Where the reader is in the chapter, for under the page: "Ch 4 of 22 · 6 pages, 12 min
/// left". Chapters are the book's longer reading-order items (covers, title pages and the like
/// aren't counted). Null on a page too short to say (a cover, a contents page).
String? chapterProgress(
  PublicationInfo publication, {
  required String href,
  int? position,
  double? progression,
  required double secondsPerPosition,
}) {
  final chapter = publication.chapterFor(href);
  if (chapter == null || chapter.count <= 1) return null;
  final chapters = publication.chapters.where((c) => c.count > 1).toList();
  final number = 'Ch ${chapters.indexOf(chapter) + 1} of ${chapters.length}';

  final double remaining;
  if (position != null && position >= chapter.start && position <= chapter.end) {
    remaining = (chapter.end - position).toDouble();
  } else if (progression != null) {
    remaining = chapter.count * (1 - progression.clamp(0.0, 1.0));
  } else {
    return number;
  }
  final pages = remaining.round();
  if (pages < 1) return '$number · last page';
  final minutes = (remaining * secondsPerPosition / 60).round();
  final time = switch (minutes) {
    < 1 => 'under a minute',
    < 60 => '$minutes min',
    _ => minutes % 60 == 0 ? '${minutes ~/ 60} h' : '${minutes ~/ 60} h ${minutes % 60} min',
  };
  return '$number · $pages ${pages == 1 ? 'page' : 'pages'}, $time left';
}
