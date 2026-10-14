import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import 'turn_painters.dart';

/// What the page turner needs from the page view underneath it.
abstract interface class PageSource {
  /// A picture of the page currently on screen.
  Future<ui.Image?> snapshot();

  /// Moves the page view on by one page; false at the end of the book. Completes once the
  /// new page is drawn.
  Future<bool> goForward();

  /// Moves the page view back by one page; false at the start of the book.
  Future<bool> goBackward();
}

enum _Direction { forward, backward }

enum _Phase { idle, preparing, turning, settling }

/// Turns the pages of [child] with a curl, slide or fade drawn by Flutter on top of it.
///
/// [child] (the Readium view) can't animate by itself, so turns work on pictures of pages:
/// - Forward: the picture of the current page curls away while the view moves to the next
///   page underneath.
/// - Backward: the picture of the current page covers the view while it moves back, and the
///   picture of the earlier page curls in over it.
///
/// So that a turn never waits on the view, the current page is pictured while the reader is
/// idle, and the page just turned away is kept as the previous page. Without them (after a
/// jump, or several turns back in a row) the turn takes its pictures first.
///
/// Drags follow the finger. Taps, passed in through [PageTurnerState.tapAt], turn with a fixed
/// animation on the outer thirds and call [onCenterTap] in the middle. Either way the page is
/// taken where the turn began: by its bottom corner near the bottom, its top corner near the
/// top, and by the edge at that height in between.
class PageTurner extends StatefulWidget {
  const PageTurner({
    super.key,
    required this.source,
    required this.pageKey,
    required this.style,
    required this.pageBack,
    required this.child,
    this.rightToLeft = false,
    this.haptics = true,
    this.tapToTurn = true,
    this.enabled = true,
    this.onCenterTap,
    this.onTurned,
  });

  final PageSource? source;

  /// Identifies what [child] shows (position, theme, text size). A change outside a turn
  /// means the cached page pictures are stale.
  final Object? pageKey;
  final TurnStyle style;

  /// Color of the back of the paper.
  final Color pageBack;
  final bool rightToLeft;
  final bool haptics;

  /// Taps on the outer thirds turn pages; when false, every tap calls [onCenterTap].
  final bool tapToTurn;

  /// Off while text is selected: swipes and taps belong to the page then.
  final bool enabled;
  final VoidCallback? onCenterTap;

  /// A page was turned by the reader (a swipe, a tap, a volume key).
  final VoidCallback? onTurned;
  final Widget child;

  @override
  State<PageTurner> createState() => PageTurnerState();
}

class PageTurnerState extends State<PageTurner> with SingleTickerProviderStateMixin {
  static ui.FragmentProgram? _program;
  static Future<ui.FragmentProgram>? _programLoading;

  /// A tap turn: unhurried, easing in and out like a page lifted and laid down.
  static const _tapDuration = Duration(milliseconds: 650);
  static const _tapCurve = Curves.easeInOutCubic;

  /// A released drag carries on at the finger's speed and settles without bouncing.
  static final _spring = SpringDescription.withDampingRatio(mass: 1, stiffness: 70, ratio: 1);

  /// How long the pictures stay after a turn while the view finishes drawing.
  static const _revealDelay = Duration(milliseconds: 180);

  /// Location reports that arrive this soon after a turn belong to that turn.
  static const _turnEcho = Duration(milliseconds: 900);

  ui.FragmentShader? _shader;
  late final AnimationController _progress = AnimationController(vsync: this);
  final _tilt = ValueNotifier<double>(0);

  _Phase _phase = _Phase.idle;
  _Direction _direction = _Direction.forward;

  /// The page that moves.
  ui.Image? _front;

  /// The page shown under a backward turn, covering the view while it moves back.
  ui.Image? _under;

  /// Picture of the page on screen, taken while idle.
  ui.Image? _current;

  /// Picture of the page before it.
  ui.Image? _previous;

