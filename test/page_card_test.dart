import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marginalia/share/page_card.dart';
import 'package:marginalia/theme/reader_theme.dart';

void main() {
  const before = 'Alice was beginning to get very tired of sitting by her sister on the bank, and of having '
      'nothing to do: once or twice she had peeped into the book her sister was reading, but it had no '
      'pictures or conversations in it, ';
  const quote = '‘and what is the use of a book,’ thought Alice ‘without pictures or conversations?’';
  const after = 'So she was considering in her own mind (as well as she could, for the hot day made her feel '
      'very sleepy and stupid), whether the pleasure of making a daisy-chain would be worth the trouble of '
      'getting up and picking the daisies, when suddenly a White Rabbit with pink eyes ran close by her.';

  // As the reader sends it: whole paragraphs, the selection's split into runs.
  const json = '{"p":[[["$before",0],["$quote",1]],[["$after",0]],[["There was nothing so very remarkable in that.",0]]]}';

  test('the page around a selection comes in as paragraphs of runs', () {
    final excerpt = PageExcerpt.fromJson(json)!;
    expect(excerpt.paragraphs, hasLength(3));
    expect(excerpt.paragraphs.first.last, (text: quote, selected: true));
    expect(excerpt.selectedLength, quote.length);
    // Nothing selected, or not the shape it should be: no excerpt (the caller falls back).
    expect(PageExcerpt.fromJson('{"p":[[["Just text",0]]]}'), isNull);
    expect(PageExcerpt.fromJson('not json'), isNull);
    expect(PageExcerpt.fromJson('{"p":3}'), isNull);
    expect(PageExcerpt.fromJson(null), isNull);
  });

  test("a highlight's kept text makes one paragraph around it", () {
    final excerpt = PageExcerpt.around('  sat by\nher sister ', ' the use of a book ', ' thought Alice\n');
    expect(excerpt.paragraphs.single.map((r) => r.text), ['sat by her sister ', 'the use of a book', ' thought Alice']);
    expect(PageExcerpt.around(null, 'Curiouser!', null).paragraphs.single, [(text: 'Curiouser!', selected: true)]);
  });

  test('the mark takes the cover color and the ink stays readable on it, on every page', () {
    double contrast(Color a, Color b) {
      final x = a.computeLuminance(), y = b.computeLuminance();
      return (x > y ? x + 0.05 : y + 0.05) / (x > y ? y + 0.05 : x + 0.05);
    }

    const covers = [Color(0xFF7A2633), Color(0xFF2F6B4A), Color(0xFF2D4E7A), Color(0xFFD9A93B), Color(0xFFF4F0E6)];
    for (final cover in covers) {
      final pages = [
        for (final t in ReaderTheme.values) ?t.preset,
        PageColors.tinted(cover, Brightness.light),
        PageColors.tinted(cover, Brightness.dark),
      ];
      for (final page in pages) {
        final (:fill, :line) = markColors(page, cover);
        expect(contrast(page.ink, fill), greaterThanOrEqualTo(4.5), reason: '${page.label} $cover');
        // The marker is visibly there (not just the page again), unless the cover is the page's color.
        if (contrast(cover, page.page) > 1.5) expect(fill, isNot(page.page), reason: '${page.label} $cover');
        if (contrast(cover, page.page) > 1.2) expect(contrast(line, page.page), greaterThanOrEqualTo(3), reason: '${page.label} $cover');
      }
    }
  });

  PageCard pageCard(PageExcerpt excerpt, PageColors page, PageMark mark) => PageCard(
    content: PageCardContent(
      excerpt: excerpt,
      title: "Alice's Adventures in Wonderland",
      author: 'Lewis Carroll',
      coverColor: const Color(0xFF2F6B4A),
    ),
    page: page,
    mark: mark,
    fade: PageFade.medium,
  );

  // As in the share sheet: scaled to fit, laid out at its own 360 × 640.
  Widget card(PageExcerpt excerpt, PageColors page, PageMark mark) =>
      MaterialApp(home: FittedBox(child: pageCard(excerpt, page, mark)));

  testWidgets('the card lays out at 360 × 640 with every mark and page, short or long', (tester) async {
    final long = PageExcerpt.around(before * 4, '$after ' * 8, after * 4);
    for (final excerpt in [PageExcerpt.fromJson(json)!, long, PageExcerpt.around(null, 'Curiouser!', null)]) {
      for (final page in [ReaderTheme.paper.preset!, ReaderTheme.oled.preset!]) {
        for (final mark in PageMark.values) {
          await tester.pumpWidget(card(excerpt, page, mark));
          expect(tester.takeException(), isNull);
          expect(tester.getSize(find.byType(PageCard)), const Size(360, 640));
        }
      }
    }
  });

  // Renders the card with the app's own fonts, to look at:
  //   PAGE_CARD_PNG=out_dir flutter test test/page_card_test.dart
  final out = Platform.environment['PAGE_CARD_PNG'];
  testWidgets('renders cards to look at', (tester) async {
    await tester.runAsync(() async {
      for (final (family, files) in [
        ('Literata', ['Literata.ttf']),
        ('Fraunces', ['Fraunces.ttf', 'Fraunces-Italic.ttf']),
        ('IBMPlexSans', ['IBMPlexSans.ttf']),
      ]) {
        final loader = FontLoader(family);
        for (final f in files) {
          loader.addFont(File('assets/fonts/$f').readAsBytes().then((b) => ByteData.sublistView(b)));
        }
        await loader.load();
      }
    });
    final cases = {
      'paper-marker': (ReaderTheme.paper.preset!, PageMark.marker),
      'dark-marker': (ReaderTheme.dark.preset!, PageMark.marker),
      'sepia-underline': (ReaderTheme.sepia.preset!, PageMark.underline),
      'cover-marker': (PageColors.tinted(const Color(0xFF2F6B4A), Brightness.light), PageMark.marker),
      'black-plain': (ReaderTheme.oled.preset!, PageMark.plain),
    };
    // A selection from the middle of one paragraph into the next.
    final across = PageExcerpt([
      [(text: before, selected: false), (text: '$quote ', selected: true)],
      [(text: after, selected: true)],
      [(text: 'There was nothing so very remarkable in that.', selected: false)],
    ]);
    for (final MapEntry(key: name, value: (page, mark)) in {
      ...cases,
      'across-marker': (ReaderTheme.paper.preset!, PageMark.marker),
    }.entries) {
      final excerpt = name.startsWith('across') ? across : PageExcerpt.fromJson(json)!;
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Center(child: RepaintBoundary(key: key, child: pageCard(excerpt, page, mark))),
        ),
      );
      await tester.runAsync(() async {
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('$out/$name.png').writeAsBytes(png!.buffer.asUint8List());
      });
    }
  }, skip: out == null);
}
