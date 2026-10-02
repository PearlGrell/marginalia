import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../dictionary/dictionary.dart';
import '../dictionary/dictionary_pack.dart';
import '../dictionary/foreign_dictionary.dart';
import '../theme/tokens.dart';
import '../words/word_store.dart';

/// Meanings of [word], from the downloaded dictionary for the book's [language]: English
/// (WordNet), or another language into English (FreeDict). The word can be saved to the word
/// list with the [sentence] it came from.
Future<void> showDefinitionSheet(
  BuildContext context,
  String word, {
  String? language,
  String? bookId,
  String? sentence,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.55,
      maxChildSize: 0.92,
      builder: (context, scroll) => _DefinitionSheet(
        word: word,
        language: language,
        bookId: bookId,
        sentence: sentence,
        scroll: scroll,
      ),
    ),
  );
}

/// What a saved word keeps: its part of speech and a short meaning.
typedef _Meaning = ({String lemma, String? partOfSpeech, String definition});

class _DefinitionSheet extends ConsumerStatefulWidget {
  const _DefinitionSheet({
    required this.word,
    required this.language,
    required this.bookId,
    required this.sentence,
    required this.scroll,
  });

  final String word;
  final String? language;
  final String? bookId;
  final String? sentence;
  final ScrollController scroll;

  @override
  ConsumerState<_DefinitionSheet> createState() => _DefinitionSheetState();
}

class _DefinitionSheetState extends ConsumerState<_DefinitionSheet> {
  /// Look the word up in English even though the book is in another language.
  bool _english = false;
  bool? _saved;

  String get _base => (widget.language ?? 'en').split(RegExp('[-_]')).first.toLowerCase();

  bool get _foreign => _base != 'en' && !_english;

  Future<void> _checkSaved(String lemma) async {
    if (_saved != null) return;
    final saved = await ref.read(wordStoreProvider).isSaved(lemma, _foreign ? _base : 'en');
    if (mounted) setState(() => _saved = saved);
  }

  Future<void> _save(_Meaning meaning) async {
    await ref.read(wordStoreProvider).save(
      word: meaning.lemma,
      language: _foreign ? _base : 'en',
      partOfSpeech: meaning.partOfSpeech,
      definition: meaning.definition,
      context: widget.sentence,
      bookId: widget.bookId,
    );
    if (!mounted) return;
    setState(() => _saved = true);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('“${meaning.lemma}” saved to your words'),
        action: SnackBarAction(
          label: 'Review',
          onPressed: () => GoRouter.of(context).push('/words/review'),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_foreign) return _foreignSheet(context);
    final text = Theme.of(context).textTheme;
    final dictionary = ref.watch(dictionaryProvider);
    return switch (dictionary) {
      AsyncData(value: final dictionary?) => _englishEntries(dictionary.lookUp(widget.word)),
      AsyncData() => _missing(
        'Define works offline once the English dictionary is downloaded (${DictionaryPack.downloadSizeLabel}).',
      ),
      AsyncError() => Center(child: Text('The dictionary could not be opened.', style: text.bodyLarge)),
      _ => const Center(child: CircularProgressIndicator()),
    };
  }

