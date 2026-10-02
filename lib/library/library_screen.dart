import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../cloud/account.dart';
import '../cloud/sync_service.dart';
import '../data/database.dart';
import '../data/library.dart';
import '../storage/local_store.dart';
import '../theme/tokens.dart';
import 'book_cover.dart';
import 'shelf.dart';

/// Set by `scripts/deploy-to-phone.ps1`, so you can tell which build is installed.
const _buildStamp = String.fromEnvironment('BUILD_STAMP', defaultValue: 'dev');

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  static const _gridKey = 'library.grid';

  late bool _grid = ref.read(localStoreProvider).readJson(_gridKey) as bool? ?? true;
  bool _searching = false;
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _setQuery(LibraryQuery Function(LibraryQuery) change) {
    final notifier = ref.read(libraryQueryProvider.notifier);
    notifier.set(change(ref.read(libraryQueryProvider)));
  }

  void _toggleGrid() {
    setState(() => _grid = !_grid);
    ref.read(localStoreProvider).writeJson(_gridKey, _grid);
  }

  Future<void> _import(Future<ImportProgress?> Function(LibraryImporter) run) async {
    final importer = ref.read(libraryImporterProvider.notifier);
    if (ref.read(libraryImporterProvider).running) return;
    final result = await run(importer);
    if (result != null && result.added > 0) ref.read(syncProvider.notifier).scheduleSoon();
    if (result != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.summary)));
    }
  }

  void _showAddSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('Add files'),
              subtitle: const Text('Pick one or more EPUBs'),
              onTap: () {
                Navigator.pop(context);
                _import((i) => i.importFiles());
              },
            ),
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('Add a folder'),
              subtitle: const Text('Every EPUB inside, subfolders too; duplicates skipped'),
              onTap: () {
                Navigator.pop(context);
                _import((i) => i.importFolder());
              },
            ),
            ListTile(
              leading: const Icon(Icons.folder_special_outlined),
              title: const Text('Watch a folder'),
              subtitle: const Text('New EPUBs put there join your library by themselves'),
              onTap: () {
                Navigator.pop(context);
                context.push('/settings/folders');
              },
            ),
            ListTile(
              leading: const Icon(Icons.auto_stories_outlined),
              title: const Text('Add a sample'),
              subtitle: const Text("Alice's Adventures in Wonderland"),
              onTap: () {
                Navigator.pop(context);
                _import((i) => i.importSample());
              },
            ),
            const SizedBox(height: Space.sm),
          ],
        ),
      ),
    );
  }

  /// Pull down: sync with your other devices.
  Future<void> _refresh() async {
    final messenger = ScaffoldMessenger.of(context);
    if (!ref.read(accountProvider).signedIn) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Sign in under Settings to sync across devices')),
      );
      return;
    }
    final report = await ref.read(syncProvider.notifier).syncNow();
    final error = ref.read(syncProvider).error;
    messenger.showSnackBar(SnackBar(content: Text(error ?? report?.summary ?? 'Up to date')));
  }

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(libraryQueryProvider);
    final books = ref.watch(booksProvider);
    final continueReading = ref.watch(continueReadingProvider).value;
    final progress = ref.watch(libraryImporterProvider);
    final text = Theme.of(context).textTheme;
    final filtered = query.filtered;
    final showContinue = continueReading != null && !filtered && query.search.isEmpty;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: CustomScrollView(
          // Always scrollable, so pulling down works on a short page too.
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(child: _header(text, query)),
            if (showContinue)
              SliverToBoxAdapter(child: _ContinueReading(book: continueReading)),
            SliverToBoxAdapter(child: _filters(query)),
            if (books.value case final list? when list.isNotEmpty)
              SliverToBoxAdapter(child: _shelfBar(query, list.length)),
            ...switch (books) {
              AsyncData(value: final list) when list.isEmpty => [
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: filtered || query.search.isNotEmpty
                      ? _NothingMatches(text: text)
                      : _EmptyLibrary(
                          onAddFiles: () => _import((i) => i.importFiles()),
                          onAddFolder: () => _import((i) => i.importFolder()),
                          onSample: () => _import((i) => i.importSample()),
                        ),
                ),
              ],
              AsyncData(value: final list) => [
                ...shelfSlivers(
                  list,
                  grid: _grid,
                  groupBySeries: query.sort == LibrarySort.series,
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 120)),
              ],
              AsyncError(:final error) => [
                SliverFillRemaining(child: Center(child: Text('$error'))),
              ],
              _ => [const SliverToBoxAdapter(child: SizedBox.shrink())],
            },
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(bottom: Space.xl),
                child: Center(child: Text('Build $_buildStamp', style: text.labelSmall)),
              ),
            ),
          ],
        ),
        ),
      ),
      bottomNavigationBar: progress.running ? _ImportBanner(progress: progress) : null,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: progress.running ? null : _showAddSheet,
        icon: const Icon(Icons.add),
        label: const Text('Add books'),
        elevation: 1,
      ),
    );
  }

  Widget _header(TextTheme text, LibraryQuery query) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.gutter, Space.xl, Space.sm, Space.md),
      child: _searching
          ? Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _search,
                    autofocus: true,
                    style: text.titleMedium,
                    decoration: const InputDecoration(
                      hintText: 'Title, author or series',
                      border: InputBorder.none,
                    ),
                    onChanged: (value) => _setQuery((q) => _copy(q, search: value)),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Close search',
                  onPressed: () {
                    _search.clear();
                    _setQuery((q) => _copy(q, search: ''));
                    setState(() => _searching = false);
                  },
                ),
              ],
            )
          : Row(
              children: [
                Expanded(child: Text('Library', style: text.displaySmall)),
                IconButton(
                  icon: const Icon(Icons.insights_outlined),
                  tooltip: 'Your reading',
                  onPressed: () => context.push('/stats'),
                ),
                IconButton(
                  icon: const Icon(Icons.search),
                  tooltip: 'Search',
                  onPressed: () => setState(() => _searching = true),
                ),
                const _AccountButton(),
              ],
            ),
    );
  }

  /// Sort order, count and grid/list, quiet above the shelf.
  Widget _shelfBar(LibraryQuery query, int count) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.gutter - Space.sm, 0, Space.sm, 0),
      child: Row(
        children: [
          PopupMenuButton<LibrarySort>(
            tooltip: 'Sort',
            initialValue: query.sort,
            onSelected: (sort) => _setQuery((q) => _copy(q, sort: sort)),
            itemBuilder: (context) => [
              for (final sort in LibrarySort.values)
                CheckedPopupMenuItem(value: sort, checked: sort == query.sort, child: Text(sort.label)),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.md),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.swap_vert, size: 18, color: muted),
                  const SizedBox(width: Space.xs),
                  Text(query.sort.label, style: text.labelLarge),
                ],
              ),
            ),
          ),
          const Spacer(),
          Text('$count ${count == 1 ? 'book' : 'books'}', style: text.labelMedium?.copyWith(color: muted)),
          IconButton(
            icon: Icon(_grid ? Icons.view_list_outlined : Icons.grid_view_outlined, size: 20),
            tooltip: _grid ? 'Show as list' : 'Show as grid',
            onPressed: _toggleGrid,
          ),
        ],
      ),
    );
  }

  Widget _filters(LibraryQuery query) {
    final nothing = !query.filtered;
    final tags = ref.watch(tagsProvider).value ?? const <String>[];
    Widget chip(String label, bool selected, VoidCallback onTap, {IconData? icon}) => Padding(
      padding: const EdgeInsets.only(right: Space.sm),
      child: ChoiceChip(
        avatar: icon == null ? null : Icon(icon, size: 16),
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
      ),
    );
    Widget gap() => Padding(
      padding: const EdgeInsets.only(right: Space.sm),
      child: Center(child: Container(width: 1, height: 20, color: Theme.of(context).colorScheme.outlineVariant)),
    );
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Space.gutter, vertical: Space.sm),
        children: [
          chip('All', nothing, () => _setQuery((q) => LibraryQuery(sort: q.sort, search: q.search))),
          for (final status in ReadingStatus.values)
            chip(
              status.label,
              query.status == status,
              () => _setQuery((q) => LibraryQuery(sort: q.sort, search: q.search, status: status)),
            ),
          chip(
            'Favorites',
            query.favoritesOnly,
            () => _setQuery((q) => LibraryQuery(sort: q.sort, search: q.search, favoritesOnly: true)),
          ),
          gap(),
          for (final shelf in SmartShelf.values)
            chip(
              shelf.label,
              query.shelf == shelf,
              () => _setQuery((q) => LibraryQuery(sort: q.sort, search: q.search, shelf: shelf)),
              icon: Icons.auto_awesome_outlined,
            ),
          if (tags.isNotEmpty) gap(),
          for (final tag in tags)
            chip(
              tag,
              query.tag == tag,
              () => _setQuery((q) => LibraryQuery(sort: q.sort, search: q.search, tag: tag)),
              icon: Icons.sell_outlined,
            ),
        ],
      ),
    );
  }

  static LibraryQuery _copy(LibraryQuery q, {String? search, LibrarySort? sort}) => LibraryQuery(
    status: q.status,
    favoritesOnly: q.favoritesOnly,
    collectionId: q.collectionId,
    search: search ?? q.search,
    sort: sort ?? q.sort,
    tag: q.tag,
    shelf: q.shelf,
  );
}

