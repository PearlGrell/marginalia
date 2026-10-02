import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marginalia/settings/library_export.dart';

void main() {
  test('the zip holds the files and texts under their names', () {
    final dir = Directory.systemTemp.createTempSync('export');
    final epub = File('${dir.path}/abc.epub')..writeAsBytesSync(List.generate(5000, (i) => i % 251));
    final zip = '${dir.path}/out.zip';

    writeZip(zip, [(epub.path, 'books/Emma - Jane Austen.epub')], [('library.json', '{"books": []}'), ('notes/Emma.md', '# Emma')]);

    final archive = ZipDecoder().decodeBytes(File(zip).readAsBytesSync());
    final names = [for (final f in archive.files) f.name];
    expect(names, containsAll(['books/Emma - Jane Austen.epub', 'library.json', 'notes/Emma.md']));
    final book = archive.files.firstWhere((f) => f.name.endsWith('.epub'));
    expect(book.content, epub.readAsBytesSync());
    expect(String.fromCharCodes(archive.files.firstWhere((f) => f.name == 'notes/Emma.md').content), '# Emma');
    dir.deleteSync(recursive: true);
  });
}
