import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../cloud/sync_service.dart';
import '../data/database.dart';
import '../data/library.dart';
import '../theme/system_bars.dart';
import '../theme/tokens.dart';
import '../share/share_sheet.dart';
import '../util/html_text.dart';
import 'book_cover.dart';
import 'collection_name_dialog.dart';

/// A book's own page. Its header takes a tint from the cover.
class BookDetailScreen extends ConsumerWidget {
  const BookDetailScreen({super.key, required this.bookId});

  final String bookId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final book = ref.watch(bookProvider(bookId)).value;
    if (book == null || book.deleted) {
      return const Scaffold(body: SizedBox.shrink());
    }
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final db = ref.read(databaseProvider);
    final tint = Color(book.coverColor ?? 0xFF3F3A2E);
    // The tint at the top, fading into the page.
    final top = Color.alphaBlend(tint.withValues(alpha: 0.55), scheme.surface);
    final onTop = ThemeData.estimateBrightnessForColor(top) == Brightness.dark
        ? Colors.white
        : Palette.ink;

    void change(BooksCompanion changes) => db.updateBook(book.id, changes);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: systemBarsFor(ThemeData.estimateBrightnessForColor(top)),
      child: Scaffold(
        body: CustomScrollView(
          slivers: [
            SliverAppBar(
              pinned: true,
              backgroundColor: top,
              foregroundColor: onTop,
              actions: [
                IconButton(
                  icon: Icon(book.favorite ? Icons.favorite : Icons.favorite_border),
                  tooltip: book.favorite ? 'Remove from favorites' : 'Add to favorites',
                  onPressed: () => change(BooksCompanion(favorite: Value(!book.favorite))),
                ),
                PopupMenuButton<String>(
                  onSelected: (action) async {
                    if (action == 'share') {
                      await showShareSheet(context, books: [book], title: book.title);
                    } else if (action == 'edit') {
                      await context.push('/book/${book.id}/edit');
                    } else if (action == 'removeLocal') {
                      if (await _confirmRemoveLocal(context, book)) {
                        final ok = await ref.read(syncProvider.notifier).removeLocalCopy(book);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                ok ? 'Removed from this phone; it downloads again when you open it' : 'Nothing to remove',
                              ),
                            ),
                          );
                        }
                      }
                    } else if (action == 'reset') {
                      final removeNotes = await _confirmStartOver(context, book);
                      if (removeNotes != null) {
                        await ref.read(syncProvider.notifier).startOver(book.id, annotations: removeNotes);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Starting from the beginning')),
                          );
                        }
                      }
                    } else if (action == 'remove' && await _confirmRemove(context, book)) {
                      await ref.read(libraryImporterProvider.notifier).remove(book);
                      if (context.mounted) context.pop();
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'edit', child: Text('Edit details and cover')),
                    const PopupMenuItem(value: 'share', child: Text('Share with someone…')),
                    const PopupMenuItem(value: 'reset', child: Text('Start over…')),
                    if (book.driveFileId != null && book.filePath != null)
                      const PopupMenuItem(value: 'removeLocal', child: Text('Remove from this phone')),
                    const PopupMenuItem(value: 'remove', child: Text('Remove from library')),
                  ],
                ),
              ],
            ),
            SliverToBoxAdapter(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [top, scheme.surface],
                  ),
                ),
                padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, Space.xl),
                child: Column(
                  children: [
                    BookCover(book: book, width: 168, heroTag: 'cover-${book.id}'),
                    const SizedBox(height: Space.xl),
                    Text(book.title, style: text.headlineMedium, textAlign: TextAlign.center),
                    if (book.authors.isNotEmpty) ...[
                      const SizedBox(height: Space.xs),
                      Text(
                        book.authors.join(', '),
                        style: text.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
                        textAlign: TextAlign.center,
                      ),
                    ],
                    if (book.series != null) ...[
                      const SizedBox(height: Space.xs),
                      Text(
                        _seriesLine(book),
                        style: text.bodyMedium?.copyWith(fontStyle: FontStyle.italic),
                        textAlign: TextAlign.center,
                      ),
                    ],
                    const SizedBox(height: Space.xl),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        // Books in the cloud download when opened.
                        onPressed: book.filePath == null && book.driveFileId == null
                            ? null
                            : () => context.push('/read/${book.id}'),
                        child: Text(
                          book.progress > 0 && book.status != ReadingStatus.finished
                              ? 'Continue · ${(book.progress * 100).round()}%'
                              : book.status == ReadingStatus.finished
                              ? 'Read again'
                              : 'Start reading',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.xxxl),
              sliver: SliverList.list(
                children: [
                  _Label('Status'),
                  Wrap(
                    spacing: Space.sm,
                    runSpacing: Space.sm,
                    children: [
                      for (final status in ReadingStatus.values)
                        ChoiceChip(
                          label: Text(status.label),
                          selected: book.status == status,
                          onSelected: (on) => change(
                            BooksCompanion(
                              status: Value(on ? status : null),
                              finishedAt: Value(
                                on && status == ReadingStatus.finished ? DateTime.now() : book.finishedAt,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  _Label('Your rating'),
                  _RatingStars(
                    halves: book.ratingHalves,
                    onChanged: (halves) => change(BooksCompanion(ratingHalves: Value(halves))),
                  ),
                  _Label('Collections'),
                  _CollectionChips(bookId: book.id),
                  _Label('Tags'),
                  _TagChips(book: book),
                  _Label('Series'),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(book.series == null ? 'Not in a series' : _seriesLine(book)),
                    trailing: const Icon(Icons.edit_outlined, size: 20),
                    onTap: () => _editSeries(context, ref, book),
                  ),
                  if (_plain(book.description) case final description? when description.isNotEmpty) ...[
                    _Label('About'),
                    Text(description, style: text.bodyLarge?.copyWith(height: 1.55)),
                  ],
                  _Label('Details'),
                  Text(
                    [
                      if (book.language case final lang?) 'Language: $lang',
                      'Size: ${(book.fileSize / (1024 * 1024)).toStringAsFixed(1)} MB',
                      'Added ${_date(book.addedAt)}',
                      if (book.finishedAt case final f? when book.status == ReadingStatus.finished)
                        'Finished ${_date(f)}',
                    ].join('\n'),
                    style: text.bodySmall?.copyWith(height: 1.7),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _seriesLine(Book book) {
    final index = book.seriesIndex;
    if (index == null) return book.series!;
    final n = index == index.roundToDouble() ? index.toInt().toString() : index.toString();
    return 'Book $n of ${book.series}';
  }

  static String? _plain(String? html) => html == null ? null : htmlToText(html);

  static String _date(DateTime d) {
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June', //
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }

  /// Null if cancelled; otherwise whether to remove highlights, notes and bookmarks too.
  Future<bool?> _confirmStartOver(BuildContext context, Book book) => showDialog<bool>(
    context: context,
    builder: (context) {
      var removeNotes = false;
      return StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Start over?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Your place, progress and reading status for “${book.title}” are cleared, '
                'here and on your other devices.',
              ),
              const SizedBox(height: Space.md),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: removeNotes,
                onChanged: (v) => setState(() => removeNotes = v ?? false),
                title: const Text('Also remove highlights, notes and bookmarks'),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            TextButton(
              onPressed: () => Navigator.pop(context, removeNotes),
              child: const Text('Start over'),
            ),
          ],
        ),
      );
    },
  );

  Future<bool> _confirmRemoveLocal(BuildContext context, Book book) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Remove from this phone?'),
          content: Text(
            '“${book.title}” stays in your library and your Drive, with your notes and place. '
            'It downloads again when you open it.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
          ],
        ),
      ) ??
      false;

  Future<bool> _confirmRemove(BuildContext context, Book book) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Remove this book?'),
          content: Text(
            '“${book.title}” and its file will be removed from this phone. '
            'Your bookmarks for it are kept if you add it again.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
          ],
        ),
      ) ??
      false;

  Future<void> _editSeries(BuildContext context, WidgetRef ref, Book book) async {
    final db = ref.read(databaseProvider);
    final names = await db.seriesNames();
    if (!context.mounted) return;
    final result = await showDialog<(String?, double?)>(
      context: context,
      builder: (context) => _SeriesDialog(book: book, suggestions: names),
    );
    if (result == null) return;
    final (series, index) = result;
    await db.updateBook(
      book.id,
      BooksCompanion(series: Value(series), seriesIndex: Value(series == null ? null : index)),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: Space.xl, bottom: Space.sm),
    child: Text(text.toUpperCase(), style: Theme.of(context).textTheme.labelSmall),
  );
}

/// Five stars; tapping the left half of a star gives a half.
class _RatingStars extends StatelessWidget {
  const _RatingStars({required this.halves, required this.onChanged});

  final int halves;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    const size = 36.0;
    return Row(
      children: [
        for (var star = 0; star < 5; star++)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (details) {
              final half = details.localPosition.dx < size / 2;
              final value = star * 2 + (half ? 1 : 2);
              // Tapping the current rating clears it.
              onChanged(value == halves ? 0 : value);
            },
            child: Semantics(
              button: true,
              label: '${star + 1} stars',
              child: Icon(
                halves >= star * 2 + 2
                    ? Icons.star
                    : halves == star * 2 + 1
                    ? Icons.star_half
                    : Icons.star_border,
                size: size,
                color: color,
              ),
            ),
          ),
        const SizedBox(width: Space.md),
        if (halves > 0)
          Text(
            halves.isEven ? '${halves ~/ 2}' : '${halves ~/ 2}.5',
            style: Theme.of(context).textTheme.titleMedium,
          ),
      ],
    );
  }
}

