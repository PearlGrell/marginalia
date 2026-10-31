import 'dart:async';
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'conversation.dart';

enum GemmaStatus { notInstalled, downloading, installed, failed }

/// The Gemma models the companion can run, smallest first. Each is a MediaPipe .task file in
/// our own storage, downloaded on request; one is kept on the phone at a time.
enum GemmaSize {
  /// Gemma 3 1B: quick, for any phone.
  small(
    file: 'gemma3-1b-it-int4.task',
    label: 'Gemma 3 (1B)',
    sizeLabel: '529 MB',
    bytesFree: '600 MB',
    contextTokens: 2048,
    freshChars: 2600,
    followUpChars: 1300,
  ),

  /// Gemma 3n E2B: much better answers, for phones with 8 GB of memory or more.
  large(
    file: 'gemma-3n-E2B-it-int4.task',
    label: 'Gemma 3n (E2B)',
    sizeLabel: '3.1 GB',
    bytesFree: '3.5 GB',
    contextTokens: 4096,
    freshChars: 7000,
    followUpChars: 3200,
  );

  const GemmaSize({
    required this.file,
    required this.label,
    required this.sizeLabel,
    required this.bytesFree,
    required this.contextTokens,
    required this.freshChars,
    required this.followUpChars,
  });

  final String file;
  final String label;
  final String sizeLabel;

  /// Room the download needs.
  final String bytesFree;

  /// Its window: prompt, conversation and answer together.
  final int contextTokens;

  /// How much of the book goes into a prompt that starts a conversation, and a follow-up.
  final int freshChars;
  final int followUpChars;

  static const _base =
      'https://objectstorage.ap-mumbai-1.oraclecloud.com/p/2BFMlWV588O5fEfDDpVh2ZzPK5B4JWiFRLlPzZ9SfCbwnfNSyM82GplI4nbcu8_S'
      '/n/bmjtkz5nnabz/b/bucket-20260914-1251/o/';

  String get url => '$_base$file';
}

class GemmaState {
  const GemmaState({this.size, this.downloading, this.progress, this.error});

  /// The model on the phone, if one is.
  final GemmaSize? size;

  /// The model being downloaded (the one on the phone, if any, keeps working meanwhile).
  final GemmaSize? downloading;

  /// 0 to 1 while downloading.
  final double? progress;
  final String? error;

  GemmaStatus get status => downloading != null
      ? GemmaStatus.downloading
      : size != null
      ? GemmaStatus.installed
      : error != null
      ? GemmaStatus.failed
      : GemmaStatus.notInstalled;

  bool get installed => size != null;
  bool get busy => downloading != null;
}

/// Gemma, the reading companion's model on phones without Gemini Nano (or, in its larger size,
/// on any phone with the memory for it), run on the phone by `CompanionChannel.kt`. Downloaded
/// on request from our own storage (it's too big to ship). A cut-off download picks up where it
/// stopped; a new size replaces the old once it's all there.
class GemmaPack extends Notifier<GemmaState> {
  static const _channel = MethodChannel('marginalia/companion');
  static const termsUrl = 'https://ai.google.dev/gemma/terms';

  HttpClient? _client;
  var _cancelled = false;

  /// Answers being written, by id: each gets the text so far as it comes.
  final _writing = <int, void Function(String)>{};
  var _nextId = 0;

