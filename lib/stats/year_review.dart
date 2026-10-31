import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/library.dart';
import '../share/image_export.dart';
import '../theme/tokens.dart';
import 'reading_stats.dart';
import 'recap_card.dart' show RecapStyle;

/// A year of reading, summed up: time and pages, books finished, the best month, the author
/// read most, the longest streak, highlights made, words saved, and one highlight to remember
/// it by.
class YearReview {
  const YearReview({
    required this.year,
    required this.stats,
    required this.bestMonth,
    required this.bestMonthSeconds,
    required this.topAuthor,
    required this.yearStreak,
    required this.highlights,
    required this.words,
    required this.quote,
    required this.quoteBook,
  });

  /// [year]'s review from everything kept (sessions, books, notes, words).
  factory YearReview.of({
    required int year,
    required List<ReadingSession> sessions,
    required List<Book> books,
    required List<Annotation> annotations,
    required List<VocabularyWord> words,
    required DateTime now,
  }) {
    final period = StatsPeriod.year(DateTime(year));
    final stats = ReadingStats.of(sessions, books, period, now: now);
    final byId = {for (final b in books) b.id: b};

    final perMonth = List.filled(12, 0);
    for (final MapEntry(key: day, value: seconds) in stats.perDay.entries) {
      perMonth[day.month - 1] += seconds;
    }
    var best = -1;
    for (var m = 0; m < 12; m++) {
      if (perMonth[m] > 0 && (best < 0 || perMonth[m] > perMonth[best])) best = m;
    }

    final perAuthor = <String, int>{};
    for (final MapEntry(key: id, value: seconds) in stats.perBook.entries) {
      final author = byId[id]?.authors.firstOrNull?.trim();
      if (author == null || author.isEmpty) continue;
      perAuthor[author] = (perAuthor[author] ?? 0) + seconds;
    }
    final topAuthor = perAuthor.isEmpty
        ? null
        : (perAuthor.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;

    final made = [
      for (final a in annotations)
        if (!a.deleted && a.type != AnnotationType.bookmark && period.contains(a.createdAt)) a,
    ];
    final quote = pickQuote(made);

    return YearReview(
      year: year,
      stats: stats,
      bestMonth: best < 0 ? null : _months[best],
      bestMonthSeconds: best < 0 ? 0 : perMonth[best],
      topAuthor: topAuthor,
      yearStreak: longestRun(stats.perDay.entries.where((e) => e.value >= ReadingStats.streakMinimum).map((e) => e.key)),
      highlights: made.length,
      words: words.where((w) => !w.deleted && period.contains(w.createdAt)).length,
      quote: quote?.selectedText?.trim(),
      quoteBook: quote == null ? null : byId[quote.bookId]?.title,
    );
  }

  final int year;
  final ReadingStats stats;
  final String? bestMonth;
  final int bestMonthSeconds;
  final String? topAuthor;

  /// The most days in a row read within the year.
  final int yearStreak;
  final int highlights;
  final int words;
  final String? quote;
  final String? quoteBook;

  bool get isEmpty => stats.seconds == 0 && stats.finished.isEmpty && highlights == 0;

  /// The highlight to show: one with a note of the reader's own (they cared enough to write),
  /// else the longest that fits on the card; never a fragment of a few words.
  static Annotation? pickQuote(List<Annotation> made) {
    bool fits(Annotation a) {
      final t = a.selectedText?.trim() ?? '';
      return t.length >= 40 && t.length <= 220;
    }

    final candidates = made.where(fits).toList();
    if (candidates.isEmpty) return null;
    final noted = candidates.where((a) => (a.note ?? '').trim().isNotEmpty).toList();
    final pool = noted.isNotEmpty ? noted : candidates;
    pool.sort((a, b) => b.selectedText!.trim().length.compareTo(a.selectedText!.trim().length));
    return pool.first;
  }

  /// The longest run of consecutive days among [days] (midnights).
  static int longestRun(Iterable<DateTime> days) {
    final sorted = days.map((d) => DateTime.utc(d.year, d.month, d.day)).toSet().toList()..sort();
    var best = 0;
    var run = 0;
    DateTime? previous;
    for (final d in sorted) {
      run = previous != null && d.difference(previous).inDays == 1 ? run + 1 : 1;
      if (run > best) best = run;
      previous = d;
    }
    return best;
  }

  static const _months = [
    'January', 'February', 'March', 'April', 'May', 'June', //
    'July', 'August', 'September', 'October', 'November', 'December',
  ];
}

/// The year in review, as a card to save or share.
Future<void> showYearReviewSheet(BuildContext context, {required int year, required List<ReadingSession> sessions}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _YearReviewSheet(year: year, sessions: sessions),
    );

class _YearReviewSheet extends ConsumerStatefulWidget {
  const _YearReviewSheet({required this.year, required this.sessions});

