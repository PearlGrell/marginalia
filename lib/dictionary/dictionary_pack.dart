import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:xml/xml_events.dart';

enum PackStatus { notInstalled, downloading, building, installed, failed }

class PackState {
  const PackState(this.status, {this.progress, this.error});

  final PackStatus status;

  /// 0 to 1 while downloading or building.
  final double? progress;
  final String? error;

  bool get busy => status == PackStatus.downloading || status == PackStatus.building;
}

/// The English dictionary, downloaded on request rather than shipped in the app: Open
/// English WordNet (CC BY 4.0) from its official release, built into a SQLite lookup table
/// on the phone. Senses are grouped by part of speech (noun, verb, adjective, adverb), with
/// examples and synonyms.
class DictionaryPack extends Notifier<PackState> {
  static const source =
      'https://github.com/globalwordnet/english-wordnet/releases/download/2025-edition/english-wordnet-2025.xml.gz';
  static const downloadSizeLabel = '11 MB';
  static const _fileName = 'dictionary-en-oewn-2025.sqlite';

  static Future<File> file() async =>
      File('${(await getApplicationSupportDirectory()).path}/$_fileName');

  @override
  PackState build() {
    unawaited(_check());
    return const PackState(PackStatus.notInstalled);
  }

  Future<void> _check() async {
    if (await (await file()).exists()) state = const PackState(PackStatus.installed);
  }

  Future<void> install() async {
    if (state.busy) return;
    final target = await file();
    final temp = await getTemporaryDirectory();
    final download = File('${temp.path}/oewn.xml.gz');
    try {
      state = const PackState(PackStatus.downloading, progress: 0);
      final client = HttpClient()..userAgent = 'Marginalia/1.0 (Android EPUB reader)';
      final request = await client.getUrl(Uri.parse(source));
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) throw HttpException('HTTP ${response.statusCode}');
      final total = response.contentLength;
      var received = 0;
      final sink = download.openWrite();
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) state = PackState(PackStatus.downloading, progress: received / total);
      }
      await sink.close();
      client.close();

      state = const PackState(PackStatus.building, progress: 0);
      final building = '${target.path}.part';
      final progress = ReceivePort();
      final done = Completer<void>();
      progress.listen((message) {
        if (message is double) {
          state = PackState(PackStatus.building, progress: message);
        } else if (message is String) {
          done.completeError(StateError(message));
        } else {
          done.complete();
        }
      });
      await Isolate.spawn(_buildEntry, (download.path, building, progress.sendPort));
      await done.future;
      progress.close();
      await File(building).rename(target.path);
      state = const PackState(PackStatus.installed);
    } catch (e) {
      state = PackState(PackStatus.failed, error: "The dictionary couldn't be downloaded. Check your connection.");
    } finally {
      if (await download.exists()) await download.delete();
    }
  }

  Future<void> remove() async {
    final f = await file();
    if (await f.exists()) await f.delete();
    state = const PackState(PackStatus.notInstalled);
  }
}

final dictionaryPackProvider = NotifierProvider<DictionaryPack, PackState>(DictionaryPack.new);

void _buildEntry((String, String, SendPort) args) async {
  final (source, target, port) = args;
  try {
    await buildDictionary(source, target, onProgress: port.send);
    port.send(null);
  } catch (e) {
    port.send('$e');
  }
}

