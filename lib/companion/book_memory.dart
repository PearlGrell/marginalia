import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../readium/readium.dart';
import 'companion.dart';
import 'conversation.dart';
import 'gemma.dart';
import 'people.dart';

/// A section of the book, from its contents: a story chapter, or front or back matter (kept
/// out of the story). A section can start part-way into one of the book's files (many books
/// put several chapters in a file): [heading] is the contents' title for it, found in the text
/// to tell where it starts.
class StoryChapter {
  const StoryChapter({required this.key, required this.index, required this.number, required this.title, this.heading});

  /// Its place among all the book's sections: what its summary is kept by.
  final int key;

  /// Reading-order index of the file it starts in.
  final int index;

  /// 1-based, among story chapters only (what the reader sees: "Ch 3 of 12"); 0 for front and
  /// back matter.
  final int number;
  final String title;

  /// Its title in the contents when it starts part-way into its file; null when it starts the
  /// file.
  final String? heading;

  bool get isStory => number > 0;

  Map<String, Object?> toJson() => {'i': index, 'n': number, 't': title, 'h': ?heading};

  static StoryChapter fromJson(Map<String, Object?> json, int key) => StoryChapter(
    key: key,
    index: json['i']! as int,
    number: json['n']! as int,
    title: json['t']! as String,
    heading: json['h'] as String?,
  );
}

/// Front and back matter: not part of the story, so never kept, summarised or searched.
final _notStory = RegExp(
  r'project gutenberg|table of contents|^contents$|copyright|licen[cs]e|title ?page|^cover$|dedication|colophon|'
  r'about the (author|publisher)|also by|^(preface|foreword|introduction|etymology|extracts|epigraph|'
  r'acknowledge?ments?|bibliography|index|glossary|footnotes|endnotes|notes|illustrations|list of illustrations|'
  r"transcriber[’']?s note)\b|\bedition\b",
  caseSensitive: false,
);

/// A part or book of a novel ("Book the First—Recalled to Life", "Part Two"), when its
/// chapters have their own entries: a heading, not a chapter.
final _division = RegExp(r'^(book|part|volume)\b', caseSensitive: false);

/// The book's sections, from its contents (and the files the contents leave out, if they're
/// longer than a page): story chapters numbered as the reader sees them, front and back matter
/// and the book's own title page left out of the story.
List<StoryChapter> storyChaptersOf(PublicationInfo publication) {
  final order = [for (final c in publication.chapters) _path(c.href)];
  int? fileOf(String href) {
    final path = _path(href);
    final i = order.indexOf(path);
    if (i >= 0) return i;
    final j = order.indexWhere((o) => o.endsWith(path) || path.endsWith(o));
    return j < 0 ? null : j;
  }

  // The contents' leaves, in reading order: a part with chapters of its own is its chapters.
  final leaves = <({int file, String title, bool fragment})>[];
  void walk(List<TocEntry> entries) {
    for (final e in entries) {
      if (e.children.isNotEmpty) {
        // The part's own page, when it has a file of its own.
        final file = fileOf(e.href);
        if (file != null && !e.children.any((c) => fileOf(c.href) == file)) {
          leaves.add((file: file, title: e.title.trim(), fragment: e.href.contains('#')));
        }
        walk(e.children);
        continue;
      }
      if (fileOf(e.href) case final file?) leaves.add((file: file, title: e.title.trim(), fragment: e.href.contains('#')));
    }
  }

  walk(publication.toc);
  // Stable: the contents' order within a file.
  final indexed = [...leaves.indexed]..sort((a, b) => a.$2.file != b.$2.file ? a.$2.file.compareTo(b.$2.file) : a.$1.compareTo(b.$1));
  final sorted = [for (final (_, l) in indexed) l];

  final bookTitle = _words(publication.title).join();
  bool front(String title) => _notStory.hasMatch(title) || (bookTitle.isNotEmpty && _words(title).join() == bookTitle);
  // Where the contents' story starts: files they leave out before it are front matter (a
  // dedication, an epigraph), not chapters.
  final firstStory = sorted.where((l) => !front(l.title)).firstOrNull?.file ?? 0;
  final out = <StoryChapter>[];
  var number = 0;
  void add(int file, String title, {String? heading, required bool story}) {
    out.add(StoryChapter(key: out.length, index: file, number: story ? ++number : 0, title: title, heading: heading));
  }

  for (final (file, chapter) in publication.chapters.indexed) {
    final here = [for (final l in sorted) if (l.file == file) l];
    if (here.isEmpty) {
      // A file the contents leave out: a chapter of its own if it's more than a page, and
      // after the story has started.
      if (chapter.count > 1) add(file, '', story: file >= firstStory);
      continue;
    }
    for (final (i, l) in here.indexed) {
      final isFront = front(l.title);
      final division = _division.hasMatch(l.title) && i + 1 < here.length;
      add(file, l.title, heading: l.fragment || i > 0 ? l.title : null, story: !isFront && !division);
    }
  }
  return out;
}

