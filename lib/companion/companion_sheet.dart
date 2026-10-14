import 'package:flutter/material.dart';

import '../readium/readium.dart';
import '../theme/tokens.dart';
import 'companion.dart';

/// Asks about the book, from the start up to [locatorJson] and never past it: who someone is
/// ([name] to start with, when a name was selected), or what has happened lately. Gemini Nano
/// writes the answer on phones that have it; the passages it came from are always shown, and
/// are the answer on phones without it.
Future<void> showCompanionSheet(
  BuildContext context, {
  required String publicationId,
  required String locatorJson,
  required String title,
  String? name,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (context) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.65,
    maxChildSize: 0.92,
    builder: (context, scroll) => _CompanionSheet(
      publicationId: publicationId,
      locatorJson: locatorJson,
      title: title,
      name: name,
      scroll: scroll,
    ),
  ),
);

enum _Ask { who, recap }

class _CompanionSheet extends StatefulWidget {
  const _CompanionSheet({
    required this.publicationId,
    required this.locatorJson,
    required this.title,
    required this.name,
    required this.scroll,
  });

  final String publicationId;
  final String locatorJson;
  final String title;
  final String? name;
  final ScrollController scroll;

  @override
  State<_CompanionSheet> createState() => _CompanionSheetState();
}

class _CompanionSheetState extends State<_CompanionSheet> {
  static const _nano = Nano();
  static const _readium = Readium();

  late _Ask _ask = widget.name == null ? _Ask.recap : _Ask.who;
  late final _name = TextEditingController(text: widget.name?.trim());
  NanoStatus? _status;
  List<Paragraph>? _text;

  bool _busy = false;
  String? _written;
  List<String> _passages = const [];
  String? _nothing;

  @override
  void initState() {
    super.initState();
    _nano.status().then((s) => mounted ? setState(() => _status = s) : null);
    _run();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<List<Paragraph>> _bookSoFar() async =>
      _text ??= await _readium.textUpTo(widget.publicationId, widget.locatorJson);

  Future<void> _run() async {
    final name = _name.text.trim();
    if (_ask == _Ask.who && name.isEmpty) return;
    setState(() {
      _busy = true;
      _written = null;
      _passages = const [];
      _nothing = null;
    });
    final text = await _bookSoFar();
    final status = _status ??= await _nano.status();
    String? prompt;
    if (_ask == _Ask.who) {
      final mentions = mentionsOf(name, text);
      if (mentions.none) {
        _nothing = '“$name” doesn’t come up in the book up to here.';
      } else {
        _passages = mentions.all;
        prompt = whoPrompt(name, widget.title, mentions);
      }
    } else {
      _passages = recapSentences(text);
      if (_passages.isEmpty) {
        _nothing = 'There’s not enough read yet for a recap.';
      } else {
        prompt = recapPrompt(widget.title, _passages);
      }
    }
    if (mounted) setState(() {});
    if (prompt != null && status == NanoStatus.available) {
      final written = await _nano.generate(prompt);
      if (mounted) setState(() => _written = written);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _getNano() async {
    setState(() => _status = NanoStatus.downloading);
    final ready = await _nano.download();
    if (!mounted) return;
    setState(() => _status = ready ? NanoStatus.available : NanoStatus.downloadable);
    if (ready) await _run();
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
        Text('Ask about the book', style: text.headlineSmall),
        Text('From the start up to your page, never further.', style: text.bodySmall?.copyWith(color: muted)),
        const SizedBox(height: Space.md),
        SegmentedButton<_Ask>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: _Ask.who, label: Text('Who is…'), icon: Icon(Icons.person_search_outlined)),
            ButtonSegment(value: _Ask.recap, label: Text('Recap so far'), icon: Icon(Icons.history_edu_outlined)),
          ],
          selected: {_ask},
          onSelectionChanged: (s) {
            setState(() => _ask = s.first);
            _run();
          },
        ),
        if (_ask == _Ask.who)
          Padding(
            padding: const EdgeInsets.only(top: Space.md),
            child: TextField(
              controller: _name,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _run(),
              decoration: InputDecoration(
                hintText: 'A name: Dorothea, Mr. Casaubon…',
                suffixIcon: IconButton(icon: const Icon(Icons.arrow_forward), onPressed: _run),
              ),
            ),
          ),
        const SizedBox(height: Space.lg),
        if (_busy && _passages.isEmpty)
          Row(
            children: [
              const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: Space.md),
              Text('Reading up to your page…', style: text.bodyMedium?.copyWith(color: muted)),
            ],
          ),
        if (_nothing case final nothing?) Text(nothing, style: text.bodyLarge),
        if (_written case final written?) ...[
          Text(written, style: text.bodyLarge?.copyWith(height: 1.5)),
          const SizedBox(height: Space.xs),
          Text('Written by Gemini Nano, on this phone', style: text.labelSmall?.copyWith(color: muted)),
          const SizedBox(height: Space.lg),
        ] else if (_busy && _passages.isNotEmpty && _status == NanoStatus.available)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.lg),
            child: Text('Gemini Nano is writing…', style: text.bodyMedium?.copyWith(color: muted)),
          ),
        if (_passages.isNotEmpty) ...[
          Text(_written == null ? 'From the book' : 'Where that comes from', style: text.titleSmall),
          const SizedBox(height: Space.sm),
          for (final p in _passages)
            Container(
              margin: const EdgeInsets.only(bottom: Space.sm),
              padding: const EdgeInsets.only(left: Space.md),
              decoration: BoxDecoration(border: Border(left: BorderSide(color: scheme.outlineVariant, width: 3))),
              child: Text(p, style: text.bodyMedium?.copyWith(fontFamily: FontFamilies.reading, height: 1.45)),
            ),
        ],
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
      ],
    );
  }
}