class _CollectionChips extends ConsumerWidget {
  const _CollectionChips({required this.bookId});

  final String bookId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final collections = ref.watch(collectionsProvider).value ?? const [];
    final member = ref.watch(bookCollectionIdsProvider(bookId)).value ?? const {};
    final db = ref.read(databaseProvider);
    return Wrap(
      spacing: Space.sm,
      runSpacing: Space.sm,
      children: [
        for (final c in collections)
          FilterChip(
            label: Text(c.collection.name),
            selected: member.contains(c.collection.id),
            onSelected: (on) => db.setInCollection(bookId, c.collection.id, on),
          ),
        ActionChip(
          avatar: const Icon(Icons.add, size: 16),
          label: const Text('New'),
          onPressed: () async {
            final name = await promptCollectionName(context);
            if (name == null) return;
            final id = await db.createCollection(name);
            await db.setInCollection(bookId, id, true);
          },
        ),
      ],
    );
  }
}

/// The book's tags, with a way to add one (suggesting tags already in use).
class _TagChips extends ConsumerWidget {
  const _TagChips({required this.book});

  final Book book;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.read(databaseProvider);
    final all = ref.watch(tagsProvider).value ?? const <String>[];
    Future<void> setTags(List<String> tags) => db.updateBook(book.id, BooksCompanion(tags: Value(tags)));
    return Wrap(
      spacing: Space.sm,
      runSpacing: Space.sm,
      children: [
        for (final tag in book.tags)
          InputChip(
            label: Text(tag),
            onDeleted: () => setTags([...book.tags]..remove(tag)),
          ),
        ActionChip(
          avatar: const Icon(Icons.add, size: 16),
          label: const Text('Tag'),
          onPressed: () async {
            final tag = await showDialog<String>(
              context: context,
              builder: (_) => _TagDialog(suggestions: [for (final t in all) if (!book.tags.contains(t)) t]),
            );
            final clean = tag?.trim();
            if (clean == null || clean.isEmpty || book.tags.contains(clean)) return;
            await setTags([...book.tags, clean]);
          },
        ),
      ],
    );
  }
}

