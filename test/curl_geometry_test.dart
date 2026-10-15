import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:marginalia/reader/page_turn/turn_painters.dart';

void main() {
  const size = Size(400, 800);

  test('a page that has not started turning has no curl', () {
    expect(CurlGeometry.at(size: size, progress: 0, cornerY: 800), isNull);
  });

  test('a fully turned page is entirely off screen', () {
    final g = CurlGeometry.at(size: size, progress: 1, cornerY: 400)!;
    // Every point of the page lies past the fold, clear of its shading, so the shader draws
    // nothing of it.
    for (final corner in const [Offset(0, 0), Offset(0, 800), Offset(400, 0), Offset(400, 800)]) {
      final x = (corner - g.axisPoint).dx * g.axisDir.dx + (corner - g.axisPoint).dy * g.axisDir.dy;
      expect(x, greaterThan(g.radius));
    }
  });

  test('halfway through a straight turn the fold is near the middle', () {
    final g = CurlGeometry.at(size: size, progress: 0.5, cornerY: 400)!;
    expect(g.axisDir.dx, closeTo(1, 1e-9));
    expect(g.axisDir.dy, closeTo(0, 1e-9));
    expect(g.axisPoint.dx, inInclusiveRange(100, 250));
  });

  test('the fold softens as the page lifts, up to a limit', () {
    final early = CurlGeometry.at(size: size, progress: 0.02, cornerY: 400)!;
    final later = CurlGeometry.at(size: size, progress: 0.6, cornerY: 400)!;
    expect(early.radius, lessThan(later.radius));
    expect(later.radius, lessThanOrEqualTo(CurlGeometry.maxRadiusFor(400)));
  });

  test('a page taken by its bottom corner and lifted folds on a slant', () {
    final g = CurlGeometry.at(size: size, progress: 0.3, cornerY: 800, tilt: -200)!;
    expect(g.axisDir.dx, greaterThan(0));
    expect(g.axisDir.dy, greaterThan(0));
  });
}
