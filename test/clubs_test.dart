import 'package:flutter_test/flutter_test.dart';
import 'package:marginalia/clubs/clubs.dart';

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
}