  final int year;
  final List<ReadingSession> sessions;

  @override
  ConsumerState<_YearReviewSheet> createState() => _YearReviewSheetState();
}

class _YearReviewSheetState extends ConsumerState<_YearReviewSheet> {
  final _card = GlobalKey();
  RecapStyle _style = RecapStyle.paper;
  late final Future<YearReview> _review = _load();

  Future<YearReview> _load() async {
    final db = ref.read(databaseProvider);
    final (books, annotations, words) = await (db.allBooks(), db.allAnnotations(), db.allWords()).wait;
    return YearReview.of(
      year: widget.year,
      sessions: widget.sessions,
      books: books,
      annotations: annotations,
      words: words,
      now: DateTime.now(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.lg),
        child: FutureBuilder<YearReview>(
          future: _review,
          builder: (context, snapshot) {
            final review = snapshot.data;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('${widget.year} in review', style: text.headlineSmall),
                const SizedBox(height: Space.md),
                SizedBox(
                  height: MediaQuery.sizeOf(context).height * 0.5,
                  child: review == null
                      ? const Center(child: CircularProgressIndicator())
                      : FittedBox(
                          child: RepaintBoundary(
                            key: _card,
                            child: YearReviewCard(review: review, style: _style),
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
                if (review != null) ImageCardActions(card: _card, fileName: 'marginalia-${widget.year}.png'),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The year in review, laid out at 360 × 640 like the recap, with Instagram's top and bottom
/// bands kept clear.
class YearReviewCard extends StatelessWidget {
  const YearReviewCard({super.key, required this.review, required this.style});

  final YearReview review;
  final RecapStyle style;

  @override
  Widget build(BuildContext context) {
    final (background, ink, muted, accent) = switch (style) {
      RecapStyle.paper => (Palette.paper, Palette.ink, Palette.inkMuted, Palette.oxblood),
      RecapStyle.ink => (Palette.charcoal, Palette.chalk, Palette.chalkMuted, Palette.oxbloodLight),
    };
    final stats = review.stats;
    final hours = stats.seconds / 3600;

    Widget figure(String value, String label) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: TextStyle(fontFamily: FontFamilies.display, fontSize: 24, height: 1.1, color: ink)),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(fontFamily: FontFamilies.ui, fontSize: 10.5, color: muted)),
        ],
      ),
    );

    Widget line(String label, String value) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: '$label  ', style: TextStyle(fontFamily: FontFamilies.ui, fontSize: 11, color: muted)),
            TextSpan(text: value, style: TextStyle(fontFamily: FontFamilies.display, fontSize: 14, color: ink)),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
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
                'MY YEAR IN BOOKS',
                style: TextStyle(fontFamily: FontFamilies.ui, fontSize: 11, letterSpacing: 2, color: accent, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text('${review.year}', style: TextStyle(fontFamily: FontFamilies.display, fontSize: 44, height: 1, color: ink)),
              const SizedBox(height: 14),
              Row(
                children: [
                  figure(hours >= 10 ? '${hours.round()}' : hours.toStringAsFixed(1), 'hours read'),
                  figure('${stats.finished.length}', stats.finished.length == 1 ? 'book finished' : 'books finished'),
                  figure('${stats.pages}', 'pages'),
                ],
              ),
              const SizedBox(height: 16),
              if (review.bestMonth case final month?) line('Best month', '$month · ${formatDuration(review.bestMonthSeconds)}'),
              if (review.topAuthor case final author?) line('Most read', author),
              if (review.yearStreak > 1) line('Longest streak', '${review.yearStreak} days'),
              if (review.highlights > 0 || review.words > 0)
                line(
                  'Kept',
                  [
                    if (review.highlights > 0) '${review.highlights} ${review.highlights == 1 ? 'highlight' : 'highlights'}',
                    if (review.words > 0) '${review.words} ${review.words == 1 ? 'word' : 'words'}',
                  ].join(' · '),
                ),
              const Spacer(),
              if (review.quote case final quote?) ...[
                Container(
                  padding: const EdgeInsets.only(left: 12),
                  decoration: BoxDecoration(border: Border(left: BorderSide(color: accent, width: 2))),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '“$quote”',
                        maxLines: 6,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontFamily: FontFamilies.reading, fontSize: 13.5, height: 1.4, color: ink),
                      ),
                      if (review.quoteBook case final book?) ...[
                        const SizedBox(height: 4),
                        Text(
                          book,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontFamily: FontFamilies.ui, fontSize: 10.5, color: muted),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 14),
              ],
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
