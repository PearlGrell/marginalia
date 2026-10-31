import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/tokens.dart';
import 'book_memory.dart';
import 'companion.dart';
import 'conversation.dart';
import 'gemma.dart';
import 'people.dart';
import 'previously.dart';
import 'semantic.dart';

/// The book so far, X-Ray style, never past [place]: a recap (each finished chapter's summary,
/// then what has happened in the chapter the reader is in) with questions to follow it up, and
/// the people and places so far, each with who they are. Everything comes from what the app
/// kept as the book was read (see [BookMemory]). Gemini Nano writes on phones that have it,
/// Gemma (downloaded on request) on the others; until there's a model, the book's own passages
/// are the answer. [name], when a name was selected, opens on that person.
Future<void> showCompanionSheet(
  BuildContext context, {
  required String bookId,
  required Place place,
  required String title,
  String? authors,
  String? name,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (context) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.7,
    maxChildSize: 0.95,
    builder: (context, scroll) => _CompanionSheet(
      bookId: bookId,
      place: place,
      title: title,
      authors: authors,
      name: name,
      scroll: scroll,
    ),
  ),
);

/// Asks before Gemma's download: its size, Wi-Fi, and its terms. True to go ahead.
Future<bool> confirmGemmaDownload(BuildContext context, {GemmaSize size = GemmaSize.small}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.auto_awesome_outlined),
        title: Text('Download ${size.label}?'),
        content: Text(
          '${size == GemmaSize.small ? 'Gemma 3 is a small AI model' : 'Gemma 3n is an AI model'} from Google '
          'that runs on your phone, so questions about your book never leave it.\n\n'
          'It’s a one-time download of ${size.sizeLabel}; Wi-Fi recommended. You can remove it '
          'in Settings › Downloads.\n\n'
          'Gemma is provided under and subject to the Gemma Terms of Use (${GemmaPack.termsUrl}).',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Not now')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Download')),
        ],
      ),
    ) ??
    false;

enum _Tab { recap, people, timeline }

class _CompanionSheet extends ConsumerStatefulWidget {
  const _CompanionSheet({
    required this.bookId,
    required this.place,
    required this.title,
    required this.authors,
    required this.name,
    required this.scroll,
  });

  final String bookId;
  final Place place;
  final String title;
  final String? authors;
  final String? name;
  final ScrollController scroll;

  @override
  ConsumerState<_CompanionSheet> createState() => _CompanionSheetState();
}

class _CompanionSheetState extends ConsumerState<_CompanionSheet> {
  static const _nano = Nano();

  late _Tab _tab = widget.name == null ? _Tab.recap : _Tab.people;
  NanoStatus? _status;
  String? _nanoError;

  /// The book so far, worked out once (off the UI thread) when the sheet opens.
  BookData? _data;

  /// Its passages by meaning, made ready in the background (keyword search until then).
  SemanticIndex? _semantic;

  /// Chapter summaries by number, kept up to date as they're written.
  Map<int, String> _summaries = const {};
  Conversation? _conversation;

  Turn? _recap;
  final _answers = <String, Turn>{};

  /// Questions to follow the recap, and to follow each answer (by question).
  List<String> _questions = const [];
  final _followUps = <String, List<String>>{};

  /// The question (or person) open, showing its answer.
  String? _open;

  /// The answer being written, and what it's for; what waits, in turn.
  StreamSubscription<Turn>? _answering;
  String? _answeringKey;
  final _queue = <(String, Ask)>[];

  // Read up front: ref can't be used in dispose.
  late final GemmaPack _gemma;
  late final ChapterSummaries _summarising;

  static const _recapKey = '\u0000recap';

  @override
  void initState() {
    super.initState();
    _gemma = ref.read(gemmaProvider.notifier)..hold();
    _summarising = ref.read(chapterSummariesProvider.notifier);
    _start();
  }

  Future<void> _start() async {
    final memory = BookMemory(widget.bookId);
    final (data, status) = await (
      memory.load(place: widget.place, title: widget.title, authors: widget.authors),
      _nano.status(),
    ).wait;
    if (!mounted) return;
    setState(() {
      _data = data;
      _summaries = {
        for (final c in data.chapters) c.number: ?data.book.summaries[c.number - 1],
      };
      _status = status;
    });
    // Already on its way (asked for before): wait on it here too.
    if (status == NanoStatus.downloading) unawaited(_getNano());
    _semantic = SemanticIndex(dir: await memory.path(), index: data.book.index);
    unawaited(_semantic!.prepare().catchError((_) {}));
    final name = widget.name?.trim();
    if (name != null && name.isNotEmpty) {
      _openPerson(name);
    } else {
      _askRecap();
    }
    // Finished chapters without a summary yet: written now, after what's asked here.
    _summarising.catchUp(bookId: widget.bookId, title: widget.title, authors: widget.authors);
  }

