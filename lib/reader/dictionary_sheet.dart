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
/// list with the [sentence] it came from. A tap on a word in a meaning looks that word up in
/// the same sheet; back returns to the word before.
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

/// A word being looked up: the one from the page, or one tapped in a meaning (with that
/// meaning as its context, and in English when it came from an English translation).
typedef _LookUp = ({String word, String? sentence, bool english});

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
  /// The words looked up, the page's first; the last is showing.
  late final _trail = <_LookUp>[(word: widget.word, sentence: widget.sentence, english: false)];
  bool? _saved;

  String get _word => _trail.last.word;

  /// Look the word up in English even though the book is in another language.
  bool get _english => _trail.last.english;
  set _english(bool english) => _trail.last = (word: _word, sentence: _trail.last.sentence, english: english);

  String get _base => (widget.language ?? 'en').split(RegExp('[-_]')).first.toLowerCase();

  bool get _foreign => _base != 'en' && !_english;

  /// The word before this one, when this one was tapped in its meaning.
  String? get _from => _trail.length > 1 ? _trail[_trail.length - 2].word : null;

  /// Looks up [word], tapped in [sentence], on top of the current word.
  void _lookUp(String word, String sentence, {bool english = false}) {
    if (word.toLowerCase() == _word.toLowerCase()) return;
    setState(() {
      _trail.add((word: word, sentence: sentence, english: english || _english));
      _saved = null;
    });
    if (widget.scroll.hasClients) widget.scroll.jumpTo(0);
  }

  void _back() => setState(() {
    _trail.removeLast();
    _saved = null;
  });

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
      context: _trail.last.sentence,
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
    // Back goes to the word before, then closes the sheet.
    return PopScope(
      canPop: _trail.length == 1,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: _foreign ? _foreignSheet(context) : _englishSheet(context),
    );
  }

  Widget _englishSheet(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final dictionary = ref.watch(dictionaryProvider);
    return switch (dictionary) {
      AsyncData(value: final dictionary?) => _englishEntries(dictionary.lookUp(_word)),
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
          word: first?.lemma ?? _word,
          saved: _saved == true,
          onSave: meaning == null ? null : () => _save(meaning),
          from: _from,
          onBack: _trail.length > 1 ? _back : null,
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
              _word.contains(' ') ? 'Select a single word to look it up.' : 'Not in the dictionary.',
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
                          _WordsText(
                            sense.definition,
                            style: text.bodyLarge,
                            onWord: (word) => _lookUp(word, sense.definition),
                          ),
                          for (final example in sense.examples.take(2))
                            Padding(
                              padding: const EdgeInsets.only(top: Space.xxs),
                              child: _WordsText(
                                example,
                                style: text.bodyMedium?.copyWith(
                                  fontFamily: FontFamilies.reading,
                                  fontStyle: FontStyle.italic,
                                  color: muted,
                                ),
                                onWord: (word) => _lookUp(word, example),
                              ),
                            ),
                          if (sense.synonyms.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: Space.xxs),
                              child: _WordsText(
                                'Also: ${sense.synonyms.join(', ')}',
                                style: text.bodySmall,
                                onWord: (word) => _lookUp(word, sense.definition),
                              ),
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
        Text(
          'Open English WordNet · CC BY 4.0 · tap a word to look it up · long-press a meaning to save it',
          style: text.labelSmall,
        ),
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
    final entries = dictionary.value?.lookUp(_word) ?? const <ForeignEntry>[];
    final first = entries.firstOrNull;
    final meaning = first == null
        ? null
        : (lemma: first.headword, partOfSpeech: _grammar(first.heading), definition: first.body.split('\n').take(3).join('; '));
    if (meaning != null) _checkSaved(meaning.lemma);
    return ListView(
      controller: widget.scroll,
      padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.xxl),
      children: [
        _Heading(
          word: first?.headword ?? _word,
          saved: _saved == true,
          onSave: meaning == null ? null : () => _save(meaning),
          from: _from,
          onBack: _trail.length > 1 ? _back : null,
        ),
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
          // The translations are English: their words are looked up in English.
          _WordsText(
            e.body,
            style: text.bodyLarge?.copyWith(height: 1.5),
            onWord: (word) => _lookUp(word, e.body, english: true),
          ),
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
        _Heading(word: _word, saved: false, onSave: null, from: _from, onBack: _trail.length > 1 ? _back : null),
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
  const _Heading({required this.word, required this.saved, required this.onSave, this.from, this.onBack});

  final String word;
  final bool saved;
  final VoidCallback? onSave;

  /// The word this one was tapped in, shown under it.
  final String? from;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(
      children: [
        if (onBack != null)
          IconButton(icon: const Icon(Icons.arrow_back), tooltip: 'Back to “$from”', onPressed: onBack),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(word, style: text.headlineMedium),
              if (from != null)
                Text(
                  'from “$from”',
                  style: text.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
            ],
          ),
        ),
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

/// [text] whose words look themselves up: a tap on a word calls [onWord] with it.
class _WordsText extends StatelessWidget {
  const _WordsText(this.text, {required this.style, required this.onWord});

  final String text;
  final TextStyle? style;
  final ValueChanged<String> onWord;

  static final _word = RegExp(r"[\p{L}\p{M}]+(?:['’-][\p{L}\p{M}]+)*", unicode: true);

  @override
  Widget build(BuildContext context) {
    final effective = DefaultTextStyle.of(context).style.merge(style);
    return LayoutBuilder(
      builder: (context, constraints) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) {
          final painter = TextPainter(
            text: TextSpan(text: text, style: effective),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
          )..layout(maxWidth: constraints.maxWidth);
          final range = painter.getWordBoundary(painter.getPositionForOffset(details.localPosition));
          painter.dispose();
          if (_word.firstMatch(text.substring(range.start, range.end))?[0] case final word?) onWord(word);
        },
        child: Text(text, style: effective),
      ),
    );
  }
}
