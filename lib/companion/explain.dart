import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/tokens.dart';
import 'companion.dart';
import 'conversation.dart';
import 'gemma.dart';

/// The model the companion writes with on this phone: the larger Gemma if it's here, else
/// Gemini Nano where the phone has it, else the small Gemma; null with none.
Future<CompanionModel?> companionModel(GemmaPack pack) async {
  final size = pack.installedSize;
  if (size == GemmaSize.large) return GemmaModel(pack);
  if (await const Nano().status() == NanoStatus.available) return const NanoModel();
  if (size != null) return GemmaModel(pack);
  return null;
}

/// The prompt to explain [selected], in [paragraph], of "[title]" (public for tests).
String explainPrompt({
  required String title,
  String? authors,
  required String selected,
  String? paragraph,
  String? story,
}) {
  final around = paragraph?.trim();
  return [
    'You help someone reading "$title"${authors == null || authors.isEmpty ? '' : ' by $authors'} understand '
        'what they are reading. Never mention or hint at anything that happens later in the book.',
    if (story != null && story.trim().isNotEmpty) 'The story so far, in brief:\n${story.trim()}',
    if (around != null && around.isNotEmpty && around != selected.trim()) 'The passage they are reading:\n$around',
    'They want explained: "${selected.trim()}"',
    'In three to five plain sentences, explain what this means here: old or unusual words, idioms, '
        'references to people, places or customs, and what it says about the characters or the story so '
        'far. Write to the reader, with no introduction.',
  ].join('\n\n');
}

/// "Explain": what a passage the reader selected means, in plain words, from the phone's
/// model, with what's around it and the story so far. Nothing leaves the phone.
Future<void> showExplainSheet(
  BuildContext context, {
  required String selected,
  String? paragraph,
  required String title,
  String? authors,
  String? story,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (context) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.55,
    maxChildSize: 0.9,
    builder: (context, scroll) => _ExplainSheet(
      scroll: scroll,
      prompt: explainPrompt(title: title, authors: authors, selected: selected, paragraph: paragraph, story: story),
      selected: selected,
    ),
  ),
);

class _ExplainSheet extends ConsumerStatefulWidget {
  const _ExplainSheet({required this.scroll, required this.prompt, required this.selected});

  final ScrollController scroll;
  final String prompt;
  final String selected;

  @override
  ConsumerState<_ExplainSheet> createState() => _ExplainSheetState();
}

class _ExplainSheetState extends ConsumerState<_ExplainSheet> {
  late final GemmaPack _gemma;
  StreamSubscription<String>? _writing;
  CompanionModel? _model;
  String _answer = '';
  String? _error;
  bool _done = false;
  bool _noModel = false;

  @override
  void initState() {
    super.initState();
    _gemma = ref.read(gemmaProvider.notifier)..hold();
    _start();
  }

  Future<void> _start() async {
    final model = await companionModel(_gemma);
    if (!mounted) return;
    if (model == null) {
      setState(() => _noModel = true);
      return;
    }
    _model = model;
    _writing = model.write(widget.prompt, fresh: true, maxTokens: 220).listen(
      (text) {
        if (mounted) setState(() => _answer = text.trimLeft());
      },
      onError: (Object e) {
        if (mounted) setState(() => _error = e is ModelFailed ? e.message : 'It couldn’t be explained just now.');
      },
      onDone: () {
        if (mounted) {
          setState(() {
            _answer = tidyAnswer(_answer);
            _done = true;
          });
        }
      },
    );
  }

  @override
  void dispose() {
    _writing?.cancel();
    if (!_done) _model?.cancel();
    _gemma.letGo();
    _gemma.releaseIfIdle();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurfaceVariant;
    return ListView(
      controller: widget.scroll,
      padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, Space.xxl),
      children: [
        Text('Explain', style: text.headlineSmall),
        const SizedBox(height: Space.sm),
        Container(
          padding: const EdgeInsets.only(left: Space.md),
          decoration: BoxDecoration(border: Border(left: BorderSide(color: scheme.outlineVariant, width: 3))),
          child: Text(
            widget.selected.trim(),
            maxLines: 6,
            overflow: TextOverflow.ellipsis,
            style: text.bodyMedium?.copyWith(fontFamily: FontFamilies.reading, height: 1.45),
          ),
        ),
        const SizedBox(height: Space.lg),
        if (_noModel)
          Text(
            'Explaining needs a model on this phone: Gemini Nano, or Gemma from Settings › Downloads.',
            style: text.bodyMedium?.copyWith(color: muted),
          )
        else if (_error case final error?)
          Text(error, style: text.bodyMedium?.copyWith(color: muted))
        else if (_answer.isEmpty)
          Row(
            children: [
              const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: Space.md),
              Expanded(child: Text('Reading it…', style: text.bodyMedium?.copyWith(color: muted))),
            ],
          )
        else
          MarkdownBody(
            data: _answer,
            selectable: true,
            softLineBreak: true,
            styleSheet: MarkdownStyleSheet(p: text.bodyLarge?.copyWith(height: 1.55)),
          ),
      ],
    );
  }
}
