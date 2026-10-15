import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

/// Who reads: Leigha or Alex, the phone's most natural female and male voices for the book
/// (see `Narrators.kt`).
class Voice {
  const Voice({required this.id, required this.name, this.selected = false});

  /// "leigha" or "alex".
  final String id;
  final String name;
  final bool selected;
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
    this.following = true,
  });

  /// Who is reading: "Leigha" or "Alex".
  final String? voice;

  /// A book is being read aloud (playing or paused).
  final bool active;
  final bool playing;
  final double speed;

  /// Readium Locator JSON of the sentence being read.
  final String? sentenceLocator;
  final SleepTimer sleep;
  final DateTime? sleepEndsAt;

  /// The page follows the voice. Turning a page by hand stops it, so the next sentence
  /// doesn't turn back; [ListenController.follow] starts it again.
  final bool following;

  ListenState copyWith({
    bool? active,
    bool? playing,
    double? speed,
    String? sentenceLocator,
    SleepTimer? sleep,
    DateTime? sleepEndsAt,
    bool clearSleepEnd = false,
    String? voice,
    bool? following,
  }) => ListenState(
    following: following ?? this.following,
    voice: voice ?? this.voice,
    active: active ?? this.active,
    playing: playing ?? this.playing,
    speed: speed ?? this.speed,
    sentenceLocator: sentenceLocator ?? this.sentenceLocator,
    sleep: sleep ?? this.sleep,
    sleepEndsAt: clearSleepEnd ? null : (sleepEndsAt ?? this.sleepEndsAt),
  );
}

/// Reads the open book aloud with the phone's own voices, as Leigha or Alex (see
/// `ListenChannel.kt`). The reader
/// follows along: it marks the sentence and turns pages, so the reading position is the
/// listening position.
class ListenController extends Notifier<ListenState> {
  static const _channel = MethodChannel('marginalia/listen');
  static const _speedKey = 'listen.speed';
  static const _narratorKey = 'listen.narrator';
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

  /// Starts reading [publicationId] aloud from [locatorJson] (the page on screen), in the
  /// book's [language], with the narrator last chosen. Returns an error message, or null once
  /// it's reading.
  Future<String?> start(String publicationId, String? locatorJson, {String? language}) async {
    try {
      final narrator = ref.read(localStoreProvider).readJson(_narratorKey) as String? ?? 'leigha';
      await _channel.invokeMethod('start', {
        'publicationId': publicationId,
        'locator': locatorJson,
        'speed': state.speed,
        'language': language,
        'narrator': narrator,
      });
      final voices = await this.voices();
      final reading = voices.where((v) => v.selected).firstOrNull;
      state = state.copyWith(active: true, playing: true, voice: reading?.name);
      return null;
    } on PlatformException catch (e) {
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
      for (final v in list) Voice(id: v['id']! as String, name: v['name']! as String, selected: v['selected'] == true),
    ];
  }

  /// Changes who reads, and remembers it for next time.
  Future<void> setVoice(Voice voice) async {
    await _channel.invokeMethod('setVoice', {'id': voice.id});
    await ref.read(localStoreProvider).writeJson(_narratorKey, voice.id);
    state = state.copyWith(voice: voice.name);
  }

  /// Reads on from [locatorJson] (a line tapped in the page), and follows it again.
  Future<void> readFrom(String locatorJson) async {
    if (!state.active) return;
    state = state.copyWith(following: true);
    await _channel.invokeMethod('goTo', {'locator': locatorJson});
  }

  /// The reader turned the page by hand: stop following the voice until asked.
  void stopFollowing() {
    if (state.active && state.following) state = state.copyWith(following: false);
  }

  /// Follow the voice again (back to the sentence being read).
  void follow() {
    if (state.active && !state.following) state = state.copyWith(following: true);
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
