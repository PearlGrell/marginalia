import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

/// A FreeDict dictionary from another language into English.
class FreeDictPack {
  const FreeDictPack({
    required this.code3,
    required this.language,
    required this.headwords,
    required this.bytes,
    required this.url,
    required this.version,
  });

  /// ISO 639-3, as FreeDict names it ("deu").
  final String code3;

  /// ISO 639-1 where there is one ("de"), to match books' languages.
  String get code => iso1[code3] ?? code3;
  final String language;
  final int headwords;
  final int bytes;
  final String url;
  final String version;

  String get sizeLabel => bytes < 1024 * 1024
      ? '${(bytes / 1024).ceil()} KB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

  static const iso1 = {
    'afr': 'af', 'ara': 'ar', 'cat': 'ca', 'ces': 'cs', 'cym': 'cy', 'dan': 'da', 'deu': 'de', //
    'ell': 'el', 'epo': 'eo', 'fin': 'fi', 'fra': 'fr', 'gle': 'ga', 'hrv': 'hr', 'hun': 'hu',
    'isl': 'is', 'ita': 'it', 'jpn': 'ja', 'kur': 'ku', 'lat': 'la', 'lit': 'lt', 'nld': 'nl',
    'pol': 'pl', 'por': 'pt', 'rus': 'ru', 'slk': 'sk', 'slv': 'sl', 'spa': 'es', 'srp': 'sr',
    'swe': 'sv', 'swh': 'sw', 'tur': 'tr',
  };

  static const names = {
    'afr': 'Afrikaans', 'ara': 'Arabic', 'cat': 'Catalan', 'ces': 'Czech', 'cym': 'Welsh', //
    'dan': 'Danish', 'deu': 'German', 'ell': 'Greek', 'epo': 'Esperanto', 'fin': 'Finnish',
    'fra': 'French', 'gle': 'Irish', 'hrv': 'Croatian', 'hun': 'Hungarian', 'isl': 'Icelandic',
    'ita': 'Italian', 'jpn': 'Japanese', 'kha': 'Khasi', 'kur': 'Kurdish', 'lat': 'Latin',
    'lit': 'Lithuanian', 'nld': 'Dutch', 'pol': 'Polish', 'por': 'Portuguese', 'rus': 'Russian',
    'slk': 'Slovak', 'slv': 'Slovenian', 'spa': 'Spanish', 'srp': 'Serbian', 'swe': 'Swedish',
    'swh': 'Swahili', 'tur': 'Turkish',
  };

