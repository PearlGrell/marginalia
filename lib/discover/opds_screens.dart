import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../cloud/sync_service.dart';
import '../data/database.dart';
import '../data/library.dart';
import '../theme/tokens.dart';
import '../util/html_text.dart';
import 'gutenberg.dart' show CatalogException;
import 'opds.dart';

/// Opens a catalog's feed at [url].
void openFeed(BuildContext context, String url, String title) =>
    context.push('/discover/opds?url=${Uri.encodeQueryComponent(url)}&title=${Uri.encodeQueryComponent(title)}');

/// The catalogs added to Discover, as chips, with a way to add another. A long press removes
/// one.
class CatalogsRow extends ConsumerWidget {
  const CatalogsRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalogs = ref.watch(opdsCatalogsProvider);
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.gutter, Space.lg, Space.gutter, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Your catalogs', style: text.titleLarge),
          const SizedBox(height: Space.sm),
          Wrap(
            spacing: Space.sm,
            runSpacing: Space.sm,
            children: [
              for (final c in catalogs)
                GestureDetector(
                  onLongPress: () => _confirmRemove(context, ref, c),
                  child: ActionChip(
                    avatar: const Icon(Icons.local_library_outlined, size: 18),
                    label: Text(c.title),
                    onPressed: () => openFeed(context, c.url, c.title),
                  ),
                ),
              ActionChip(
                avatar: const Icon(Icons.add, size: 18),
                label: Text(catalogs.isEmpty ? 'Add an OPDS catalog' : 'Add'),
                onPressed: () => addCatalog(context, ref),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _confirmRemove(BuildContext context, WidgetRef ref, OpdsCatalog catalog) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${catalog.title}?'),
        content: const Text('Books you added from it stay in your library.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
        ],
      ),
    );
    if (remove == true) await ref.read(opdsCatalogsProvider.notifier).remove(catalog);
  }
}

/// Asks for a catalog's address (and login, if it needs one), checks it's a catalog, and
/// adds it.
Future<void> addCatalog(BuildContext context, WidgetRef ref) =>
    showDialog<void>(context: context, builder: (context) => const _AddCatalogDialog());

class _AddCatalogDialog extends ConsumerStatefulWidget {
  const _AddCatalogDialog();

  @override
  ConsumerState<_AddCatalogDialog> createState() => _AddCatalogDialogState();
}

class _AddCatalogDialogState extends ConsumerState<_AddCatalogDialog> {
  final _url = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();
  bool _login = false;
  bool _checking = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    var address = _url.text.trim();
    if (address.isEmpty) return;
    if (!address.contains('://')) address = 'https://$address';
    final uri = Uri.tryParse(address);
    if (uri == null || !uri.hasAuthority) return setState(() => _error = "That isn't a web address.");
    setState(() {
      _checking = true;
      _error = null;
    });
    final user = _login ? _user.text.trim() : '';
    try {
      // Checked with the login given here, before anything is saved.
      final feed = await OpdsClient(
        () => {if (user.isNotEmpty) address: (user: user, password: _password.text)},
      ).feed(uri);
      await ref
          .read(opdsCatalogsProvider.notifier)
          .add(OpdsCatalog(title: feed.title, url: address), user: user, password: _password.text);
      if (mounted) Navigator.pop(context);
    } on CatalogException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final added = {for (final c in ref.watch(opdsCatalogsProvider)) c.url};
    final suggestions = suggestedCatalogs.where((c) => !added.contains(c.url)).toList();
    return AlertDialog(
      title: const Text('Add a catalog'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('The address of an OPDS feed: a library, a bookshop, your own Calibre or Kavita server.'),
            const SizedBox(height: Space.md),
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Address', hintText: 'https://example.org/opds'),
              onSubmitted: (_) => _add(),
            ),
            if (suggestions.isNotEmpty) ...[
              const SizedBox(height: Space.sm),
              Wrap(
                spacing: Space.xs,
                children: [
                  for (final s in suggestions)
                    ActionChip(label: Text(s.title), onPressed: () => setState(() => _url.text = s.url)),
                ],
              ),
            ],
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _login,
              onChanged: (on) => setState(() => _login = on ?? false),
              title: const Text('It needs a login'),
              subtitle: const Text('Kept on this phone only'),
            ),
            if (_login) ...[
              TextField(controller: _user, autocorrect: false, decoration: const InputDecoration(labelText: 'User name')),
              TextField(controller: _password, obscureText: true, decoration: const InputDecoration(labelText: 'Password')),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: Space.sm),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _checking ? null : _add,
          child: _checking
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Add'),
        ),
      ],
    );
  }
}

