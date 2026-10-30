import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/local_store.dart';
import '../theme/reader_theme.dart';
import '../theme/tokens.dart';
import 'image_export.dart';

/// A run of a paragraph's text, selected or not.
typedef PageRun = ({String text, bool selected});

/// A passage as it sits on the page: whole paragraphs around a selection.
class PageExcerpt {
  const PageExcerpt(this.paragraphs);

  /// The page around a selection, as the reader read it when Share was picked: `{p: [[[text,
  /// selected], …], …]}` (see `SHARE_CONTEXT_SCRIPT` in ReaderPlatformView.kt). Null if there's
  /// nothing selected in it.
  static PageExcerpt? fromJson(String? json) {
    if (json == null) return null;
    try {
      final paragraphs = [
        for (final p in (jsonDecode(json) as Map)['p'] as List)
          [
            for (final run in p as List)
              (text: (run as List)[0] as String, selected: run[1] == 1 || run[1] == true),
          ],
      ];
      final excerpt = PageExcerpt(paragraphs);
      return excerpt.selectedLength == 0 ? null : excerpt;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  /// A highlight with the bit of text kept on either side of it, in one paragraph.
  factory PageExcerpt.around(String? before, String selected, String? after) {
    String clean(String? s) => (s ?? '').replaceAll(RegExp(r'\s+'), ' ');
    return PageExcerpt([
      [
        if (clean(before).trimLeft() case final b when b.isNotEmpty) (text: b, selected: false),
        (text: clean(selected).trim(), selected: true),
        if (clean(after).trimRight() case final a when a.isNotEmpty) (text: a, selected: false),
      ],
    ]);
  }

  final List<List<PageRun>> paragraphs;

  int get selectedLength => paragraphs.expand((p) => p).where((r) => r.selected).fold(0, (n, r) => n + r.text.length);
}

/// How the selected lines stand out from the faded page.
enum PageMark {
  marker('Marker'),
  underline('Underline'),
  plain('Fade only');

  const PageMark(this.label);

  final String label;
}

/// How faint the rest of the page is.
enum PageFade {
  soft('Soft', 0.45),
  medium('Medium', 0.3),
  strong('Strong', 0.16);

  const PageFade(this.label, this.opacity);

  final String label;
  final double opacity;
}

/// What goes on a page card.
class PageCardContent {
  const PageCardContent({
    required this.excerpt,
    required this.title,
    this.author,
    this.coverColor,
    this.coverPath,
  });

  final PageExcerpt excerpt;
  final String title;
  final String? author;

  /// The book's tint (from its cover): the mark's color, and the Cover page's.
  final Color? coverColor;

  /// The cover image on this device, for the book line.
  final String? coverPath;

  Color get tint => coverColor ?? Palette.oxblood;
}

/// The mark's colors on [page] for a book tinted [tint]: the marker's fill, as much of the tint
/// as leaves the ink on it easy to read (4.5:1), and the underline, the tint darkened or lifted
/// until it shows on the page (3:1).
({Color fill, Color line}) markColors(PageColors page, Color tint) {
  final dark = page.brightness == Brightness.dark;
  var amount = dark ? 0.6 : 0.38;
  var fill = Color.lerp(page.page, tint, amount)!;
  while (_contrast(page.ink, fill) < 4.5 && amount > 0.05) {
    amount -= 0.03;
    fill = Color.lerp(page.page, tint, amount)!;
  }
  var line = tint;
  for (var lift = 0.05; _contrast(line, page.page) < 3 && lift <= 1; lift += 0.05) {
    line = Color.lerp(tint, dark ? Colors.white : Colors.black, lift)!;
  }
  return (fill: fill, line: line);
}

double _contrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

/// Share a passage as an image of its page (1080 × 1920): the selected lines marked, the rest
/// faded, in [reading] (the page colors the book is read in). Mark and fade are remembered.
Future<void> showPageShareSheet(BuildContext context, PageCardContent content, {required PageColors reading}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _PageShareSheet(content: content, reading: reading),
  );
}

class _PageShareSheet extends ConsumerStatefulWidget {
  const _PageShareSheet({required this.content, required this.reading});

  final PageCardContent content;
  final PageColors reading;

  @override
  ConsumerState<_PageShareSheet> createState() => _PageShareSheetState();
}

class _PageShareSheetState extends ConsumerState<_PageShareSheet> {
  static const _markKey = 'share.page.mark';
  static const _fadeKey = 'share.page.fade';

  final _card = GlobalKey();
  late final LocalStore _store = ref.read(localStoreProvider);
  late PageMark _mark = PageMark.values.where((m) => m.name == _store.readJson(_markKey)).firstOrNull ?? PageMark.marker;
  late PageFade _fade = PageFade.values.where((f) => f.name == _store.readJson(_fadeKey)).firstOrNull ?? PageFade.medium;
  late final List<PageColors> _pages = _pageChoices();
  late PageColors _page = _pages.firstWhere((p) => p.label == widget.reading.label, orElse: () => _pages.first);
  Future<void>? _coverLoaded;