  /// The X → English dictionaries in FreeDict's catalogue that come in dictd format.
  static List<FreeDictPack> fromCatalogue(List<dynamic> catalogue) {
    final packs = <FreeDictPack>[];
    for (final item in catalogue.whereType<Map<String, dynamic>>()) {
      final name = item['name'] as String? ?? '';
      if (!name.endsWith('-eng') || name == 'eng-eng') continue;
      final release = (item['releases'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .where((r) => r['platform'] == 'dictd')
          .firstOrNull;
      if (release == null) continue;
      final code3 = name.substring(0, name.length - 4);
      packs.add(
        FreeDictPack(
          code3: code3,
          language: names[code3] ?? code3,
          headwords: int.tryParse('${item['headwords']}') ?? 0,
          bytes: int.tryParse('${release['size']}') ?? 0,
          url: release['URL'] as String,
          version: release['version'] as String? ?? '',
        ),
      );
    }
    return packs..sort((a, b) => a.language.compareTo(b.language));
  }
}

Future<Directory> _dir() async {
  final dir = Directory('${(await getApplicationSupportDirectory()).path}/dictionaries');
  await dir.create(recursive: true);
  return dir;
}

Future<File> _packFile(String code3) async => File('${(await _dir()).path}/freedict-$code3-eng.sqlite');

/// FreeDict's catalogue, kept for a week.
final freeDictCatalogueProvider = FutureProvider<List<FreeDictPack>>((ref) async {
  final cache = File('${(await _dir()).path}/freedict-database.json');
  Future<List<FreeDictPack>> parse(String json) async => FreeDictPack.fromCatalogue(jsonDecode(json) as List);
  if (await cache.exists() && DateTime.now().difference(await cache.lastModified()).inDays < 7) {
    return parse(await cache.readAsString());
  }
  try {
    final client = HttpClient()..userAgent = 'Marginalia/1.0 (Android EPUB reader)';
    final response = await (await client.getUrl(Uri.parse('https://freedict.org/freedict-database.json'))).close();
    if (response.statusCode != 200) throw HttpException('HTTP ${response.statusCode}');
    final body = await response.transform(utf8.decoder).join();
    client.close();
    await cache.writeAsString(body);
    return parse(body);
  } catch (_) {
    if (await cache.exists()) return parse(await cache.readAsString());
    rethrow;
  }
});

class ForeignPacksState {
  const ForeignPacksState({this.installed = const {}, this.progress = const {}, this.errors = const {}});

  /// Installed packs by ISO 639-3 code.
  final Set<String> installed;

  /// Packs being downloaded or built, 0 to 1.
  final Map<String, double> progress;
  final Map<String, String> errors;

  ForeignPacksState copyWith({Set<String>? installed, Map<String, double>? progress, Map<String, String>? errors}) =>
      ForeignPacksState(
        installed: installed ?? this.installed,
        progress: progress ?? this.progress,
        errors: errors ?? this.errors,
      );
}

/// Dictionaries for books in other languages: downloaded from FreeDict on request and built
/// into a lookup table on the phone.
class ForeignPacks extends Notifier<ForeignPacksState> {
  @override
  ForeignPacksState build() {
    unawaited(_scan());
    return const ForeignPacksState();
  }

  Future<void> _scan() async {
    final dir = await _dir();
    final installed = <String>{
      await for (final f in dir.list())
        if (RegExp(r'freedict-([a-z]{3})-eng\.sqlite$').firstMatch(f.path) case final m?) m[1]!,
    };
    state = state.copyWith(installed: installed);
  }

  Future<void> install(FreeDictPack pack) async {
    if (state.progress.containsKey(pack.code3)) return;
    void progress(double p) => state = state.copyWith(progress: {...state.progress, pack.code3: p});
    progress(0);
    final download = File('${(await getTemporaryDirectory()).path}/freedict-${pack.code3}.tar.xz');
    try {
      final client = HttpClient()..userAgent = 'Marginalia/1.0 (Android EPUB reader)';
      final response = await (await client.getUrl(Uri.parse(pack.url))).close();
      if (response.statusCode != 200) throw HttpException('HTTP ${response.statusCode}');
      final total = response.contentLength > 0 ? response.contentLength : pack.bytes;
      var received = 0;
      final sink = download.openWrite();
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) progress(0.8 * received / total);
      }
      await sink.close();
      client.close();

      final target = await _packFile(pack.code3);
      final building = '${target.path}.part';
      final source = download.path;
      await Isolate.run(() => buildFreeDict(source, building));
      await File(building).rename(target.path);
      state = state.copyWith(
        installed: {...state.installed, pack.code3},
        progress: {...state.progress}..remove(pack.code3),
        errors: {...state.errors}..remove(pack.code3),
      );
    } catch (e) {
      state = state.copyWith(
        progress: {...state.progress}..remove(pack.code3),
        errors: {...state.errors, pack.code3: "Couldn't download it. Check your connection."},
      );
    } finally {
      if (await download.exists()) await download.delete();
    }
  }

  Future<void> remove(String code3) async {
    final file = await _packFile(code3);
    if (await file.exists()) await file.delete();
    state = state.copyWith(installed: {...state.installed}..remove(code3));
  }

  /// The installed pack for a book in [language] ("de", "de-AT", "deu"), if any.
  String? packFor(String? language) {
    if (language == null) return null;
    final base = language.split(RegExp('[-_]')).first.toLowerCase();
    for (final code3 in state.installed) {
      if (code3 == base || FreeDictPack.iso1[code3] == base) return code3;
    }
    return null;
  }
}

final foreignPacksProvider = NotifierProvider<ForeignPacks, ForeignPacksState>(ForeignPacks.new);

/// One headword's entry: its first line (the word, pronunciation, grammar) and its senses.
class ForeignEntry {
  const ForeignEntry({required this.headword, required this.text});