/// Settings, shown as your Google photo when signed in.
class _AccountButton extends ConsumerWidget {
  const _AccountButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider).account;
    final photo = account?.photoUrl;
    return IconButton(
      tooltip: 'Settings',
      onPressed: () => context.push('/settings'),
      icon: photo == null
          ? const Icon(Icons.account_circle_outlined)
          : CircleAvatar(radius: 13, backgroundImage: NetworkImage(photo)),
    );
  }
}

/// The book being read, large, at the top of the library.
class _ContinueReading extends StatelessWidget {
  const _ContinueReading({required this.book});

  final Book book;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.lg),
        onTap: () => context.push('/read/${book.id}'),
        child: Container(
          padding: const EdgeInsets.all(Space.lg),
          decoration: BoxDecoration(
            color: scheme.surfaceContainer,
            borderRadius: BorderRadius.circular(Radii.lg),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Row(
            children: [
              BookCover(book: book, width: 72, heroTag: 'continue-${book.id}'),
              const SizedBox(width: Space.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('CONTINUE READING', style: text.labelSmall),
                    const SizedBox(height: Space.xs),
                    Text(book.title, style: text.titleLarge, maxLines: 2, overflow: TextOverflow.ellipsis),
                    if (book.authors.isNotEmpty)
                      Text(book.authors.join(', '), style: text.bodySmall, maxLines: 1),
                    const SizedBox(height: Space.md),
                    Row(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(value: book.progress, minHeight: 3),
                          ),
                        ),
                        const SizedBox(width: Space.sm),
                        Text('${(book.progress * 100).round()}%', style: text.labelMedium),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ImportBanner extends StatelessWidget {
  const _ImportBanner({required this.progress});

  final ImportProgress progress;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final fraction = progress.total == 0 ? null : progress.done / progress.total;
    return Material(
      color: scheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, Space.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                progress.total == 0
                    ? (progress.current ?? 'Importing…')
                    : 'Importing ${progress.done + 1} of ${progress.total}',
                style: text.labelLarge,
              ),
              if (progress.total > 0 && progress.current != null)
                Text(progress.current!, style: text.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: Space.sm),
              LinearProgressIndicator(value: fraction, minHeight: 2),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({required this.onAddFiles, required this.onAddFolder, required this.onSample});

  final VoidCallback onAddFiles;
  final VoidCallback onAddFolder;
  final VoidCallback onSample;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.gutter, Space.xxl, Space.gutter, 96),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Your shelves are empty', style: text.headlineMedium),
          const SizedBox(height: Space.sm),
          Text(
            'Add EPUBs from this phone, a whole folder at once, or start with a classic.',
            style: text.bodyLarge?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: Space.xl),
          FilledButton.icon(
            onPressed: onAddFiles,
            icon: const Icon(Icons.description_outlined),
            label: const Text('Add files'),
          ),
          const SizedBox(height: Space.sm),
          OutlinedButton.icon(
            onPressed: onAddFolder,
            icon: const Icon(Icons.folder_outlined),
            label: const Text('Add a folder'),
          ),
          const SizedBox(height: Space.sm),
          TextButton(onPressed: onSample, child: const Text("Try Alice's Adventures in Wonderland")),
        ],
      ),
    );
  }
}

class _NothingMatches extends StatelessWidget {
  const _NothingMatches({required this.text});

  final TextTheme text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(Space.xxl),
      child: Text(
        'No books here yet.',
        textAlign: TextAlign.center,
        style: text.bodyLarge?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }
}
