import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../storage/local_store.dart';

/// One of Kokoro's voices. The model numbers them; the name says who they are: the first
/// letter is the language (a American, b British, e Spanish, f French, h Hindi, i Italian,
/// j Japanese, p Brazilian Portuguese, z Chinese), the second the voice (f female, m male).
class KokoroVoice {
  const KokoroVoice(this.speaker, this.id);

  final int speaker;

  /// Kokoro's own name, such as "am_liam".
  final String id;

  String get name {
    final n = id.split('_').last;
    return n[0].toUpperCase() + n.substring(1);
  }

  /// BCP 47.
  String get language => switch (id[0]) {
    'a' => 'en-US',
    'b' => 'en-GB',
    'e' => 'es',
    'f' => 'fr',
    'h' => 'hi',
    'i' => 'it',
    'j' => 'ja',
    'p' => 'pt-BR',
    'z' => 'zh',
    _ => 'en',
  };

  String get accent => switch (id[0]) {
    'a' => 'American',
    'b' => 'British',
    'e' => 'Spanish',
    'f' => 'French',
    'h' => 'Hindi',
    'i' => 'Italian',
    'j' => 'Japanese',
    'p' => 'Brazilian',
    'z' => 'Mandarin',
    _ => '',
  };

  String get gender => id[1] == 'f' ? 'female' : 'male';

  String get baseLanguage => language.split('-').first;

  /// The best-rated voices in Kokoro's own grades, offered first.
  bool get featured => const {'af_heart', 'af_bella', 'am_liam', 'am_michael', 'am_fenrir', 'bf_emma', 'bm_george', 'ff_siwis'}.contains(id);

  static const all = [
    KokoroVoice(0, 'af_alloy'), KokoroVoice(1, 'af_aoede'), KokoroVoice(2, 'af_bella'), //
    KokoroVoice(3, 'af_heart'), KokoroVoice(4, 'af_jessica'), KokoroVoice(5, 'af_kore'),
    KokoroVoice(6, 'af_nicole'), KokoroVoice(7, 'af_nova'), KokoroVoice(8, 'af_river'),
    KokoroVoice(9, 'af_sarah'), KokoroVoice(10, 'af_sky'), KokoroVoice(11, 'am_adam'),
    KokoroVoice(12, 'am_echo'), KokoroVoice(13, 'am_eric'), KokoroVoice(14, 'am_fenrir'),
    KokoroVoice(15, 'am_liam'), KokoroVoice(16, 'am_michael'), KokoroVoice(17, 'am_onyx'),
    KokoroVoice(18, 'am_puck'), KokoroVoice(19, 'am_santa'), KokoroVoice(20, 'bf_alice'),
    KokoroVoice(21, 'bf_emma'), KokoroVoice(22, 'bf_isabella'), KokoroVoice(23, 'bf_lily'),
    KokoroVoice(24, 'bm_daniel'), KokoroVoice(25, 'bm_fable'), KokoroVoice(26, 'bm_george'),
    KokoroVoice(27, 'bm_lewis'), KokoroVoice(28, 'ef_dora'), KokoroVoice(29, 'em_alex'),
    KokoroVoice(30, 'ff_siwis'), KokoroVoice(31, 'hf_alpha'), KokoroVoice(32, 'hf_beta'),
    KokoroVoice(33, 'hm_omega'), KokoroVoice(34, 'hm_psi'), KokoroVoice(35, 'if_sara'),
    KokoroVoice(36, 'im_nicola'), KokoroVoice(37, 'jf_alpha'), KokoroVoice(38, 'jf_gongitsune'),
    KokoroVoice(39, 'jf_nezumi'), KokoroVoice(40, 'jf_tebukuro'), KokoroVoice(41, 'jm_kumo'),
    KokoroVoice(42, 'pf_dora'), KokoroVoice(43, 'pm_alex'), KokoroVoice(44, 'pm_santa'),
    KokoroVoice(45, 'zf_xiaobei'), KokoroVoice(46, 'zf_xiaoni'), KokoroVoice(47, 'zf_xiaoxiao'),
    KokoroVoice(48, 'zf_xiaoyi'), KokoroVoice(49, 'zm_yunjian'), KokoroVoice(50, 'zm_yunxi'),
    KokoroVoice(51, 'zm_yunxia'), KokoroVoice(52, 'zm_yunyang'), KokoroVoice(53, 'em_santa'),
  ];