/// Builds the lookup database from the WordNet LMF XML (gzipped):
///
///     entries(id, lemma, pos)            one per word and part of speech
///     forms(form, entry)                 lookup keys, lowercased, irregular forms included
///     senses(entry, rank, synset)        meanings, most common first
///     synsets(id, definition, examples)  examples joined by newlines
Future<void> buildDictionary(String gzPath, String dbPath, {void Function(double)? onProgress}) async {
  final out = File(dbPath);
  if (out.existsSync()) out.deleteSync();
  final db = sqlite3.open(dbPath);
  try {
    db.execute('''
      PRAGMA journal_mode = OFF;
      PRAGMA synchronous = OFF;
      CREATE TABLE entries (id INTEGER PRIMARY KEY, lemma TEXT NOT NULL, pos TEXT NOT NULL);
      CREATE TABLE forms (form TEXT NOT NULL, entry INTEGER NOT NULL);
      CREATE TABLE senses (entry INTEGER NOT NULL, rank INTEGER NOT NULL, synset INTEGER NOT NULL);
      CREATE TABLE synsets (id INTEGER PRIMARY KEY, definition TEXT NOT NULL, examples TEXT);
      BEGIN;
    ''');
    final insertEntry = db.prepare('INSERT INTO entries VALUES (?, ?, ?)');
    final insertForm = db.prepare('INSERT INTO forms VALUES (?, ?)');
    final insertSense = db.prepare('INSERT INTO senses VALUES (?, ?, ?)');
    final insertSynset = db.prepare('INSERT INTO synsets VALUES (?, ?, ?)');

    final synsetIds = <String, int>{};
    int synsetId(String name) => synsetIds.putIfAbsent(name, () => synsetIds.length + 1);

    // Current element state.
    var entryId = 0;
    String? lemma;
    String? pos;
    final forms = <String>{};
    final senses = <String>[];
    String? synset;
    final definition = StringBuffer();
    final examples = <String>[];
    StringBuffer? text;

    final compressed = File(gzPath);
    final total = compressed.lengthSync();
    var read = 0;
    var lastReported = 0.0;
    final bytes = compressed.openRead().map((chunk) {
      read += chunk.length;
      final p = read / total;
      if (p - lastReported > 0.01) {
        lastReported = p;
        onProgress?.call(p);
      }
      return chunk;
    });

    await for (final events in bytes.transform(gzip.decoder).transform(utf8.decoder).toXmlEvents()) {
      for (final event in events) {
        if (event is XmlStartElementEvent) {
          String? attr(String name) =>
              event.attributes.where((a) => a.name == name).firstOrNull?.value;
          switch (event.name) {
            case 'LexicalEntry':
              lemma = null;
              pos = null;
              forms.clear();
              senses.clear();
            case 'Lemma':
              lemma = attr('writtenForm');
              pos = attr('partOfSpeech');
            case 'Form':
              final f = attr('writtenForm');
              if (f != null) forms.add(f.toLowerCase());
            case 'Sense':
              final s = attr('synset');
              if (s != null) senses.add(s);
            case 'Synset':
              synset = attr('id');
              definition.clear();
              examples.clear();
            case 'Definition' || 'Example':
              if (!event.isSelfClosing) text = StringBuffer();
          }
        } else if (event is XmlTextEvent) {
          text?.write(event.value);
        } else if (event is XmlCDATAEvent) {
          text?.write(event.value);
        } else if (event is XmlEndElementEvent) {
          switch (event.name) {
            case 'Definition':
              definition.write(text?.toString().trim() ?? '');
              text = null;
            case 'Example':
              final e = text?.toString().trim() ?? '';
              if (e.isNotEmpty) examples.add(e);
              text = null;
            case 'LexicalEntry':
              if (lemma != null && pos != null) {
                entryId++;
                insertEntry.execute([entryId, lemma, pos]);
                for (final f in {lemma.toLowerCase(), ...forms}) {
                  insertForm.execute([f, entryId]);
                }
                for (final (rank, s) in senses.indexed) {
                  insertSense.execute([entryId, rank, synsetId(s)]);
                }
              }
            case 'Synset':
              if (synset != null) {
                insertSynset.execute([
                  synsetId(synset),
                  definition.toString(),
                  examples.isEmpty ? null : examples.join('\n'),
                ]);
              }
          }
        }
      }
    }

    for (final s in [insertEntry, insertForm, insertSense, insertSynset]) {
      s.close();
    }
    db.execute('''
      COMMIT;
      CREATE INDEX forms_form ON forms (form);
      CREATE INDEX senses_entry ON senses (entry);
      CREATE INDEX senses_synset ON senses (synset);
    ''');
    onProgress?.call(1);
  } finally {
    db.close();
  }
}