  /// The four page presets and the cover-tinted page (by night if that's how it's read), and
  /// the reader's own colors when that's what the book is read in.
  List<PageColors> _pageChoices() {
    final reading = widget.reading;
    final coverBrightness = reading.label == 'Cover' ? reading.brightness : Brightness.light;
    return [
      for (final theme in ReaderTheme.values) ?theme.preset,
      PageColors.tinted(widget.content.tint, coverBrightness),
      if (reading.label == 'Custom') reading,
    ];
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The cover has to be decoded before the card is rendered, or it comes out blank.
    if (widget.content.coverPath case final path?) {
      _coverLoaded ??= precacheImage(FileImage(File(path)), context, onError: (_, _) {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final height = MediaQuery.sizeOf(context).height;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Share this passage', style: text.headlineSmall),
            const SizedBox(height: Space.md),
            SizedBox(
              height: math.min(height * 0.45, 400),
              child: FittedBox(
                child: RepaintBoundary(
                  key: _card,
                  child: PageCard(content: widget.content, page: _page, mark: _mark, fade: _fade),
                ),
              ),
            ),
            const SizedBox(height: Space.md),
            _ChipRow(
              label: 'Mark',
              children: [
                for (final m in PageMark.values)
                  _chip(m.label, selected: m == _mark, onSelected: () {
                    setState(() => _mark = m);
                    _store.writeJson(_markKey, m.name);
                  }),
              ],
            ),
            _ChipRow(
              label: 'Page',
              children: [
                for (final p in _pages)
                  _chip(
                    p.label,
                    selected: p == _page,
                    swatch: p.page,
                    onSelected: () => setState(() => _page = p),
                  ),
              ],
            ),
            _ChipRow(
              label: 'Fade',
              children: [
                for (final f in PageFade.values)
                  _chip(f.label, selected: f == _fade, onSelected: () {
                    setState(() => _fade = f);
                    _store.writeJson(_fadeKey, f.name);
                  }),
              ],
            ),
            const SizedBox(height: Space.md),
            ImageCardActions(card: _card, fileName: 'marginalia-page.png', beforeRender: () async => _coverLoaded),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, {required bool selected, required VoidCallback onSelected, Color? swatch}) {
    final scheme = Theme.of(context).colorScheme;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      showCheckmark: false,
      avatar: swatch == null
          ? null
          : Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                color: swatch,
                borderRadius: BorderRadius.circular(Radii.sm),
                border: Border.all(color: scheme.outline.withValues(alpha: 0.5)),
              ),
            ),
      onSelected: (_) => onSelected(),
    );
  }
}

/// A labelled row of chips that scrolls sideways when it doesn't fit.
class _ChipRow extends StatelessWidget {
  const _ChipRow({required this.label, required this.children});

  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.xxs),
      child: Row(
        children: [
          SizedBox(
            width: 52,
            child: Text(label, style: text.labelMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final (i, chip) in children.indexed) ...[
                    if (i > 0) const SizedBox(width: Space.sm - 2),
                    chip,
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The card, laid out at 360 × 640 (a 9:16 story; saved at 3×): the wordmark at the top left,
/// the book's cover, title and author, then the page itself, cut off above and below like a
/// crop of the book, centred on the selected lines.
class PageCard extends StatelessWidget {
  const PageCard({super.key, required this.content, required this.page, required this.mark, required this.fade});

  final PageCardContent content;
  final PageColors page;
  final PageMark mark;
  final PageFade fade;

  @override
  Widget build(BuildContext context) {
    final rule = page.ink.withValues(alpha: 0.14);
    return SizedBox(
      width: 360,
      height: 640,
      child: Material(
        color: page.page,
        child: Stack(
          children: [
            Positioned(
              left: 30,
              top: 26,
              child: Text(
                'marginalia',
                style: TextStyle(
                  fontFamily: FontFamilies.display,
                  fontStyle: FontStyle.italic,
                  fontSize: 13,
                  color: page.muted,
                ),
              ),
            ),
            Positioned(
              left: 30,
              right: 30,
              top: 62,
              child: Container(
                padding: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: rule))),
                child: _BookLine(content: content, page: page),
              ),
            ),
            Positioned(
              left: 30,
              right: 30,
              top: 140,
              bottom: 56,
              child: CustomPaint(
                painter: _PagePainter(
                  excerpt: content.excerpt,
                  page: page,
                  mark: mark,
                  fade: fade.opacity,
                  colors: markColors(page, content.tint),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BookLine extends StatelessWidget {
  const _BookLine({required this.content, required this.page});

  final PageCardContent content;
  final PageColors page;

  @override
  Widget build(BuildContext context) {
    final placeholder = ColoredBox(color: content.tint);
    return Row(
      children: [
        Container(
          width: 30,
          height: 45,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(2),
            boxShadow: const [BoxShadow(color: Color(0x4D000000), blurRadius: 8, offset: Offset(0, 3))],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: switch (content.coverPath) {
              final path? => Image.file(File(path), fit: BoxFit.cover, errorBuilder: (_, _, _) => placeholder),
              null => placeholder,
            },
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                content.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: FontFamilies.display,
                  fontWeight: FontWeight.w500,
                  fontSize: 14,
                  height: 1.2,
                  color: page.ink,
                ),
              ),
              if (content.author case final author? when author.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontFamily: FontFamilies.ui, fontSize: 11, color: page.muted),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The page's text, justified, its paragraphs indented, the unselected text faded and the
/// selection marked; moved so the selection sits in the middle, and cut off at the edges.
class _PagePainter extends CustomPainter {
  _PagePainter({
    required this.excerpt,
    required this.page,
    required this.mark,
    required this.fade,
    required this.colors,
  });

  final PageExcerpt excerpt;
  final PageColors page;
  final PageMark mark;
  final double fade;
  final ({Color fill, Color line}) colors;

  @override
  void paint(Canvas canvas, Size size) {
    // Long selections get smaller type, so more of them fits.
    final length = excerpt.selectedLength;
    final fontSize = length < 520 ? 14.5 : length < 900 ? 13.0 : 12.0;
    final base = TextStyle(fontFamily: FontFamilies.reading, fontSize: fontSize, height: 1.62, color: page.ink);
    final faded = base.copyWith(color: page.ink.withValues(alpha: fade));
    final selected = mark == PageMark.underline
        ? base.copyWith(
            decoration: TextDecoration.underline,
            decorationColor: colors.line,
            decorationThickness: 1.8,
          )
        : base;

    final spans = <TextSpan>[];
    var at = 0;
    // The selected text's ranges: each run's words, without its spaces at either end or the
    // paragraph's indent, so the marker hugs the words.
    final ranges = <TextSelection>[];
    void add(String text, TextStyle style, {bool isSelected = false}) {
      if (isSelected) {
        final lead = text.length - text.trimLeft().length;
        final words = text.trim().length;
        if (words > 0) ranges.add(TextSelection(baseOffset: at + lead, extentOffset: at + lead + words));
      }
      spans.add(TextSpan(text: text, style: style));
      at += text.length;
    }

    for (final (i, paragraph) in excerpt.paragraphs.indexed) {
      if (i > 0) {
        add('\n', faded);
        // The first line indented, as in a book (no-break spaces: the reading fonts all have them).
        add(' ' * 5, faded);
      }
      for (final run in paragraph) {
        add(run.text, run.selected ? selected : faded, isSelected: run.selected);
      }
    }

    final painter = TextPainter(
      text: TextSpan(children: spans),
      textAlign: TextAlign.justify,
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    )..layout(maxWidth: size.width);

    // A box per line of selected text, from its first word to its last: measured word by word
    // and joined, so the spaces at a line's end (stretched, in justified text) aren't marked.
    final text = painter.plainText;
    final lines = <double, Rect>{};
    for (final range in ranges) {
      for (final word in RegExp(r'\S+').allMatches(text.substring(range.start, range.end))) {
        final selection = TextSelection(baseOffset: range.start + word.start, extentOffset: range.start + word.end);
        for (final box in painter.getBoxesForSelection(selection, boxHeightStyle: ui.BoxHeightStyle.tight)) {
          final rect = box.toRect();
          final line = lines.keys.where((top) => (top - rect.top).abs() < 2).firstOrNull ?? rect.top;
          lines[line] = lines[line]?.expandToInclude(rect) ?? rect;
        }
      }
    }
    final boxes = lines.values.toList()..sort((a, b) => a.top.compareTo(b.top));
    final middle = boxes.isEmpty ? painter.height / 2 : (boxes.first.top + boxes.last.bottom) / 2;
    final dy = size.height / 2 - middle;

    canvas
      ..save()
      ..clipRect(Offset.zero & size)
      ..translate(0, dy);
    if (mark == PageMark.marker) {
      final paint = Paint()..color = colors.fill;
      for (final box in boxes) {
        if (box.right - box.left < 1) continue;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(box.left - 2, box.top - 1, box.right + 2, box.bottom + 1),
            const Radius.circular(2),
          ),
          paint,
        );
      }
    }
    painter.paint(canvas, Offset.zero);
    canvas.restore();
    painter.dispose();
  }

  @override
  bool shouldRepaint(_PagePainter old) =>
      old.excerpt != excerpt || old.page != page || old.mark != mark || old.fade != fade || old.colors != colors;
}