  /// Book languages Kokoro reads.
  static const languages = {'en', 'es', 'fr', 'hi', 'it', 'ja', 'pt', 'zh'};

  static bool speaks(String? language) => languages.contains(_base(language));

  /// Voices for [language] ("en-GB" puts British voices first), featured first.
  static List<KokoroVoice> forLanguage(String language) {
    final base = _base(language);
    final list = [for (final v in all) if (v.baseLanguage == base) v];
    final region = language.toLowerCase();
    int rank(KokoroVoice v) =>
        (v.language.toLowerCase() == region ? 0 : 2) + (v.featured ? 0 : 1);
    return list..sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : a.speaker.compareTo(b.speaker);
    });
  }

  /// The voice used for [language] when none was chosen.
  static KokoroVoice defaultFor(String? language) {
    final l = (language ?? 'en').toLowerCase();
    final id = switch (_base(l)) {
      'en' when l.startsWith('en-gb') => 'bf_emma',
      'es' => 'ef_dora',
      'fr' => 'ff_siwis',
      'hi' => 'hf_alpha',
      'it' => 'if_sara',
      'ja' => 'jf_alpha',
      'pt' => 'pf_dora',
      'zh' => 'zf_xiaobei',
      _ => 'am_liam',
    };
    return all.firstWhere((v) => v.id == id);
  }

  static KokoroVoice? bySpeaker(int speaker) => speaker >= 0 && speaker < all.length ? all[speaker] : null;

  static String _base(String? language) => (language ?? '').split(RegExp('[-_]')).first.toLowerCase();
}

/// The languages Kokoro speaks, with the BCP 47 code to pick voices by.
const kokoroLanguages = [
  ('en-US', 'English (American)'),
  ('en-GB', 'English (British)'),
  ('es', 'Spanish'),
  ('fr', 'French'),
  ('hi', 'Hindi'),
  ('it', 'Italian'),
  ('ja', 'Japanese'),
  ('pt-BR', 'Portuguese (Brazil)'),
  ('zh', 'Chinese'),
];

/// Lines read when trying a voice, in its language (public domain openings).
const sampleLines = {
  'en': 'It was the best of times, it was the worst of times, it was the age of wisdom.',
  'fr': "Longtemps, je me suis couché de bonne heure. Parfois, à peine ma bougie éteinte, mes yeux se fermaient si vite.",
  'es': 'En un lugar de la Mancha, de cuyo nombre no quiero acordarme, no ha mucho tiempo que vivía un hidalgo.',
  'it': 'Nel mezzo del cammin di nostra vita mi ritrovai per una selva oscura.',
  'pt': 'As armas e os barões assinalados, que da ocidental praia lusitana, por mares nunca de antes navegados.',
  'hi': 'एक छोटे से गाँव में एक बूढ़ा किसान रहता था, जो हर सुबह सूरज से पहले उठता था।',
  'ja': '吾輩は猫である。名前はまだ無い。どこで生れたかとんと見当がつかぬ。',
  'zh': '学而时习之，不亦说乎？有朋自远方来，不亦乐乎？',
};

enum KokoroStatus { notInstalled, downloading, unpacking, installed, failed }

class KokoroState {
  const KokoroState(this.status, {this.progress, this.error});

  final KokoroStatus status;

  /// 0 to 1 while downloading or unpacking.
  final double? progress;
  final String? error;

  bool get busy => status == KokoroStatus.downloading || status == KokoroStatus.unpacking;
  bool get installed => status == KokoroStatus.installed;
}

