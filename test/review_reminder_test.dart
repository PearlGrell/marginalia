import 'package:flutter_test/flutter_test.dart';
import 'package:marginalia/data/database.dart';
import 'package:marginalia/words/review_reminder.dart';

VocabularyWord _word(String word) {
  final t = DateTime(2026, 10, 1);
  return VocabularyWord(
    id: word,
    word: word,
    language: 'en',
    createdAt: t,
    dueAt: t,
    intervalDays: 1,
    ease: 2.5,
    reps: 1,
    lapses: 0,
    updatedAt: t,
    deleted: false,
    dirty: false,
  );
}

void main() {
  test('nothing due, nothing said', () {
    expect(ReviewReminder.message(const []), isNull);
  });

  test('one word by name; several by count with a few named', () {
    expect(ReviewReminder.message([_word('limn')]), contains('“limn”'));
    final five = ReviewReminder.message([for (final w in ['a', 'b', 'c', 'd', 'e']) _word(w)])!;
    expect(five, startsWith('5 words'));
    expect(five, contains('a, b, c and 2 more'));
  });

  test('the next check is later today, or tomorrow once the time has passed', () {
    const reminder = ReviewReminder(enabled: true, minuteOfDay: 9 * 60);
    expect(reminder.nextAfter(DateTime(2026, 10, 3, 8)), DateTime(2026, 10, 3, 9));
    expect(reminder.nextAfter(DateTime(2026, 10, 3, 10)), DateTime(2026, 10, 4, 9));
  });
}