class _TagDialog extends StatefulWidget {
  const _TagDialog({required this.suggestions});

  final List<String> suggestions;

  @override
  State<_TagDialog> createState() => _TagDialogState();
}

class _TagDialogState extends State<_TagDialog> {
  final _field = TextEditingController();

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _field.text.trim().toLowerCase();
    final matches = widget.suggestions.where((t) => t.toLowerCase().contains(query)).take(8).toList();
    return AlertDialog(
      title: const Text('Add a tag'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _field,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'comfort reads, to lend…'),
            onChanged: (_) => setState(() {}),
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
          if (matches.isNotEmpty) ...[
            const SizedBox(height: Space.md),
            Wrap(
              spacing: Space.sm,
              runSpacing: Space.sm,
              children: [
                for (final t in matches) ActionChip(label: Text(t), onPressed: () => Navigator.pop(context, t)),
              ],
            ),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(context, _field.text), child: const Text('Add')),
      ],
    );
  }
}

class _SeriesDialog extends StatefulWidget {
  const _SeriesDialog({required this.book, required this.suggestions});

  final Book book;
  final List<String> suggestions;

  @override
  State<_SeriesDialog> createState() => _SeriesDialogState();
}

class _SeriesDialogState extends State<_SeriesDialog> {
  late final _name = TextEditingController(text: widget.book.series ?? '');
  late final _index = TextEditingController(
    text: switch (widget.book.seriesIndex) {
      null => '',
      final i when i == i.roundToDouble() => i.toInt().toString(),
      final i => i.toString(),
    },
  );

  @override
  void dispose() {
    _name.dispose();
    _index.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Series'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Autocomplete<String>(
            initialValue: _name.value,
            optionsBuilder: (value) => widget.suggestions.where(
              (s) => s.toLowerCase().contains(value.text.toLowerCase()),
            ),
            onSelected: (s) => _name.text = s,
            fieldViewBuilder: (context, controller, focus, onSubmit) {
              controller.addListener(() => _name.text = controller.text);
              return TextField(
                controller: controller,
                focusNode: focus,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Series name'),
              );
            },
          ),
          const SizedBox(height: Space.md),
          TextField(
            controller: _index,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Number in series'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, (null, null)),
          child: const Text('Not in a series'),
        ),
        TextButton(
          onPressed: () {
            final name = _name.text.trim();
            Navigator.pop(context, (name.isEmpty ? null : name, double.tryParse(_index.text.trim())));
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
