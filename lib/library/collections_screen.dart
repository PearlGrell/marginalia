import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/database.dart';
import '../data/library.dart';
import '../storage/local_store.dart';
import '../theme/tokens.dart';
import '../share/share_sheet.dart';
import '../share/shared_screens.dart';
import 'book_cover.dart';
import 'collection_name_dialog.dart';
import 'shelf.dart';

/// Every collection, each shown as a small fan of its covers.
class CollectionsScreen extends ConsumerWidget {
  const CollectionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final collections = ref.watch(collectionsProvider);
    final text = Theme.of(context).textTheme;
    final db = ref.read(databaseProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Collections')),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('New collection'),
        onPressed: () async {
          final name = await promptCollectionName(context);
          if (name != null) await db.createCollection(name);
        },
      ),
      body: switch (collections) {
        AsyncData(value: final list) when list.isEmpty => Padding(
          padding: const EdgeInsets.all(Space.gutter),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: Space.xl),
              Text('No collections yet', style: text.headlineSmall),
              const SizedBox(height: Space.sm),
              Text(
                'Group books your way: a reading list, a course, a gift pile. '
                "Add books to a collection from each book's page.",
                style: text.bodyLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        AsyncData(value: final list) => GridView.builder(
          padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 120),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 200,
            mainAxisSpacing: Space.xl,
            crossAxisSpacing: Space.lg,
            childAspectRatio: 0.8,
          ),
          itemCount: list.length,
          itemBuilder: (context, i) => _CollectionCard(entry: list[i]),
        ),
        _ => const SizedBox.shrink(),
      },
    );
  }
}

final _collectionBooksProvider = StreamProvider.family<List<Book>, String>(
  (ref, id) => ref
      .watch(databaseProvider)
      .watchBooks(LibraryQuery(collectionId: id, sort: LibrarySort.title)),
);

class _CollectionCard extends ConsumerWidget {
  const _CollectionCard({required this.entry});

  final CollectionWithCount entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final books = ref.watch(_collectionBooksProvider(entry.collection.id)).value ?? const [];
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(Radii.md),
      onTap: () => context.push('/collections/${entry.collection.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) {
                final coverWidth = box.maxHeight / 1.5 * 0.86;
                final fan = books.take(3).toList();
                return Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(Radii.md),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  alignment: Alignment.center,
                  child: fan.isEmpty
                      ? Icon(Icons.collections_bookmark_outlined, color: scheme.onSurfaceVariant)
                      : Stack(
                          alignment: Alignment.center,
                          children: [
                            // Back to front, fanned out from the middle.
                            for (var i = fan.length - 1; i >= 0; i--)
                              Transform.translate(
                                offset: Offset((i - (fan.length - 1) / 2) * coverWidth * 0.42, 0),
                                child: Transform.rotate(
                                  angle: (i - (fan.length - 1) / 2) * 0.08,
                                  child: BookCover(book: fan[i], width: coverWidth * 0.8),
                                ),
                              ),
                          ],
                        ),
                );
              },
            ),
          ),
          const SizedBox(height: Space.sm),
          Text(entry.collection.name, style: text.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
          Text('${entry.count} ${entry.count == 1 ? 'book' : 'books'}', style: text.bodySmall),
        ],
      ),
    );
  }
}

/// One collection's books.
class CollectionScreen extends ConsumerWidget {
  const CollectionScreen({super.key, required this.collectionId});

  final String collectionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final collections = ref.watch(collectionsProvider).value ?? const [];
    final entry = collections.where((c) => c.collection.id == collectionId).firstOrNull;
    final books = ref.watch(_collectionBooksProvider(collectionId));
    final grid = ref.read(localStoreProvider).readJson('library.grid') as bool? ?? true;
    final db = ref.read(databaseProvider);
    final text = Theme.of(context).textTheme;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            title: Text(entry?.collection.name ?? ''),
            actions: [
              if (entry != null)
                PopupMenuButton<String>(
                  onSelected: (action) async {
                    if (action == 'share') {
                      final books = await collectionBooks(ref, collectionId);
                      if (!context.mounted) return;
                      if (books.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Add books to this collection first')),
                        );
                      } else {
                        await showShareSheet(context, books: books, title: entry.collection.name);
                      }
                    } else if (action == 'rename') {
                      final name = await promptCollectionName(
                        context,
                        title: 'Rename collection',
                        initial: entry.collection.name,
                      );
                      if (name != null) await db.renameCollection(collectionId, name);
                    } else {
                      await db.deleteCollection(collectionId);
                      if (context.mounted) context.pop();
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'share', child: Text('Share this collection…')),
                    PopupMenuItem(value: 'rename', child: Text('Rename')),
                    PopupMenuItem(value: 'delete', child: Text('Delete collection (books stay)')),
                  ],
                ),
            ],
          ),
          ...switch (books) {
            AsyncData(value: final list) when list.isEmpty => [
              SliverFillRemaining(
                hasScrollBody: false,
                child: Padding(
                  padding: const EdgeInsets.all(Space.xxl),
                  child: Text(
                    "Nothing here yet. Open a book's page and tick this collection.",
                    textAlign: TextAlign.center,
                    style: text.bodyLarge?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ],
            AsyncData(value: final list) => [
              const SliverToBoxAdapter(child: SizedBox(height: Space.md)),
              ...shelfSlivers(list, grid: grid),
              const SliverToBoxAdapter(child: SizedBox(height: Space.xxxl)),
            ],
            _ => [const SliverToBoxAdapter(child: SizedBox.shrink())],
          },
        ],
      ),
    );
  }
}
