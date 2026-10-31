import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../companion/book_memory.dart';
import '../companion/conversation.dart' show parseQuestions;
import '../companion/explain.dart' show companionModel;
import '../companion/gemma.dart';
import '../share/share_sheet.dart' show shareText;
import '../theme/tokens.dart';

/// The prompt for a club's discussion questions about "[title]", from the story so far and
/// the latest chapters' summaries (public for tests).
String discussionPrompt({
  required String title,
  String? story,
  required List<({String chapter, String summary})> recent,
}) => [
  'You lead a book club reading "$title". Everyone has read up to the end of the chapters below; '
      'never mention or hint at anything after them.',
  if (story != null && story.trim().isNotEmpty) 'The story so far:\n${story.trim()}',
  if (recent.isNotEmpty) 'The latest chapters:\n${[for (final r in recent) '${r.chapter}: ${r.summary}'].join('\n')}',
  'Write five open questions for the club to talk about: why characters did what they did, how they '
      'have changed, what the book seems to be saying, and what members thought or would have done. '
      'Not about what happens next. One question per line, nothing else.',
].join('\n\n');

/// Questions for a book club to talk about, written on this phone from what this reader has
/// read of the club's book (the companion's memory of it), to copy or send to the club.
Future<void> showDiscussionSheet(BuildContext context, {required String bookId, required String title}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _DiscussionSheet(bookId: bookId, title: title),
    );

class _DiscussionSheet extends ConsumerStatefulWidget {
  const _DiscussionSheet({required this.bookId, required this.title});

  final String bookId;
  final String title;

  @override
  ConsumerState<_DiscussionSheet> createState() => _DiscussionSheetState();
}

class _DiscussionSheetState extends ConsumerState<_DiscussionSheet> {
  late final GemmaPack _gemma;
  List<String>? _questions;
  String? _upTo;
  String? _problem;

  @override
  void initState() {
    super.initState();
    _gemma = ref.read(gemmaProvider.notifier)..hold();
    _write();
  }

  @override
  void dispose() {
    _gemma.letGo();
    _gemma.releaseIfIdle();
    super.dispose();
  }

  Future<void> _write() async {
    setState(() {
      _questions = null;
      _problem = null;
    });
    final material = await BookMemory(widget.bookId).discussionMaterial();
    if (material.recent.isEmpty && (material.story ?? '').isEmpty) {
      if (mounted) {
        setState(() => _problem = 'Questions come from the chapters you’ve finished, with the book’s companion. '
            'Read on a little (with Gemini Nano or Gemma on this phone) and try again.');
      }
      return;
    }
    final model = await companionModel(_gemma);
    if (model == null) {
      if (mounted) setState(() => _problem = 'Questions need a model on this phone: Gemini Nano, or Gemma from Settings › Downloads.');
      return;
    }
    final reply = await model.once(
      discussionPrompt(title: widget.title, story: material.story, recent: material.recent),
      maxTokens: 220,
    );
    if (!mounted) return;
    final questions = reply == null ? const <String>[] : parseQuestions(reply).take(6).toList();
    setState(() {
      _upTo = material.recent.lastOrNull?.chapter;
      _questions = questions;
      if (questions.isEmpty) _problem = 'No questions came this time. Try again.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final questions = _questions;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, Space.lg),
          children: [
            Text('To talk about', style: text.headlineSmall),
            if (_upTo case final upTo?)
              Text('From what you’ve read, up to $upTo. Share them when the club is there too.',
                  style: text.bodySmall?.copyWith(color: muted)),
            const SizedBox(height: Space.md),
            if (_problem case final problem?)
              Text(problem, style: text.bodyMedium?.copyWith(color: muted))
            else if (questions == null)
              Row(
                children: [
                  const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: Space.md),
                  Text('Thinking of questions…', style: text.bodyMedium?.copyWith(color: muted)),
                ],
              )
            else
              for (final (i, q) in questions.indexed)
                Padding(
                  padding: const EdgeInsets.only(bottom: Space.sm),
                  child: Text('${i + 1}. $q', style: text.bodyLarge),
                ),
            const SizedBox(height: Space.md),
            Wrap(
              spacing: Space.sm,
              children: [
                if (questions != null && questions.isNotEmpty) ...[
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.ios_share, size: 18),
                    label: const Text('Send'),
                    onPressed: () => shareText(
                      'Questions for “${widget.title}”${_upTo == null ? '' : ' (up to $_upTo)'}:\n'
                      '${[for (final (i, q) in questions.indexed) '${i + 1}. $q'].join('\n')}',
                    ),
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('Copy'),
                    onPressed: () => Clipboard.setData(ClipboardData(text: questions.join('\n'))),
                  ),
                ],
                if (questions != null || _problem != null)
                  TextButton.icon(icon: const Icon(Icons.refresh, size: 18), label: const Text('New ones'), onPressed: _write),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
