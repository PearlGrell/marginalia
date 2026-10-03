import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'kokoro.dart';
import '../storage/local_store.dart';

enum SleepTimer {
  off('Off'),
  minutes15('15 minutes'),
  minutes30('30 minutes'),
  minutes45('45 minutes'),
  minutes60('1 hour'),
  endOfChapter('End of chapter');

  const SleepTimer(this.label);

  final String label;

  Duration? get duration => switch (this) {
    minutes15 => const Duration(minutes: 15),
    minutes30 => const Duration(minutes: 30),
    minutes45 => const Duration(minutes: 45),
    minutes60 => const Duration(minutes: 60),
    _ => null,
  };
}

/// A Kokoro voice offered for the open book.
class Voice {
  const Voice({required this.id, required this.kokoroName, required this.language, this.selected = false});

  /// The speaker number.
  final String id;

  /// Kokoro's name for it ("am_liam").
  final String kokoroName;
  final String language;
  final bool selected;

  KokoroVoice get voice => KokoroVoice(int.tryParse(id) ?? 0, kokoroName);

  /// "Liam · American male".
  String get name => '${voice.name} · ${voice.accent} ${voice.gender}';
}

class ListenState {
  const ListenState({
    this.active = false,
    this.playing = false,
    this.speed = 1.0,
    this.sentenceLocator,
    this.sleep = SleepTimer.off,
    this.sleepEndsAt,
    this.voice,
  });

  /// The voice reading.
  final KokoroVoice? voice;

  /// A book is being read aloud (playing or paused).
  final bool active;
  final bool playing;
  final double speed;

  /// Readium Locator JSON of the sentence being read.
  final String? sentenceLocator;
  final SleepTimer sleep;
  final DateTime? sleepEndsAt;

  ListenState copyWith({
    bool? active,
    bool? playing,
    double? speed,
    String? sentenceLocator,
    SleepTimer? sleep,
    DateTime? sleepEndsAt,
    bool clearSleepEnd = false,
    KokoroVoice? voice,
  }) => ListenState(
    voice: voice ?? this.voice,
    active: active ?? this.active,
    playing: playing ?? this.playing,
    speed: speed ?? this.speed,
    sentenceLocator: sentenceLocator ?? this.sentenceLocator,
    sleep: sleep ?? this.sleep,
    sleepEndsAt: clearSleepEnd ? null : (sleepEndsAt ?? this.sleepEndsAt),
  );
}