String _path(String href) => href.split('#').first.replaceFirst(RegExp(r'^/+'), '');

/// [text]'s words, lowercased, letters and digits only.
List<String> _words(String text) =>
    text.toLowerCase().split(RegExp(r'[^\p{L}\p{N}]+', unicode: true)).where((w) => w.isNotEmpty).toList();

/// Whether paragraph [text] is the heading the contents call [title]: the same words, or the
/// start or end of them ("CHAPTER II." for "I hope Mr. Bingley will like it. CHAPTER II."), or
/// the contents' title starting a longer heading ("Chapter 3" for "Chapter 3: The Visit").
bool isHeading(String text, String title) {
  if (text.length > 160) return false;
  final p = _words(text), t = _words(title);
  if (p.isEmpty || t.isEmpty) return false;
  if (p.join() == t.join()) return true;
  bool startsWith(List<String> a, List<String> b) => a.length >= b.length && List.generate(b.length, (i) => a[i] == b[i]).every((x) => x);
  bool endsWith(List<String> a, List<String> b) => startsWith(a.reversed.toList(), b.reversed.toList());
  bool enough(List<String> w) => w.join().length >= 5;
  return (enough(p) && (startsWith(t, p) || endsWith(t, p))) || (enough(t) && startsWith(p, t));
}

/// A paragraph kept of the book: its file (reading-order index) and progression in it.
typedef KeptParagraph = ({int chapter, double progression, String text});

/// Which of [sections] each of [paragraphs] (in reading order) is in, by index into
/// [sections]; -1 before the first.
///
/// A section starts where its heading is: the last place in its file the heading comes before
/// the next section's start (a list of contents or illustrations comes before the chapters it
/// lists), and not in such a list (short lines with other headings among them). A file's first
/// section whose heading isn't found starts the file; a later one is left empty, its text
/// staying with the section before.
List<int> sectionsOf(List<StoryChapter> sections, List<KeptParagraph> paragraphs) {
  final byFile = <int, List<int>>{};
  for (final (j, s) in sections.indexed) {
    (byFile[s.index] ??= []).add(j);
  }
  final starts = <int, int>{};
  for (var from = 0; from < paragraphs.length;) {
    final file = paragraphs[from].chapter;
    var end = from;
    while (end < paragraphs.length && paragraphs[end].chapter == file) {
      end++;
    }
    final here = byFile[file] ?? const <int>[];
    final headings = [for (final j in here) ?sections[j].heading];
    // Short lines (page numbers aside) with another of the file's headings among them.
    bool listed(int at) {
      final next = paragraphs.sublist(at + 1, end).where((q) => q.text.length > 4).take(6).toList();
      if (next.isEmpty || next.take(3).any((q) => q.text.length > 100)) return false;
      return next.any((q) => headings.any((h) => isHeading(q.text, h) && !isHeading(paragraphs[at].text, h)));
    }

    var bound = end;
    for (final (k, j) in here.indexed.toList().reversed) {
      final heading = sections[j].heading;
      int? at;
      if (heading != null) {
        for (var p = bound - 1; p >= from; p--) {
          if (isHeading(paragraphs[p].text, heading) && !listed(p)) {
            at = p;
            break;
          }
        }
      }
      if (at == null && k == 0) at = from;
      if (at != null) {
        starts[j] = at;
        bound = at;
      }
    }
    from = end;
  }

  final out = List.filled(paragraphs.length, -1);
  var current = -1;
  int? file;
  final starting = <int, List<int>>{};
  for (final MapEntry(key: j, value: at) in starts.entries) {
    (starting[at] ??= []).add(j);
  }
  for (var i = 0; i < paragraphs.length; i++) {
    if (paragraphs[i].chapter != file) {
      file = paragraphs[i].chapter;
      // Sections of files not kept in between: the text carries on from the last of them.
      current = math.max(current, sections.lastIndexWhere((s) => s.index < file!));
    }
    if (starting[i] case final js?) current = js.reduce(math.max);
    out[i] = current;
  }
  return out;
}