  Widget _englishEntries(List<DictionaryEntry> entries) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurfaceVariant;
    final first = entries.firstOrNull;
    final meaning = first == null || first.senses.isEmpty
        ? null
        : (lemma: first.lemma, partOfSpeech: first.partOfSpeech, definition: first.senses.first.definition);
    if (meaning != null) _checkSaved(meaning.lemma);
    return ListView(
      controller: widget.scroll,
      padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.xxl),
      children: [
        _Heading(
          word: first?.lemma ?? widget.word,
          saved: _saved == true,
          onSave: meaning == null ? null : () => _save(meaning),
        ),
        if (_base != 'en')
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(() {
                _english = false;
                _saved = null;
              }),
              child: const Text('Back to the book’s language'),
            ),
          ),
        if (entries.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Space.md),
            child: Text(
              widget.word.contains(' ') ? 'Select a single word to look it up.' : 'Not in the dictionary.',
              style: text.bodyLarge?.copyWith(color: muted),
            ),
          ),
        for (final entry in entries) ...[
          const SizedBox(height: Space.xl),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.xxs),
                decoration: BoxDecoration(
                  border: Border.all(color: scheme.outlineVariant),
                  borderRadius: BorderRadius.circular(Radii.sm),
                ),
                child: Text(entry.partOfSpeech, style: text.labelMedium?.copyWith(fontStyle: FontStyle.italic)),
              ),
              const SizedBox(width: Space.sm),
              Text(
                '${entry.senses.length} ${entry.senses.length == 1 ? 'meaning' : 'meanings'}',
                style: text.bodySmall,
              ),
            ],
          ),
          for (final (i, sense) in entry.senses.indexed)
            Padding(
              padding: const EdgeInsets.only(top: Space.md),
              child: InkWell(
                // Save with this meaning rather than the first.
                onLongPress: () => _save((lemma: entry.lemma, partOfSpeech: entry.partOfSpeech, definition: sense.definition)),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 24, child: Text('${i + 1}', style: text.titleSmall)),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(sense.definition, style: text.bodyLarge),
                          for (final example in sense.examples.take(2))
                            Padding(
                              padding: const EdgeInsets.only(top: Space.xxs),
                              child: Text(
                                example,
                                style: text.bodyMedium?.copyWith(
                                  fontFamily: FontFamilies.reading,
                                  fontStyle: FontStyle.italic,
                                  color: muted,
                                ),
                              ),
                            ),
                          if (sense.synonyms.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: Space.xxs),
                              child: Text('Also: ${sense.synonyms.join(', ')}', style: text.bodySmall),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
        const SizedBox(height: Space.xl),
        Text('Open English WordNet · CC BY 4.0 · long-press a meaning to save it', style: text.labelSmall),
      ],
    );
  }

  Widget _foreignSheet(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final packs = ref.watch(foreignPacksProvider);
    final code3 = ref.read(foreignPacksProvider.notifier).packFor(_base);
    final languageName = FreeDictPack.names.entries
            .where((e) => e.key == _base || FreeDictPack.iso1[e.key] == _base)
            .firstOrNull
            ?.value ??
        _base.toUpperCase();

    if (code3 == null) {
      final available = ref.watch(freeDictCatalogueProvider).value?.where((p) => p.code == _base || p.code3 == _base).firstOrNull;
      return _missing(
        available == null
            ? 'There is no $languageName dictionary to download yet.'
            : 'Define works offline in $languageName once its dictionary is downloaded (${available.sizeLabel}).',
        showEnglish: true,
        busy: available != null && packs.progress.containsKey(available.code3),
        onDownload: available == null ? null : () => ref.read(foreignPacksProvider.notifier).install(available),
      );
    }

    final dictionary = ref.watch(foreignDictionaryProvider(code3));
    final entries = dictionary.value?.lookUp(widget.word) ?? const <ForeignEntry>[];
    final first = entries.firstOrNull;
    final meaning = first == null
        ? null
        : (lemma: first.headword, partOfSpeech: _grammar(first.heading), definition: first.body.split('\n').take(3).join('; '));
    if (meaning != null) _checkSaved(meaning.lemma);
    return ListView(
      controller: widget.scroll,
      padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.xxl),
      children: [
        _Heading(word: first?.headword ?? widget.word, saved: _saved == true, onSave: meaning == null ? null : () => _save(meaning)),
        if (dictionary.isLoading) const LinearProgressIndicator(minHeight: 2),
        if (!dictionary.isLoading && entries.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Space.md),
            child: Text('Not in the $languageName dictionary.', style: text.bodyLarge?.copyWith(color: muted)),
          ),
        for (final e in entries) ...[
          const SizedBox(height: Space.lg),
          Text(e.heading, style: text.titleSmall?.copyWith(color: muted)),
          const SizedBox(height: Space.xs),
          SelectableText(e.body, style: text.bodyLarge?.copyWith(height: 1.5)),
        ],
        const SizedBox(height: Space.lg),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => setState(() {
              _english = true;
              _saved = null;
            }),
            child: const Text('Look it up in English instead'),
          ),
        ),
        const SizedBox(height: Space.sm),
        Text('$languageName → English · FreeDict', style: text.labelSmall),
      ],
    );
  }

  /// `<n, fem>` → "noun, feminine"-ish: FreeDict's grammar note, readable.
  static String? _grammar(String heading) {
    final m = RegExp(r'<([^>]+)>').firstMatch(heading);
    if (m == null) return null;
    const words = {
      'n': 'noun', 'v': 'verb', 'adj': 'adjective', 'adv': 'adverb', 'prep': 'preposition', //
      'pron': 'pronoun', 'conj': 'conjunction', 'masc': 'masculine', 'fem': 'feminine', 'neut': 'neuter',
      'pl': 'plural', 'vt': 'verb', 'vi': 'verb', 'interj': 'interjection', 'num': 'number',
    };
    return m[1]!.split(RegExp(r',\s*')).map((p) => words[p.trim()] ?? p.trim()).join(', ');
  }

  Widget _missing(String message, {bool showEnglish = false, bool busy = false, VoidCallback? onDownload}) {
    final text = Theme.of(context).textTheme;
    return ListView(
      controller: widget.scroll,
      padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.xxl),
      children: [
        Text(widget.word, style: text.headlineMedium),
        const SizedBox(height: Space.md),
        Text(message, style: text.bodyLarge),
        const SizedBox(height: Space.lg),
        Wrap(
          spacing: Space.sm,
          runSpacing: Space.sm,
          children: [
            if (onDownload != null)
              FilledButton.icon(
                icon: busy
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.download_outlined),
                label: Text(busy ? 'Downloading…' : 'Download'),
                onPressed: busy ? null : onDownload,
              ),
            OutlinedButton.icon(
              icon: const Icon(Icons.tune),
              label: const Text('Open downloads'),
              onPressed: () {
                Navigator.pop(context);
                context.push('/settings/downloads');
              },
            ),
            if (showEnglish)
              TextButton(
                onPressed: () => setState(() {
                  _english = true;
                  _saved = null;
                }),
                child: const Text('Look it up in English'),
              ),
          ],
        ),
      ],
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading({required this.word, required this.saved, required this.onSave});

  final String word;
  final bool saved;
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(word, style: Theme.of(context).textTheme.headlineMedium)),
        if (onSave != null)
          saved
              ? TextButton.icon(
                  icon: const Icon(Icons.bookmark_added, size: 18),
                  label: const Text('Saved'),
                  onPressed: onSave,
                )
              : FilledButton.tonalIcon(
                  icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                  label: const Text('Save word'),
                  onPressed: onSave,
                ),
      ],
    );
  }
}
