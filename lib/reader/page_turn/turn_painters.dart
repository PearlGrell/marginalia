import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

enum TurnStyle {
  curl('Curl'),
  slide('Slide'),
  fade('Fade'),
  none('None');

  const TurnStyle(this.label);

  final String label;
}

/// Where the curl is for a given turn progress. See `shaders/page_curl.frag`.
class CurlGeometry {
  const CurlGeometry({required this.axisPoint, required this.axisDir, required this.radius});

  /// [progress] 0 is the page lying flat, 1 is the page fully turned away to the left.
  /// The lifted corner starts at the right edge at [cornerY] and moves by [tilt] vertically,
  /// which slants the fold.
  static CurlGeometry? at({
    required Size size,
    required double progress,
    required double cornerY,
    double tilt = 0,
  }) {
    final w = size.width;
    final maxRadius = maxRadiusFor(w);
    final corner = Offset(w, cornerY);
    final travel = travelFor(w);
    final finger = Offset(w - progress * travel, cornerY + tilt * progress);

    final delta = corner - finger;
    final distance = delta.distance;
    if (distance < 0.5) return null;

    final dir = delta / distance;
    final radius = math.min(maxRadius, distance / math.pi);
    final axisOffset = (distance - math.pi * radius) / 2;
    return CurlGeometry(
      axisPoint: finger + dir * axisOffset,
      axisDir: dir,
      radius: radius,
    );
  }

  static double maxRadiusFor(double width) => (width * 0.09).clamp(18.0, 60.0);

  /// How far the lifted corner moves from flat (progress 0) to fully turned (progress 1).
  static double travelFor(double width) => 2 * width + math.pi * maxRadiusFor(width);

  final Offset axisPoint;
  final Offset axisDir;
  final double radius;
}

/// Draws [page] curling according to [progress] with the page curl shader.
///
/// Repaints straight from [progress] and [tilt], so an animation frame costs one paint and no
/// widget rebuild.
class CurlPainter extends CustomPainter {
  CurlPainter({
    required this.shader,
    required this.page,
    required this.progress,
    required this.cornerY,
    required this.tilt,
    required this.backColor,
  }) : super(repaint: Listenable.merge([progress, tilt]));

  final ui.FragmentShader shader;
  final ui.Image page;
  final ValueListenable<double> progress;
  final double cornerY;
  final ValueListenable<double> tilt;
  final Color backColor;

  @override
  void paint(Canvas canvas, Size size) {
    final p = progress.value;
    final geometry = CurlGeometry.at(
      size: size,
      progress: p,
      cornerY: cornerY,
      tilt: tilt.value,
    );
    if (geometry == null) {
      paintImageFill(canvas, size, page);
      return;
    }
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, geometry.axisPoint.dx)
      ..setFloat(3, geometry.axisPoint.dy)
      ..setFloat(4, geometry.axisDir.dx)
      ..setFloat(5, geometry.axisDir.dy)
      ..setFloat(6, geometry.radius)
      ..setFloat(7, backColor.r)
      ..setFloat(8, backColor.g)
      ..setFloat(9, backColor.b)
      ..setFloat(10, 1)
      // The shadow fades out as the page leaves the screen.
      ..setFloat(11, 1 - math.pow(p, 6).toDouble())
      ..setImageSampler(0, page);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(CurlPainter old) =>
      old.page != page ||
      old.progress != progress ||
      old.cornerY != cornerY ||
      old.tilt != tilt ||
      old.backColor != backColor;
}

/// Slides [page] off to the left, casting a soft shadow on the page underneath.
class SlidePainter extends CustomPainter {
  SlidePainter({required this.page, required this.progress}) : super(repaint: progress);

  final ui.Image page;
  final ValueListenable<double> progress;

  @override
  void paint(Canvas canvas, Size size) {
    final p = progress.value;
    final dx = -p * size.width;
    final edge = size.width + dx;
    if (edge > 0 && p > 0) {
      final shadow = Rect.fromLTWH(edge, 0, 24, size.height);
      canvas.drawRect(
        shadow,
        Paint()
          ..shader = ui.Gradient.linear(
            shadow.centerLeft,
            shadow.centerRight,
            [const Color(0x33000000), const Color(0x00000000)],
          ),
      );
    }
    canvas.save();
    canvas.translate(dx, 0);
    paintImageFill(canvas, size, page);
    canvas.restore();
  }

  @override
  bool shouldRepaint(SlidePainter old) => old.page != page || old.progress != progress;
}

/// Fades [page] out.
class FadePainter extends CustomPainter {
  FadePainter({required this.page, required this.progress}) : super(repaint: progress);

  final ui.Image page;
  final ValueListenable<double> progress;

  @override
  void paint(Canvas canvas, Size size) {
    paintImageFill(canvas, size, page, opacity: 1 - progress.value);
  }

  @override
  bool shouldRepaint(FadePainter old) => old.page != page || old.progress != progress;
}

/// Draws a page snapshot (in physical pixels) over the whole logical [size].
void paintImageFill(Canvas canvas, Size size, ui.Image image, {double opacity = 1}) {
  canvas.drawImageRect(
    image,
    Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    Offset.zero & size,
    Paint()
      ..filterQuality = FilterQuality.medium
      ..color = Color.fromRGBO(0, 0, 0, opacity.clamp(0.0, 1.0)),
  );
}
