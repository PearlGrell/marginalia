import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'readium.dart';

const _viewType = 'marginalia/readium-view';

/// Shows a Readium EPUB navigator as an Android platform view.
///
/// The view receives taps (so links work), long presses (text selection) and, in [scroll]
/// mode, vertical drags. Horizontal drags are left to Flutter ancestors, which turn pages
/// through the [ReadiumViewController]. Taps that don't follow a link come back as [onTap].
class ReadiumView extends StatelessWidget {
  const ReadiumView({
    super.key,
    required this.publicationId,
    required this.preferences,
    this.scroll = false,
    this.initialLocatorJson,
    required this.onCreated,
    this.onLocationChanged,
    this.onTap,
    this.onSelection,
    this.onHighlightTapped,
    this.onSelectionActive,
    this.onFootnote,
    this.selecting = false,
  });

  final String publicationId;
  final Map<String, Object?> preferences;
  final bool scroll;
  final String? initialLocatorJson;
  final ValueChanged<ReadiumViewController> onCreated;
  final ValueChanged<ReaderLocation>? onLocationChanged;

  /// A tap that didn't follow a link, at fractions of the view's width and height.
  final ValueChanged<Offset>? onTap;

  /// The selection menu was used: `action` (highlight, note, define, copy) plus the
  /// selection's locator and text (see `onSelection` in ReaderPlatformView.kt).
  final ValueChanged<Map<Object?, Object?>>? onSelection;
  final ValueChanged<String>? onHighlightTapped;

  /// Text selection started or ended in the page.
  final ValueChanged<bool>? onSelectionActive;

  /// A footnote link was tapped; the page stays where it is.
  final ValueChanged<Footnote>? onFootnote;

  /// While text is selected, the page gets every touch, so dragging a selection handle is
  /// never taken for a page turn.
  final bool selecting;

  @override
  Widget build(BuildContext context) {
    return AndroidView(
      viewType: _viewType,
      layoutDirection: TextDirection.ltr,
      creationParams: {
        'publicationId': publicationId,
        'locator': initialLocatorJson,
        'preferences': preferences,
      },
      creationParamsCodec: const StandardMessageCodec(),
      gestureRecognizers: selecting
          ? {Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new)}
          : {
              Factory<LongPressGestureRecognizer>(LongPressGestureRecognizer.new),
              if (scroll) Factory<VerticalDragGestureRecognizer>(VerticalDragGestureRecognizer.new),
            },
      onPlatformViewCreated: (id) {
        onCreated(
          ReadiumViewController._(
            id,
            onLocationChanged,
            onTap,
            onSelection,
            onHighlightTapped,
            onSelectionActive,
            onFootnote,
          ),
        );
      },
    );
  }
}

/// Drives one [ReadiumView]. Navigation methods complete once the new page is laid out.
class ReadiumViewController {
  ReadiumViewController._(
    int viewId,
    this._onLocationChanged,
    this._onTap,
    this._onSelection,
    this._onHighlightTapped,
    this._onSelectionActive,
    this._onFootnote,
  )
    : _channel = MethodChannel('$_viewType/$viewId') {
    _channel.setMethodCallHandler(_handle);
  }

  final MethodChannel _channel;
  final ValueChanged<ReaderLocation>? _onLocationChanged;
  final ValueChanged<Offset>? _onTap;
  final ValueChanged<Map<Object?, Object?>>? _onSelection;
  final ValueChanged<String>? _onHighlightTapped;
  final ValueChanged<bool>? _onSelectionActive;
  final ValueChanged<Footnote>? _onFootnote;

  ReaderLocation? _location;
  ReaderLocation? get location => _location;

