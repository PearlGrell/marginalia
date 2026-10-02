import 'package:flutter/material.dart';

import '../readium/readium.dart';
import '../readium/readium_view.dart';
import '../theme/tokens.dart';

/// The last search in the open book, kept so reopening the sheet shows it again and the
/// reader can step through the results.
class BookSearch {
  String query = '';
  List<SearchResult> results = const [];

  /// The result being looked at, if any.
  int? index;

  static const limit = 300;

  bool get hitLimit => results.length >= limit;

  String get countLabel => results.isEmpty
      ? 'No results'
      : '${results.length}${hitLimit ? '+' : ''} ${results.length == 1 ? 'result' : 'results'}';
}

/// Searches the book; returns the index of the result picked.
Future<int?> showSearchSheet(
  BuildContext context, {
  required ReadiumViewController controller,
  required BookSearch search,
}) {
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        maxChildSize: 0.95,
        builder: (context, scroll) => _SearchSheet(controller: controller, search: search, scroll: scroll),
      ),
    ),
  );
}

class _SearchSheet extends StatefulWidget {
  const _SearchSheet({required this.controller, required this.search, required this.scroll});

  final ReadiumViewController controller;
  final BookSearch search;
  final ScrollController scroll;

  @override
  State<_SearchSheet> createState() => _SearchSheetState();
}

class _SearchSheetState extends State<_SearchSheet> {
  late final _field = TextEditingController(text: widget.search.query);
  bool _searching = false;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Future<void> _run(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    setState(() => _searching = true);
    final results = await widget.controller.search(q);
    if (!mounted) return;
    setState(() {
      widget.search
        ..query = q
        ..results = results
        ..index = null;
      _searching = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final search = widget.search;
    final hasQuery = search.query.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.sm),
          child: TextField(
            controller: _field,
            autofocus: !hasQuery,
            textInputAction: TextInputAction.search,
            onSubmitted: _run,
            decoration: InputDecoration(
              hintText: 'Search this book',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searching
                  ? const Padding(
                      padding: EdgeInsets.all(14),
                      child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  : IconButton(
                      tooltip: 'Search',
                      icon: const Icon(Icons.arrow_forward),
                      onPressed: () => _run(_field.text),
                    ),
              filled: true,
              fillColor: scheme.surfaceContainer,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(Radii.md),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        if (hasQuery && !_searching)
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.xs),
            child: Text(
              search.hitLimit ? '${search.countLabel} · showing the first ${BookSearch.limit}' : search.countLabel,
              style: text.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: ListView.separated(
            controller: widget.scroll,
            padding: const EdgeInsets.only(bottom: Space.xl),
            itemCount: search.results.length,
            separatorBuilder: (_, _) => const Divider(height: 1, indent: Space.gutter, endIndent: Space.gutter),
            itemBuilder: (context, i) => _ResultTile(
              result: search.results[i],
              current: search.index == i,
              onTap: () => Navigator.pop(context, i),
            ),
          ),
        ),
      ],
    );
  }
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({required this.result, required this.current, required this.onTap});

  final SearchResult result;
  final bool current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final where = [
      if (result.chapter case final c? when c.isNotEmpty) c,
      if (result.progression case final p?) '${(p * 100).round()}%',
    ].join(' · ');
    final body = text.bodyMedium?.copyWith(fontFamily: FontFamilies.reading, height: 1.45);
    return InkWell(
      onTap: onTap,
      child: Container(
        color: current ? scheme.primaryContainer.withValues(alpha: 0.35) : null,
        padding: const EdgeInsets.symmetric(horizontal: Space.gutter, vertical: Space.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (where.isNotEmpty)
              Text(where, style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: Space.xxs),
            Text.rich(
              TextSpan(
                style: body,
                children: [
                  TextSpan(text: snippetBefore(result.before)),
                  TextSpan(
                    text: result.match,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      backgroundColor: scheme.primaryContainer,
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                  TextSpan(text: snippetAfter(result.after)),
                ],
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

/// The end of the text before a match, from a word boundary, about [length] characters.
String snippetBefore(String before, {int length = 70}) {
  final flat = before.replaceAll(RegExp(r'\s+'), ' ');
  if (flat.length <= length) return flat.trimLeft();
  final cut = flat.substring(flat.length - length);
  final space = cut.indexOf(' ');
  return '…${space < 0 ? cut : cut.substring(space + 1)}';
}

/// The start of the text after a match, up to a word boundary.
String snippetAfter(String after, {int length = 110}) {
  final flat = after.replaceAll(RegExp(r'\s+'), ' ');
  if (flat.length <= length) return flat.trimRight();
  final cut = flat.substring(0, length);
  final space = cut.lastIndexOf(' ');
  return '${space < 0 ? cut : cut.substring(0, space)}…';
}