  /// A summary has been written: only the summaries are read again.
  Future<void> _summariesChanged() async {
    final data = _data;
    if (data == null) return;
    final byKey = await BookMemory(widget.bookId).summaries();
    if (!mounted) return;
    setState(() {
      _summaries = {
        for (final c in data.chapters) c.number: ?byKey[c.key],
      };
    });
  }

  @override
  void dispose() {
    _answering?.cancel();
    _gemma.letGo();
    // Gemma takes about 1 GB loaded: not kept once the sheet is closed (Listen needs room too).
    _gemma.cancelAnswer().then((_) => _gemma.releaseIfIdle());
    super.dispose();
  }

  /// The model writing here: the larger Gemma if it's here (it writes better than Nano), else
  /// Nano where the phone has it, else the small Gemma once downloaded.
  CompanionModel? _model() {
    final gemma = ref.read(gemmaProvider).size;
    if (gemma == GemmaSize.large) return GemmaModel(_gemma);
    if (_status == NanoStatus.available) return const NanoModel();
    if (gemma != null) return GemmaModel(_gemma);
    return null;
  }

  /// Asks [ask] for [key], keeping its turn there as it's answered; after what's being
  /// written now, if anything is.
  void _run(String key, Ask ask) {
    final data = _data;
    if (data == null) return;
    final model = _model();
    var conversation = _conversation;
    if (conversation == null || (model == null) != (conversation.model is _NoModel)) {
      final semantic = _semantic;
      conversation = _conversation = Conversation(
        book: data.book,
        model: model ?? const _NoModel(),
        similar: semantic == null ? null : (query) => semantic.search(query),
      );
    }
    void keep(Turn turn) => key == _recapKey ? _recap = turn : _answers[key] = turn;
    if (model == null) {
      // No model: the passages from the book are the answer.
      final turn = Turn(ask)
        ..passages = (conversation.passagesFor(ask, 3000)..sort(readingOrder))
        ..done = true;
      setState(() => keep(turn));
      return;
    }
    if (_answeringKey != null) {
      if (_answeringKey != key && !_queue.any((q) => q.$1 == key)) _queue.add((key, ask));
      return;
    }
    _answeringKey = key;
    _answering = conversation.ask(ask).listen((turn) {
      if (!mounted) return;
      setState(() => keep(turn));
      if (!turn.done) return;
      _answeringKey = null;
      _answering = null;
      if (turn.answer.isNotEmpty && ask.kind != AskKind.who) unawaited(_suggest(key, turn.answer));
      if (_queue.isNotEmpty) {
        final (nextKey, nextAsk) = _queue.removeAt(0);
        _run(nextKey, nextAsk);
      }
    });
  }

  /// Questions to follow [after] (the recap, or the answer to [key]).
  Future<void> _suggest(String key, String after) async {
    final conversation = _conversation;
    final data = _data;
    if (conversation == null || data == null) return;
    final chapter = data.book.chapter;
    final here = [
      for (final p in data.people.take(12))
        if (p.byChapter.length >= chapter && chapter > 0 && p.byChapter[chapter - 1] > 0)
          p.firstSeen.chapter == chapter ? '${p.name} (new)' : p.name,
    ];
    final questions = await conversation.suggest(after: after, people: here);
    if (!mounted) return;
    setState(() {
      if (key == _recapKey) {
        // Someone new in this chapter: who they are is a question worth having.
        final newcomer = data.people.where((p) => p.firstSeen.chapter == chapter && p.mentions >= 3).firstOrNull;
        _questions = [
          if (newcomer != null && !questions.any((q) => q.contains(newcomer.name))) 'Who is ${newcomer.name}?',
          ...questions,
        ].take(3).toList();
      } else {
        _followUps[key] = questions.take(2).toList();
      }
    });
  }

  void _askRecap() => _run(_recapKey, const Ask.recap());

  void _openPerson(String name) {
    setState(() {
      _tab = _Tab.people;
      _open = name;
    });
    if (_answers['who:$name'] == null) _run('who:$name', Ask.who(name));
  }

