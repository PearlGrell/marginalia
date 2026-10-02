import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../theme/tokens.dart';
import '../share/shared_screens.dart';
import 'gutenberg.dart';

/// Free public-domain books, browsed like a bookshop: curated shelves, then search.
class DiscoverScreen extends ConsumerStatefulWidget {
  const DiscoverScreen({super.key});

  @override
  ConsumerState<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends ConsumerState<DiscoverScreen> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _submit(String query) {
    final q = query.trim();
    if (q.isEmpty) return;
    context.push('/discover/list?title=${Uri.encodeQueryComponent('“$q”')}&query=${Uri.encodeQueryComponent(q)}');
  }

  /// Pull down: fetch the shelves again.
  Future<void> _refresh() async {
    await ref.read(gutenbergProvider).clearCache();
    for (final shelf in shelves) {
      ref.invalidate(shelfProvider(shelf.query));
    }
    await ref.read(shelfProvider(shelves.first.query).future).catchError((_) => <CatalogBook>[]);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: CustomScrollView(
          // Always scrollable, so pulling down works on a short page too.
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(Space.gutter, Space.xl, Space.gutter, Space.xs),
                child: Text('Discover', style: text.displaySmall),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
                child: Text(
                  '75,000 free books from Project Gutenberg',
                  style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(Space.gutter, Space.lg, Space.gutter, Space.sm),
                child: TextField(
                  controller: _search,
                  textInputAction: TextInputAction.search,
                  onSubmitted: _submit,
                  decoration: InputDecoration(
                    hintText: 'Search titles and authors',
                    prefixIcon: const Icon(Icons.search),
                    filled: true,
                    fillColor: scheme.surfaceContainer,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(Radii.md),
                      borderSide: BorderSide(color: scheme.outlineVariant),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(Radii.md),
                      borderSide: BorderSide(color: scheme.outlineVariant),
                    ),
                  ),
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SharedWithYouRow()),
            SliverList.builder(
              itemCount: shelves.length,
              itemBuilder: (context, i) => _ShelfRow(shelf: shelves[i]),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: Space.xxxl)),
          ],
        ),
        ),
      ),
    );
  }
}

class _ShelfRow extends ConsumerWidget {
  const _ShelfRow({required this.shelf});

  final Shelf shelf;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final books = ref.watch(shelfProvider(shelf.query));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.gutter, Space.xl, Space.sm, Space.sm),
          child: Row(
            children: [
              Expanded(child: Text(shelf.title, style: text.titleLarge)),
              TextButton(
                onPressed: () => context.push(
                  '/discover/list?title=${Uri.encodeQueryComponent(shelf.title)}'
                  '&query=${Uri.encodeQueryComponent(shelf.query)}',
                ),
                child: const Text('See all'),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 236,
          child: switch (books) {
            AsyncData(value: final list) => ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
              itemCount: list.length,
              separatorBuilder: (_, _) => const SizedBox(width: Space.lg),
              itemBuilder: (context, i) => SizedBox(width: 104, child: CatalogTile(book: list[i])),
            ),
            AsyncError(:final error) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
              child: Row(
                children: [
                  Expanded(child: Text('$error', style: text.bodySmall)),
                  TextButton(
                    onPressed: () => ref.invalidate(shelfProvider(shelf.query)),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
            _ => const _ShelfPlaceholder(),
          },
        ),
      ],
    );
  }
}

class _ShelfPlaceholder extends StatelessWidget {
  const _ShelfPlaceholder();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainer;
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
      physics: const NeverScrollableScrollPhysics(),
      itemCount: 4,
      separatorBuilder: (_, _) => const SizedBox(width: Space.lg),
      itemBuilder: (_, _) => Align(
        alignment: Alignment.topCenter,
        child: Container(
          width: 104,
          height: 156,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(Radii.sm)),
        ),
      ),
    );
  }
}

/// A catalog book: cover from Gutenberg, title, author.
class CatalogTile extends StatelessWidget {
  const CatalogTile({super.key, required this.book});

  final CatalogBook book;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return GestureDetector(
      onTap: () => context.push('/discover/book/${book.id}'),
      child: LayoutBuilder(
        // Text gets whatever height the cover leaves, so long titles never overflow.
        builder: (context, box) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CatalogCover(book: book, width: box.maxWidth),
            const SizedBox(height: Space.sm),
            Flexible(
              child: Text(book.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: text.titleSmall),
            ),
            if (book.author case final author?)
              Flexible(
                child: Text(author, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodySmall),
              ),
          ],
        ),
      ),
    );
  }
}

class CatalogCover extends StatelessWidget {
  const CatalogCover({super.key, required this.book, required this.width});

  final CatalogBook book;
  final double width;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final fallback = Container(
      color: scheme.surfaceContainer,
      padding: const EdgeInsets.all(Space.sm),
      alignment: Alignment.topLeft,
      child: Text(
        book.title,
        maxLines: 5,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontFamily: FontFamilies.display, fontSize: width / 8, height: 1.15),
      ),
    );
    return Hero(
      tag: 'catalog-${book.id}',
      child: Container(
        width: width,
        height: width * 1.5,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Radii.sm),
          boxShadow: const [BoxShadow(color: Color(0x26000000), blurRadius: 8, offset: Offset(0, 3))],
        ),
        clipBehavior: Clip.antiAlias,
        child: Image.network(
          book.coverUrl,
          fit: BoxFit.cover,
          cacheWidth: (width * dpr).round(),
          headers: const {'User-Agent': 'Marginalia/1.0 (Android EPUB reader)'},
          errorBuilder: (_, _, _) => fallback,
          frameBuilder: (context, child, frame, sync) =>
              frame == null && !sync ? Container(color: scheme.surfaceContainer) : child,
        ),
      ),
    );
  }
}

/// A full list: a shelf's "See all", or search results. Loads more as you scroll.
class CatalogListScreen extends ConsumerStatefulWidget {
  const CatalogListScreen({super.key, required this.title, required this.query});

  final String title;
  final String query;

  @override
  ConsumerState<CatalogListScreen> createState() => _CatalogListScreenState();
}

class _CatalogListScreenState extends ConsumerState<CatalogListScreen> {
  final _books = <CatalogBook>[];
  bool _loading = false;
  bool _done = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _more();
  }

  Future<void> _more() async {
    if (_loading || _done) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await ref.read(gutenbergProvider).search(widget.query, start: _books.length + 1);
      final known = {for (final b in _books) b.id};
      final fresh = page.where((b) => !known.contains(b.id)).toList();
      setState(() {
        _books.addAll(fresh);
        _done = fresh.isEmpty;
      });
    } on CatalogException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.extentAfter < 600) _more();
          return false;
        },
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 128,
                  mainAxisSpacing: Space.xl,
                  crossAxisSpacing: Space.lg,
                  childAspectRatio: 0.44,
                ),
                delegate: SliverChildBuilderDelegate(
                  childCount: _books.length,
                  (context, i) => CatalogTile(book: _books[i]),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(Space.xl),
                child: Center(
                  child: _error != null
                      ? Column(
                          children: [
                            Text(_error!, style: text.bodyMedium, textAlign: TextAlign.center),
                            TextButton(onPressed: _more, child: const Text('Retry')),
                          ],
                        )
                      : _loading
                      ? const CircularProgressIndicator()
                      : _books.isEmpty
                      ? Text('No books found.', style: text.bodyLarge)
                      : const SizedBox.shrink(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