  @override
  GemmaState build() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onGemmaText') {
        final args = call.arguments as Map;
        _writing[args['id'] as int]?.call(args['text'] as String);
      }
      return null;
    });
    ref.onDispose(() => _channel.setMethodCallHandler(null));
    unawaited(_check());
    return const GemmaState();
  }

  static Future<File> _file(GemmaSize size) async =>
      File('${(await getApplicationSupportDirectory()).path}/models/${size.file}');

  /// The installed model's file (the larger, if both are somehow there).
  Future<File?> _installed() async {
    for (final size in GemmaSize.values.reversed) {
      final file = await _file(size);
      if (await file.exists()) return file;
    }
    return null;
  }

  /// A file only takes its name once all of it has come (see [install]).
  Future<void> _check() async {
    for (final size in GemmaSize.values.reversed) {
      if (await (await _file(size)).exists()) {
        state = GemmaState(size: size, downloading: state.downloading, progress: state.progress);
        return;
      }
    }
  }

  /// How much memory the phone has, in GB (0 if it can't say).
  Future<double> phoneMemoryGb() async {
    try {
      return ((await _channel.invokeMethod<int>('memoryBytes')) ?? 0) / (1024 * 1024 * 1024);
    } on PlatformException {
      return 0;
    } on MissingPluginException {
      return 0;
    }
  }

  /// Downloads Gemma in [size]; once it's all there it replaces the size there was.
  Future<void> install([GemmaSize size = GemmaSize.small]) async {
    if (state.busy || state.size == size) return;
    final file = await _file(size);
    final part = File('${file.path}.part');
    _cancelled = false;
    final before = state.size;
    try {
      await file.parent.create(recursive: true);
      var received = await part.exists() ? await part.length() : 0;
      state = GemmaState(size: before, downloading: size, progress: 0);
      final client = _client = HttpClient()..userAgent = 'Marginalia/1.0 (Android EPUB reader)';
      final request = await client.getUrl(Uri.parse(size.url));
      if (received > 0) request.headers.set(HttpHeaders.rangeHeader, 'bytes=$received-');
      final response = await request.close();
      if (response.statusCode == HttpStatus.ok) {
        received = 0; // The server sent it all again.
      } else if (response.statusCode != HttpStatus.partialContent) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      // The whole file's size: what's here plus what's coming (a resumed download gets the rest).
      if (response.contentLength <= 0) throw const HttpException('no length');
      final total = received + response.contentLength;
      final sink = part.openWrite(mode: received > 0 ? FileMode.append : FileMode.write);
      var shown = 0.0;
      try {
        await for (final chunk in response) {
          sink.add(chunk);
          received += chunk.length;
          final p = received / total;
          if (p - shown >= 0.005) {
            shown = p;
            state = GemmaState(size: before, downloading: size, progress: p);
          }
        }
      } finally {
        await sink.close();
      }
      client.close();
      _client = null;
      if (await part.length() != total) throw const FileSystemException('incomplete');
      if (before != null) {
        // The other size goes: one model on the phone at a time.
        await release();
        final old = await _file(before);
        if (await old.exists()) await old.delete();
      }
      await part.rename(file.path);
      state = GemmaState(size: size);
    } catch (e) {
      _client = null;
      // Cancelled: what came so far stays, for next time.
      state = _cancelled
          ? GemmaState(size: before)
          : GemmaState(
              size: before,
              error: e is HttpException && e.message == 'HTTP 404'
                  ? '${size.label} isn’t available to download yet.'
                  : '${size.label} couldn’t be downloaded. Check your connection and that ${size.bytesFree} is free; '
                        'it will carry on from where it stopped.',
            );
    }
  }

  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
    _client = null;
  }

  /// Answers being written in the companion, and who's waiting for there to be none.
  var _answering = 0;
  Completer<void>? _idle;

  /// Once no answer is being written in the companion (at once, if none is): what's done in
  /// the background waits for this, so a question doesn't queue behind it.
  Future<void> idle() async {
    while (_answering > 0) {
      await (_idle ??= Completer<void>()).future;
    }
  }

  void _answered() {
    if (--_answering > 0) return;
    _idle?.complete();
    _idle = null;
  }

  /// Gemma's answer to [prompt] on its own, outside the conversation; null if it couldn't.
  Future<String?> once(String prompt, {int maxTokens = 200}) async {
    final size = state.size;
    final file = await _installed();
    if (size == null || file == null) return null;
    try {
      return await _channel.invokeMethod<String>('gemmaOnce', {
        'path': file.path,
        'prompt': prompt,
        'maxTokens': maxTokens,
        'contextTokens': size.contextTokens,
      });
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Whether something on screen is using Gemma (the companion sheet), so it stays loaded.
  var _holds = 0;

  void hold() => _holds++;

  void letGo() => _holds--;

  /// Lets go of Gemma's memory unless something on screen is using it.
  Future<void> releaseIfIdle() async {
    if (_holds <= 0) await release();
  }

  /// Stops the answer being written, if there is one.
  Future<void> cancelAnswer() async {
    try {
      await _channel.invokeMethod('gemmaCancel');
    } on MissingPluginException {
      // Not on a phone (tests).
    }
  }

  /// Lets go of the model's memory (1 to 3 GB while loaded) and the conversation; it loads
  /// again when next asked.
  Future<void> release() async {
    try {
      await _channel.invokeMethod('gemmaClose');
    } on MissingPluginException {
      // Not on a phone (tests).
    }
  }

  Future<void> remove() async {
    await release();
    final dir = (await _file(GemmaSize.small)).parent;
    // The models, part-downloaded ones, and what was learnt about running them.
    if (await dir.exists()) {
      await for (final f in dir.list()) {
        final name = f.uri.pathSegments.last;
        if (f is File && (GemmaSize.values.any((s) => name.startsWith(s.file)) || name.startsWith('gemma-'))) {
          await f.delete();
        }
      }
    }
    state = const GemmaState();
  }

  /// Gemma's answer to [prompt], the text so far each time more is written, in the
  /// conversation it's having (or a new one, when [fresh]). Fails with [ConversationFull] when a
  /// follow-up won't fit, or [ModelFailed].
  Stream<String> chat(String prompt, {required bool fresh, int maxTokens = 200}) {
    final id = _nextId++;
    final out = StreamController<String>();
    _writing[id] = out.add;
    _answering++;
    final frames = _watchFrames();
    () async {
      try {
        final size = state.size;
        final file = await _installed();
        if (size == null || file == null) throw const ModelFailed('Gemma isn’t downloaded.');
        final text = await _channel.invokeMethod<String>('gemmaChat', {
          'id': id,
          'path': file.path,
          'prompt': prompt,
          'fresh': fresh,
          'maxTokens': maxTokens,
          'contextTokens': size.contextTokens,
        });
        if (text == null || text.trim().isEmpty) throw const ModelFailed('Gemma gave no answer.');
        out.add(text);
      } on PlatformException catch (e) {
        out.addError(e.code == 'context_full' ? const ConversationFull() : ModelFailed(e.message ?? e.code));
      } on MissingPluginException {
        out.addError(const ModelFailed('Gemma isn’t available in this build.'));
      } catch (e) {
        out.addError(e);
      } finally {
        _writing.remove(id);
        _answered();
        frames();
        await out.close();
      }
    }();
    return out.stream;
  }

  /// Watches the screen's frames while Gemma writes; the returned function stops watching and,
  /// if many frames were slow, says so (Gemma then leaves the GPU to the screen).
  void Function() _watchFrames() {
    var frames = 0, slow = 0;
    void count(List<FrameTiming> timings) {
      for (final t in timings) {
        frames++;
        if (t.totalSpan > const Duration(milliseconds: 50)) slow++;
      }
    }

    SchedulerBinding.instance.addTimingsCallback(count);
    return () {
      SchedulerBinding.instance.removeTimingsCallback(count);
      if (frames >= 20 && slow * 4 > frames) {
        _channel.invokeMethod('gemmaJanky').catchError((_) {});
      }
    };
  }
}

/// Gemma as the companion's model: it keeps the conversation, and reads a few pages at once.
class GemmaModel implements CompanionModel {
  GemmaModel(this.pack);

  final GemmaPack pack;

  @override
  bool get remembers => true;

  // The 1B model: about 650 tokens of book to start (reading it is most of the wait on a slower
  // phone), 350 for a follow-up, in a window of 2048 with the answers and conversation so far.
  // The larger model reads more in a window twice the size.
  @override
  int get freshChars => (pack.state.size ?? GemmaSize.small).freshChars;

  @override
  int get followUpChars => (pack.state.size ?? GemmaSize.small).followUpChars;

  @override
  Stream<String> write(String prompt, {required bool fresh, required int maxTokens}) =>
      pack.chat(prompt, fresh: fresh, maxTokens: maxTokens);

  @override
  Future<String?> once(String prompt, {required int maxTokens}) => pack.once(prompt, maxTokens: maxTokens);

  @override
  Future<void> cancel() => pack.cancelAnswer();
}

final gemmaProvider = NotifierProvider<GemmaPack, GemmaState>(GemmaPack.new);