  void _toggleQuestion(String question) {
    if (_open == question) return setState(() => _open = null);
    setState(() => _open = question);
    final ask = Ask.parse(question);
    if (ask.kind == AskKind.who) {
      // "Who is …" answers are the people's, wherever they're asked.
      if (_answers['who:${ask.name}'] == null) _run('who:${ask.name}', Ask.who(ask.name!));
      return;
    }
    if (_answers[question] == null) _run(question, ask);
  }

  Turn? _answerFor(String question) {
    final ask = Ask.parse(question);
    return ask.kind == AskKind.who ? _answers['who:${ask.name}'] : _answers[question];
  }

  void _togglePerson(String name) {
    if (_open == name) return setState(() => _open = null);
    _openPerson(name);
  }

  Future<void> _getNano() async {
    setState(() {
      _status = NanoStatus.downloading;
      _nanoError = null;
    });
    final (:ready, :error) = await _nano.download();
    if (!mounted) return;
    setState(() {
      _status = ready ? NanoStatus.available : NanoStatus.downloadable;
      _nanoError = ready ? null : 'Gemini Nano couldn’t be fetched${error == null ? '' : ': $error'}.';
    });
    if (ready) _askRecap();
  }

  Future<void> _getGemma() async {
    if (await confirmGemmaDownload(context) && mounted) await ref.read(gemmaProvider.notifier).install();
  }

