import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cloud/account.dart';
import '../data/database.dart';
import '../data/library.dart';
import '../reader/annotations.dart';
import '../share/file_export.dart';
import '../share/quote_service.dart';
import '../share/share_service.dart';
import '../share/share_sheet.dart' show shareText;
import '../share/story_card.dart';
import '../theme/tokens.dart';
import 'notes_export.dart';

/// Export one book's notes, or every book's, as Markdown or PDF.
Future<void> exportNotes(BuildContext context, WidgetRef ref, {String? bookId}) async {
  final db = ref.read(databaseProvider);
  final books = await gatherNotes(db, bookId: bookId);
  if (!context.mounted) return;
  if (books.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No highlights or notes to export yet')));
    return;
  }
  final format = await showModalBottomSheet<String>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.sm),
            child: Text(
              bookId == null ? 'Export all notes' : 'Export notes',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('Markdown'),
            subtitle: const Text('Plain text for Obsidian, Notion, Bear or any notes app'),
            onTap: () => Navigator.pop(context, 'md'),
          ),
          ListTile(
            leading: const Icon(Icons.picture_as_pdf_outlined),
            title: const Text('PDF'),
            subtitle: const Text('A tidy booklet to print or keep'),
            onTap: () => Navigator.pop(context, 'pdf'),
          ),
          const SizedBox(height: Space.sm),
        ],
      ),
    ),
  );
  if (format == null || !context.mounted) return;
  final base = safeFileName(books.length == 1 ? '${books.single.book.title} - notes' : 'Marginalia notes');
  if (format == 'md') {
    await offerFile(
      context,
      name: '$base.md',
      mimeType: 'text/markdown',
      bytes: utf8.encode(notesMarkdown(books)),
    );
  } else {
    final pdf = await notesPdf(books, fonts: await PdfFonts.load());
    if (!context.mounted) return;
    await offerFile(context, name: '$base.pdf', mimeType: 'application/pdf', bytes: pdf);
  }
}

/// Sends a link to [annotation]: the passage in the message, and a link that opens it in
/// Marginalia.
Future<void> shareNoteLink(BuildContext context, WidgetRef ref, Annotation annotation) async {
  final messenger = ScaffoldMessenger.of(context);
  if (!ref.read(accountProvider).signedIn) {
    messenger.showSnackBar(const SnackBar(content: Text('Sign in under Settings to share links')));
    return;
  }
  final book = await ref.read(databaseProvider).getBook(annotation.bookId);
  if (book == null) return;
  try {
    final code = await ref.read(quoteServiceProvider).linkFor(annotation, book);
    await shareText(
      quoteMessage(
        quote: annotation.selectedText ?? '',
        note: annotation.note,
        title: book.title,
        authors: book.authors,
        code: code,
      ),
    );
  } on ShareException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
  } catch (_) {
    messenger.showSnackBar(const SnackBar(content: Text("Couldn't make a link. Check your connection.")));
  }
}

/// The passage as a story card.
Future<void> shareNoteImage(BuildContext context, Annotation annotation, Book? book) {
  return showStorySheet(
    context,
    StoryContent(
      quote: annotation.selectedText ?? '',
      note: annotation.note,
      title: book?.title ?? '',
      author: book?.authors.join(', '),
      accent: annotation.highlightColor.onLight,
      coverColor: book?.coverColor == null ? null : Color(book!.coverColor!),
      coverPath: book?.coverPath,
    ),
  );
}

Future<void> copyNote(BuildContext context, Annotation annotation) async {
  final text = [
    if (annotation.selectedText case final q? when q.trim().isNotEmpty) q.trim(),
    if (annotation.note case final n? when n.trim().isNotEmpty) '\n${n.trim()}',
  ].join('\n');
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
}
