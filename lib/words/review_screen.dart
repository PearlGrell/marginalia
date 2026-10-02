import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/library.dart';
import '../theme/tokens.dart';
import 'review.dart';
import 'word_store.dart';

/// Flashcards for the words that are due: see the word and where you met it, recall its
/// meaning, then turn the card and say how well you knew it.
class ReviewScreen extends ConsumerStatefulWidget {
  const ReviewScreen({super.key});

  @override
  ConsumerState<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends ConsumerState<ReviewScreen> {
  List<VocabularyWord>? _queue;
  int _done = 0;
  bool _revealed = false;

  @override
  void initState() {
    super.initState();
    ref.read(databaseProvider).dueWords(DateTime.now()).then((words) {
      if (mounted) setState(() => _queue = [...words]);
    });
  }

  Future<void> _grade(ReviewGrade grade) async {
    final queue = _queue!;
    final word = queue.removeAt(0);
    await ref.read(wordStoreProvider).grade(word, grade);
    setState(() {
      _revealed = false;
      // Forgotten words come round again in this session.
      if (grade == ReviewGrade.again) {
        queue.insert(queue.length < 3 ? queue.length : 3, word.copyWith(reps: 0));
      } else {
        _done++;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final queue = _queue;
    return Scaffold(
      appBar: AppBar(
        title: Text(queue == null || queue.isEmpty ? 'Review' : '${queue.length} to go'),
      ),
      body: switch (queue) {
        null => const Center(child: CircularProgressIndicator()),
        [] => Center(
          child: Padding(
            padding: const EdgeInsets.all(Space.xxl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_circle_outline, size: 48, color: scheme.primary),
                const SizedBox(height: Space.md),
                Text(_done == 0 ? 'Nothing to review' : 'All done', style: text.headlineSmall),
                const SizedBox(height: Space.sm),
                Text(
                  _done == 0
                      ? 'Words you save from Define come here when they are due.'
                      : 'You went through $_done ${_done == 1 ? 'word' : 'words'}. They come back when it helps to see them again.',
                  textAlign: TextAlign.center,
                  style: text.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: Space.xl),
                FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
              ],
            ),
          ),
        ),
        _ => _card(queue.first, text, scheme),
      },
    );
  }

  Widget _card(VocabularyWord word, TextTheme text, ColorScheme scheme) {
    final now = DateTime.now();
    final state = WordStore.stateOf(word);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: GestureDetector(
                onTap: () => setState(() => _revealed = true),
                child: Container(
                  padding: const EdgeInsets.all(Space.xl),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(Radii.lg),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(word.word, style: text.displaySmall),
                        if (word.partOfSpeech case final pos?)
                          Text(pos, style: text.titleSmall?.copyWith(fontStyle: FontStyle.italic, color: scheme.onSurfaceVariant)),
                        if (word.context case final ctx? when ctx.isNotEmpty) ...[
                          const SizedBox(height: Space.lg),
                          _HighlightedContext(context: ctx, word: word.word),
                        ],
                        const SizedBox(height: Space.xl),
                        AnimatedCrossFade(
                          duration: Motion.standard,
                          crossFadeState: _revealed ? CrossFadeState.showSecond : CrossFadeState.showFirst,
                          firstChild: Text(
                            'Think of what it means, then tap to check.',
                            style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                          secondChild: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Divider(),
                              const SizedBox(height: Space.sm),
                              Text(word.definition ?? 'No meaning saved.', style: text.titleMedium?.copyWith(height: 1.45)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: Space.lg),
            if (!_revealed)
              FilledButton(onPressed: () => setState(() => _revealed = true), child: const Text('Show meaning'))
            else
              Row(
                children: [
                  for (final grade in ReviewGrade.values) ...[
                    Expanded(
                      child: _GradeButton(
                        label: grade.label,
                        gap: reviewGap(scheduleReview(state, grade, now), now),
                        primary: grade == ReviewGrade.good,
                        onPressed: () => _grade(grade),
                      ),
                    ),
                    if (grade != ReviewGrade.values.last) const SizedBox(width: Space.sm),
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _GradeButton extends StatelessWidget {
  const _GradeButton({required this.label, required this.gap, required this.primary, required this.onPressed});

  final String label;
  final String gap;
  final bool primary;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final child = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label),
        Text(gap, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w400)),
      ],
    );
    final padding = const EdgeInsets.symmetric(vertical: Space.sm);
    return primary
        ? FilledButton(style: FilledButton.styleFrom(padding: padding), onPressed: onPressed, child: child)
        : OutlinedButton(style: OutlinedButton.styleFrom(padding: padding), onPressed: onPressed, child: child);
  }
}

/// The sentence the word came from, with the word picked out.
class _HighlightedContext extends StatelessWidget {
  const _HighlightedContext({required this.context, required this.word});

  final String context;
  final String word;

  @override
  Widget build(BuildContext ctx) {
    final style = Theme.of(ctx).textTheme.bodyLarge?.copyWith(fontFamily: FontFamilies.reading, fontStyle: FontStyle.italic, height: 1.5);
    final i = context.toLowerCase().indexOf(word.toLowerCase());
    if (i < 0) return Text(context, style: style);
    return Text.rich(
      TextSpan(
        style: style,
        children: [
          TextSpan(text: context.substring(0, i)),
          TextSpan(text: context.substring(i, i + word.length), style: const TextStyle(fontWeight: FontWeight.w700, fontStyle: FontStyle.normal)),
          TextSpan(text: context.substring(i + word.length)),
        ],
      ),
    );
  }
}
