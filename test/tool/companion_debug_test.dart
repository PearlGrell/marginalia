// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marginalia/companion/book_memory.dart';
import 'package:marginalia/companion/conversation.dart';
import 'package:marginalia/readium/readium.dart';
import 'package:xml/xml.dart';

/// Runs the reading companion on real EPUBs, as the app would after reading half of each:
/// the story chapters it finds, the people, and what it would ask the model.
///   COMPANION_BOOKS=dir/with/epubs flutter test test/tool/companion_debug_test.dart
void main() {
  final dir = Platform.environment['COMPANION_BOOKS'];
  test('the companion on real books', () async {
    for (final file in Directory(dir!).listSync().whereType<File>().where((f) => f.path.endsWith('.epub'))) {
      final book = readEpub(file);
      final info = PublicationInfo(
        id: 'x',
        title: book.title,
        authors: book.authors,
        language: 'en',
        isRightToLeft: false,
        toc: book.toc,
        chapters: book.chapters,
      );
      final sections = storyChaptersOf(info);
      final story = [for (final s in sections) if (s.isStory) s];
      final out = StringBuffer()
        ..writeln('\n================ ${book.title} (${file.uri.pathSegments.last})')
        ..writeln('files: ${book.chapters.length}, sections: ${sections.length}, story chapters: ${story.length}')
        ..writeln('  left out: ${[for (final s in sections) if (!s.isStory) '[${s.index}] "${s.title}"'].take(10).join('; ')}');
      if (story.isEmpty) {
        print(out);
        continue;
      }

      // The whole book kept (to check every chapter gets its own text), then a place halfway.
      final all = [
        for (final (f, paragraphs) in book.text.indexed)
          for (final (i, p) in paragraphs.indexed)
            if (!isBoilerplate(p)) (chapter: f, progression: i / paragraphs.length, text: p),
      ];
      final placed = sectionsOf(sections, all);
      if (Platform.environment['COMPANION_TRACE'] case final trace? when book.title.contains(trace)) {
        for (final (i, p) in all.indexed) {
          if (i > 0 && placed[i] == placed[i - 1] && p.text.length > 80) continue;
          print('  #$i f${p.chapter} s${placed[i]} ${p.text.length > 70 ? '${p.text.substring(0, 70)}…' : p.text}');
          if (i > 400) break;
        }
      }
      final counts = <int, int>{};
      for (final s in placed) {
        counts[s] = (counts[s] ?? 0) + 1;
      }
      final empty = [for (final s in story) if ((counts[s.key] ?? 0) == 0) s.title];
      out
        ..writeln('  paragraphs per chapter: ${[for (final s in story.take(14)) '${s.number}:${counts[s.key] ?? 0}'].join(' ')}')
        ..writeln('  chapters whose start was never found: ${empty.length} ${empty.take(5)}')
        ..writeln('  first: ${story.take(3).map((c) => '${c.number} "${c.title}"').join(', ')}');

      final here = story[story.length ~/ 2];
      // A dozen paragraphs into it.
      final start = placed.indexOf(here.key);
      final at = all[math.min(all.length - 1, (start < 0 ? 0 : start) + 12)];
      final place = (chapter: at.chapter, progression: at.progression);
      final memory = Directory.systemTemp.createTempSync('companion');
      File('${memory.path}/text.jsonl').writeAsStringSync(
        all.map((p) => jsonEncode({'c': p.chapter, 'p': p.progression, 't': p.text})).join('\n'),
      );
      File('${memory.path}/state.json').writeAsStringSync(jsonEncode({
        'chapters': [for (final c in sections) c.toJson()],
        'complete': [for (var f = 0; f < place.chapter; f++) f],
      }));
      final data = await buildBookData(memory.path, place, book.title, book.authors.join(', '));
      out
        ..writeln('at: ${data.current?.number} "${data.current?.title}" (meant ${here.number}); ${data.book.index.chunks.length} chunks so far')
        ..writeln('people (${data.people.length}): ${data.people.take(25).map((p) => '${p.name} ${p.mentions}').join(', ')}');
      final conversation = Conversation(book: data.book, model: const _Gemma());
      for (final ask in [const Ask.recap(), if (data.people.isNotEmpty) Ask.who(data.people.first.name)]) {
        final passages = conversation.passagesFor(ask, 2600);
        final prompt = conversation.prompt(ask, passages, fresh: true);
        out
          ..writeln('--- ${ask.text}: ${passages.length} passages, prompt ${prompt.length} chars (~${prompt.length ~/ 4} tokens)')
          ..writeln(prompt.substring(prompt.indexOf('From the book')).replaceAll(RegExp(r'(?<=^.{160}).*', multiLine: true), '…'));
      }
      final previous = story[math.max(0, story.indexOf(here) - 1)];
      final text = [for (final (i, p) in all.indexed) if (placed[i] == previous.key) p.text];
      final summary = ChapterSummaries.summaryPrompt(book.title, book.authors.join(', '), previous, text);
      out.writeln('--- summary prompt for ${previous.number} (${text.length} paragraphs, ${summary.length} chars):\n$summary');
      File('${Directory.systemTemp.path}/companion-${file.uri.pathSegments.last}.txt').writeAsStringSync(out.toString());
      print(out);
      memory.deleteSync(recursive: true);
    }
  }, skip: dir == null, timeout: const Timeout(Duration(minutes: 5)));
}

class _Gemma implements CompanionModel {
  const _Gemma();