  final String headword;
  final String text;

  /// `Haus /haʊs/ <n, neut>`: the entry's own heading line.
  String get heading => text.split('\n').first.trim();

  /// The translations, after the heading.
  String get body {
    final lines = text.split('\n');
    return lines.skip(1).map((l) => l.trim()).where((l) => l.isNotEmpty).join('\n');
  }
}

/// A built FreeDict dictionary, opened for lookups.
class ForeignDictionary {
  ForeignDictionary._(this._db);

  final Database _db;

  static Future<ForeignDictionary?> open(String code3) async {
    final file = await _packFile(code3);
    if (!await file.exists()) return null;
    return ForeignDictionary._(sqlite3.open(file.path, mode: OpenMode.readOnly));
  }

  List<ForeignEntry> lookUp(String word) {
    final cleaned = word
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r"^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$", unicode: true), '');
    if (cleaned.isEmpty) return const [];
    return [
      for (final row in _db.select('SELECT headword, definition FROM entries WHERE key = ? LIMIT 8', [cleaned]))
        ForeignEntry(headword: row['headword'] as String, text: row['definition'] as String),
    ];
  }

  void close() => _db.close();
}

final foreignDictionaryProvider = FutureProvider.family<ForeignDictionary?, String>((ref, code3) async {
  final installed = ref.watch(foreignPacksProvider.select((s) => s.installed.contains(code3)));
  if (!installed) return null;
  final dictionary = await ForeignDictionary.open(code3);
  if (dictionary != null) ref.onDispose(dictionary.close);
  return dictionary;
});

/// Decodes a dictd index number (its own base64: A–Z, a–z, 0–9, +, /).
int dictdNumber(String s) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  var n = 0;
  for (final c in s.split('')) {
    final v = alphabet.indexOf(c);
    if (v < 0) throw FormatException('Not a dictd number: $s');
    n = n * 64 + v;
  }
  return n;
}

/// Builds a lookup table from a FreeDict dictd release (`.tar.xz` with `.index` and
/// `.dict.dz`): `entries(key, headword, definition)`, keyed by the lowercased headword.
void buildFreeDict(String tarXzPath, String dbPath) {
  final tar = TarDecoder().decodeBytes(XZDecoder().decodeBytes(File(tarXzPath).readAsBytesSync()));
  final indexFile = tar.files.where((f) => f.isFile && f.name.endsWith('.index')).firstOrNull;
  final dictFile = tar.files.where((f) => f.isFile && (f.name.endsWith('.dict.dz') || f.name.endsWith('.dict'))).firstOrNull;
  if (indexFile == null || dictFile == null) throw const FormatException('Not a dictd dictionary');
  final dictBytes = dictFile.name.endsWith('.dz') ? gzip.decode(dictFile.content) : dictFile.content;
  final index = utf8.decode(indexFile.content, allowMalformed: true);

  final out = File(dbPath);
  if (out.existsSync()) out.deleteSync();
  final db = sqlite3.open(dbPath);
  try {
    db.execute('''
      PRAGMA journal_mode = OFF;
      PRAGMA synchronous = OFF;
      CREATE TABLE entries (key TEXT NOT NULL, headword TEXT NOT NULL, definition TEXT NOT NULL);
      BEGIN;
    ''');
    final insert = db.prepare('INSERT INTO entries VALUES (?, ?, ?)');
    for (final line in const LineSplitter().convert(index)) {
      final parts = line.split('\t');
      if (parts.length < 3) continue;
      final headword = parts[0];
      // FreeDict's own information entries.
      if (headword.startsWith('00-database') || headword.startsWith('00database')) continue;
      final offset = dictdNumber(parts[1]);
      final length = dictdNumber(parts[2]);
      if (offset + length > dictBytes.length) continue;
      final definition = utf8.decode(dictBytes.sublist(offset, offset + length), allowMalformed: true).trim();
      insert.execute([headword.toLowerCase(), headword, definition]);
    }
    insert.close();
    db.execute('''
      COMMIT;
      CREATE INDEX entries_key ON entries (key);
    ''');
  } finally {
    db.close();
  }
}
