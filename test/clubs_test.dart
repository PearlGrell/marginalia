import 'package:flutter_test/flutter_test.dart';
import 'package:marginalia/clubs/clubs.dart';
import 'package:marginalia/clubs/discussion.dart';

void main() {
  test('a club code is read from what was typed or the invitation link', () {
    expect(normalizeClubCode(' abcd efgh jkmn '), 'ABCD-EFGH-JKMN');
    expect(normalizeClubCode('marginalia://app/club/ABCD-EFGH-JKMN'), 'ABCD-EFGH-JKMN');
  });

  test('friends’ highlights are told apart from the reader’s own in the page', () {
    final note = ClubNote(
      club: 'ABCD-EFGH-JKMN',
      id: 'a1b2',
      authorUid: 'u1',
      authorName: 'Celia',
      locator: '{}',
      createdAt: DateTime(2026),
    );
    expect(ClubNote.parseDecorationId(note.decorationId), ('ABCD-EFGH-JKMN', 'a1b2'));
    expect(ClubNote.parseDecorationId('a1b2'), isNull);
  });

  test('each member keeps one color, the same on every phone', () {
    expect(memberColor('uid-celia'), memberColor('uid-celia'));
    final colors = {for (var i = 0; i < 40; i++) memberColor('reader-$i')};
    expect(colors.length, greaterThan(4));
  });

  test('the next milestone is the first not yet reached, late once its date has passed', () {
    final schedule = [
      ClubMilestone(label: 'Part two', fraction: 0.5, due: DateTime(2026, 11, 15)),
      ClubMilestone(label: 'Chapter 5', fraction: 0.2, due: DateTime(2026, 11, 1)),
    ];
    final now = DateTime(2026, 11, 3);
    expect(nextMilestone(schedule, 0.1, now)?.milestone.label, 'Chapter 5');
    expect(nextMilestone(schedule, 0.1, now)?.late, isTrue);
    expect(nextMilestone(schedule, 0.3, now)?.milestone.label, 'Part two');
    expect(nextMilestone(schedule, 0.3, now)?.late, isFalse);
    expect(nextMilestone(schedule, 0.5, now), isNull);
  });

  test('reactions add up, most given first', () {
    expect(reactionSummary({'a': '😂', 'b': '❤️', 'c': '❤️'}), '❤️ 2  😂 1');
    expect(reactionSummary(const {}), '');
  });

  test('discussion questions are asked from what the club has read, and no further', () {
    final prompt = discussionPrompt(
      title: 'Emma',
      story: 'Emma matches Harriet with Mr. Elton.',
      recent: [(chapter: 'chapter 15', summary: 'Mr. Elton proposes to Emma instead.')],
    );
    expect(prompt, contains('Emma matches Harriet'));
    expect(prompt, contains('chapter 15: Mr. Elton proposes'));
    expect(prompt, contains('never mention or hint at anything after them'));
    expect(prompt, contains('One question per line'));
  });
}
