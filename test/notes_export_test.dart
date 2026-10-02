import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:marginalia/data/database.dart';
import 'package:marginalia/notes/notes_export.dart';
import 'package:marginalia/share/file_export.dart';
import 'package:pdf/widgets.dart' as pw;

void main() {
  final book = Book(
    id: 'b',
    title: "Alice's Adventures in Wonderland",
    authors: const ['Lewis Carroll'],
    sortTitle: 'alice',
    sortAuthor: 'carroll',
    fileSize: 0,
    source: BookSource.import,
    tags: const [],
    ratingHalves: 0,
    favorite: false,
    progress: 0,
    addedAt: DateTime(2026),
    updatedAt: DateTime(2026),
    deleted: false,
    dirty: false,
  );

  Annotation note(String id, String quote, {String? text, String color = 'green'}) => Annotation(
    id: id,
    bookId: 'b',
    type: text == null ? AnnotationType.highlight : AnnotationType.note,
    locator: '{}',
    selectedText: quote,
    note: text,
    color: color,
    chapterTitle: 'Down the Rabbit-Hole',
    progression: 0.04,
    createdAt: DateTime(2026, 3, 9),
    updatedAt: DateTime(2026, 3, 9),
    deleted: false,
    dirty: false,
  );

  final books = [
    BookNotes(book, [
      note('1', 'Curiouser and curiouser!'),
      note('2', 'Who in the world am I?\nAh, that’s the great puzzle!', text: 'The whole book in a line.'),
    ]),
  ];

  test('Markdown quotes each passage with its note and place', () {
    final md = notesMarkdown(books, now: DateTime(2026, 10, 3));
    expect(md, startsWith("# Alice's Adventures in Wonderland\n"));
    expect(md, contains('*Exported 3 October 2026 · 2 highlights*'));
    expect(md, contains('> Who in the world am I?\n> Ah, that’s the great puzzle!'));
    expect(md, contains('The whole book in a line.'));
    expect(md, contains('<sub>Down the Rabbit-Hole · 4% · 9 March 2026</sub>'));
  });

  test('Markdown for several books has a heading for each', () {
    final md = notesMarkdown([...books, BookNotes(book.copyWith(title: 'Emma'), [note('3', 'Badly done!')])]);
    expect(md, startsWith('# Notes from Marginalia'));
    expect(md, contains('2 books · 3 highlights'));
    expect(md, contains('## Emma'));
  });

  test('the PDF builds with the app fonts', () async {
    pw.Font font(String name) =>
        pw.Font.ttf(ByteData.sublistView(File('assets/fonts/$name.ttf').readAsBytesSync()));
    final fonts = PdfFonts(
      serif: font('Literata'),
      serifItalic: font('Literata-Italic'),
      sans: font('IBMPlexSans'),
      display: font('Fraunces'),
    );
    final bytes = await notesPdf(books, fonts: fonts);
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    expect(bytes.length, greaterThan(1000));
  });

  test('file names are made safe', () {
    expect(safeFileName('Notes: Alice / Wonderland?'), 'Notes - Alice - Wonderland -');
    expect(safeFileName('   '), 'Marginalia');
  });
}
