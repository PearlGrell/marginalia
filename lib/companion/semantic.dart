import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'retrieval.dart';

/// The text embedder (MediaPipe's Universal Sentence Encoder, 6 MB): turns a passage into a
/// vector, so passages can be found by what they mean, not only the words they share with a
/// question. Downloaded once, quietly, the first time the companion opens; run on the phone.
class TextEmbedderModel {
  const TextEmbedderModel();

  static const _channel = MethodChannel('marginalia/companion');
  static const url =
      'https://storage.googleapis.com/mediapipe-models/text_embedder/universal_sentence_encoder/float32/1/'
      'universal_sentence_encoder.tflite';

  /// Names the vectors it makes: a different model, and a book's are made again.
  static const name = 'use-1';

  static Future<File> file() async =>
      File('${(await getApplicationSupportDirectory()).path}/models/universal_sentence_encoder.tflite');

  static Future<void>? _fetching;

  /// The model's file once it's here, fetching it if it isn't (null if that fails).
  Future<File?> ensure() async {
    final f = await file();
    if (await f.exists()) return f;
    await (_fetching ??= _fetch(f).whenComplete(() => _fetching = null));
    return await f.exists() ? f : null;
  }

  Future<void> _fetch(File f) async {
    final client = HttpClient()..userAgent = 'Marginalia/1.0 (Android EPUB reader)';
    try {
      await f.parent.create(recursive: true);
      final response = await (await client.getUrl(Uri.parse(url))).close();
      if (response.statusCode != HttpStatus.ok) return;
      final part = File('${f.path}.part');
      final sink = part.openWrite();
      await response.pipe(sink);
      if (response.contentLength > 0 && await part.length() != response.contentLength) return;
      await part.rename(f.path);
    } catch (_) {
      // Next time the companion opens.
    } finally {
      client.close();
    }
  }

  /// A vector for each of [texts]; null when the model isn't here or can't run.
  Future<List<Float32List>?> embed(List<String> texts) async {
    final f = await file();
    if (!await f.exists()) return null;
    try {
      final out = await _channel.invokeListMethod<Object?>('embed', {'path': f.path, 'texts': texts});
      return [for (final v in out ?? const []) v is Float32List ? v : Float32List.fromList((v! as List).cast<double>())];
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}

/// [v] scaled to length 1, for cosine similarity as a dot product.
Float32List normalized(Float32List v) {
  var sum = 0.0;
  for (final x in v) {
    sum += x * x;
  }
  final length = math.sqrt(sum);
  if (length == 0) return v;
  return Float32List.fromList([for (final x in v) x / length]);
}

double dot(Float32List a, Float32List b) {
  var sum = 0.0;
  for (var i = 0; i < math.min(a.length, b.length); i++) {
    sum += a[i] * b[i];
  }
  return sum;
}

/// A passage's key in the cache: a hash of its text (FNV-1a, 32 bits, as hex).
String passageKey(String text) {
  var hash = 0x811c9dc5;
  for (final unit in text.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16);
}

/// Two rankings as one, by reciprocal rank (a passage high in either rises; one in both rises
/// most): the usual way to join keyword and meaning search.
List<Chunk> fuseRankings(List<Chunk> a, List<Chunk> b, {int limit = 10, int k = 60}) {
  final scores = <int, double>{};
  final byIndex = <int, Chunk>{};
  for (final list in [a, b]) {
    for (final (rank, c) in list.indexed) {
      scores[c.index] = (scores[c.index] ?? 0) + 1 / (k + rank + 1);
      byIndex[c.index] = c;
    }
  }
  final order = scores.keys.toList()..sort((x, y) => scores[y]!.compareTo(scores[x]!));
  return [for (final i in order.take(limit)) byIndex[i]!];
}

/// A book's passages found by meaning: each passage's vector, made once and kept with the
/// book (`embeddings.json`), only ever for the text read so far.
class SemanticIndex {
  SemanticIndex({required this.dir, required this.index, this.model = const TextEmbedderModel()});

  /// Where the book's memory is kept.
  final String dir;
  final BookIndex index;
  final TextEmbedderModel model;

  final _vectors = <String, Float32List>{};
  Future<void>? _preparing;
  var _ready = false;

  /// Whether enough passages have vectors to search by meaning.
  bool get ready => _ready;

  File get _file => File('$dir/embeddings.json');

  /// Fetches the model if need be, then makes the vectors the passages don't have yet, a batch
  /// at a time, saving as it goes. Safe to call again: it only works once at a time.
  Future<void> prepare() => _preparing ??= _prepare().whenComplete(() => _preparing = null);

  Future<void> _prepare() async {
    await _load();
    if (await model.ensure() == null) return;
    final missing = [for (final c in index.chunks) if (!_vectors.containsKey(passageKey(c.text))) c.text];
    for (var i = 0; i < missing.length; i += 48) {
      final batch = missing.sublist(i, math.min(missing.length, i + 48));
      final vectors = await model.embed(batch);
      if (vectors == null || vectors.length != batch.length) break;
      for (final (j, v) in vectors.indexed) {
        _vectors[passageKey(batch[j])] = normalized(v);
      }
      _ready = _coverage() >= 0.9;
      if (i % (48 * 8) == 0) await _save();
    }
    _ready = _coverage() >= 0.9;
    await _save();
  }

  double _coverage() {
    if (index.chunks.isEmpty) return 0;
    final have = index.chunks.where((c) => _vectors.containsKey(passageKey(c.text))).length;
    return have / index.chunks.length;
  }

  Future<void> _load() async {
    if (_vectors.isNotEmpty || !await _file.exists()) return;
    try {
      final json = jsonDecode(await _file.readAsString()) as Map<String, Object?>;
      if (json['model'] != TextEmbedderModel.name) return;
      for (final MapEntry(:key, :value) in ((json['v'] as Map?) ?? const {}).entries) {
        final bytes = base64Decode(value as String);
        _vectors[key as String] = Float32List.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes ~/ 4);
      }
      _ready = _coverage() >= 0.9;
    } on FormatException {
      // Made again.
    }
  }

  Future<void> _save() async {
    final known = {for (final c in index.chunks) passageKey(c.text)};
    await _file.writeAsString(
      jsonEncode({
        'model': TextEmbedderModel.name,
        'v': {
          for (final MapEntry(:key, :value) in _vectors.entries)
            // Only passages of the book as it's kept now.
            if (known.contains(key)) key: base64Encode(value.buffer.asUint8List(value.offsetInBytes, value.lengthInBytes)),
        },
      }),
    );
  }

  /// The passages closest in meaning to [query], best first, with how close (cosine, -1 to
  /// 1); empty until [ready].
  Future<List<(Chunk, double)>> search(String query, {int limit = 10}) async {
    if (!_ready) return const [];
    final vectors = await model.embed([query]);
    if (vectors == null || vectors.isEmpty) return const [];
    final q = normalized(vectors.first);
    final scored = <(Chunk, double)>[
      for (final c in index.chunks)
        if (_vectors[passageKey(c.text)] case final v?) (c, dot(q, v)),
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    return scored.take(limit).toList();
  }
}
