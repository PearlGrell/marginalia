import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:xml/xml.dart';

import '../storage/local_store.dart';
import '../storage/synced_setting.dart';
import 'gutenberg.dart' show CatalogException;

/// A catalog added to Discover: any OPDS 1 feed (Standard Ebooks, a Calibre or Kavita
/// server, a library). The list follows the account; logins stay on this phone.
class OpdsCatalog {
  const OpdsCatalog({required this.title, required this.url});

  factory OpdsCatalog.fromJson(Map<Object?, Object?> json) =>
      OpdsCatalog(title: json['title']! as String, url: json['url']! as String);

  final String title;
  final String url;

  Map<String, Object?> toJson() => {'title': title, 'url': url};
}

/// A way to get a book: its link and file type.
class OpdsAcquisition {
  const OpdsAcquisition(this.href, this.type);

  final Uri href;
  final String type;

  /// The file extension for [type], or null for one the library can't read.
  String? get extension => switch (type.split(';').first.trim()) {
    'application/epub+zip' => 'epub',
    _ => null,
  };
}

/// One entry in a feed: a book, or a way into another feed (a genre, "New", an author).
class OpdsEntry {
  const OpdsEntry({
    required this.id,
    required this.title,
    this.author,
    this.summary,
    this.cover,
    this.thumbnail,
    this.acquisitions = const [],
    this.feed,
  });

  final String id;
  final String title;
  final String? author;
  final String? summary;
  final Uri? cover;
  final Uri? thumbnail;
  final List<OpdsAcquisition> acquisitions;

  /// For a navigation entry: the feed it leads to.
  final Uri? feed;

  bool get isBook => acquisitions.isNotEmpty;

  /// The edition to download: the first the library can read.
  OpdsAcquisition? get readable => acquisitions.where((a) => a.extension != null).firstOrNull;
}

/// A page of a catalog.
class OpdsFeed {
  const OpdsFeed({required this.title, required this.entries, this.next, this.search});

  /// Reads an OPDS 1 (Atom) feed fetched from [base].
  factory OpdsFeed.parse(String xml, Uri base) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(xml);
    } on XmlException {
      throw CatalogException("That address isn't an OPDS catalog.");
    }
    final feed = doc.rootElement;
    if (feed.name.local != 'feed') throw CatalogException("That address isn't an OPDS catalog.");

    Uri? link(XmlElement parent, bool Function(String rel, String type) test) {
      for (final l in parent.childElements.where((e) => e.name.local == 'link')) {
        final href = l.getAttribute('href');
        if (href != null && test(l.getAttribute('rel') ?? '', l.getAttribute('type') ?? '')) {
          return base.resolve(href);
        }
      }
      return null;
    }

    String? text(XmlElement parent, String name) {
      final e = parent.childElements.where((c) => c.name.local == name).firstOrNull;
      final value = e?.innerText.replaceAll(RegExp(r'\s+'), ' ').trim();
      return value == null || value.isEmpty ? null : value;
    }

    final entries = <OpdsEntry>[];
    for (final e in feed.childElements.where((c) => c.name.local == 'entry')) {
      final acquisitions = [
        for (final l in e.childElements.where((c) => c.name.local == 'link'))
          if ((l.getAttribute('rel') ?? '').startsWith('http://opds-spec.org/acquisition') &&
              l.getAttribute('href') != null)
            OpdsAcquisition(base.resolve(l.getAttribute('href')!), l.getAttribute('type') ?? ''),
      ];
      final authors = [
        for (final a in e.childElements.where((c) => c.name.local == 'author')) ?text(a, 'name'),
      ];
      entries.add(
        OpdsEntry(
          id: text(e, 'id') ?? text(e, 'title') ?? '${entries.length}',
          title: text(e, 'title') ?? 'Untitled',
          author: authors.isEmpty ? null : authors.join(', '),
          summary: text(e, 'summary') ?? text(e, 'content'),
          cover: link(e, (rel, _) => rel == 'http://opds-spec.org/image' || rel == 'http://opds-spec.org/cover'),
          thumbnail: link(e, (rel, _) => rel == 'http://opds-spec.org/image/thumbnail' || rel == 'http://opds-spec.org/thumbnail'),
          acquisitions: acquisitions,
          feed: acquisitions.isNotEmpty
              ? null
              : link(e, (rel, type) => type.contains('application/atom+xml') && !rel.contains('image')),
        ),
      );
    }
    return OpdsFeed(
      title: text(feed, 'title') ?? 'Catalog',
      entries: entries,
      next: link(feed, (rel, _) => rel == 'next'),
      search: link(feed, (rel, _) => rel == 'search'),
    );
  }

  final String title;
  final List<OpdsEntry> entries;

  /// The next page, if there is one.
  final Uri? next;

  /// Searching: an OpenSearch description, or a URL template with `{searchTerms}`.
  final Uri? search;
}

