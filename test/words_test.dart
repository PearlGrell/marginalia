import 'package:flutter_test/flutter_test.dart';
import 'package:marginalia/words/review.dart';

void main() {
  final now = DateTime(2026, 10, 3, 9);

  group('scheduleReview', () {
    test('a new word: good is tomorrow, easy is in four days, again is in ten minutes', () {
      final fresh = ReviewState(dueAt: now);
      expect(scheduleReview(fresh, ReviewGrade.good, now).dueAt, now.add(const Duration(days: 1)));
      expect(scheduleReview(fresh, ReviewGrade.easy, now).dueAt, now.add(const Duration(days: 4)));
      expect(scheduleReview(fresh, ReviewGrade.again, now).dueAt, now.add(const Duration(minutes: 10)));
    });

    test('remembered words come back after longer and longer gaps', () {
      var s = ReviewState(dueAt: now);
      final gaps = <double>[];
      for (var i = 0; i < 5; i++) {
        s = scheduleReview(s, ReviewGrade.good, now);
        gaps.add(s.intervalDays);
      }
      expect(gaps.take(2), [1.0, 3.0]);
      for (var i = 1; i < gaps.length; i++) {
        expect(gaps[i], greaterThan(gaps[i - 1]));
      }
      expect(s.reps, 5);
    });

    test('forgetting a learned word resets it and lowers its ease, never below 1.3', () {
      var s = ReviewState(intervalDays: 20, ease: 1.35, reps: 4, dueAt: _epoch);
      s = scheduleReview(s, ReviewGrade.again, now);
      expect(s.reps, 0);
      expect(s.lapses, 1);
      expect(s.ease, 1.3);
      expect(s.intervalDays, 0);
    });
  });

  test('gaps read naturally', () {
    expect(reviewGap(ReviewState(dueAt: now.add(const Duration(minutes: 10))), now), '10 min');
    expect(reviewGap(ReviewState(dueAt: now.add(const Duration(days: 3))), now), '3 d');
    expect(reviewGap(ReviewState(dueAt: now.add(const Duration(days: 90))), now), '3 mo');
  });

  test('the sentence around a word', () {
    expect(
      contextSentence('It rained all day. The garden looked ', 'lugubrious', ' in the grey light. Then the sun came.'),
      'The garden looked lugubrious in the grey light.',
    );
    expect(contextSentence(null, 'word', null), 'word');
    expect(contextSentence('“Stop!” she said. He was ', 'obdurate', ''), 'He was obdurate');
  });
}

final _epoch = DateTime(2026);
