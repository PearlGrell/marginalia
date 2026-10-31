import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:marginalia/companion/retrieval.dart';
import 'package:marginalia/companion/semantic.dart';

Chunk _c(int i) => Chunk(index: i, chapter: 1, text: 'passage $i');

void main() {
  test('a passage high in both rankings comes first', () {
    final fused = fuseRankings([_c(1), _c(2), _c(3)], [_c(3), _c(4), _c(1)], limit: 3);
    expect(fused.map((c) => c.index).take(2).toSet(), {1, 3});
    expect(fused.length, 3);
  });

  test('vectors are compared by the angle between them', () {
    final a = normalized(Float32List.fromList([3, 4]));
    expect(a[0], closeTo(0.6, 1e-6));
    expect(dot(a, normalized(Float32List.fromList([6, 8]))), closeTo(1, 1e-6));
    expect(dot(a, normalized(Float32List.fromList([-4, 3]))), closeTo(0, 1e-6));
  });

  test('passage keys are stable and tell texts apart', () {
    expect(passageKey('Alice'), passageKey('Alice'));
    expect(passageKey('Alice'), isNot(passageKey('alice')));
  });
}