/// The search URL template in an OpenSearch description, for Atom results.
String? openSearchTemplate(String xml) {
  try {
    final urls = XmlDocument.parse(xml).findAllElements('Url');
    final atom = urls.where((u) => (u.getAttribute('type') ?? '').contains('atom')).firstOrNull ?? urls.firstOrNull;
    return atom?.getAttribute('template');
  } on XmlException {
    return null;
  }
}

/// [template] (OpenSearch: `…?q={searchTerms}&page={startPage?}`) filled in for [query],
/// against [base]; optional parameters are left empty.
Uri fillSearchTemplate(String template, String query, Uri base) {
  final braces = template.replaceAll('%7B', '{').replaceAll('%7D', '}').replaceAll('%7b', '{').replaceAll('%7d', '}');
  final filled = braces
      .replaceAll(RegExp(r'\{searchTerms\??\}'), Uri.encodeQueryComponent(query))
      .replaceAll(RegExp(r'\{[^}]*\}'), '');
  return base.resolve(filled);
}

/// Fetches OPDS feeds and books, with the login for each catalog that has one.
class OpdsClient {
  OpdsClient(this._logins);

  final Map<String, ({String user, String password})> Function() _logins;
  static const _timeout = Duration(seconds: 25);

  final _client = HttpClient()
    ..userAgent = 'Marginalia/1.0 (Android EPUB reader)'
    ..connectionTimeout = const Duration(seconds: 15);

  Future<HttpClientResponse> _open(Uri uri) async {
    final request = await _client.getUrl(uri).timeout(_timeout);
    request.headers.set(HttpHeaders.acceptHeader, 'application/atom+xml, application/xml, */*');
    for (final MapEntry(key: prefix, value: login) in _logins().entries) {
      if (uri.toString().startsWith(Uri.parse(prefix).origin)) {
        final token = base64.encode(utf8.encode('${login.user}:${login.password}'));
        request.headers.set(HttpHeaders.authorizationHeader, 'Basic $token');
        break;
      }
    }
    final response = await request.close().timeout(_timeout);
    if (response.statusCode == HttpStatus.unauthorized) throw CatalogException('This catalog needs a login.');
    if (response.statusCode != HttpStatus.ok) throw CatalogException('The catalog answered ${response.statusCode}.');
    return response;
  }

  Future<String> _text(Uri uri) async {
    try {
      final response = await _open(uri);
      return await response.transform(utf8.decoder).join().timeout(_timeout);
    } on CatalogException {
      rethrow;
    } catch (_) {
      throw CatalogException("Can't reach the catalog. Check the address and your connection.");
    }
  }

  Future<OpdsFeed> feed(Uri uri) async => OpdsFeed.parse(await _text(uri), uri);