  @override
  Widget build(BuildContext context) {
    final gemma = ref.watch(gemmaProvider);
    ref.listen(chapterSummariesProvider, (_, _) => _summariesChanged());
    // Once Gemma is in, the recap is written with it.
    ref.listen(gemmaProvider, (before, now) {
      if (now.size != null && before?.size != now.size) {
        _answers.clear();
        _conversation = null;
        _askRecap();
        _summarising.catchUp(bookId: widget.bookId, title: widget.title, authors: widget.authors);
      }
    });
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurfaceVariant;
    final data = _data;
    final current = data?.current;
    return ListView(
      controller: widget.scroll,
      padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, Space.xxl),
      children: [
        Text('The book so far', style: text.headlineSmall),
        Text(
          data == null
              ? 'Reading up to your page…'
              : current == null
              ? 'Up to your page, never further.'
              : 'Up to ${_chapterLabel(current.number)}, never further.',
          style: text.bodySmall?.copyWith(color: muted),
        ),
        const SizedBox(height: Space.md),
        SegmentedButton<_Tab>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: _Tab.recap, label: Text('Recap'), icon: Icon(Icons.history_edu_outlined)),
            ButtonSegment(value: _Tab.people, label: Text('People'), icon: Icon(Icons.groups_outlined)),
            ButtonSegment(value: _Tab.timeline, label: Text('Timeline'), icon: Icon(Icons.timeline)),
          ],
          selected: {_tab},
          onSelectionChanged: (s) => setState(() => _tab = s.first),
        ),
        const SizedBox(height: Space.lg),
        if (data == null)
          _working('Reading up to your page…', text, muted)
        else if (_tab == _Tab.recap)
          ..._recapTab(data, text, scheme)
        else if (_tab == _Tab.people)
          ..._peopleTab(data, text, scheme)
        else
          ..._timelineTab(data, text, scheme),
        ..._modelCards(gemma, text: text, scheme: scheme),
      ],
    );
  }

  /// "Chapter 3 · A Caucus-Race and a Long Tale", or the contents' title as it is when it
  /// already says the chapter ("CHAPTER III. A Caucus-Race…").
  String _chapterLabel(int number) {
    final title = _data?.book.titleOf(number);
    if (title == null) return 'Chapter $number';
    return RegExp(r'^(chapter|part|book)\b', caseSensitive: false).hasMatch(title) ? title : 'Chapter $number · $title';
  }

  Widget _working(String label, TextTheme text, Color muted) => Padding(
    padding: const EdgeInsets.symmetric(vertical: Space.sm),
    child: Row(
      children: [
        const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: Space.md),
        Expanded(child: Text(label, style: text.bodyMedium?.copyWith(color: muted))),
      ],
    ),
  );

  String get _writingLabel =>
      _status == NanoStatus.available ? 'Writing…' : 'Writing… The first one takes longest on this phone.';

  /// The model's answer, its markdown laid out (paragraphs, bold, lists), selectable.
  Widget _prose(String markdown, TextTheme text) => MarkdownBody(
    data: markdown,
    selectable: true,
    softLineBreak: true,
    styleSheet: MarkdownStyleSheet(
      p: text.bodyLarge?.copyWith(height: 1.55),
      listBullet: text.bodyLarge,
      strong: const TextStyle(fontWeight: FontWeight.w600),
      blockSpacing: Space.sm,
      h1: text.titleMedium,
      h2: text.titleMedium,
      h3: text.titleSmall,
    ),
  );

  /// A turn's answer when it's written; while it's being written, a line saying so.
  List<Widget> _answer(Turn? turn, TextTheme text, ColorScheme scheme, {required String empty}) {
    final muted = scheme.onSurfaceVariant;
    if (turn == null || !turn.done) return [_working(_writingLabel, text, muted)];
    return [
      if (turn.answer.isNotEmpty) _prose(turn.answer, text),
      if (turn.error case final error?) Text(error, style: text.bodyMedium?.copyWith(color: muted)),
      if (turn.answer.isEmpty && turn.error == null && turn.passages.isNotEmpty) ...[
        for (final p in turn.passages) _passage(p.text, text, scheme),
      ] else if (turn.answer.isEmpty && turn.error == null)
        Text(empty, style: text.bodyMedium?.copyWith(color: muted)),
    ];
  }

  Widget _passage(String passage, TextTheme text, ColorScheme scheme, {String? label}) => Container(
    margin: const EdgeInsets.only(bottom: Space.sm),
    padding: const EdgeInsets.only(left: Space.md),
    decoration: BoxDecoration(border: Border(left: BorderSide(color: scheme.outlineVariant, width: 3))),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null) Text(label, style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
        Text(passage, style: text.bodyMedium?.copyWith(fontFamily: FontFamilies.reading, height: 1.45)),
      ],
    ),
  );

  /// Earlier chapters shown in full (the rest fold away).
  var _allChapters = false;

  /// The chapters finished, each with its summary (written as the book is read), then the one
  /// the reader is in, written now.
  List<Widget> _chapters(BookData data, TextTheme text, ColorScheme scheme) {
    final muted = scheme.onSurfaceVariant;
    final now = data.current?.number;
    final withText = data.book.chapters.toSet();
    final finished = [
      for (final c in data.chapters)
        if (c.number != now && _summaries[c.number] != '') c.number,
    ];
    final shown = _allChapters ? finished : finished.skip(math.max(0, finished.length - 3)).toList();
    Widget heading(int number, {bool isNow = false}) => Padding(
      padding: const EdgeInsets.only(top: Space.md, bottom: Space.xs),
      child: Text(
        isNow ? 'Now · ${_chapterLabel(number)}' : _chapterLabel(number),
        style: text.titleSmall?.copyWith(color: isNow ? scheme.primary : null),
      ),
    );
    return [
      if (shown.length < finished.length)
        TextButton.icon(
          style: TextButton.styleFrom(padding: EdgeInsets.zero, alignment: Alignment.centerLeft),
          onPressed: () => setState(() => _allChapters = true),
          icon: const Icon(Icons.unfold_more, size: 18),
          label: Text('${finished.length - shown.length} earlier chapters'),
        ),
      for (final number in shown) ...[
        heading(number),
        if (_summaries[number] case final summary? when summary.isNotEmpty)
          _prose(summary, text)
        else if (!withText.contains(number))
          Text('Catching up on this chapter…', style: text.bodyMedium?.copyWith(color: muted))
        else if (_model() != null)
          Text('Summary on its way…', style: text.bodyMedium?.copyWith(color: muted))
        else
          Text(
            (data.keySentences[number] ?? const []).join(' '),
            style: text.bodyMedium?.copyWith(fontFamily: FontFamilies.reading),
          ),
      ],
      if (now != null && finished.isNotEmpty) heading(now, isNow: true),
    ];
  }

  Widget _question(String q, TextTheme text, ColorScheme scheme, {bool small = false}) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ListTile(
        contentPadding: EdgeInsets.zero,
        dense: small,
        leading: small ? Icon(Icons.subdirectory_arrow_right, size: 18, color: scheme.onSurfaceVariant) : null,
        title: Text(q, style: small ? text.bodyMedium : text.bodyLarge),
        trailing: Icon(_open == q ? Icons.expand_less : Icons.expand_more),
        onTap: () => _toggleQuestion(q),
      ),
      if (_open == q)
        Padding(
          padding: const EdgeInsets.only(bottom: Space.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ..._answer(_answerFor(q), text, scheme, empty: 'The book so far doesn’t say.'),
              // What to ask next, from the answer.
              for (final next in _followUps[q] ?? const <String>[]) _question(next, text, scheme, small: true),
            ],
          ),
        ),
    ],
  );

  List<Widget> _recapTab(BookData data, TextTheme text, ColorScheme scheme) => [
    if (data.story?.story case final story? when story.trim().isNotEmpty) ...[
      Text('The story so far', style: text.titleSmall),
      const SizedBox(height: Space.xs),
      _prose(story, text),
      const SizedBox(height: Space.sm),
    ],
    ..._chapters(data, text, scheme),
    ..._answer(_recap, text, scheme, empty: 'There’s not enough read yet for a recap.'),
    if (_questions.isNotEmpty) ...[
      const SizedBox(height: Space.xl),
      Text('Questions', style: text.titleSmall),
      const SizedBox(height: Space.xs),
      for (final q in _questions) ...[_question(q, text, scheme), const Divider(height: 1)],
    ],
  ];

  List<Widget> _peopleTab(BookData data, TextTheme text, ColorScheme scheme) {
    final muted = scheme.onSurfaceVariant;
    final people = data.people;
    if (people.isEmpty) {
      return [Text('No one named often enough yet.', style: text.bodyMedium?.copyWith(color: muted))];
    }
    // A name selected in the book, if the list doesn't have it.
    final extra = widget.name?.trim();
    final names = [
      if (extra != null && extra.isNotEmpty && !people.any((p) => p.name == extra)) extra,
      for (final p in people) p.name,
    ];
    return [
      for (final name in names) ...[
        _personTile(name, people.where((p) => p.name == name).firstOrNull, text, scheme),
        if (_open == name)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (data.book.profileOf(name) case final profile?) ...[
                  Text('So far', style: text.labelSmall?.copyWith(color: muted)),
                  _prose(profile, text),
                  const SizedBox(height: Space.sm),
                ],
                if (people.where((p) => p.name == name).firstOrNull case final person?)
                  _passage(
                    person.firstSentence,
                    text,
                    scheme,
                    label: 'First appears · ${_chapterLabel(person.firstSeen.chapter)}',
                  ),
                const SizedBox(height: Space.xs),
                ..._answer(_answers['who:$name'], text, scheme, empty: '“$name” doesn’t come up in the book up to here.'),
              ],
            ),
          ),
        const Divider(height: 1),
      ],
    ];
  }

  /// Chapter by chapter up to the reader's: who's in each, who first comes in, and what
  /// happens (its summary, when there is one).
  List<Widget> _timelineTab(BookData data, TextTheme text, ColorScheme scheme) {
    final muted = scheme.onSurfaceVariant;
    if (data.chapters.isEmpty) {
      return [Text('Nothing kept of the book yet.', style: text.bodyMedium?.copyWith(color: muted))];
    }
    final now = data.current?.number;
    final withText = data.book.chapters.toSet();
    return [
      for (final c in data.chapters)
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 24,
                child: Column(
                  children: [
                    const SizedBox(height: 6),
                    Icon(
                      c.number == now ? Icons.radio_button_checked : Icons.circle,
                      size: c.number == now ? 14 : 8,
                      color: c.number == now ? scheme.primary : scheme.outline,
                    ),
                    if (c.number != now) Expanded(child: VerticalDivider(width: 2, thickness: 2, color: scheme.outlineVariant)),
                  ],
                ),
              ),
              const SizedBox(width: Space.sm),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: Space.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        c.number == now ? 'Now · ${_chapterLabel(c.number)}' : _chapterLabel(c.number),
                        style: text.titleSmall?.copyWith(color: c.number == now ? scheme.primary : null),
                      ),
                      if (!withText.contains(c.number))
                        Text('Catching up on this chapter…', style: text.bodySmall?.copyWith(color: muted))
                      else ...[
                        if (chapterCast(data.people, c.number) case final cast when cast.isNotEmpty)
                          Text('With ${cast.join(', ')}', style: text.bodyMedium),
                        if (firstAppearances(data.people, c.number) case final first when first.isNotEmpty)
                          Text('First appearance: ${first.join(', ')}', style: text.bodySmall?.copyWith(color: muted)),
                        if (_summaries[c.number] case final summary? when summary.isNotEmpty && c.number != now)
                          Padding(
                            padding: const EdgeInsets.only(top: Space.xs),
                            child: Text(summary, style: text.bodySmall?.copyWith(fontFamily: FontFamilies.reading)),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
    ];
  }

  Widget _personTile(String name, Person? person, TextTheme text, ColorScheme scheme) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(name, style: text.bodyLarge),
    subtitle: person == null ? null : Text('${person.mentions} mentions', style: text.bodySmall),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (person != null) _ChapterStrip(person.byChapter, color: scheme.primary, empty: scheme.outlineVariant),
        const SizedBox(width: Space.sm),
        Icon(_open == name ? Icons.expand_less : Icons.expand_more),
      ],
    ),
    onTap: () => _togglePerson(name),
  );

  List<Widget> _modelCards(GemmaState gemma, {required TextTheme text, required ColorScheme scheme}) => [
    if (_status == NanoStatus.downloadable || _status == NanoStatus.downloading) ...[
      const SizedBox(height: Space.lg),
      Card.outlined(
        child: Padding(
          padding: const EdgeInsets.all(Space.md),
          child: Row(
            children: [
              const Icon(Icons.auto_awesome_outlined),
              const SizedBox(width: Space.md),
              Expanded(
                child: Text(
                  'This phone can answer in its own words with Gemini Nano: free, and nothing leaves the phone.',
                  style: text.bodySmall,
                ),
              ),
              const SizedBox(width: Space.sm),
              _status == NanoStatus.downloading
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : FilledButton.tonal(onPressed: _getNano, child: const Text('Get it')),
            ],
          ),
        ),
      ),
    ],
    if (_nanoError case final error?)
      Padding(
        padding: const EdgeInsets.only(top: Space.sm),
        child: Text(error, style: text.bodySmall?.copyWith(color: scheme.error)),
      ),
    if (_status == NanoStatus.unavailable && !gemma.installed) ...[
      const SizedBox(height: Space.lg),
      Card.outlined(
        child: Padding(
          padding: const EdgeInsets.all(Space.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.auto_awesome_outlined),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: Text(
                      gemma.busy
                          ? 'Downloading ${gemma.downloading!.label}… ${((gemma.progress ?? 0) * 100).round()}%'
                          : 'Get a written recap, answers and who’s who with Gemma, a model that runs on this '
                                'phone: free, and nothing leaves the phone.',
                      style: text.bodySmall,
                    ),
                  ),
                  const SizedBox(width: Space.sm),
                  gemma.busy
                      ? TextButton(onPressed: ref.read(gemmaProvider.notifier).cancel, child: const Text('Cancel'))
                      : FilledButton.tonal(onPressed: _getGemma, child: const Text('Get it')),
                ],
              ),
              if (gemma.busy) ...[
                const SizedBox(height: Space.sm),
                LinearProgressIndicator(value: gemma.progress, minHeight: 3),
              ],
              if (gemma.error case final error?) ...[
                const SizedBox(height: Space.sm),
                Text(error, style: text.bodySmall?.copyWith(color: scheme.error)),
              ],
            ],
          ),
        ),
      ),
    ],
  ];
}

/// Where someone comes up, chapter by chapter: a bar for each, as tall as how often.
class _ChapterStrip extends StatelessWidget {
  const _ChapterStrip(this.counts, {required this.color, required this.empty});

  final List<int> counts;
  final Color color;
  final Color empty;

  @override
  Widget build(BuildContext context) {
    final most = counts.fold(1, math.max);
    final width = math.min(4.0, 72 / math.max(1, counts.length));
    return SizedBox(
      height: 20,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final n in counts)
            Container(
              width: width,
              height: n == 0 ? 2 : 4 + 16 * n / most,
              margin: const EdgeInsets.only(right: 1),
              color: n == 0 ? empty : color,
            ),
        ],
      ),
    );
  }
}

/// No model on this phone yet: the conversation only finds passages.
class _NoModel implements CompanionModel {
  const _NoModel();

  @override
  bool get remembers => false;

  @override
  int get freshChars => 3000;

  @override
  int get followUpChars => 3000;

  @override
  Stream<String> write(String prompt, {required bool fresh, required int maxTokens}) =>
      Stream.error(const ModelFailed('No model yet.'));

  @override
  Future<String?> once(String prompt, {required int maxTokens}) async => null;

  @override
  Future<void> cancel() async {}
}
