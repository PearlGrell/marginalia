import 'package:flutter_test/flutter_test.dart';
import 'package:marginalia/share/share_service.dart';

void main() {
  test('share codes are read however they are typed or pasted', () {
    expect(ShareService.normalizeCode('abcd-efgh-jkmn'), 'ABCD-EFGH-JKMN');
    expect(ShareService.normalizeCode(' ABCDEFGHJKMN '), 'ABCD-EFGH-JKMN');
    expect(ShareService.normalizeCode('marginalia://app/share/ABCD-EFGH-JKMN'), 'ABCD-EFGH-JKMN');
  });
}