/// Whether [text] isn't the book's: Project Gutenberg's notices, illustration captions.
bool isBoilerplate(String text) => _boilerplate.hasMatch(text);

final _boilerplate = RegExp(r'project gutenberg|^\[?illustration\b|^(heading|tailpiece) to (chapter|preface)\b', caseSensitive: false);

/// Where the reader is: a reading-order index and how far through it.
typedef Place = ({int chapter, double progression});

/// What the companion keeps of a book, on the phone, as it's read: the text a page at a time
/// (`text.jsonl`, never the whole book at once), how far each file is kept (`state.json`, with
/// the book's sections) and each finished chapter's summary (`section-summaries.json`). Files
/// before the reader's page that weren't paged through (a jump ahead) are filled in later, one
/// at a time.
class BookMemory {
  BookMemory(this.bookId);

  final String bookId;

  Future<Directory> _dir() async {
    final dir = Directory('${(await getApplicationSupportDirectory()).path}/companion/$bookId');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> _file(String name) async => File('${(await _dir()).path}/$name');

  Future<Map<String, Object?>> _state() async {
    final file = await _file('state.json');
    if (!await file.exists()) return {};
    try {
      return (jsonDecode(await file.readAsString()) as Map).cast<String, Object?>();
    } on FormatException {
      return {};
    }
  }

  Future<void> _saveState(Map<String, Object?> state) async => (await _file('state.json')).writeAsString(jsonEncode(state));

  /// The book's sections, story chapters and the rest.
  Future<List<StoryChapter>> chapters() async => _chaptersIn(await _state());

  /// How far each file's text is kept (its last paragraph's progression), and which are kept
  /// to the end.
  Future<({Map<int, double> upTo, Set<int> complete})> kept() async {
    final state = await _state();
    return (
      upTo: {
        for (final e in ((state['upTo'] as Map?) ?? const {}).entries) int.parse(e.key as String): (e.value as num).toDouble(),
      },
      complete: {for (final c in (state['complete'] as List?) ?? const []) c as int},
    );
  }

  Future<void> setChapters(List<StoryChapter> chapters) async {
    await _saveState((await _state())..['chapters'] = [for (final c in chapters) c.toJson()]);
    // Kept by an earlier version: whole chapters (the page-by-page text replaces them), and
    // summaries of whole files (now they're of chapters).
    await for (final f in (await _dir()).list()) {
      if (f is File && RegExp(r'(chapter-\d+|[/\\]summaries)\.json$').hasMatch(f.path)) await f.delete();
    }
  }

  Future<void> _append(List<KeptParagraph> paragraphs) async {
    if (paragraphs.isEmpty) return;
    final out = StringBuffer();
    for (final p in paragraphs) {
      out.writeln(jsonEncode({'c': p.chapter, 'p': p.progression, 't': p.text}));
    }
    await (await _file('text.jsonl')).writeAsString(out.toString(), mode: FileMode.append, flush: true);
  }

  /// Keeps file [chapter]'s text up to [progression] (all of it at 1), reading out of the book
  /// only what isn't kept yet. Says whether that finished the file, and what it kept.
  Future<({bool finished, List<String> kept})> keep(Readium readium, String publicationId, int chapter, double progression) async {
    final state = await _state();
    final upTo = ((state['upTo'] as Map?) ?? {}).cast<String, Object?>();
    final complete = {for (final c in (state['complete'] as List?) ?? const []) c as int};
    if (complete.contains(chapter)) return (finished: false, kept: const <String>[]);
    final from = (upTo['$chapter'] as num?)?.toDouble() ?? -1;
    if (progression <= from) return (finished: false, kept: const <String>[]);
    final paragraphs = await readium.textRange(
      publicationId,
      fromChapter: chapter,
      afterProgression: from,
      toProgression: progression,
    );
    await _append(paragraphs);
    final reached = paragraphs.isEmpty ? progression : paragraphs.last.progression;
    upTo['$chapter'] = progression >= 1 ? 1.0 : (reached > from ? reached : from);
    final finished = progression >= 1;
    if (finished) complete.add(chapter);
    await _saveState(
      state
        ..['upTo'] = upTo
        ..['complete'] = complete.toList(),
    );
    return (finished: finished, kept: [for (final p in paragraphs) p.text]);
  }

  /// Summaries by section key ('' for a chapter with nothing to tell).
  Future<Map<int, String>> summaries() async {
    final file = await _file('section-summaries.json');
    if (!await file.exists()) return {};
    return {
      for (final MapEntry(:key, :value) in (jsonDecode(await file.readAsString()) as Map).entries)
        int.parse(key as String): value as String,
    };
  }

  Future<void> keepSummary(int key, String summary) async {
    final all = await summaries()..[key] = summary;
    await (await _file('section-summaries.json')).writeAsString(jsonEncode({for (final e in all.entries) '${e.key}': e.value}));
  }

  /// Everything kept of the book, in reading order.
  Future<List<KeptParagraph>> paragraphs() async {
    final file = await _file('text.jsonl');
    if (!await file.exists()) return const [];
    return _parse(await file.readAsString());
  }

  /// Everything kept of the book, when it's removed from the library.
  Future<void> forget() async {
    final dir = await _dir();
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  /// The book so far, at [place], built off the UI thread from what's kept: never anything past
  /// [place] (when the reader went back), and story chapters only, numbered as the reader sees
  /// them.
  Future<BookData> load({required Place place, required String title, String? authors}) async {
    final dir = (await _dir()).path;
    return Isolate.run(() => buildBookData(dir, place, title, authors));
  }
}

List<StoryChapter> _chaptersIn(Map<String, Object?> state) => [
  for (final (i, c) in ((state['chapters'] as List?) ?? const []).indexed) StoryChapter.fromJson((c as Map).cast(), i),
];

/// The kept text, in reading order, without what isn't the book's (see [isBoilerplate]).
List<KeptParagraph> _parse(String jsonl) => [
  for (final line in const LineSplitter().convert(jsonl))
    if (line.isNotEmpty)
      if (jsonDecode(line) case {'c': final int c, 'p': final num p, 't': final String t} when !isBoilerplate(t))
        (chapter: c, progression: p.toDouble(), text: t),
]..sort((a, b) => a.chapter != b.chapter ? a.chapter.compareTo(b.chapter) : a.progression.compareTo(b.progression));

/// The story chapters finished (a later section has begun, or the file they end is kept to its
/// end) in [sections], given which section each kept paragraph is in ([placed]) and the files
/// kept to the end.
Set<int> finishedChapters(List<StoryChapter> sections, List<int> placed, Set<int> completeFiles) {
  final latest = placed.fold(-1, math.max);
  return {
    for (final (i, s) in sections.indexed)
      if (s.isStory && (i < latest || (completeFiles.contains(s.index) && !sections.skip(i + 1).any((n) => n.index == s.index))))
        i,
  };
}

/// Everything the companion sheet shows, worked out at once (in an isolate).
class BookData {
  const BookData({
    required this.book,
    required this.people,
    required this.chapters,
    required this.current,
    required this.keySentences,
  });

  final BookSoFar book;
  final List<Person> people;

  /// The story chapters up to the reader's, with their numbers and titles.
  final List<StoryChapter> chapters;

  /// The chapter the reader is in, if it's a story chapter.
  final StoryChapter? current;

  /// A few of each chapter's own sentences (by number), for when it has no summary yet.
  final Map<int, List<String>> keySentences;
}

/// [BookData] from the files kept in [dir] (see [BookMemory.load]; public for tests).
Future<BookData> buildBookData(String dir, Place place, String title, String? authors) async {
  Future<String?> read(String name) async {
    final file = File('$dir/$name');
    return await file.exists() ? file.readAsString() : null;
  }

  final sections = _chaptersIn((jsonDecode(await read('state.json') ?? '{}') as Map).cast<String, Object?>());
  final summariesJson = (jsonDecode(await read('section-summaries.json') ?? '{}') as Map).cast<String, Object?>();

  // Never past the page: the reader may have gone back.
  bool before(int chapter, double progression) =>
      chapter < place.chapter || chapter == place.chapter && progression <= place.progression;
  final all = [
    for (final p in _parse(await read('text.jsonl') ?? ''))
      if (before(p.chapter, p.progression)) p,
  ];
  final placed = sectionsOf(sections, all);

  // Where the reader is: the section of the last paragraph kept up to the page, or else the
  // one the page's file starts with (its first, heading or not: see [sectionsOf]), or the last
  // one before it.
  final fileStart = sections.indexWhere((s) => s.index == place.chapter);
  final here = placed.isNotEmpty && all.last.chapter == place.chapter
      ? placed.last
      : fileStart >= 0
      ? fileStart
      : sections.lastIndexWhere((s) => s.index < place.chapter);
  final current = here >= 0 && sections[here].isStory ? sections[here] : null;

  // Story chapters only, numbered from here on as chapter N is paragraph chapter N - 1.
  final paragraphs = [
    for (final (i, p) in all.indexed)
      if (placed[i] >= 0 && sections[placed[i]].isStory) (chapter: sections[placed[i]].number - 1, text: p.text),
  ];
  final upTo = [for (final (i, c) in sections.indexed) if (c.isStory && i <= here) c];
  final book = BookSoFar(
    title: title,
    authors: authors,
    paragraphs: paragraphs,
    summaries: {
      for (final c in upTo)
        if (c != current)
          if (summariesJson['${c.key}'] case final String summary) c.number - 1: summary,
    },
    titles: {for (final c in upTo) c.number: c.title},
    chapterNow: current?.number,
  );
  return BookData(
    book: book,
    people: peopleIn(book.index),
    chapters: upTo,
    current: current,
    keySentences: {
      for (final c in upTo)
        if (c != current && !summariesJson.containsKey('${c.key}')) c.number: book.keySentences(c.number),
    },
  );
}

/// Keeps a book's text as it's read: a page at a time after each turn (a moment after, so
/// flicking through doesn't read anything), and the files before the page that weren't paged
/// through, one at a time in the background. Finished chapters get their summaries (see
/// [ChapterSummaries]).
class BookKeeper {
  BookKeeper({
    required this.bookId,
    required this.publication,
    required this.title,
    this.authors,
    required this.onChapterFinished,
  }) : memory = BookMemory(bookId);

  final String bookId;
  final PublicationInfo publication;
  final String title;
  final String? authors;
  final BookMemory memory;

  /// A chapter may have just finished: its summary can be written.
  final void Function() onChapterFinished;

  static const _readium = Readium();

  late final List<StoryChapter> _chapters = storyChaptersOf(publication);

  /// The files that hold story (reading-order indexes), in order.
  late final List<int> _storyFiles = {for (final c in _chapters) if (c.isStory) c.index}.toList()..sort();
  Future<void>? _ready;
  Timer? _debounce;
  Place? _pending;
  Future<void> _work = Future.value();
  var _filling = false;
  final _tried = <int>{};
  var _closed = false;

  /// Where [location] is, as a reading-order index and progression.
  Place? placeOf(ReaderLocation location) {
    final chapter = publication.chapterFor(location.href);
    if (chapter == null) return null;
    return (chapter: publication.chapters.indexOf(chapter), progression: location.progression ?? 0);
  }

  Future<void> _start() => _ready ??= memory.setChapters(_chapters);

  /// The reader is at [location]: keep the page, a moment from now.
  void reached(ReaderLocation location) {
    final place = placeOf(location);
    if (place == null) return;
    _pending = place;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 1200), flush);
  }

