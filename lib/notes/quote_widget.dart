import '../data/database.dart';

/// The highlights the home-screen highlight widget chooses from, a different one each day:
/// the newest [limit] that read well on their own (not a word or two, not a page), each with
/// its book's title and where it is, for opening the book there.
List<Map<String, Object?>> widgetQuotes(List<Annotation> notes, Map<String, Book> books, {int limit = 60}) => [
  for (final a in notes)
    if (!a.deleted && a.type != AnnotationType.bookmark)
      if (a.selectedText?.trim() case final text? when text.length >= 30 && text.length <= 280)
        if (books[a.bookId] case final book? when !book.deleted)
          {'text': text.replaceAll(RegExp(r'\s+'), ' '), 'title': book.title, 'bookId': a.bookId, 'locator': a.locator},
].take(limit).toList();