/// A page of a catalog: its sections, then its books, more as you scroll; searchable when
/// the catalog is.
class OpdsFeedScreen extends ConsumerStatefulWidget {
  const OpdsFeedScreen({super.key, required this.url, required this.title});

  final String url;
  final String title;

  @override
  ConsumerState<OpdsFeedScreen> createState() => _OpdsFeedScreenState();
}

class _OpdsFeedScreenState extends ConsumerState<OpdsFeedScreen> {
  final _search = TextEditingController();
  OpdsFeed? _first;
  final _entries = <OpdsEntry>[];
  Uri? _next;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load(Uri.parse(widget.url));
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load(Uri uri, {bool more = false}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final feed = await ref.read(opdsClientProvider).feed(uri);
      setState(() {
        _first ??= feed;
        if (!more) _entries.clear();
        _entries.addAll(feed.entries);
        _next = feed.next;
      });
    } on CatalogException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _searchFor(String query) async {
    final feed = _first;
    if (feed == null || query.trim().isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await ref.read(opdsClientProvider).search(feed, query.trim());
      if (!mounted) return;
      if (results == null) {
        setState(() => _error = "This catalog can't be searched.");
      } else {
        openFeedResults(results, '“${query.trim()}”');
      }
    } on CatalogException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void openFeedResults(OpdsFeed results, String title) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => _ResultsScreen(catalogUrl: widget.url, title: title, feed: results),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final searchable = _first?.search != null;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (_next != null && n.metrics.extentAfter < 600) _load(_next!, more: true);
          return false;
        },
        child: ListView(
          children: [
            if (searchable)
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, Space.sm),
                child: TextField(
                  controller: _search,
                  textInputAction: TextInputAction.search,
                  onSubmitted: _searchFor,
                  decoration: const InputDecoration(hintText: 'Search this catalog', prefixIcon: Icon(Icons.search)),
                ),
              ),
            for (final entry in _entries) _EntryTile(catalogUrl: widget.url, entry: entry),
            if (_loading)
              const Padding(padding: EdgeInsets.all(Space.xl), child: Center(child: CircularProgressIndicator())),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(Space.gutter),
                child: Column(
                  children: [
                    Text(_error!, textAlign: TextAlign.center, style: text.bodyLarge),
                    TextButton(onPressed: () => _load(Uri.parse(widget.url)), child: const Text('Retry')),
                  ],
                ),
              ),
            if (!_loading && _error == null && _entries.isEmpty)
              Padding(
                padding: const EdgeInsets.all(Space.xl),
                child: Text('Nothing here.', textAlign: TextAlign.center, style: text.bodyLarge),
              ),
          ],
        ),
      ),
    );
  }
}

class _ResultsScreen extends StatelessWidget {
  const _ResultsScreen({required this.catalogUrl, required this.title, required this.feed});

  final String catalogUrl;
  final String title;
  final OpdsFeed feed;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: feed.entries.isEmpty
        ? const Center(child: Text('No books found.'))
        : ListView(children: [for (final e in feed.entries) _EntryTile(catalogUrl: catalogUrl, entry: e)]),
  );
}