  /// Keeps what's waiting now (before the companion opens, so it has the page on screen).
  Future<void> flush() {
    _debounce?.cancel();
    final place = _pending;
    _pending = null;
    if (place == null) return _work;
    return _work = _work.then((_) => _keep(place)).catchError((_) {});
  }

  /// Keeps file [file] up to [progression]; says when that may have finished a chapter (the
  /// file ended, or a later chapter's heading came).
  Future<void> _keepFile(int file, double progression) async {
    final (:finished, :kept) = await memory.keep(_readium, publication.id, file, progression);
    final headings = [for (final c in _chapters) if (c.index == file && c.heading != null) c.heading!];
    if (finished || kept.any((t) => headings.any((h) => isHeading(t, h)))) onChapterFinished();
  }

  Future<void> _keep(Place place) async {
    if (_closed) return;
    await _start();
    if (!_storyFiles.contains(place.chapter)) return;
    // The file before, if the reader just turned out of it: kept to its end now.
    final previous = _storyFiles.where((f) => f < place.chapter).lastOrNull;
    if (previous != null) {
      final (:upTo, :complete) = await memory.kept();
      if (!complete.contains(previous) && upTo.containsKey(previous)) await _keepFile(previous, 1);
    }
    await _keepFile(place.chapter, place.progression);
    unawaited(_fillGaps(place.chapter));
  }

