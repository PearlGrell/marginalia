import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/library.dart';
import '../library/book_cover.dart';
import '../theme/tokens.dart';
import 'sync_service.dart';

final _allBooksProvider = StreamProvider<List<Book>>(
  (ref) => ref.watch(databaseProvider).watchAllBooks(),
);

String _size(int bytes) => bytes >= 1024 * 1024 * 1024
    ? '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB'
    : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

/// What is in the user's Drive app folder, and what is still only on this phone.
class DriveBooksScreen extends ConsumerWidget {
  const DriveBooksScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final books = ref.watch(_allBooksProvider).value ?? const <Book>[];
    final uploaded = books.where((b) => b.driveFileId != null).toList();
    final waiting = books.where((b) => b.driveFileId == null && b.filePath != null).toList();
    final total = uploaded.fold<int>(0, (sum, b) => sum + b.fileSize);
    final limit = ref.watch(uploadLimitProvider);
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;

    return Scaffold(
      appBar: AppBar(title: const Text('Books in your Drive')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xxxl),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, Space.lg),
            child: Text(
              '${uploaded.length} ${uploaded.length == 1 ? 'book' : 'books'} · ${_size(total)}'
              '${limit == null ? '' : ' of your ${_size(limit)} limit'}',
              style: text.titleMedium,
            ),
          ),
          if (uploaded.isNotEmpty) _Header('Uploaded'),
          for (final book in uploaded)
            _BookRow(
              book: book,
              trailing: PopupMenuButton<String>(
                onSelected: (_) async {
                  final ok = await ref.read(syncProvider.notifier).removeFromDrive(book);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(ok ? 'Removed from Drive' : "Couldn't reach Drive")),
                    );
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'remove', child: Text('Remove from Drive')),
                ],
              ),
            ),
          if (waiting.isNotEmpty) ...[
            _Header('Only on this phone'),
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.sm),
              child: Text(
                'These upload at the next sync while Drive has more than 1 GB free'
                '${limit == null ? '' : ' and your limit allows'}.',
                style: text.bodySmall?.copyWith(color: muted),
              ),
            ),
            for (final book in waiting) _BookRow(book: book),
          ],
          if (books.isEmpty)
            Padding(
              padding: const EdgeInsets.all(Space.xxl),
              child: Text('Your library is empty.', style: text.bodyLarge, textAlign: TextAlign.center),
            ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Space.gutter, Space.lg, Space.gutter, Space.sm),
    child: Text(title.toUpperCase(), style: Theme.of(context).textTheme.labelSmall),
  );
}

class _BookRow extends StatelessWidget {
  const _BookRow({required this.book, this.trailing});

  final Book book;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final here = book.filePath != null && File(book.filePath!).existsSync();
    return ListTile(
      contentPadding: const EdgeInsets.only(left: Space.gutter, right: Space.sm),
      leading: BookCover(book: book, width: 32),
      title: Text(book.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('${_size(book.fileSize)}${here ? '' : ' · not downloaded here'}', style: text.bodySmall),
      trailing: trailing,
    );
  }
}