  Future<ui.Image?>? _capturing;
  Timer? _captureTimer;
  DateTime _lastTurnEnd = DateTime.fromMillisecondsSinceEpoch(0);

  /// The view's move for this turn; awaited before tidying up.
  Future<bool>? _moved;

  /// Completes once a forward turn has its picture of the new page (or won't get one).
  Future<void>? _underReady;

  double _cornerY = 0;
  Offset _dragTotal = Offset.zero;

  /// One turn per drag, so a drag that hits the end of the book doesn't keep retrying.
  bool _dragTurned = false;

  /// A release that came in while pictures were still being taken.
  double? _pendingReleaseVelocity;

  /// A tap that came in during a turn; it runs when the turn ends.
  _Direction? _queuedTap;

  @override
  void initState() {
    super.initState();
    _loadShader();
    _scheduleCapture();
  }

  Future<void> _loadShader() async {
    try {
      final program = _program ??= await (_programLoading ??= ui.FragmentProgram.fromAsset(
        'shaders/page_curl.frag',
      ));
      if (mounted) setState(() => _shader = program.fragmentShader());
    } catch (e) {
      // Without the shader, curls fall back to slides.
      debugPrint('Page curl shader unavailable: $e');
    }
  }

  @override
  void didUpdateWidget(PageTurner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pageKey != widget.pageKey) {
      final echo = DateTime.now().difference(_lastTurnEnd) < _turnEcho;
      if (_phase == _Phase.idle && !echo) _dropCache();
      _scheduleCapture();
    } else if (oldWidget.source != widget.source) {
      _scheduleCapture();
    }
  }

  @override
  void dispose() {
    _captureTimer?.cancel();
    _progress.dispose();
    _tilt.dispose();
    _shader?.dispose();
    for (final image in {_front, _under, _current, _previous}) {
      image?.dispose();
    }
    super.dispose();
  }

  TurnStyle get _style {
    final style = widget.style;
    if (MediaQuery.disableAnimationsOf(context) && style != TurnStyle.none) {
      return TurnStyle.fade;
    }
    if (style == TurnStyle.curl && _shader == null) return TurnStyle.slide;
    return style;
  }

  double get _width => context.size?.width ?? 400;

  // ---- Page pictures ----

  void _scheduleCapture() {
    _captureTimer?.cancel();
    if (_current != null) return;
    // Wait for the view to settle and the turn's last frames to pass.
    _captureTimer = Timer(const Duration(milliseconds: 350), _capture);
  }

  Future<void> _capture() async {
    final source = widget.source;
    if (!mounted || source == null || _current != null || _capturing != null) return;
    if (_style == TurnStyle.none) return;
    if (_phase != _Phase.idle) return _scheduleCapture();

    final key = widget.pageKey;
    final image = await (_capturing = source.snapshot());
    _capturing = null;
    if (image == null) return;
    if (!mounted || _phase != _Phase.idle || widget.pageKey != key || _current != null) {
      image.dispose();
      return;
    }
    _current = image;
  }

  void _dropCache() {
    final current = _current;
    final previous = _previous;
    _current = null;
    _previous = null;
    _disposeUnlessHeld(current);
    _disposeUnlessHeld(previous);
  }

  void _disposeUnlessHeld(ui.Image? image) {
    if (image == null) return;
    if (identical(image, _front) ||
        identical(image, _under) ||
        identical(image, _current) ||
        identical(image, _previous)) {
      return;
    }
    // After the frame that stops drawing it.
    WidgetsBinding.instance.addPostFrameCallback((_) => image.dispose());
  }

  /// Turns a page as a tap on that side would; used by the volume keys.
  void turn({required bool forward}) =>
      _tapTurn(forward ? _Direction.forward : _Direction.backward);

  // ---- Gestures ----

  /// A tap at [x] and [y], fractions of the size. The page view claims taps (so links work)
  /// and passes on the others, so taps arrive here rather than through a gesture detector.
  void tapAt(double x, {double y = _defaultTapY}) {
    if (!widget.enabled) return;
    if (!widget.tapToTurn) {
      widget.onCenterTap?.call();
    } else if (x < 0.28) {
      _tapTurn(widget.rightToLeft ? _Direction.forward : _Direction.backward, y: y);
    } else if (x > 0.72) {
      _tapTurn(widget.rightToLeft ? _Direction.backward : _Direction.forward, y: y);
    } else {
      widget.onCenterTap?.call();
    }
  }

  /// Turns without a place (the volume keys) take the page by its bottom corner.
  static const _defaultTapY = 0.96;

  Future<void> _tapTurn(_Direction direction, {double y = _defaultTapY}) async {
    if (_phase != _Phase.idle) {
      _queuedTap = direction;
      return;
    }
    final height = context.size!.height;
    _cornerY = _anchorFor(y * height, height);
    _tilt.value = _lean(height) * 1.2;
    _dragTotal = Offset.zero;
    if (await _begin(direction)) _settle(complete: true, tap: true);
  }

  /// Where on the right edge the page is lifted for a turn begun at [y]: a corner near the
  /// top or bottom, otherwise the edge at that height.
  static double _anchorFor(double y, double height) {
    if (y > height * 0.7) return height;
    if (y < height * 0.3) return 0;
    return y;
  }

  /// How far a lifted corner rises towards the middle over a whole turn, as paper held by a
  /// corner does. Held by the edge, it hardly leans.
  double _lean(double height) {
    if (_cornerY >= height) return -height * 0.1;
    if (_cornerY <= 0) return height * 0.1;
    return -height * 0.03;
  }

  void _onDragStart(DragStartDetails details) {
    if (_phase != _Phase.idle) return;
    _dragTotal = Offset.zero;
    _dragTurned = false;
    _pendingReleaseVelocity = null;
    _queuedTap = null;
    final height = context.size!.height;
    _cornerY = _anchorFor(details.localPosition.dy.clamp(0, height), height);
    _tilt.value = _lean(height);
  }

  void _onDragUpdate(DragUpdateDetails details) {
    _dragTotal += details.delta;
    if (_phase == _Phase.idle) {
      if (_dragTurned || _dragTotal.dx.abs() < 2) return;
      _dragTurned = true;
      final towardsLeft = _dragTotal.dx < 0;
      final forward = towardsLeft != widget.rightToLeft;
      _begin(forward ? _Direction.forward : _Direction.backward);
      return;
    }
    if (_phase == _Phase.turning) _followFinger();
  }

  /// Horizontal drag in reading direction: negative is towards the next page.
  double get _dx => widget.rightToLeft ? -_dragTotal.dx : _dragTotal.dx;

  void _followFinger() {
    final width = _width;
    final forward = _direction == _Direction.forward;
    final double p;
    if (_style == TurnStyle.curl) {
      final travel = CurlGeometry.travelFor(width);
      // Forward, the lifted corner stays under the finger. Backward, the fold (halfway
      // between the corner and the spine) does, as if pulling the page's edge.
      p = forward ? -_dx / travel : (2 * width - 2 * _dx) / travel;
    } else {
      p = forward ? -_dx / width : 1 - _dx / width;
    }
    _progress.value = p.clamp(0.0, 1.0);
    if (_style == TurnStyle.curl) _followFingerUpAndDown();
  }

  /// The lifted point moves up and down with the finger, staying on the page. The curl
  /// scales [_tilt] by progress (so a page laid back down lies flat), so set it to give the
  /// finger's offset at the current progress, within bounds so a release can't swing it.
  void _followFingerUpAndDown() {
    final height = context.size!.height;
    final offset = (_cornerY + _dragTotal.dy).clamp(0.0, height) - _cornerY;
    final p = math.max(_progress.value, 0.05);
    _tilt.value = (_lean(height) + offset / p).clamp(-height * 0.3, height * 0.3);
  }

  /// Change in progress per pixel the finger moves, for carrying its speed into the spring.
  double get _progressPerPixel {
    final width = _width;
    if (_style == TurnStyle.curl) {
      final travel = CurlGeometry.travelFor(width);
      return _direction == _Direction.forward ? -1 / travel : -2 / travel;
    }
    return -1 / width;
  }

  void _onDragEnd(DragEndDetails details) {
    final velocity = details.velocity.pixelsPerSecond.dx * (widget.rightToLeft ? -1 : 1);
    switch (_phase) {
      case _Phase.preparing:
        _pendingReleaseVelocity = velocity;
      case _Phase.turning:
        _release(velocity);
      case _Phase.idle:
      case _Phase.settling:
        break;
    }
  }

  void _release(double velocity) {
    const flick = 350.0;
    final forward = _direction == _Direction.forward;
    // How far and how fast the finger went in the turn's direction.
    final distance = (forward ? -_dx : _dx) / _width;
    final speed = forward ? -velocity : velocity;
    final complete = speed > flick || (speed > -flick && distance > 0.2);
    _settle(complete: complete, velocity: velocity);
  }

  // ---- Turning ----

  /// Gets the pictures for a turn. Returns false if there is no page to turn to.
  Future<bool> _begin(_Direction direction) async {
    final source = widget.source;
    if (source == null) return false;
    _direction = direction;
    _captureTimer?.cancel();

    if (_style == TurnStyle.none) {
      // No animation: track the drag without drawing anything, move once it's released.
      _phase = _Phase.turning;
      _moved = null;
      _progress.value = direction == _Direction.forward ? 0 : 1;
      return true;
    }

    setState(() => _phase = _Phase.preparing);
    if (_capturing != null) await _capturing;

    if (direction == _Direction.forward) {
      final current = _current ?? await source.snapshot();
      _current = null;
      if (!mounted || current == null) {
        _reset();
        return false;
      }
      _front = current;
      _progress.value = 0;
      _moved = source.goForward();
      _underReady = _moved!.then((moved) async {
        if (!moved) {
          // The last page: abandon the turn.
          if (mounted && identical(_front, current)) unawaited(_settle(complete: false));
          return;
        }
        // Show a picture of the new page under the curl, so what it reveals is already
        // complete while the view itself finishes drawing.
        final next = await source.snapshot();
        if (next == null) return;
        if (mounted && identical(_front, current) && _under == null) {
          setState(() => _under = next);
        } else {
          next.dispose();
        }
      });
    } else if (_current != null && _previous != null) {
      // Both pictures are ready: start at once and let the view catch up underneath.
      _under = _current;
      _front = _previous;
      _current = null;
      _previous = null;
      _progress.value = 1;
      _moved = source.goBackward();
    } else {
      final current = _current ?? await source.snapshot();
      _current = null;
      if (!mounted || current == null) {
        _reset();
        return false;
      }
      setState(() => _under = current); // Cover the view while it moves back.
      final moved = await source.goBackward();
      _moved = Future.value(moved);
      final previous = moved ? await source.snapshot() : null;
      if (!mounted || previous == null) {
        _reset();
        return false;
      }
      _front = previous;
      _progress.value = 1;
    }

    setState(() => _phase = _Phase.turning);
    if (_dragTotal != Offset.zero) _followFinger();
    final pending = _pendingReleaseVelocity;
    if (pending != null) {
      _pendingReleaseVelocity = null;
      _release(pending);
    }
    return true;
  }

  Future<void> _settle({required bool complete, double velocity = 0, bool tap = false}) async {
    if (_phase == _Phase.settling) return;
    final forward = _direction == _Direction.forward;
    final source = widget.source!;

    if (_style == TurnStyle.none) {
      _phase = _Phase.settling;
      if (complete && await (forward ? source.goForward() : source.goBackward())) {
        if (widget.haptics) HapticFeedback.selectionClick();
        widget.onTurned?.call();
      }
      _finish(complete: complete);
      return;
    }

    _phase = _Phase.settling;
    final target = complete == forward ? 1.0 : 0.0;
    if (tap) {
      await _progress.animateTo(target, duration: _tapDuration, curve: _tapCurve);
    } else {
      final simulation = SpringSimulation(
        _spring,
        _progress.value,
        target,
        velocity * _progressPerPixel,
        tolerance: const Tolerance(distance: 0.002, velocity: 0.02),
      );
      await _progress.animateWith(simulation);
      _progress.value = target;
    }
    if (!mounted) return;

    final moved = await (_moved ?? Future.value(false));
    if (!complete && moved) {
      // Put the view back where it was, still hidden under the picture.
      await (forward ? source.goBackward() : source.goForward());
    }
    if (complete && moved) {
      if (widget.haptics) HapticFeedback.selectionClick();
      widget.onTurned?.call();
      // Keep the pictures up a moment longer, so the view underneath has drawn the new page
      // (images included) by the time it shows.
      await _underReady;
      await Future<void>.delayed(_revealDelay);
    }
    if (mounted) _finish(complete: complete && moved);
  }

  /// Ends a turn, keeping the pictures that still show a known page.
  void _finish({required bool complete}) {
    final front = _front;
    final under = _under;
    final forward = _direction == _Direction.forward;
    final oldCurrent = _current;
    final oldPrevious = _previous;

    if (front == null) {
      // A turn without animation took no pictures; the cached ones are now stale.
      _current = null;
      _previous = null;
    } else {
      if (forward) {
        if (complete) {
          _previous = front; // The page turned away.
          _current = under; // The picture of the new page, if it was taken.
        } else {
          _current = front;
        }
      } else {
        if (complete) {
          _current = front; // The earlier page, now on screen.
          _previous = null;
        } else {
          _current = under;
          _previous = front;
        }
      }
    }
    _lastTurnEnd = DateTime.now();
    _reset();
    for (final image in {oldCurrent, oldPrevious, front, under}) {
      _disposeUnlessHeld(image);
    }
  }

  void _reset() {
    setState(() {
      _phase = _Phase.idle;
      _front = null;
      _under = null;
      _moved = null;
      _underReady = null;
      _pendingReleaseVelocity = null;
    });
    _scheduleCapture();
    final queued = _queuedTap;
    _queuedTap = null;
    if (queued != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _tapTurn(queued);
      });
    }
  }

  // ---- Drawing ----

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: widget.enabled ? _onDragStart : null,
      onHorizontalDragUpdate: widget.enabled ? _onDragUpdate : null,
      onHorizontalDragEnd: widget.enabled ? _onDragEnd : null,
      onHorizontalDragCancel: widget.enabled ? () => _onDragEnd(DragEndDetails()) : null,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (_under case final under?)
            IgnorePointer(child: RawImage(image: under, fit: BoxFit.fill)),
          if (_front case final front?)
            IgnorePointer(child: RepaintBoundary(child: _turningPage(front))),
        ],
      ),
    );
  }

  Widget _turningPage(ui.Image page) {
    final painter = switch (_style) {
      TurnStyle.curl => CurlPainter(
        shader: _shader!,
        page: page,
        progress: _progress,
        cornerY: _cornerY,
        tilt: _tilt,
        backColor: widget.pageBack,
      ),
      TurnStyle.slide => SlidePainter(page: page, progress: _progress),
      TurnStyle.fade || TurnStyle.none => FadePainter(page: page, progress: _progress),
    };
    final paint = CustomPaint(painter: painter, size: Size.infinite);
    // Right-to-left books turn the other way.
    if (!widget.rightToLeft || _style == TurnStyle.fade) return paint;
    return Transform.flip(flipX: true, child: paint);
  }
}
