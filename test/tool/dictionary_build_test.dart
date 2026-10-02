import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marginalia/dictionary/dictionary_pack.dart';
import 'package:sqlite3/sqlite3.dart';

/// Builds the dictionary from a local copy of the WordNet release, when one is given:
///   OEWN_XML_GZ=path/to/english-wordnet-2025.xml.gz flutter test test/tool
void main() {
  final source = Platform.environment['OEWN_XML_GZ'];
  test('builds the lookup database', () async {
    final out = '${Directory.systemTemp.path}/oewn-test.sqlite';
    await buildDictionary(source!, out);
    final db = sqlite3.open(out);
    expect(db.select('SELECT count(*) AS n FROM entries').first['n'], greaterThan(130000));
    expect(db.select('SELECT count(*) AS n FROM synsets').first['n'], greaterThan(100000));
    final ran = db.select(
      'SELECT e.lemma, e.pos FROM forms f JOIN entries e ON e.id = f.entry WHERE f.form = ?',
      ['ran'],
    );
    expect(ran.map((r) => r['lemma']), contains('run'));
    final melancholy = db.select(
      'SELECT DISTINCT e.pos FROM forms f JOIN entries e ON e.id = f.entry WHERE f.form = ?',
      ['melancholy'],
    );
    expect(melancholy.map((r) => r['pos']).toSet(), containsAll(['n', 'a']));
    db.close();
  }, skip: source == null ? 'Set OEWN_XML_GZ to run' : false, timeout: const Timeout(Duration(minutes: 5)));
}
