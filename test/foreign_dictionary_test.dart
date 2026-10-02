import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marginalia/dictionary/foreign_dictionary.dart';
import 'package:sqlite3/sqlite3.dart';

/// dictd's own base64 for numbers.
String _num(int n) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  if (n == 0) return 'A';
  var s = '';
  while (n > 0) {
    s = alphabet[n % 64] + s;
    n ~/= 64;
  }
  return s;
}

void main() {
  test('dictd numbers', () {
    expect(dictdNumber('A'), 0);
    expect(dictdNumber('B'), 1);
    expect(dictdNumber('BA'), 64);
    expect(dictdNumber(_num(123456)), 123456);
  });

  test('a FreeDict release builds into a lookup table', () {
    final entries = {
      '00-database-info': 'This is a test dictionary.',
      'Haus': 'Haus /haʊs/ <n, neut>\nhouse; home',
      'Straße': 'Straße /ʃtʁaːsə/ <n, fem>\nstreet; road',
    };
    final dict = BytesBuilder();
    final index = StringBuffer();
    for (final MapEntry(:key, :value) in entries.entries) {
      final bytes = utf8.encode('$value\n');
      index.writeln('$key\t${_num(dict.length)}\t${_num(bytes.length)}');
      dict.add(bytes);
    }
    final archive = Archive()
      ..addFile(ArchiveFile.bytes('deu-eng/deu-eng.index', utf8.encode(index.toString())))
      ..addFile(ArchiveFile.bytes('deu-eng/deu-eng.dict.dz', gzip.encode(dict.takeBytes())));
    final dir = Directory.systemTemp.createTempSync('freedict');
    final source = File('${dir.path}/deu-eng.tar.xz')
      ..writeAsBytesSync(XZEncoder().encodeBytes(TarEncoder().encodeBytes(archive)));
    final target = '${dir.path}/deu.sqlite';

    buildFreeDict(source.path, target);

    final db = sqlite3.open(target);
    final rows = db.select('SELECT key, headword, definition FROM entries ORDER BY key');
    expect([for (final r in rows) r['key']], ['haus', 'straße']);
    final entry = ForeignEntry(headword: rows.first['headword'] as String, text: rows.first['definition'] as String);
    expect(entry.heading, 'Haus /haʊs/ <n, neut>');
    expect(entry.body, 'house; home');
    db.close();
    dir.deleteSync(recursive: true);
  });

  test('the catalogue keeps X → English dictd releases', () {
    final packs = FreeDictPack.fromCatalogue([
      {
        'name': 'deu-eng',
        'headwords': '517534',
        'releases': [
          {'platform': 'stardict', 'URL': 'x.stardict', 'size': '1'},
          {'platform': 'dictd', 'URL': 'https://x/deu-eng.dictd.tar.xz', 'size': '20967808', 'version': '1.9'},
        ],
      },
      {'name': 'eng-deu', 'releases': [{'platform': 'dictd', 'URL': 'y', 'size': '1'}]},
      {'name': 'kha-eng', 'releases': [{'platform': 'src', 'URL': 'z', 'size': '1'}]},
    ]);
    expect(packs.single.code, 'de');
    expect(packs.single.language, 'German');
    expect(packs.single.sizeLabel, '20.0 MB');
  });
}
