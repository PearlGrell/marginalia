import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'image_export.dart';

enum StoryStyle {
  cover('Cover'),
  paper('Paper'),
  ink('Ink');

  const StoryStyle(this.label);

  final String label;
}

/// What goes on a card.
class StoryContent {
  const StoryContent({
    required this.quote,
    required this.title,
    this.author,
    this.note,
    required this.accent,
    this.coverColor,
    this.coverPath,
  });

  final String quote;
  final String title;
  final String? author;
  final String? note;

  /// The highlight's color, for the mark beside the quote.
  final Color accent;

  /// The book's tint, for the Cover style when there's no cover image.
  final Color? coverColor;

  /// The cover image on this device, shown on the card and blurred behind the Cover style.
  final String? coverPath;

  bool get hasCover => coverColor != null || coverPath != null;
}

/// Share a highlight as a story-sized image (1080 × 1920).
Future<void> showStorySheet(BuildContext context, StoryContent content) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _StorySheet(content: content),
  );
}

class _StorySheet extends StatefulWidget {
  const _StorySheet({required this.content});

  final StoryContent content;

  @override
  State<_StorySheet> createState() => _StorySheetState();
}

class _StorySheetState extends State<_StorySheet> {
  final _card = GlobalKey();
  late StoryStyle _style = widget.content.hasCover ? StoryStyle.cover : StoryStyle.paper;
  Future<void>? _coverLoaded;

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
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Share as a story', style: text.headlineSmall),
            const SizedBox(height: Space.md),
            SizedBox(
              height: height * 0.5,
              child: FittedBox(
                child: RepaintBoundary(
                  key: _card,
                  child: StoryCard(content: widget.content, style: _style),
                ),
              ),
            ),
            const SizedBox(height: Space.md),
            SegmentedButton<StoryStyle>(
              showSelectedIcon: false,
              segments: [
                for (final s in StoryStyle.values)
                  if (s != StoryStyle.cover || widget.content.hasCover)
                    ButtonSegment(value: s, label: Text(s.label)),
              ],
              selected: {_style},
              onSelectionChanged: (s) => setState(() => _style = s.first),
            ),
            const SizedBox(height: Space.md),
            ImageCardActions(
              card: _card,
              fileName: 'marginalia-story.png',
              beforeRender: () async => _coverLoaded,
            ),
          ],
        ),
      ),
    );
  }
}

/// The card itself, laid out at 360 × 640 (a 9:16 story).
///
/// Instagram draws its own controls over roughly the top 14% and bottom 18% of a story,
/// so everything that matters sits between those bands.
class StoryCard extends StatelessWidget {
  const StoryCard({super.key, required this.content, required this.style});

  final StoryContent content;
  final StoryStyle style;

  static const _safeTop = 92.0;
  static const _safeBottom = 118.0;

  @override
  Widget build(BuildContext context) {
    final tint = content.coverColor ?? Palette.oxblood;
    final (ink, muted) = switch (style) {
      StoryStyle.paper => (Palette.ink, Palette.inkMuted),
      StoryStyle.ink => (Palette.chalk, Palette.chalkMuted),
      StoryStyle.cover => (const Color(0xFFF7F1E6), const Color(0xFFDCD2C0)),
    };
    // On the dark styles a dark highlight color would disappear; lift it.
    final accent = style == StoryStyle.paper || content.accent.computeLuminance() >= 0.35
        ? content.accent
        : Color.lerp(content.accent, Colors.white, 0.45)!;
    // Long passages get smaller type so they always fit.
    final length = content.quote.length + (content.note?.length ?? 0);
    final quoteSize = length < 140 ? 25.0 : length < 260 ? 20.0 : length < 420 ? 16.5 : 14.0;

    return SizedBox(
      width: 360,
      height: 640,
      child: Material(
        color: switch (style) {
          StoryStyle.paper => Palette.paper,
          StoryStyle.ink => Palette.charcoal,
          StoryStyle.cover => Color.alphaBlend(Colors.black.withValues(alpha: 0.35), tint),
        },
        clipBehavior: Clip.hardEdge,
        child: Stack(
          children: [
            if (style == StoryStyle.cover) ..._coverBackdrop(),
            Padding(
              padding: const EdgeInsets.fromLTRB(32, _safeTop, 32, _safeBottom),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _BookLine(content: content, ink: ink, muted: muted),
                  const SizedBox(height: 22),
                  Text(
                    '“',
                    style: TextStyle(fontFamily: FontFamilies.display, fontSize: 72, height: 0.8, color: accent),
                  ),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Flexible(
                          child: Container(
                            padding: const EdgeInsets.only(left: 14),
                            decoration: BoxDecoration(
                              border: Border(left: BorderSide(color: accent, width: 3)),
                            ),
                            child: Text(
                              content.quote.trim(),
                              overflow: TextOverflow.fade,
                              style: TextStyle(
                                fontFamily: FontFamilies.reading,
                                fontSize: quoteSize,
                                height: 1.45,
                                color: ink,
                              ),
                            ),
                          ),
                        ),
                        if (content.note case final note? when note.trim().isNotEmpty) ...[
                          const SizedBox(height: 18),
                          Text(
                            note.trim(),
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: FontFamilies.ui,
                              fontSize: 13,
                              height: 1.45,
                              fontStyle: FontStyle.italic,
                              color: muted,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The cover, blurred to fill the card and darkened so light text reads on any cover.
  List<Widget> _coverBackdrop() => [
    if (content.coverPath case final path?)
      Positioned.fill(
        child: ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: 28, sigmaY: 28, tileMode: TileMode.mirror),
          child: Transform.scale(
            scale: 1.15,
            child: Image.file(File(path), fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox()),
          ),
        ),
      ),
    Positioned.fill(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withValues(alpha: 0.38),
              Colors.black.withValues(alpha: 0.55),
              Colors.black.withValues(alpha: 0.7),
            ],
          ),
        ),
      ),
    ),
  ];
}

/// The book's cover beside its title and author, at the top of the card.
class _BookLine extends StatelessWidget {
  const _BookLine({required this.content, required this.ink, required this.muted});

  final StoryContent content;
  final Color ink;
  final Color muted;

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      color: content.coverColor ?? Palette.oxblood,
      alignment: Alignment.center,
      child: const Icon(Icons.menu_book_outlined, size: 26, color: Color(0xCCFFFFFF)),
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (content.hasCover) ...[
          Container(
            width: 64,
            height: 96,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              boxShadow: const [BoxShadow(color: Color(0x59000000), blurRadius: 14, offset: Offset(0, 6))],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: switch (content.coverPath) {
                final path? => Image.file(File(path), fit: BoxFit.cover, errorBuilder: (_, _, _) => placeholder),
                null => placeholder,
              },
            ),
          ),
          const SizedBox(width: 16),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                content.title,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontFamily: FontFamilies.display, fontSize: 18, height: 1.2, color: ink),
              ),
              if (content.author case final author? when author.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontFamily: FontFamilies.ui, fontSize: 12.5, color: muted),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
