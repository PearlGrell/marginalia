import 'package:flutter_test/flutter_test.dart';
import 'package:marginalia/data/library.dart';

void main() {
  test('titles sort without a leading article', () {
    expect(sortableTitle('The Hobbit'), 'hobbit');
    expect(sortableTitle('A Tale of Two Cities'), 'tale of two cities');
    expect(sortableTitle('Anathem'), 'anathem');
  });

  test('authors sort by surname', () {
    expect(sortableAuthor(['Lewis Carroll']), 'carroll, lewis');
    expect(sortableAuthor(['J. R. R. Tolkien', 'Christopher Tolkien']), 'tolkien, j. r. r.');
    expect(sortableAuthor(['Austen, Jane']), 'austen, jane');
    expect(sortableAuthor(['Homer']), 'homer');
  });

  test('books without an author sort last', () {
    expect(sortableAuthor([]).compareTo(sortableAuthor(['Zola'])), greaterThan(0));
  });
}
