import 'dart:io';

import 'package:flutter/material.dart';

import '../data/database.dart';
import '../share/image_export.dart';
import '../theme/tokens.dart';
import 'reading_stats.dart';
import 'stats_screen.dart';

enum RecapStyle {
  paper('Paper'),
  ink('Ink');

  const RecapStyle(this.label);

  final String label;
}

/// A story-sized card of a period's reading, to save or share.
Future<void> showRecapSheet(BuildContext context, ReadingStats stats, Map<String, Book> books) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _RecapSheet(stats: stats, books: books),
  );
}

class _RecapSheet extends StatefulWidget {
  const _RecapSheet({required this.stats, required this.books});

  final ReadingStats stats;
  final Map<String, Book> books;

  @override
  State<_RecapSheet> createState() => _RecapSheetState();
}

class _RecapSheetState extends State<_RecapSheet> {
  final _card = GlobalKey();
  RecapStyle _style = RecapStyle.paper;
  Future<void>? _covers;

  List<Book> get _shown => RecapCard.coverBooks(widget.stats, widget.books);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _covers ??= Future.wait([
      for (final b in _shown)
        if (coverExists(b.coverPath)) precacheImage(FileImage(File(b.coverPath!)), context, onError: (_, _) {}),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Your reading recap', style: text.headlineSmall),
            const SizedBox(height: Space.md),
            SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.5,
              child: FittedBox(
                child: RepaintBoundary(
                  key: _card,
                  child: RecapCard(stats: widget.stats, books: widget.books, style: _style, now: DateTime.now()),
                ),
              ),
            ),
            const SizedBox(height: Space.md),
            SegmentedButton<RecapStyle>(
              showSelectedIcon: false,
              segments: [for (final s in RecapStyle.values) ButtonSegment(value: s, label: Text(s.label))],
              selected: {_style},
              onSelectionChanged: (s) => setState(() => _style = s.first),
            ),
            const SizedBox(height: Space.md),
            ImageCardActions(card: _card, fileName: 'marginalia-recap.png', beforeRender: () async => _covers),
          ],
        ),
      ),
    );
  }
}

/// The recap, laid out at 360 × 640 with Instagram's top and bottom bands kept clear.
class RecapCard extends StatelessWidget {
  const RecapCard({super.key, required this.stats, required this.books, required this.style, required this.now});

  final ReadingStats stats;
  final Map<String, Book> books;
  final RecapStyle style;
  final DateTime now;

  /// Finished books first, then the most read, up to five.
  static List<Book> coverBooks(ReadingStats stats, Map<String, Book> books) {
    final ids = <String>{for (final b in stats.finished) b.id, ...stats.topBooks};
    return [for (final id in ids) ?books[id]].take(5).toList();
  }

  @override
  Widget build(BuildContext context) {
    final (background, ink, muted, accent) = switch (style) {
      RecapStyle.paper => (Palette.paper, Palette.ink, Palette.inkMuted, Palette.oxblood),
      RecapStyle.ink => (Palette.charcoal, Palette.chalk, Palette.chalkMuted, Palette.oxbloodLight),
    };
    final covers = coverBooks(stats, books);
    final hours = stats.seconds / 3600;
    final (bigValue, bigUnit) = hours >= 1
        ? (hours >= 10 ? hours.round().toString() : hours.toStringAsFixed(1), hours < 1.05 ? 'hour of reading' : 'hours of reading')
        : ('${(stats.seconds / 60).round()}', 'minutes of reading');

    Widget figure(String value, String label) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: TextStyle(fontFamily: FontFamilies.display, fontSize: 26, height: 1.1, color: ink)),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(fontFamily: FontFamilies.ui, fontSize: 10.5, color: muted)),
        ],
      ),
    );

    return SizedBox(
      width: 360,
      height: 640,
      child: Material(
        color: background,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(32, 92, 32, 118),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'MY READING',
                style: TextStyle(fontFamily: FontFamilies.ui, fontSize: 11, letterSpacing: 2, color: accent, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text(
                stats.period.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontFamily: FontFamilies.display, fontSize: 30, height: 1.1, color: ink),
              ),
              const SizedBox(height: 14),
              Text(bigValue, style: TextStyle(fontFamily: FontFamilies.display, fontSize: 56, height: 1, color: ink)),
              Text(bigUnit, style: TextStyle(fontFamily: FontFamilies.ui, fontSize: 13, color: muted)),
              const SizedBox(height: 12),
              Row(
                children: [
                  figure('${stats.pages}', 'pages'),
                  figure('${stats.finished.length}', stats.finished.length == 1 ? 'book finished' : 'books finished'),
                  figure('${stats.daysRead}', stats.daysRead == 1 ? 'day read' : 'days read'),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 40,
                child: ReadingChart(stats: stats, now: now, color: accent, labelColor: muted, labels: false),
              ),
              const Spacer(),
              if (covers.isNotEmpty) ...[
                SizedBox(
                  height: 84,
                  child: Stack(
                    children: [
                      for (final (i, book) in covers.indexed)
                        Positioned(
                          left: i * 46.0,
                          child: Container(
                            width: 56,
                            height: 84,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(3),
                              boxShadow: const [BoxShadow(color: Color(0x44000000), blurRadius: 10, offset: Offset(0, 4))],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(3),
                              child: coverExists(book.coverPath)
                                  ? Image.file(File(book.coverPath!), fit: BoxFit.cover)
                                  : Container(
                                      color: Color(book.coverColor ?? Palette.oxblood.toARGB32()),
                                      padding: const EdgeInsets.all(6),
                                      alignment: Alignment.bottomLeft,
                                      child: Text(
                                        book.title,
                                        maxLines: 4,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontFamily: FontFamilies.display, fontSize: 9, color: Colors.white),
                                      ),
                                    ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],
              if (stats.bestStreak > 1)
                Text(
                  stats.currentStreak > 1
                      ? 'On a ${stats.currentStreak}-day streak'
                      : 'Longest streak: ${stats.bestStreak} days',
                  style: TextStyle(fontFamily: FontFamilies.ui, fontSize: 12, color: ink),
                ),
              const SizedBox(height: 14),
              Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(5),
                    child: Image.asset('assets/brand/mark-1024.png', width: 18, height: 18),
                  ),
                  const SizedBox(width: 8),
                  Text('Marginalia', style: TextStyle(fontFamily: FontFamilies.display, fontSize: 12.5, color: muted)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
