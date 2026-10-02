import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/database.dart';
import '../data/library.dart';
import '../library/book_cover.dart';
import '../reader/annotations.dart';
import '../theme/tokens.dart';
import '../words/words_view.dart';
import 'note_actions.dart';

final allNotesProvider = StreamProvider<List<Annotation>>((ref) => ref.watch(databaseProvider).watchAllNotes());

/// Every highlight and note across the library, and the saved words.
class NotesScreen extends ConsumerStatefulWidget {
  const NotesScreen({super.key});

  @override
  ConsumerState<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends ConsumerState<NotesScreen> {
  int _tab = 0;
  bool _searching = false;
  final _search = TextEditingController();
  HighlightColor? _color;
  bool _withNotesOnly = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _header(text)),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.sm),
                child: SegmentedButton<int>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 0, icon: Icon(Icons.format_quote_outlined, size: 18), label: Text('Highlights')),
                    ButtonSegment(value: 1, icon: Icon(Icons.spellcheck, size: 18), label: Text('Words')),
                  ],
                  selected: {_tab},
                  onSelectionChanged: (s) => setState(() => _tab = s.first),
                ),
              ),
            ),
            if (_tab == 0) ..._highlights(context) else ...wordSlivers(context, ref, query: _search.text),
            const SliverToBoxAdapter(child: SizedBox(height: 96)),
          ],
        ),
      ),
    );
  }

  Widget _header(TextTheme text) {
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
                    decoration: InputDecoration(
                      hintText: _tab == 0 ? 'Words in a highlight, note or title' : 'A word or meaning',
                      border: InputBorder.none,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Close search',
                  onPressed: () => setState(() {
                    _search.clear();
                    _searching = false;
                  }),
                ),
              ],
            )
          : Row(
              children: [
                Expanded(child: Text('Notes', style: text.displaySmall)),
                IconButton(
                  icon: const Icon(Icons.search),
                  tooltip: 'Search',
                  onPressed: () => setState(() => _searching = true),
                ),
                IconButton(
                  icon: const Icon(Icons.ios_share),
                  tooltip: 'Export all notes',
                  onPressed: () => exportNotes(context, ref),
                ),
              ],
            ),
    );
  }

  List<Widget> _highlights(BuildContext context) {
    final notes = ref.watch(allNotesProvider);
    final books = ref.watch(allBooksProvider).value ?? const <String, Book>{};
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final q = _search.text.trim().toLowerCase();

    bool keep(Annotation a) {
      if (!books.containsKey(a.bookId)) return false;
      if (_color != null && a.highlightColor != _color) return false;
      if (_withNotesOnly && (a.note?.trim().isEmpty ?? true)) return false;
      if (q.isEmpty) return true;
      return (a.selectedText?.toLowerCase().contains(q) ?? false) ||
          (a.note?.toLowerCase().contains(q) ?? false) ||
          books[a.bookId]!.title.toLowerCase().contains(q);
    }

    final list = (notes.value ?? const <Annotation>[]).where(keep).toList();
    // Books in the order they were last annotated, each book's notes in reading order.
    final groups = <String, List<Annotation>>{};
    for (final a in list) {
      (groups[a.bookId] ??= []).add(a);
    }
    for (final g in groups.values) {
      g.sort((a, b) => (a.progression ?? 2).compareTo(b.progression ?? 2));
    }

    final brightness = Theme.of(context).brightness;
    return [
      SliverToBoxAdapter(
        child: SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter, vertical: Space.xs),
            children: [
              Padding(
                padding: const EdgeInsets.only(right: Space.sm),
                child: FilterChip(
                  label: const Text('With a note'),
                  selected: _withNotesOnly,
                  onSelected: (on) => setState(() => _withNotesOnly = on),
                ),
              ),
              for (final c in HighlightColor.values)
                Padding(
                  padding: const EdgeInsets.only(right: Space.sm),
                  child: ChoiceChip(
                    avatar: CircleAvatar(backgroundColor: c.resolve(brightness), radius: 7),
                    label: Text(c.name[0].toUpperCase() + c.name.substring(1)),
                    selected: _color == c,
                    onSelected: (on) => setState(() => _color = on ? c : null),
                  ),
                ),
            ],
          ),
        ),
      ),
      if (notes.hasValue && list.isEmpty)
        SliverFillRemaining(
          hasScrollBody: false,
          child: Padding(
            padding: const EdgeInsets.all(Space.xxl),
            child: Text(
              q.isNotEmpty || _color != null || _withNotesOnly
                  ? 'Nothing matches.'
                  : 'Select text while reading to highlight it or add a note. Every book’s notes gather here.',
              textAlign: TextAlign.center,
              style: text.bodyLarge?.copyWith(color: muted),
            ),
          ),
        ),
      for (final entry in groups.entries) ...[
        SliverToBoxAdapter(child: _BookHeader(book: books[entry.key]!, count: entry.value.length)),
        SliverList.separated(
          itemCount: entry.value.length,
          separatorBuilder: (_, _) => const Divider(height: 1, indent: Space.gutter, endIndent: Space.gutter),
          itemBuilder: (context, i) => _NoteTile(annotation: entry.value[i], book: books[entry.key]!),
        ),
      ],
    ];
  }
}

