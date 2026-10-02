import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../data/database.dart';
import '../theme/tokens.dart';

/// A book with its highlights and notes, in reading order.
class BookNotes {
  const BookNotes(this.book, this.notes);

  final Book book;
  final List<Annotation> notes;
}

/// Every book's highlights and notes (or one book's), skipping books without any.
Future<List<BookNotes>> gatherNotes(AppDatabase db, {String? bookId}) async {
  final books = bookId == null
      ? [for (final b in await db.allBooks()) if (!b.deleted) b]
      : [?await db.getBook(bookId)];
  final result = <BookNotes>[];
  for (final book in books..sort((a, b) => a.sortTitle.compareTo(b.sortTitle))) {
    final notes = await db.notesFor(book.id);
    if (notes.isNotEmpty) result.add(BookNotes(book, notes));
  }
  return result;
}

const _months = [
  'January', 'February', 'March', 'April', 'May', 'June', //
  'July', 'August', 'September', 'October', 'November', 'December',
];

String _date(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';

String _where(Annotation a) => [
  if (a.chapterTitle case final c? when c.trim().isNotEmpty) c.trim(),
  if (a.progression case final p?) '${(p * 100).round()}%',
  _date(a.createdAt),
].join(' · ');

String _count(int n, String one) => '$n ${n == 1 ? one : '${one}s'}';

/// Notes as Markdown: a heading per book, each passage quoted with its note beneath.
String notesMarkdown(List<BookNotes> books, {DateTime? now}) {
  final total = books.fold(0, (sum, b) => sum + b.notes.length);
  final out = StringBuffer()
    ..writeln(books.length == 1 ? '# ${books.single.book.title}' : '# Notes from Marginalia')
    ..writeln()
    ..writeln('*Exported ${_date(now ?? DateTime.now())} · '
        '${books.length == 1 ? '' : '${_count(books.length, 'book')} · '}${_count(total, 'highlight')}*')
    ..writeln();
  for (final entry in books) {
    final book = entry.book;
    if (books.length > 1) {
      out
        ..writeln('## ${book.title}')
        ..writeln();
    }
    if (book.authors.isNotEmpty) {
      out
        ..writeln('by ${book.authors.join(', ')}')
        ..writeln();
    }
    for (final a in entry.notes) {
      if (a.selectedText case final quote? when quote.trim().isNotEmpty) {
        for (final line in quote.trim().split('\n')) {
          out.writeln('> ${line.trim()}');
        }
        out.writeln();
      }
      if (a.note case final note? when note.trim().isNotEmpty) {
        out
          ..writeln(note.trim())
          ..writeln();
      }
      out
        ..writeln('<sub>${_where(a)}</sub>')
        ..writeln();
    }
  }
  return out.toString();
}

/// The fonts the PDF is set in (the app's own, so it looks like the app).
class PdfFonts {
  const PdfFonts({required this.serif, required this.serifItalic, required this.sans, required this.display});

  final pw.Font serif;
  final pw.Font serifItalic;
  final pw.Font sans;
  final pw.Font display;

  static Future<PdfFonts> load() async {
    Future<pw.Font> font(String name) async => pw.Font.ttf(await rootBundle.load('assets/fonts/$name.ttf'));
    return PdfFonts(
      serif: await font('Literata'),
      serifItalic: await font('Literata-Italic'),
      sans: await font('IBMPlexSans'),
      display: await font('Fraunces'),
    );
  }
}

/// Notes as a printable A5-ish booklet.
Future<Uint8List> notesPdf(List<BookNotes> books, {required PdfFonts fonts, DateTime? now}) {
  final ink = PdfColor.fromInt(Palette.ink.toARGB32());
  final muted = PdfColor.fromInt(Palette.inkMuted.toARGB32());
  final accent = PdfColor.fromInt(Palette.oxblood.toARGB32());
  final total = books.fold(0, (sum, b) => sum + b.notes.length);
  final doc = pw.Document(title: books.length == 1 ? books.single.book.title : 'Notes from Marginalia', author: 'Marginalia');

  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a5,
      margin: const pw.EdgeInsets.fromLTRB(42, 48, 42, 48),
      theme: pw.ThemeData.withFont(base: fonts.serif, italic: fonts.serifItalic, bold: fonts.sans),
      footer: (context) => pw.Container(
        alignment: pw.Alignment.centerRight,
        margin: const pw.EdgeInsets.only(top: 12),
        child: pw.Text('${context.pageNumber}', style: pw.TextStyle(font: fonts.sans, fontSize: 8, color: muted)),
      ),
      build: (context) => [
        pw.Text(
          books.length == 1 ? books.single.book.title : 'Notes from Marginalia',
          style: pw.TextStyle(font: fonts.display, fontSize: 24, color: ink),
        ),
        pw.SizedBox(height: 4),
        pw.Text(
          'Exported ${_date(now ?? DateTime.now())} · '
          '${books.length == 1 ? '' : '${_count(books.length, 'book')} · '}${_count(total, 'highlight')}',
          style: pw.TextStyle(font: fonts.sans, fontSize: 9, color: muted),
        ),
        pw.SizedBox(height: 18),
        for (final entry in books) ...[
          if (books.length > 1) ...[
            pw.SizedBox(height: 10),
            pw.Header(
              level: 1,
              decoration: pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: muted, width: 0.5))),
              child: pw.Text(entry.book.title, style: pw.TextStyle(font: fonts.display, fontSize: 16, color: ink)),
            ),
          ],
          if (entry.book.authors.isNotEmpty)
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 8),
              child: pw.Text(
                entry.book.authors.join(', '),
                style: pw.TextStyle(font: fonts.sans, fontSize: 9, color: muted),
              ),
            ),
          for (final a in entry.notes)
            pw.Container(
              margin: const pw.EdgeInsets.only(bottom: 12),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  if (a.selectedText case final quote? when quote.trim().isNotEmpty)
                    pw.Container(
                      padding: const pw.EdgeInsets.only(left: 8),
                      decoration: pw.BoxDecoration(
                        border: pw.Border(
                          left: pw.BorderSide(color: PdfColor.fromInt(_highlight(a).toARGB32()), width: 2.5),
                        ),
                      ),
                      child: pw.Text(quote.trim(), style: pw.TextStyle(fontSize: 10.5, lineSpacing: 2, color: ink)),
                    ),
                  if (a.note case final note? when note.trim().isNotEmpty)
                    pw.Padding(
                      padding: const pw.EdgeInsets.only(top: 4, left: 10.5),
                      child: pw.Text(
                        note.trim(),
                        style: pw.TextStyle(font: fonts.serifItalic, fontSize: 10, color: accent),
                      ),
                    ),
                  pw.Padding(
                    padding: const pw.EdgeInsets.only(top: 3, left: 10.5),
                    child: pw.Text(_where(a), style: pw.TextStyle(font: fonts.sans, fontSize: 7.5, color: muted)),
                  ),
                ],
              ),
            ),
        ],
      ],
    ),
  );
  return doc.save();
}

Color _highlight(Annotation a) =>
    (HighlightColor.values.where((c) => c.name == a.color).firstOrNull ?? HighlightColor.yellow).onLight;