  /// Searches [feed]'s catalog for [query]; null if it can't be searched.
  Future<OpdsFeed?> search(OpdsFeed feed, String query) async {
    final link = feed.search;
    if (link == null) return null;
    var template = link.toString();
    if (!template.toLowerCase().contains('searchterms')) {
      // An OpenSearch description, which holds the template.
      template = openSearchTemplate(await _text(link)) ?? '';
      if (template.isEmpty) return null;
    }
    return this.feed(fillSearchTemplate(template, query, link));
  }

  /// Downloads [book] to a temporary file, reporting progress from 0 to 1.
  Future<File> download(OpdsAcquisition book, {void Function(double)? onProgress}) async {
    final extension = book.extension;
    if (extension == null) throw CatalogException('There is no edition of this book the library can open.');
    try {
      final response = await _open(book.href);
      final file = File('${(await getTemporaryDirectory()).path}/opds-${DateTime.now().microsecondsSinceEpoch}.$extension');
      final sink = file.openWrite();
      final total = response.contentLength;
      var received = 0;
      await for (final chunk in response.timeout(_timeout)) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }
      await sink.close();
      return file;
    } on CatalogException {
      rethrow;
    } catch (_) {
      throw CatalogException("The download didn't finish. Check your connection.");
    }
  }
}

/// The catalogs added to Discover.
class OpdsCatalogs extends Notifier<List<OpdsCatalog>> {
  static const _loginsKey = 'discover.catalogLogins';

  @override
  List<OpdsCatalog> build() {
    final saved = SyncedSetting.catalogs.read(ref.read(localStoreProvider));
    return [
      if (saved is List)
        for (final c in saved)
          if (c is Map && c['url'] is String && c['title'] is String) OpdsCatalog.fromJson(c),
    ];
  }

  Future<void> add(OpdsCatalog catalog, {String? user, String? password}) async {
    state = [...state.where((c) => c.url != catalog.url), catalog];
    await _save();
    if (user != null && user.isNotEmpty) {
      final store = ref.read(localStoreProvider);
      final logins = Map<String, Object?>.from(store.readJson(_loginsKey) as Map? ?? const {});
      logins[catalog.url] = {'user': user, 'password': password ?? ''};
      await store.writeJson(_loginsKey, logins);
    }
  }

  Future<void> remove(OpdsCatalog catalog) async {
    state = state.where((c) => c.url != catalog.url).toList();
    await _save();
    final store = ref.read(localStoreProvider);
    final logins = Map<String, Object?>.from(store.readJson(_loginsKey) as Map? ?? const {})..remove(catalog.url);
    await store.writeJson(_loginsKey, logins);
  }

  Future<void> _save() =>
      SyncedSetting.catalogs.write(ref.read(localStoreProvider), [for (final c in state) c.toJson()]);

  /// Logins by catalog address, kept on this phone only.
  Map<String, ({String user, String password})> logins() {
    final saved = ref.read(localStoreProvider).readJson(_loginsKey);
    return {
      if (saved is Map)
        for (final MapEntry(:key, :value) in saved.entries)
          if (value is Map) '$key': (user: '${value['user'] ?? ''}', password: '${value['password'] ?? ''}'),
    };
  }
}

final opdsCatalogsProvider = NotifierProvider<OpdsCatalogs, List<OpdsCatalog>>(OpdsCatalogs.new);

final opdsClientProvider = Provider<OpdsClient>(
  (ref) => OpdsClient(() => ref.read(opdsCatalogsProvider.notifier).logins()),
);

final opdsFeedProvider = FutureProvider.family<OpdsFeed, String>(
  (ref, url) => ref.watch(opdsClientProvider).feed(Uri.parse(url)),
);

/// Catalogs worth knowing about, offered when adding one.
const suggestedCatalogs = [
  OpdsCatalog(title: 'Standard Ebooks', url: 'https://standardebooks.org/feeds/opds'),
  OpdsCatalog(title: 'Feedbooks public domain', url: 'https://catalog.feedbooks.com/catalog/public_domain.atom'),
];