/// The Kokoro voice model, downloaded on request (it's too big to ship): sherpa-onnx's int8
/// build of Kokoro v1.0, 54 voices in 9 languages.
class KokoroPack extends Notifier<KokoroState> {
  static const _channel = MethodChannel('marginalia/voices');
  static const url =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-int8-multi-lang-v1_0.tar.bz2';
  static const downloadSizeLabel = '132 MB';
  static const installedSizeLabel = '330 MB';

  HttpClient? _client;

  @override
  KokoroState build() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onKokoroProgress' && state.status == KokoroStatus.unpacking) {
        state = KokoroState(KokoroStatus.unpacking, progress: ((call.arguments as Map)['fraction'] as num).toDouble());
      }
      return null;
    });
    ref.onDispose(() => _channel.setMethodCallHandler(null));
    unawaited(_check());
    return const KokoroState(KokoroStatus.notInstalled);
  }

  Future<void> _check() async {
    try {
      if (await _channel.invokeMethod<bool>('kokoroInstalled') == true) {
        state = const KokoroState(KokoroStatus.installed);
      }
    } on MissingPluginException {
      // Not on a phone (tests).
    }
  }

  Future<void> install() async {
    if (state.busy || state.installed) return;
    final file = File('${(await getTemporaryDirectory()).path}/kokoro.tar.bz2');
    try {
      state = const KokoroState(KokoroStatus.downloading, progress: 0);
      final client = _client = HttpClient()..userAgent = 'Marginalia/1.0 (Android EPUB reader)';
      final response = await (await client.getUrl(Uri.parse(url))).close();
      if (response.statusCode != HttpStatus.ok) throw HttpException('HTTP ${response.statusCode}');
      final total = response.contentLength;
      var received = 0;
      var shown = 0.0;
      final sink = file.openWrite();
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        final p = total > 0 ? received / total : 0.0;
        if (p - shown >= 0.005) {
          shown = p;
          state = KokoroState(KokoroStatus.downloading, progress: p);
        }
      }
      await sink.close();
      client.close();
      _client = null;

      state = const KokoroState(KokoroStatus.unpacking, progress: 0);
      final ok = await _channel.invokeMethod<bool>('installKokoro', {'path': file.path}) ?? false;
      state = ok
          ? const KokoroState(KokoroStatus.installed)
          : const KokoroState(KokoroStatus.failed, error: "The voices couldn't be unpacked. Is there 400 MB free?");
    } catch (e) {
      state = const KokoroState(KokoroStatus.failed, error: "The voices couldn't be downloaded. Check your connection.");
    } finally {
      if (await file.exists()) await file.delete();
    }
  }

  void cancel() {
    _client?.close(force: true);
    _client = null;
  }

  Future<void> remove() async {
    await _channel.invokeMethod('removeKokoro');
    state = const KokoroState(KokoroStatus.notInstalled);
  }

  /// Speaks a line with [voice]; completes when it has been said (or stopped).
  Future<void> sample(KokoroVoice voice, String text) =>
      _channel.invokeMethod('kokoroSample', {'speaker': voice.speaker, 'text': text, 'language': voice.language});

  Future<void> stop() => _channel.invokeMethod('stop');
}

final kokoroProvider = NotifierProvider<KokoroPack, KokoroState>(KokoroPack.new);

/// The Kokoro voice chosen for each language.
class ListenVoices {
  ListenVoices(this._store);

  final LocalStore _store;

  static String _key(String language) => 'listen.kokoro.${language.split(RegExp('[-_]')).first.toLowerCase()}';

  KokoroVoice kokoroFor(String? language) {
    final saved = _store.readJson(_key(language ?? 'en'));
    return (saved is int ? KokoroVoice.bySpeaker(saved) : null) ?? KokoroVoice.defaultFor(language);
  }

  Future<void> setKokoro(KokoroVoice voice) => _store.writeJson(_key(voice.language), voice.speaker);
}

final listenVoicesProvider = Provider<ListenVoices>((ref) => ListenVoices(ref.watch(localStoreProvider)));