  /// Files before [file] not kept to their end (jumped over, or read before the app kept books):
  /// kept now, nearest first, one file a step with a pause between.
  Future<void> _fillGaps(int file) async {
    if (_filling) return;
    _filling = true;
    try {
      while (!_closed) {
        final (:upTo, :complete) = await memory.kept();
        final gap = _storyFiles.reversed.where((f) => f < file && !complete.contains(f) && !_tried.contains(f)).firstOrNull;
        if (gap == null) break;
        // Once each while the book is open: one that can't be read isn't tried over and over.
        _tried.add(gap);
        await (_work = _work.then((_) => _keepFile(gap, 1)).catchError((_) {}));
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    } finally {
      _filling = false;
    }
  }

  void close() {
    _closed = true;
    _debounce?.cancel();
  }
}

/// Writes chapter summaries in the background, from the kept text: one at a time, newest first,
/// with whichever model the phone has (none: nothing). The reader keeps the text; nothing is
/// read out of the book here. A question asked in the companion goes first: each summary waits
/// until nothing is being answered.
class ChapterSummaries extends Notifier<int> {
  /// Bumped each time a summary is written, for what shows them.
  @override
  int build() => 0;

  final _queue = <(String, String, String?)>[];
  Future<void>? _running;

  /// Summarises book [bookId]'s finished chapters that have no summary yet.
  void catchUp({required String bookId, required String title, String? authors}) {
    if (!_queue.any((q) => q.$1 == bookId)) _queue.add((bookId, title, authors));
    _running ??= _run().whenComplete(() => _running = null);
  }