/// A section (opens its feed) or a book (opens its sheet).
class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.catalogUrl, required this.entry});

  final String catalogUrl;
  final OpdsEntry entry;

  @override
  Widget build(BuildContext context) {
    final feed = entry.feed;
    if (!entry.isBook) {
      return ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: Space.gutter),
        leading: const Icon(Icons.folder_outlined),
        title: Text(entry.title),
        subtitle: entry.summary == null ? null : Text(htmlToText(entry.summary!), maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: const Icon(Icons.chevron_right),
        enabled: feed != null,
        onTap: feed == null ? null : () => openFeed(context, feed.toString(), entry.title),
      );
    }
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: Space.gutter, vertical: Space.xs),
      leading: _Cover(url: entry.thumbnail ?? entry.cover, width: 44),
      title: Text(entry.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: entry.author == null ? null : Text(entry.author!, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: () => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (context) => _BookSheet(catalogUrl: catalogUrl, entry: entry),
      ),
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover({required this.url, required this.width});

  final Uri? url;
  final double width;

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      width: width,
      height: width * 1.5,
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: Icon(Icons.menu_book_outlined, size: width / 2),
    );
    final url = this.url;
    if (url == null) return placeholder;
    return ClipRRect(
      borderRadius: BorderRadius.circular(Radii.sm),
      child: Image.network(
        url.toString(),
        width: width,
        height: width * 1.5,
        fit: BoxFit.cover,
        cacheWidth: (width * MediaQuery.devicePixelRatioOf(context)).round(),
        headers: const {'User-Agent': 'Marginalia/1.0 (Android EPUB reader)'},
        errorBuilder: (_, _, _) => placeholder,
      ),
    );
  }
}

final _libraryCopyProvider = StreamProvider.family<Book?, String>(
  (ref, sourceId) => ref.watch(databaseProvider).watchBySource(BookSource.opds, sourceId),
);

/// A catalog book: what it is, and one tap to add it to the library.
class _BookSheet extends ConsumerStatefulWidget {
  const _BookSheet({required this.catalogUrl, required this.entry});

  final String catalogUrl;
  final OpdsEntry entry;

  @override
  ConsumerState<_BookSheet> createState() => _BookSheetState();
}

class _BookSheetState extends ConsumerState<_BookSheet> {
  double? _progress;
  String? _error;

  String get _sourceId => '${widget.catalogUrl}|${widget.entry.id}';

  Future<void> _add(OpdsAcquisition edition) async {
    setState(() {
      _progress = 0;
      _error = null;
    });
    try {
      final file = await ref
          .read(opdsClientProvider)
          .download(edition, onProgress: (p) => mounted ? setState(() => _progress = p) : null);
      await ref.read(libraryImporterProvider.notifier).importDownloaded(file, source: BookSource.opds, sourceId: _sourceId);
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
    final entry = widget.entry;
    final copy = ref.watch(_libraryCopyProvider(_sourceId)).value;
    final edition = entry.readable;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.92,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, Space.xxl),
        children: [
          Center(child: _Cover(url: entry.cover ?? entry.thumbnail, width: 120)),
          const SizedBox(height: Space.lg),
          Text(entry.title, style: text.headlineSmall, textAlign: TextAlign.center),
          if (entry.author case final author?)
            Padding(
              padding: const EdgeInsets.only(top: Space.xs),
              child: Text(author, textAlign: TextAlign.center, style: text.bodyLarge?.copyWith(color: scheme.onSurfaceVariant)),
            ),
          const SizedBox(height: Space.lg),
          if (copy != null)
            FilledButton(
              onPressed: () {
                Navigator.pop(context);
                context.push('/read/${copy.id}');
              },
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
              onPressed: edition == null ? null : () => _add(edition),
              icon: const Icon(Icons.download_outlined),
              label: Text(edition == null ? 'No edition this app can open' : 'Add to library'),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: Space.sm),
              child: Text(_error!, style: text.bodySmall?.copyWith(color: scheme.error)),
            ),
          if (entry.summary case final summary?) ...[
            const SizedBox(height: Space.lg),
            Text(htmlToText(summary), style: text.bodyLarge?.copyWith(height: 1.5)),
          ],
        ],
      ),
    );
  }
}