  @override
  bool get remembers => true;
  @override
  int get freshChars => 2600;
  @override
  int get followUpChars => 1300;
  @override
  Stream<String> write(String prompt, {required bool fresh, required int maxTokens}) => const Stream.empty();
  @override
  Future<String?> once(String prompt, {required int maxTokens}) async => null;
  @override
  Future<void> cancel() async {}
}

/// An EPUB as Readium would give it to the app: the reading order with Readium positions
/// (one per 1,024 bytes of each file), the contents, and each file's text by block, as
/// Readium's content iterator reads it.
class EpubBook {
  EpubBook(this.title, this.authors, this.toc, this.chapters, this.text, this._titles);

  final String title;
  final List<String> authors;
  final List<TocEntry> toc;
  final List<ChapterPositions> chapters;
  final List<List<String>> text;
  final Map<String, String> _titles;

  String titleOf(String href) => _titles[href] ?? '';
}

EpubBook readEpub(File file) {
  final archive = ZipDecoder().decodeBytes(file.readAsBytesSync());
  String read(String path) => utf8.decode(archive.findFile(path)!.content as List<int>, allowMalformed: true);
  final container = XmlDocument.parse(read('META-INF/container.xml'));
  final opfPath = container.findAllElements('rootfile').first.getAttribute('full-path')!;
  final base = opfPath.contains('/') ? opfPath.substring(0, opfPath.lastIndexOf('/') + 1) : '';
  final opf = XmlDocument.parse(read(opfPath));
  final title = opf.findAllElements('dc:title').firstOrNull?.innerText ?? '?';
  final authors = [for (final c in opf.findAllElements('dc:creator')) c.innerText];
  final manifest = {
    for (final item in opf.findAllElements('item'))
      item.getAttribute('id')!: (href: Uri.decodeFull(item.getAttribute('href')!), type: item.getAttribute('media-type'), props: item.getAttribute('properties') ?? ''),
  };
  final spine = [for (final ref in opf.findAllElements('itemref')) manifest[ref.getAttribute('idref')]!.href];

  // The contents: EPUB 3 nav, else NCX.
  final titles = <String, String>{};
  List<TocEntry> toc;
  final nav = manifest.values.where((m) => m.props.contains('nav')).firstOrNull;
  if (nav != null) {
    final doc = XmlDocument.parse(read('$base${nav.href}'));
    final tocNav = doc.findAllElements('nav').firstWhere((n) => (n.getAttribute('epub:type') ?? '').contains('toc'), orElse: () => doc.findAllElements('nav').first);
    List<TocEntry> walk(XmlElement ol) => [
      for (final li in ol.childElements.where((e) => e.name.local == 'li'))
        if (li.childElements.where((e) => e.name.local == 'a').firstOrNull case final a?)
          TocEntry(
            title: a.innerText.trim().replaceAll(RegExp(r'\s+'), ' '),
            href: '$base${a.getAttribute('href')}',
            children: [for (final sub in li.childElements.where((e) => e.name.local == 'ol')) ...walk(sub)],
          ),
    ];
    toc = walk(tocNav.findAllElements('ol').first);
  } else {
    final ncx = manifest.values.firstWhere((m) => m.type == 'application/x-dtbncx+xml');
    final doc = XmlDocument.parse(read('$base${ncx.href}'));
    List<TocEntry> walk(XmlElement parent) => [
      for (final p in parent.childElements.where((e) => e.name.local == 'navPoint'))
        TocEntry(
          title: p.findAllElements('text').first.innerText.trim(),
          href: '$base${p.findAllElements('content').first.getAttribute('src')}',
          children: walk(p),
        ),
    ];
    toc = walk(doc.findAllElements('navMap').first);
  }
  void index(List<TocEntry> entries) {
    for (final e in entries) {
      titles.putIfAbsent(e.href.split('#').first, () => e.title);
      index(e.children);
    }
  }

  index(toc);

  final chapters = <ChapterPositions>[];
  final text = <List<String>>[];
  var start = 1;
  for (final href in spine) {
    final path = '$base$href';
    final bytes = archive.findFile(path)!.content as List<int>;
    final count = (bytes.length / 1024).ceil();
    chapters.add(ChapterPositions(href: path, start: start, count: count));
    start += count;
    text.add(_blocks(utf8.decode(bytes, allowMalformed: true)));
  }
  return EpubBook(title, authors, toc, chapters, text, titles);
}

const _blockNames = {'p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'li', 'blockquote', 'dd', 'dt', 'pre', 'td', 'figcaption', 'div'};

/// The text of each block (the innermost ones), whitespace collapsed.
List<String> _blocks(String html) {
  XmlDocument doc;
  try {
    doc = XmlDocument.parse(html);
  } catch (_) {
    return [
      for (final m in RegExp(r'<p[^>]*>([\s\S]*?)</p>').allMatches(html))
        if (m[1]!.replaceAll(RegExp(r'<[^>]+>'), '').replaceAll(RegExp(r'\s+'), ' ').trim() case final t when t.isNotEmpty) t,
    ];
  }
  final out = <String>[];
  for (final el in doc.descendants.whereType<XmlElement>()) {
    if (!_blockNames.contains(el.name.local)) continue;
    if (el.descendants.whereType<XmlElement>().any((d) => _blockNames.contains(d.name.local))) continue;
    final t = el.innerText.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.isNotEmpty) out.add(t);
  }
  return out;
}