  Future<Object?> _handle(MethodCall call) async {
    if (call.method == 'onLocatorChanged') {
      final location = ReaderLocation.fromMap(call.arguments as Map<Object?, Object?>);
      _location = location;
      _onLocationChanged?.call(location);
    } else if (call.method == 'onTap') {
      final args = call.arguments as Map<Object?, Object?>;
      _onTap?.call(Offset((args['x']! as num).toDouble(), (args['y']! as num).toDouble()));
    } else if (call.method == 'onSelection') {
      _onSelection?.call(call.arguments as Map<Object?, Object?>);
    } else if (call.method == 'onSelectionActive') {
      _onSelectionActive?.call((call.arguments as Map)['active'] == true);
    } else if (call.method == 'onHighlightTapped') {
      _onHighlightTapped?.call((call.arguments as Map)['id'] as String);
    } else if (call.method == 'onFootnote') {
      final args = call.arguments as Map;
      _onFootnote?.call(Footnote(html: args['html'] as String? ?? '', href: args['href'] as String?));
    }
    return null;
  }

  /// Returns false at the end of the book.
  Future<bool> goForward() => _go('goForward');

  /// Returns false at the start of the book.
  Future<bool> goBackward() => _go('goBackward');

  Future<bool> goToLocator(String locatorJson) => _go('goToLocator', {'locator': locatorJson});

  Future<bool> goToHref(String href) => _go('goToHref', {'href': href});

  Future<bool> goToProgression(double progression) =>
      _go('goToProgression', {'progression': progression.clamp(0.0, 1.0)});

  /// Draws highlights: each `{id, locator (JSON), color (ARGB)}`.
  Future<void> setHighlights(List<Map<String, Object?>> highlights) =>
      _channel.invokeMethod('setHighlights', {'highlights': highlights});

  /// Marks the sentence being read aloud and keeps it on screen; null clears it.
  Future<void> setSpokenSentence(String? locatorJson, int color) =>
      _channel.invokeMethod('setSpokenSentence', {'locator': locatorJson, 'color': color});

  /// Every place [query] appears in the book (up to 300), in reading order.
  Future<List<SearchResult>> search(String query) async {
    try {
      final list = await _channel.invokeListMethod<Map<Object?, Object?>>('search', {'query': query});
      return [for (final m in list ?? const <Map<Object?, Object?>>[]) SearchResult.fromMap(m)];
    } on PlatformException {
      return const [];
    }
  }

  /// Underlines the search result being looked at; null clears it.
  Future<void> markSearchResult(String? locatorJson, int color) =>
      _channel.invokeMethod('markSearchResult', {'locator': locatorJson, 'color': color});

  /// The paragraph at a point (fractions of the view) as Locator JSON, or null if there's no
  /// text there.
  Future<String?> locatorAt(Offset point) async {
    try {
      return await _channel.invokeMethod<String>('locatorAt', {'x': point.dx, 'y': point.dy});
    } on PlatformException {
      return null;
    }
  }

  /// Shows [text] under the paragraph marked [id] when it was selected for translating.
  Future<bool> insertTranslation(String id, String text) async =>
      await _channel.invokeMethod<bool>('insertTranslation', {'id': id, 'text': text}) ?? false;

  Future<void> setPreferences(Map<String, Object?> preferences) =>
      _channel.invokeMethod('setPreferences', preferences);

  /// A picture of the page currently on screen, at [scale] of the view's pixel size.
  /// Returns null if the view isn't ready.
  Future<ui.Image?> snapshot({double scale = 1.0}) async {
    final Map<Object?, Object?>? result;
    try {
      result = await _channel.invokeMethod<Map<Object?, Object?>>('snapshot', {'scale': scale});
    } on PlatformException {
      return null;
    }
    if (result == null) return null;
    final pixels = result['pixels']! as Uint8List;
    final width = result['width']! as int;
    final height = result['height']! as int;

    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(pixels, width, height, ui.PixelFormat.rgba8888, completer.complete);
    return completer.future;
  }

  Future<bool> _go(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<bool>(method, args) ?? false;
    } on PlatformException {
      return false;
    }
  }

  void dispose() => _channel.setMethodCallHandler(null);
}