class _BookHeader extends ConsumerWidget {
  const _BookHeader({required this.book, required this.count});

  final Book book;
  final int count;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    return InkWell(
      onTap: () => context.push('/book/${book.id}'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Space.gutter, Space.xl, Space.sm, Space.sm),
        child: Row(
          children: [
            BookCover(book: book, width: 32),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(book.title, style: text.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(
                    '$count ${count == 1 ? 'highlight' : 'highlights'}'
                    '${book.authors.isEmpty ? '' : ' · ${book.authors.first}'}',
                    style: text.bodySmall,
                    maxLines: 1,
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Export this book’s notes',
              icon: const Icon(Icons.ios_share, size: 20),
              onPressed: () => exportNotes(context, ref, bookId: book.id),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoteTile extends ConsumerWidget {
  const _NoteTile({required this.annotation, required this.book});

  final Annotation annotation;
  final Book book;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = annotation;
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final where = [
      if (a.chapterTitle case final c? when c.isNotEmpty) c,
      if (a.progression case final p?) '${(p * 100).round()}%',
    ].join(' · ');
    void open() => context.push('/read/${a.bookId}?at=${Uri.encodeComponent(a.locator)}');
    return InkWell(
      onTap: open,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.xs, Space.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 3,
              height: 40,
              margin: const EdgeInsets.only(right: Space.md, top: 3),
              color: a.highlightColor.resolve(Theme.of(context).brightness),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (a.selectedText case final quote?)
                    Text(
                      quote.trim(),
                      maxLines: 5,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyLarge?.copyWith(fontFamily: FontFamilies.reading, height: 1.45),
                    ),
                  if (a.note case final note? when note.trim().isNotEmpty) ...[
                    const SizedBox(height: Space.xs),
                    Text(note.trim(), style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
                  ],
                  if (where.isNotEmpty) ...[
                    const SizedBox(height: Space.xs),
                    Text(where, style: text.bodySmall?.copyWith(color: muted)),
                  ],
                ],
              ),
            ),
            PopupMenuButton<String>(
              tooltip: 'More',
              onSelected: (action) async {
                switch (action) {
                  case 'open':
                    open();
                  case 'copy':
                    await copyNote(context, a);
                  case 'image':
                    await shareNoteImage(context, a, book);
                  case 'link':
                    await shareNoteLink(context, ref, a);
                  case 'delete':
                    await ref.read(annotationStoreProvider).delete(a.id);
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'open', child: Text('Open in the book')),
                PopupMenuItem(value: 'copy', child: Text('Copy')),
                PopupMenuItem(value: 'image', child: Text('Share as image')),
                PopupMenuItem(value: 'link', child: Text('Share as link')),
                PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
