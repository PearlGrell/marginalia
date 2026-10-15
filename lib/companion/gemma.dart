import 'dart:async';
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'conversation.dart';

enum GemmaStatus { notInstalled, downloading, installed, failed }

class GemmaState {
  const GemmaState(this.status, {this.progress, this.error});

  final GemmaStatus status;

  /// 0 to 1 while downloading.
  final double? progress;
  final String? error;

  bool get installed => status == GemmaStatus.installed;
  bool get busy => status == GemmaStatus.downloading;
}

/// Gemma 3 1B (int4, a MediaPipe .task file), the reading companion's model on phones without
/// Gemini Nano.
/// Downloaded on request from our own storage (it's too big to ship) and run on the phone by
/// `CompanionChannel.kt`. A cut-off download picks up where it stopped.
class GemmaPack extends Notifier<GemmaState> {
  static const _channel = MethodChannel('marginalia/companion');
  static const url =
      'https://objectstorage.ap-mumbai-1.oraclecloud.com/p/2BFMlWV588O5fEfDDpVh2ZzPK5B4JWiFRLlPzZ9SfCbwnfNSyM82GplI4nbcu8_S'
      '/n/bmjtkz5nnabz/b/bucket-20260914-1251/o/gemma3-1b-it-int4.task';
  static const sizeLabel = '529 MB';
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
    return const GemmaState(GemmaStatus.notInstalled);
  }

  static Future<File> _file() async =>
      File('${(await getApplicationSupportDirectory()).path}/models/gemma3-1b-it-int4.task');

  /// The file only takes its name once all of it has come (see [install]).
  Future<void> _check() async {
    if (await (await _file()).exists()) state = const GemmaState(GemmaStatus.installed);
  }

  Future<void> install() async {
    if (state.busy || state.installed) return;
    final file = await _file();
    final part = File('${file.path}.part');
    _cancelled = false;
    try {
      await file.parent.create(recursive: true);
      var received = await part.exists() ? await part.length() : 0;
      state = GemmaState(GemmaStatus.downloading, progress: 0);
      final client = _client = HttpClient()..userAgent = 'Marginalia/1.0 (Android EPUB reader)';
      final request = await client.getUrl(Uri.parse(url));
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
            state = GemmaState(GemmaStatus.downloading, progress: p);
          }
        }
      } finally {
        await sink.close();
      }
      client.close();
      _client = null;
      if (await part.length() != total) throw const FileSystemException('incomplete');
      await part.rename(file.path);
      state = const GemmaState(GemmaStatus.installed);
    } catch (_) {
      _client = null;
      // Cancelled: what came so far stays, for next time.
      state = _cancelled
          ? const GemmaState(GemmaStatus.notInstalled)
          : const GemmaState(
              GemmaStatus.failed,
              error:
                  "Gemma couldn't be downloaded. Check your connection and that 600 MB is free; it will carry on from where it stopped.",
            );
    }
  }

  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
    _client = null;
  }

  /// Gemma's answer to [prompt] on its own, outside the conversation; null if it couldn't.
  Future<String?> once(String prompt, {int maxTokens = 200}) async {
    if (!state.installed) return null;
    try {
      return await _channel.invokeMethod<String>('gemmaOnce', {
        'path': (await _file()).path,
        'prompt': prompt,
        'maxTokens': maxTokens,
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

  /// Lets go of the model's memory (about 1 GB while loaded) and the conversation; it loads
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
    final file = await _file();
    // The model, a part-downloaded one, and what was learnt about running it.
    if (await file.parent.exists()) {
      await for (final f in file.parent.list()) {
        if (f is File && (f.path.startsWith(file.path) || f.path.contains('gemma-'))) await f.delete();
      }
    }
    state = const GemmaState(GemmaStatus.notInstalled);
  }

  /// Gemma's answer to [prompt], the text so far each time more is written, in the
  /// conversation it's having (or a new one, when [fresh]). Fails with [ConversationFull] when a
  /// follow-up won't fit, or [ModelFailed].
  Stream<String> chat(String prompt, {required bool fresh, int maxTokens = 200}) {
    final id = _nextId++;
    final out = StreamController<String>();
    _writing[id] = out.add;
    final frames = _watchFrames();
    () async {
      try {
        if (!state.installed) throw const ModelFailed('Gemma isn’t downloaded.');
        final text = await _channel.invokeMethod<String>('gemmaChat', {
          'id': id,
          'path': (await _file()).path,
          'prompt': prompt,
          'fresh': fresh,
          'maxTokens': maxTokens,
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

  // About 650 tokens of book to start (reading it is most of the wait on a slower phone), 350
  // for a follow-up: Gemma's window is 2048, answers and the conversation so far included.
  @override
  int get freshChars => 2600;

  @override
  int get followUpChars => 1300;

  @override
  Stream<String> write(String prompt, {required bool fresh, required int maxTokens}) =>
      pack.chat(prompt, fresh: fresh, maxTokens: maxTokens);

  @override
  Future<String?> once(String prompt, {required int maxTokens}) => pack.once(prompt, maxTokens: maxTokens);

  @override
  Future<void> cancel() => pack.cancelAnswer();
}

final gemmaProvider = NotifierProvider<GemmaPack, GemmaState>(GemmaPack.new);
