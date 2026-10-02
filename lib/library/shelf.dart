import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../data/database.dart';
import '../theme/tokens.dart';
import 'book_cover.dart';

/// The books as slivers, in a grid or a list. With [groupBySeries] (the library sorted by
/// series), each series gets a heading, and books outside a series come last.
List<Widget> shelfSlivers(
  List<Book> books, {
  required bool grid,
  bool groupBySeries = false,
}) {
  Widget shelf(List<Book> part) => grid ? BookGridSliver(books: part) : BookListSliver(books: part);
  if (!groupBySeries) return [shelf(books)];

  final groups = <String?, List<Book>>{};
  for (final book in books) {
    (groups[book.series] ??= []).add(book);
  }
  final names = groups.keys.whereType<String>().toList();
  return [
    for (final name in [...names, if (groups.containsKey(null)) null]) ...[
      SliverToBoxAdapter(child: SeriesHeading(name: name, count: groups[name]!.length)),
      shelf(groups[name]!),
    ],
  ];
}

class SeriesHeading extends StatelessWidget {
  const SeriesHeading({super.key, required this.name, required this.count});

  /// Null for books outside a series.
  final String? name;
  final int count;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.gutter, Space.xl, Space.gutter, Space.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: Text(
                  name ?? 'Not in a series',
                  style: name == null
                      ? text.titleMedium?.copyWith(color: scheme.onSurfaceVariant)
                      : text.titleLarge,
                ),
              ),
              Text('$count ${count == 1 ? 'book' : 'books'}', style: text.labelSmall),
            ],
          ),
          const SizedBox(height: Space.sm),
          Divider(height: 1, color: scheme.outlineVariant),
        ],
      ),
    );
  }
}

class BookGridSliver extends StatelessWidget {
  const BookGridSliver({super.key, required this.books});

  final List<Book> books;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, 0),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 128,
          mainAxisSpacing: Space.xl,
          crossAxisSpacing: Space.lg,
          childAspectRatio: 0.44,
        ),
        delegate: SliverChildBuilderDelegate(
          childCount: books.length,
          (context, i) {
            final book = books[i];
            return GestureDetector(
              onTap: () => context.push('/book/${book.id}'),
              child: LayoutBuilder(
                builder: (context, constraints) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    BookCover(book: book, width: constraints.maxWidth, heroTag: 'cover-${book.id}'),
                    const SizedBox(height: Space.sm),
                    if (book.progress > 0 && book.status != ReadingStatus.finished) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(value: book.progress, minHeight: 2),
                      ),
                      const SizedBox(height: Space.xs),
                    ],
                    Flexible(
                      child: Text(
                        book.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleSmall?.copyWith(height: 1.2),
                      ),
                    ),
                    if (book.authors.isNotEmpty)
                      Flexible(
                        child: Text(
                          book.authors.first,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall,
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class BookListSliver extends StatelessWidget {
  const BookListSliver({super.key, required this.books});

  final List<Book> books;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SliverList.separated(
      itemCount: books.length,
      separatorBuilder: (_, _) => const Divider(indent: Space.gutter, endIndent: Space.gutter),
      itemBuilder: (context, i) {
        final book = books[i];
        final series = book.series == null
            ? null
            : book.seriesIndex == null
            ? book.series
            : '${book.series} · ${_formatIndex(book.seriesIndex!)}';
        return InkWell(
          onTap: () => context.push('/book/${book.id}'),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter, vertical: Space.md),
            child: Row(
              children: [
                BookCover(book: book, width: 52, heroTag: 'cover-${book.id}'),
                const SizedBox(width: Space.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(book.title, style: text.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
                      if (book.authors.isNotEmpty)
                        Text(book.authors.join(', '), style: text.bodySmall, maxLines: 1),
                      if (series != null) Text(series, style: text.bodySmall, maxLines: 1),
                      const SizedBox(height: Space.xs),
                      _Meta(book: book),
                    ],
                  ),
                ),
                if (book.favorite)
                  Icon(Icons.favorite, size: 16, color: Theme.of(context).colorScheme.primary),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Status, rating and progress in one quiet line.
class _Meta extends StatelessWidget {
  const _Meta({required this.book});

  final Book book;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final parts = [
      if (book.status case final status?) status.label,
      if (book.progress > 0 && book.status != ReadingStatus.finished)
        '${(book.progress * 100).round()}%',
      if (book.ratingHalves > 0) '${'★' * (book.ratingHalves ~/ 2)}${book.ratingHalves.isOdd ? '½' : ''}',
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    return Text(parts.join(' · '), style: text.labelMedium?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ));
  }
}

String _formatIndex(double index) =>
    index == index.roundToDouble() ? '#${index.toInt()}' : '#$index';

