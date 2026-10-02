import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

import '../theme/tokens.dart';
import 'translation.dart';

/// Translates [text] (in the book's [bookLanguage], if known) into the reader's language.
///
/// With the [paragraph] around the selection, the whole paragraph can be translated instead,
/// and [onShowInPage] puts that translation under the paragraph in the book.
Future<void> showTranslateSheet(
  BuildContext context,
  String text, {
  String? bookLanguage,
  String? paragraph,
  Future<bool> Function(String translation)? onShowInPage,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.55,
      maxChildSize: 0.92,
      builder: (context, scroll) => _TranslateSheet(
        text: text,
        paragraph: paragraph?.trim().isEmpty ?? true ? null : paragraph!.trim(),
        onShowInPage: onShowInPage,
        initialSource: TranslateLanguageName.fromCode(bookLanguage) ?? TranslateLanguage.english,
        scroll: scroll,
      ),
    ),
  );
}

class _TranslateSheet extends ConsumerStatefulWidget {
  const _TranslateSheet({
    required this.text,
    required this.initialSource,
    required this.scroll,
    this.paragraph,
    this.onShowInPage,
  });

  final String text;
  final String? paragraph;
  final Future<bool> Function(String translation)? onShowInPage;
  final TranslateLanguage initialSource;
  final ScrollController scroll;

  @override
  ConsumerState<_TranslateSheet> createState() => _TranslateSheetState();
}

class _TranslateSheetState extends ConsumerState<_TranslateSheet> {
  late TranslateLanguage _source = widget.initialSource;
  Future<String>? _result;
  (TranslateLanguage, TranslateLanguage, bool)? _resultFor;

  /// Translating the whole paragraph rather than the selection.
  bool _wholeParagraph = false;

  String get _input => _wholeParagraph ? widget.paragraph! : widget.text;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(translationProvider);
    final translation = ref.read(translationProvider.notifier);
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final target = state.target;
    final missing = [
      for (final l in {_source, target})
        if (!state.downloaded.contains(l)) l,
    ];
    final downloading = missing.any(state.downloading.contains);

    if (missing.isEmpty && _source != target && _resultFor != (_source, target, _wholeParagraph)) {
      _resultFor = (_source, target, _wholeParagraph);
      _result = translation.translate(_input, _source, target);
    }

    return ListView(
      controller: widget.scroll,
      padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.xxl),
      children: [
        Row(
          children: [
            _LanguageButton(
              language: _source,
              onChanged: (l) => setState(() => _source = l),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: Space.sm),
              child: Icon(Icons.arrow_forward, size: 18),
            ),
            _LanguageButton(language: target, onChanged: translation.setTarget),
          ],
        ),
        if (widget.paragraph != null) ...[
          const SizedBox(height: Space.md),
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: false, label: Text('Selection')),
              ButtonSegment(value: true, label: Text('Whole paragraph')),
            ],
            selected: {_wholeParagraph},
            onSelectionChanged: (s) => setState(() => _wholeParagraph = s.first),
          ),
        ],
        const SizedBox(height: Space.lg),
        Text(
          _input.trim(),
          maxLines: _wholeParagraph ? 8 : null,
          overflow: _wholeParagraph ? TextOverflow.ellipsis : null,
          style: text.bodyLarge?.copyWith(fontFamily: FontFamilies.reading, color: muted),
        ),
        const Divider(height: Space.xxl),
        if (_source == target)
          Text('Choose a different language to translate into.', style: text.bodyMedium)
        else if (missing.isNotEmpty)
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Translation works offline once ${missing.map((l) => l.label).join(' and ')} '
                '${missing.length == 1 ? 'is' : 'are'} downloaded (about 30 MB each).',
                style: text.bodyMedium,
              ),
              const SizedBox(height: Space.md),
              if (downloading)
                const LinearProgressIndicator(minHeight: 3)
              else
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.download_outlined),
                    label: const Text('Open downloads'),
                    onPressed: () {
                      Navigator.pop(context);
                      context.push('/settings/downloads');
                    },
                  ),
                ),
            ],
          )
        else
          FutureBuilder<String>(
            future: _result,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Text("This couldn't be translated.", style: text.bodyMedium);
              }
              if (!snapshot.hasData) return const LinearProgressIndicator(minHeight: 2);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(snapshot.data!, style: text.bodyLarge?.copyWith(fontFamily: FontFamilies.reading)),
                  const SizedBox(height: Space.sm),
                  Wrap(
                    spacing: Space.sm,
                    children: [
                      TextButton.icon(
                        icon: const Icon(Icons.copy_outlined, size: 18),
                        label: const Text('Copy'),
                        onPressed: () => Clipboard.setData(ClipboardData(text: snapshot.data!)),
                      ),
                      if (_wholeParagraph && widget.onShowInPage != null)
                        FilledButton.tonalIcon(
                          icon: const Icon(Icons.vertical_align_bottom, size: 18),
                          label: const Text('Show under the paragraph'),
                          onPressed: () async {
                            final messenger = ScaffoldMessenger.of(context);
                            final navigator = Navigator.of(context);
                            final shown = await widget.onShowInPage!(snapshot.data!);
                            navigator.pop();
                            if (!shown) {
                              messenger.showSnackBar(
                                const SnackBar(content: Text("The paragraph has moved off the page; try again")),
                              );
                            }
                          },
                        ),
                    ],
                  ),
                ],
              );
            },
          ),
        const SizedBox(height: Space.xl),
        Text('Translated on this phone by Google ML Kit', style: text.labelSmall),
      ],
    );
  }
}

class _LanguageButton extends StatelessWidget {
  const _LanguageButton({required this.language, required this.onChanged});

  final TranslateLanguage language;
  final ValueChanged<TranslateLanguage> onChanged;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: () async {
        final picked = await pickTranslateLanguage(context, selected: language);
        if (picked != null) onChanged(picked);
      },
      child: Text(language.label),
    );
  }
}

/// A list of every language ML Kit translates.
Future<TranslateLanguage?> pickTranslateLanguage(BuildContext context, {TranslateLanguage? selected}) {
  final languages = [...TranslateLanguage.values]..sort((a, b) => a.label.compareTo(b.label));
  return showModalBottomSheet<TranslateLanguage>(
    context: context,
    isScrollControlled: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      builder: (context, scroll) => ListView.builder(
        controller: scroll,
        itemCount: languages.length,
        itemBuilder: (context, i) => ListTile(
          title: Text(languages[i].label),
          trailing: languages[i] == selected ? const Icon(Icons.check) : null,
          onTap: () => Navigator.pop(context, languages[i]),
        ),
      ),
    ),
  );
}