  Future<void> _run() async {
    while (_queue.isNotEmpty) {
      final (bookId, title, authors) = _queue.removeAt(0);
      try {
        await _summarise(bookId, title, authors);
      } catch (_) {
        // Next time a chapter is finished.
      }
    }
  }

  Future<void> _summarise(String bookId, String title, String? authors) async {
    final nano = await const Nano().status() == NanoStatus.available;
    final gemma = ref.read(gemmaProvider.notifier);
    if (!nano && !ref.read(gemmaProvider).installed) return;
    final memory = BookMemory(bookId);
    final sections = await memory.chapters();
    final paragraphs = await memory.paragraphs();
    final placed = sectionsOf(sections, paragraphs);
    final finished = finishedChapters(sections, placed, (await memory.kept()).complete);
    final done = await memory.summaries();
    for (final i in finished.toList().reversed) {
      final chapter = sections[i];
      if (done.containsKey(chapter.key)) continue;
      final text = [for (final (j, p) in paragraphs.indexed) if (placed[j] == i) p.text];
      if (text.fold(0, (n, p) => n + p.length) < 600) {
        await memory.keepSummary(chapter.key, '');
        continue;
      }
      // Questions in the companion first.
      if (!nano) await gemma.idle();
      final prompt = summaryPrompt(title, authors, chapter, text);
      final summary = nano ? await const Nano().generate(prompt) : await gemma.once(prompt, maxTokens: 90);
      if (summary == null || summary.trim().isEmpty) return;
      await memory.keepSummary(chapter.key, tidyAnswer(summary));
      state++;
    }
    if (!nano) await gemma.releaseIfIdle();
  }

  /// The prompt for [chapter]'s summary, from its [text] (public for tests).
  static String summaryPrompt(String title, String? authors, StoryChapter chapter, List<String> text) {
    final key = recapSentences([for (final p in text) (chapter: 0, text: p)], chapters: 1, count: 14);
    final passages = StringBuffer();
    for (final s in key) {
      if (passages.length + s.length > 2400) break;
      passages.writeln('- $s');
    }
    return 'These are the key sentences, in order, of ${chapterLabel(chapter.number, chapter.title)} of "$title"'
        '${authors == null || authors.isEmpty ? '' : ' by $authors'}.\n\n$passages\n'
        'Summarise what happens in this chapter in two or three plain sentences: who is involved and what '
        'they do. Use only these sentences. No introduction, no lists.';
  }
}

final chapterSummariesProvider = NotifierProvider<ChapterSummaries, int>(ChapterSummaries.new);
