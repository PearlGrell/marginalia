import '../companion/book_memory.dart';
import '../readium/readium.dart';

/// Where the reader is in the chapter, for under the page: "Ch 4 of 22 · 6 pages, 12 min
/// left". Chapters are the book's story chapters, as the companion counts them (see
/// [storyChaptersOf]): front and back matter aren't counted. Null on a page too short to say
/// (a cover, a contents page) or that isn't in a chapter.
String? chapterProgress(
  PublicationInfo publication, {
  required String href,
  int? position,
  double? progression,
  required double secondsPerPosition,
}) {
  final chapter = publication.chapterFor(href);
  if (chapter == null || chapter.count <= 1) return null;
  final sections = _sections[publication] ??= storyChaptersOf(publication);
  final file = publication.chapters.indexOf(chapter);
  // The file's first chapter (later ones in it start somewhere on its pages), or, for a file
  // with none of its own, the one before it carries on.
  final inFile = sections.where((s) => s.index == file);
  final section = inFile.isNotEmpty
      ? inFile.where((s) => s.isStory).firstOrNull
      : sections.where((s) => s.index < file).lastOrNull;
  if (section == null || !section.isStory) return null;
  final number = 'Ch ${section.number} of ${sections.where((s) => s.isStory).length}';

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

/// Each book's sections, worked out once (this runs on every page).
final _sections = Expando<List<StoryChapter>>();
