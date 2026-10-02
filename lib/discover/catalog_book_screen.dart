import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../cloud/sync_service.dart';
import '../data/database.dart';
import '../data/library.dart';
import '../theme/tokens.dart';
import 'discover_screen.dart';
import 'gutenberg.dart';

final _libraryCopyProvider = StreamProvider.family<Book?, int>(
  (ref, id) => ref.watch(databaseProvider).watchBySource(BookSource.gutenberg, '$id'),
);

/// A Gutenberg book: what it is, and one tap to add it to the library.
class CatalogBookScreen extends ConsumerStatefulWidget {
  const CatalogBookScreen({super.key, required this.id});

  final int id;

  @override
  ConsumerState<CatalogBookScreen> createState() => _CatalogBookScreenState();
}

class _CatalogBookScreenState extends ConsumerState<CatalogBookScreen> {
  double? _progress;
  String? _error;

  Future<void> _add(CatalogBookDetail book) async {
    setState(() {
      _progress = 0;
      _error = null;
    });
    try {
      final file = await ref
          .read(gutenbergProvider)
          .download(book, onProgress: (p) => mounted ? setState(() => _progress = p) : null);
      await ref
          .read(libraryImporterProvider.notifier)
          .importDownloaded(file, source: BookSource.gutenberg, sourceId: '${book.id}');
      // Public-domain downloads are uploaded like any book, so every device has them.
      await ref.read(syncProvider.notifier).scheduleSoon();
    } on CatalogException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = "This book couldn't be added.");
    } finally {
      if (mounted) setState(() => _progress = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(catalogBookProvider(widget.id));
    final copy = ref.watch(_libraryCopyProvider(widget.id)).value;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(),
      body: switch (detail) {
        AsyncError(:final error) => Center(
          child: Padding(
            padding: const EdgeInsets.all(Space.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('$error', textAlign: TextAlign.center, style: text.bodyLarge),
                TextButton(
                  onPressed: () => ref.invalidate(catalogBookProvider(widget.id)),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
        AsyncData(value: final book) => ListView(
          padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.xxxl),
          children: [
            Center(child: CatalogCover(book: book, width: 168)),
            const SizedBox(height: Space.xl),
            Text(book.title, style: text.headlineMedium, textAlign: TextAlign.center),
            if (book.author case final author?)
              Padding(
                padding: const EdgeInsets.only(top: Space.xs),
                child: Text(
                  author,
                  textAlign: TextAlign.center,
                  style: text.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            const SizedBox(height: Space.xl),
            if (copy != null)
              FilledButton(
                onPressed: () => context.push('/read/${copy.id}'),
                child: const Text('In your library · Read'),
              )
            else if (_progress != null)
              Column(
                children: [
                  LinearProgressIndicator(value: _progress == 0 ? null : _progress, minHeight: 3),
                  const SizedBox(height: Space.sm),
                  Text('Adding to your library…', style: text.bodySmall),
                ],
              )
            else
              FilledButton.icon(
                onPressed: book.epubUrl == null ? null : () => _add(book),
                icon: const Icon(Icons.download_outlined),
                label: const Text('Add to library'),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: Space.sm),
                child: Text(_error!, style: text.bodySmall?.copyWith(color: scheme.error)),
              ),
            if (book.summary case final summary?) ...[
              const SizedBox(height: Space.xl),
              Text(summary, style: text.bodyLarge?.copyWith(height: 1.55)),
            ],
            if (book.subjects.isNotEmpty) ...[
              const SizedBox(height: Space.xl),
              Text('SUBJECTS', style: text.labelSmall),
              const SizedBox(height: Space.sm),
              Wrap(
                spacing: Space.sm,
                runSpacing: Space.sm,
                children: [
                  for (final subject in book.subjects.take(8))
                    ActionChip(
                      label: Text(subject.replaceAll(' -- Fiction', '')),
                      onPressed: () {
                        final topic = subject.split(' -- ').first;
                        context.push(
                          '/discover/list?title=${Uri.encodeQueryComponent(topic)}'
                          '&query=${Uri.encodeQueryComponent('s.$topic')}',
                        );
                      },
                    ),
                ],
              ),
            ],
            const SizedBox(height: Space.xl),
            Text(
              [
                if (book.language case final l?) 'Language: $l',
                if (book.downloads case final d?) 'Downloaded $d times in the last month',
                'Project Gutenberg #${book.id} · Public domain in the USA',
              ].join('\n'),
              style: text.bodySmall?.copyWith(height: 1.7),
            ),
          ],
        ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}
