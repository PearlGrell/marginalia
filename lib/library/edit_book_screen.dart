import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cloud/sync_service.dart';
import '../data/database.dart';
import '../data/library.dart';
import '../theme/tokens.dart';
import '../util/html_text.dart';
import 'book_cover.dart';

/// Change a book's title, authors, description, language and cover. Changes sync; a new cover
/// goes to the other devices too.
class EditBookScreen extends ConsumerStatefulWidget {
  const EditBookScreen({super.key, required this.bookId});

  final String bookId;

  @override
  ConsumerState<EditBookScreen> createState() => _EditBookScreenState();
}

class _EditBookScreenState extends ConsumerState<EditBookScreen> {
  final _title = TextEditingController();
  final _authors = TextEditingController();
  final _description = TextEditingController();
  final _language = TextEditingController();
  bool _loaded = false;
  bool _pickingCover = false;

  @override
  void dispose() {
    _title.dispose();
    _authors.dispose();
    _description.dispose();
    _language.dispose();
    super.dispose();
  }

  void _load(Book book) {
    if (_loaded) return;
    _loaded = true;
    _title.text = book.title;
    _authors.text = book.authors.join('; ');
    _description.text = book.description == null ? '' : htmlToText(book.description!);
    _language.text = book.language ?? '';
  }

  Future<void> _save(Book book) async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('A book needs a title')));
      return;
    }
    final authors = splitAuthors(_authors.text);
    final description = _description.text.trim();
    final language = _language.text.trim();
    final originalDescription = book.description == null ? '' : htmlToText(book.description!);
    await ref.read(databaseProvider).updateBook(
      book.id,
      BooksCompanion(
        title: Value(title),
        sortTitle: Value(sortableTitle(title)),
        authors: Value(authors),
        sortAuthor: Value(sortableAuthor(authors)),
        // Untouched, the book's own (formatted) description stays.
        description: description == originalDescription
            ? const Value.absent()
            : Value(description.isEmpty ? null : description),
        language: Value(language.isEmpty ? null : language),
      ),
    );
    await ref.read(syncProvider.notifier).scheduleSoon();
    if (mounted) Navigator.pop(context);
  }

  Future<void> _changeCover(Book book) async {
    setState(() => _pickingCover = true);
    try {
      final result = await const MethodChannel('marginalia/library')
          .invokeMapMethod<String, Object?>('pickCover', {'bookId': book.id});
      if (result == null) return;
      final db = ref.read(databaseProvider);
      final old = book.coverPath;
      await db.setLocalFields(book.id, BooksCompanion(coverPath: Value(result['coverPath'] as String?)));
      await db.updateBook(book.id, BooksCompanion(coverColor: Value((result['coverColor'] as num?)?.toInt())));
      if (old != null && old != result['coverPath']) {
        final file = File(old);
        if (await file.exists()) await file.delete();
      }
      await ref.read(syncProvider.notifier).coverChanged(book.id);
    } on PlatformException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message ?? "That image couldn't be used")));
      }
    } finally {
      if (mounted) setState(() => _pickingCover = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final book = ref.watch(bookProvider(widget.bookId)).value;
    if (book == null) return const Scaffold(body: SizedBox.shrink());
    _load(book);
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit details'),
        actions: [
          TextButton(onPressed: () => _save(book), child: const Text('Save')),
          const SizedBox(width: Space.sm),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, Space.xxxl),
        children: [
          Center(
            child: Column(
              children: [
                BookCover(book: book, width: 120),
                const SizedBox(height: Space.sm),
                OutlinedButton.icon(
                  icon: _pickingCover
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.image_outlined, size: 18),
                  label: const Text('Change cover'),
                  onPressed: _pickingCover ? null : () => _changeCover(book),
                ),
                Text('Pick any image; your other devices get it too.', style: text.bodySmall),
              ],
            ),
          ),
          const SizedBox(height: Space.xl),
          TextField(
            controller: _title,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Title'),
          ),
          const SizedBox(height: Space.md),
          TextField(
            controller: _authors,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Authors',
              helperText: 'Separate several with ; or &',
            ),
          ),
          const SizedBox(height: Space.md),
          TextField(
            controller: _language,
            decoration: const InputDecoration(
              labelText: 'Language',
              helperText: 'A code such as en, fr or pt-BR: used by Listen, Define and Translate',
            ),
          ),
          const SizedBox(height: Space.md),
          TextField(
            controller: _description,
            minLines: 4,
            maxLines: 12,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'About', alignLabelWithHint: true),
          ),
        ],
      ),
    );
  }
}

/// "Neil Gaiman & Terry Pratchett; Jane Doe" → three authors.
List<String> splitAuthors(String text) => [
  for (final part in text.split(RegExp(r'\s*(?:;|&|\n)\s*')))
    if (part.trim().isNotEmpty) part.trim(),
];
