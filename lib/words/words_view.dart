import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/database.dart';
import '../theme/tokens.dart';
import 'word_store.dart';

/// The word list as slivers, for the Notes tab: a review prompt, then every saved word.
List<Widget> wordSlivers(BuildContext context, WidgetRef ref, {required String query}) {
  final words = ref.watch(wordsProvider);
  final due = ref.watch(dueCountProvider).value ?? 0;
  final text = Theme.of(context).textTheme;
  final scheme = Theme.of(context).colorScheme;
  final q = query.trim().toLowerCase();

  return [
    SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, Space.md),
        child: Container(
          padding: const EdgeInsets.all(Space.lg),
          decoration: BoxDecoration(
            color: scheme.surfaceContainer,
            borderRadius: BorderRadius.circular(Radii.lg),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(due == 0 ? 'All caught up' : '$due ${due == 1 ? 'word' : 'words'} to review', style: text.titleMedium),
                    Text(
                      'Words come back just before you would forget them.',
                      style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Space.md),
              FilledButton(
                onPressed: due == 0 ? null : () => context.push('/words/review'),
                child: const Text('Review'),
              ),
            ],
          ),
        ),
      ),
    ),
    ...switch (words) {
      AsyncData(value: final list) when list.isEmpty => [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Padding(
            padding: const EdgeInsets.all(Space.xxl),
            child: Text(
              'Select a word while reading and tap Define, then Save word. Your words gather here '
              'with the sentence you found them in.',
              textAlign: TextAlign.center,
              style: text.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ),
      ],
      AsyncData(value: final list) => [
        SliverList.separated(
          itemCount: list.where((w) => _matches(w, q)).length,
          separatorBuilder: (_, _) => const Divider(height: 1, indent: Space.gutter, endIndent: Space.gutter),
          itemBuilder: (context, i) => _WordTile(word: list.where((w) => _matches(w, q)).elementAt(i)),
        ),
      ],
      _ => [const SliverToBoxAdapter(child: SizedBox.shrink())],
    },
  ];
}

bool _matches(VocabularyWord w, String q) =>
    q.isEmpty || w.word.toLowerCase().contains(q) || (w.definition?.toLowerCase().contains(q) ?? false);

class _WordTile extends ConsumerWidget {
  const _WordTile({required this.word});

  final VocabularyWord word;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final learned = word.reps >= 3;
    return Dismissible(
      key: ValueKey(word.id),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Theme.of(context).colorScheme.errorContainer,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: Space.gutter),
        child: const Icon(Icons.delete_outline),
      ),
      onDismissed: (_) => ref.read(wordStoreProvider).remove(word.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.gutter, vertical: Space.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(word.word, style: text.titleMedium),
                if (word.partOfSpeech case final pos?) ...[
                  const SizedBox(width: Space.sm),
                  Text(pos, style: text.bodySmall?.copyWith(fontStyle: FontStyle.italic, color: muted)),
                ],
                const Spacer(),
                if (learned) Icon(Icons.verified_outlined, size: 16, color: muted),
                if (word.language != 'en')
                  Padding(
                    padding: const EdgeInsets.only(left: Space.xs),
                    child: Text(word.language.toUpperCase(), style: text.labelSmall),
                  ),
              ],
            ),
            if (word.definition case final d?) Text(d, style: text.bodyMedium, maxLines: 3, overflow: TextOverflow.ellipsis),
            if (word.context case final c? when c.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: Space.xxs),
                child: Text(
                  c,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall?.copyWith(fontFamily: FontFamilies.reading, fontStyle: FontStyle.italic, color: muted),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
