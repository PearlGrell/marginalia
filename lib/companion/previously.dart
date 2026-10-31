import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'book_memory.dart';
import 'people.dart';

/// "Previously…": what to remind a reader of who's been away from the book: the last finished
/// chapter (its summary, or a few of its own sentences), then the chapter they're in so far.
/// Null when too little is kept to say anything.
({String heading, String text})? previouslyOn(BookData data) {
  final current = data.current;
  final before = [for (final c in data.chapters) if (c.key != current?.key) c];
  final parts = <String>[];
  final story = data.story?.story.trim();
  if (story != null && story.isNotEmpty) {
    // The whole story so far, as the companion remembers it.
    parts.add(_clip(story, max: 420));
  } else if (before.lastOrNull case final last?) {
    final summary = data.book.summaries[last.number - 1];
    final told = summary != null && summary.trim().isNotEmpty
        ? summary.trim()
        : (data.keySentences[last.number] ?? const <String>[]).take(2).join(' ');
    if (told.isNotEmpty) parts.add(_clip(told));
  }
  if (current != null) {
    final soFar = data.book.keySentences(current.number, count: 2).join(' ');
    if (soFar.isNotEmpty) parts.add('${parts.isEmpty ? '' : 'Then: '}${_clip(soFar)}');
  }
  if (parts.isEmpty) return null;
  return (heading: 'Previously in ${data.book.title}', text: parts.join('\n\n'));
}

String _clip(String text, {int max = 320}) {
  if (text.length <= max) return text;
  final cut = text.lastIndexOf(' ', max);
  return '${text.substring(0, cut < 0 ? max : cut)}…';
}

/// The people in chapter [number] (1-based), most named first: at most [max].
List<String> chapterCast(List<Person> people, int number, {int max = 4}) {
  final here = [
    for (final p in people)
      if (number - 1 < p.byChapter.length && p.byChapter[number - 1] > 0) p,
  ]..sort((a, b) => b.byChapter[number - 1].compareTo(a.byChapter[number - 1]));
  return [for (final p in here.take(max)) p.name];
}

/// The people who first come in in chapter [number].
List<String> firstAppearances(List<Person> people, int number) => [
  for (final p in people)
    if (p.firstSeen.chapter == number) p.name,
];

/// The reminder, over the page, when a book is opened after a while away.
class PreviouslyCard extends StatelessWidget {
  const PreviouslyCard({
    super.key,
    required this.heading,
    required this.text,
    required this.page,
    required this.ink,
    required this.muted,
    required this.onClose,
    required this.onMore,
  });

  final String heading;
  final String text;
  final Color page;
  final Color ink;
  final Color muted;
  final VoidCallback onClose;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme;
    return Material(
      color: page,
      elevation: 6,
      shadowColor: Colors.black45,
      borderRadius: BorderRadius.circular(Radii.md),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.xs, Space.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.history_edu_outlined, size: 18, color: muted),
                const SizedBox(width: Space.sm),
                Expanded(
                  child: Text(
                    heading,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style.titleSmall?.copyWith(color: ink),
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.close, size: 18, color: muted),
                  onPressed: onClose,
                ),
              ],
            ),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.3),
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(right: Space.md),
                child: Text(
                  text,
                  style: style.bodyMedium?.copyWith(color: ink, fontFamily: FontFamilies.reading, height: 1.45),
                ),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: onMore, child: const Text('The book so far')),
            ),
          ],
        ),
      ),
    );
  }
}