/// Reads the open book aloud with Kokoro's voices (see `ListenChannel.kt`). The reader
/// follows along: it marks the sentence and turns pages, so the reading position is the
/// listening position.
class ListenController extends Notifier<ListenState> {
  static const _channel = MethodChannel('marginalia/listen');
  static const _speedKey = 'listen.speed';
  static const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0];

  Timer? _sleepTimer;
  String? _chapterAtSleep;

  @override
  ListenState build() {
    _channel.setMethodCallHandler(_handle);
    ref.onDispose(() {
      _channel.setMethodCallHandler(null);
      _sleepTimer?.cancel();
    });
    final speed = ref.read(localStoreProvider).readDouble(_speedKey) ?? 1.0;
    return ListenState(speed: speed);
  }

  Future<Object?> _handle(MethodCall call) async {
    final args = (call.arguments as Map?) ?? const {};
    switch (call.method) {
      case 'onUtterance':
        final locator = args['locator'] as String?;
        _checkEndOfChapter(locator);
        state = state.copyWith(sentenceLocator: locator);
      case 'onPlayback':
        if (args['stopped'] == true) {
          _clearSleep();
          state = ListenState(speed: state.speed);
        } else {
          state = state.copyWith(playing: args['playing'] == true);
          if (args['ended'] == true) await stop();
        }
    }
    return null;
  }

  bool get isActive => state.active;

  /// Returned by [start] when the voices still have to be downloaded.
  static const needsVoices = 'needs-voices';

  /// Starts reading [publicationId] aloud from [locatorJson] (the page on screen), with the
  /// Kokoro voice chosen for the book's [language]. Returns an error message, [needsVoices],
  /// or null once it's reading.
  Future<String?> start(String publicationId, String? locatorJson, {String? language}) async {
    if (!ref.read(kokoroProvider).installed) return needsVoices;
    if (!KokoroVoice.speaks(language)) {
      return "There are no voices for this book's language yet. They speak English, Spanish, "
          'French, Hindi, Italian, Japanese, Portuguese and Chinese.';
    }
    try {
      final voice = ref.read(listenVoicesProvider).kokoroFor(language);
      await _channel.invokeMethod('start', {
        'publicationId': publicationId,
        'locator': locatorJson,
        'speed': state.speed,
        'language': language,
        'speaker': voice.speaker,
      });
      state = state.copyWith(active: true, playing: true, voice: voice);
      return null;
    } on PlatformException catch (e) {
      if (e.code == 'not_installed') return needsVoices;
      return e.message ?? "This book can't be read aloud.";
    }
  }

  Future<void> togglePlay() => _channel.invokeMethod(state.playing ? 'pause' : 'play');

  Future<void> nextSentence() => _channel.invokeMethod('nextSentence');

  Future<void> previousSentence() => _channel.invokeMethod('previousSentence');

  Future<void> nextChapter() => _channel.invokeMethod('nextChapter');

  Future<void> previousChapter() => _channel.invokeMethod('previousChapter');

  Future<void> setSpeed(double speed) async {
    state = state.copyWith(speed: speed);
    await ref.read(localStoreProvider).writeDouble(_speedKey, speed);
    if (state.active) await _channel.invokeMethod('setSpeed', {'speed': speed});
  }

  Future<List<Voice>> voices() async {
    final list = await _channel.invokeListMethod<Map<Object?, Object?>>('voices') ?? const [];
    return [
      for (final v in list)
        Voice(
          id: v['id']! as String,
          kokoroName: v['name']! as String,
          language: v['language']! as String,
          selected: v['selected'] == true,
        ),
    ];
  }

  /// Changes the voice, and remembers it for books in its language.
  Future<void> setVoice(Voice voice) async {
    await _channel.invokeMethod('setVoice', {'id': voice.id});
    await ref.read(listenVoicesProvider).setKokoro(voice.voice);
    state = state.copyWith(voice: voice.voice);
  }

  /// Reads on from [locatorJson] (a line tapped in the page).
  Future<void> readFrom(String locatorJson) async {
    if (!state.active) return;
    await _channel.invokeMethod('goTo', {'locator': locatorJson});
  }

  /// The next sleep timer setting, for stepping through them with one button.
  void nextSleep() => setSleep(SleepTimer.values[(state.sleep.index + 1) % SleepTimer.values.length]);

  void setSleep(SleepTimer sleep) {
    _clearSleep();
    final duration = sleep.duration;
    if (duration != null) {
      _sleepTimer = Timer(duration, _sleepNow);
      state = state.copyWith(sleep: sleep, sleepEndsAt: DateTime.now().add(duration));
    } else {
      _chapterAtSleep = sleep == SleepTimer.endOfChapter ? _href(state.sentenceLocator) : null;
      state = state.copyWith(sleep: sleep, clearSleepEnd: true);
    }
  }

  void _checkEndOfChapter(String? locator) {
    if (state.sleep != SleepTimer.endOfChapter) return;
    final href = _href(locator);
    _chapterAtSleep ??= href;
    if (href != null && href != _chapterAtSleep) _sleepNow();
  }

  void _sleepNow() {
    _clearSleep();
    if (state.playing) _channel.invokeMethod('pause');
  }

  void _clearSleep() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _chapterAtSleep = null;
    state = state.copyWith(sleep: SleepTimer.off, clearSleepEnd: true);
  }

  Future<void> stop() async {
    _clearSleep();
    await _channel.invokeMethod('stop');
    state = ListenState(speed: state.speed);
  }

  static String? _href(String? locatorJson) => locatorJson == null
      ? null
      : RegExp(r'"href"\s*:\s*"([^"#]*)').firstMatch(locatorJson)?.group(1);
}

final listenProvider = NotifierProvider<ListenController, ListenState>(ListenController.new);
