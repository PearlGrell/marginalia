import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';

import '../cloud/account.dart';
import '../cloud/sync_screen.dart' show AppMark;
import '../data/database.dart';
import '../data/library.dart';
import '../reader/reader_sheets.dart';
import '../theme/tokens.dart';
import 'app_settings.dart';
import 'library_export.dart';

/// Set by `scripts/deploy-to-phone.ps1`, so you can tell which build is installed.
const _buildStamp = String.fromEnvironment('BUILD_STAMP', defaultValue: 'dev');

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final themeMode = ref.watch(appThemeModeProvider);
    final text = Theme.of(context).textTheme;

    Widget section(String title) => Padding(
      padding: const EdgeInsets.fromLTRB(Space.gutter, Space.xl, Space.gutter, Space.sm),
      child: Text(title.toUpperCase(), style: text.labelSmall),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xxxl),
        children: [
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            leading: account.account?.photoUrl == null
                ? const CircleAvatar(child: Icon(Icons.person_outline))
                : CircleAvatar(backgroundImage: NetworkImage(account.account!.photoUrl!)),
            title: Text(account.account?.name ?? 'Account and sync'),
            subtitle: Text(
              !account.configured
                  ? 'Sync is not set up in this build'
                  : account.signedIn
                  ? account.account!.email ?? 'Signed in'
                  : 'Sign in to sync across devices',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/account'),
          ),

          if (account.signedIn)
            _NavTile(
              icon: Icons.ios_share,
              title: 'Shared by you',
              subtitle: 'Books and collections you have shared, and stopping them',
              onTap: () => context.push('/settings/shared'),
            ),

          section('Appearance'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            child: SegmentedButton<ThemeMode>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: ThemeMode.system, label: Text('Match phone')),
                ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
              ],
              selected: {themeMode},
              onSelectionChanged: (s) => ref.read(appThemeModeProvider.notifier).set(s.first),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, 0),
            child: Text(
              'The app around your books. Pages have their own themes under Reading.',
              style: text.bodySmall,
            ),
          ),

          section('Reading'),
          _NavTile(
            icon: Icons.text_fields,
            title: 'Page, type and turning',
            subtitle: 'Themes, fonts, spacing, page turns, volume keys',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  appBar: AppBar(title: const Text('Reading')),
                  body: const ReaderSettingsList(inSheet: false),
                ),
              ),
            ),
          ),

          _NavTile(
            icon: Icons.insights_outlined,
            title: 'Your reading',
            subtitle: 'Time read, streaks, and a recap to share',
            onTap: () => context.push('/stats'),
          ),

          section('Downloads'),
          _NavTile(
            icon: Icons.download_outlined,
            title: 'Dictionary, translation and voices',
            subtitle: 'Add or remove what works offline',
            onTap: () => context.push('/settings/downloads'),
          ),

          section('Library'),
          _NavTile(
            icon: Icons.folder_special_outlined,
            title: 'Watched folders',
            subtitle: 'New EPUBs in these folders join your library',
            onTap: () => context.push('/settings/folders'),
          ),
          _NavTile(
            icon: Icons.archive_outlined,
            title: 'Export everything',
            subtitle: 'Books, covers, notes and reading history in one zip',
            onTap: () => exportLibrary(context, ref),
          ),

          section('Storage'),
          const _StorageSection(),

          section('About'),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            leading: const AppMark(size: 40),
            title: const Text('Marginalia'),
            subtitle: const Text('Build $_buildStamp · licenses and credits'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showLicensePage(
              applicationIcon: const Padding(
                padding: EdgeInsets.all(Space.md),
                child: AppMark(size: 72),
              ),
              context: context,
              applicationName: 'Marginalia',
              applicationVersion: 'Build $_buildStamp',
              applicationLegalese:
                  'Books from Project Gutenberg. Dictionary: Open English WordNet (CC BY 4.0). '
                  'Translation: Google ML Kit. Fonts: Fraunces, IBM Plex Sans, Literata, '
                  'Source Serif 4, EB Garamond, Atkinson Hyperlegible (SIL Open Font License). '
                  'Rendering: Readium.',
            ),
          ),
        ],
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({required this.icon, required this.title, required this.subtitle, required this.onTap});

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: Space.gutter),
    leading: Icon(icon),
    title: Text(title),
    subtitle: Text(subtitle),
    trailing: const Icon(Icons.chevron_right),
    onTap: onTap,
  );
}

/// What the app takes up on the phone, and clearing what can be fetched again.
class _StorageSection extends ConsumerStatefulWidget {
  const _StorageSection();

  @override
  ConsumerState<_StorageSection> createState() => _StorageSectionState();
}

class _StorageSectionState extends ConsumerState<_StorageSection> {
  Future<({int library, int downloaded, int covers, int other})>? _sizes;

  @override
  void initState() {
    super.initState();
    _sizes = _measure();
  }

  static Future<int> _size(String path) async {
    final entity = Directory(path);
    if (!await entity.exists()) return 0;
    var total = 0;
    await for (final f in entity.list(recursive: true, followLinks: false)) {
      if (f is File) total += await f.length();
    }
    return total;
  }

  /// The importer keeps books and covers in the app's files folder (path_provider's
  /// support directory on Android); Drive downloads and catalog responses are cache.
  Future<({int library, int downloaded, int covers, int other})> _measure() async {
    final files = (await getApplicationSupportDirectory()).path;
    final cache = (await getApplicationCacheDirectory()).path;
    return (
      library: await _size('$files/library'),
      downloaded: await _size('$cache/books'),
      covers: await _size('$files/covers') + await _size('$cache/covers'),
      other: await _size('$cache/gutenberg'),
    );
  }

  /// Book copies downloaded from Drive go; they download again when opened.
  Future<void> _clearDownloaded() async {
    final cache = (await getApplicationCacheDirectory()).path;
    final db = ref.read(databaseProvider);
    final books = await db.allBooks();
    for (final book in books) {
      final path = book.filePath;
      if (path == null || !path.startsWith('$cache/books') || book.driveFileId == null) continue;
      final file = File(path);
      if (await file.exists()) await file.delete();
      await db.setLocalFields(book.id, const BooksCompanion(filePath: Value(null)));
    }
    final catalog = Directory('$cache/gutenberg');
    if (await catalog.exists()) await catalog.delete(recursive: true);
    setState(() => _sizes = _measure());
  }

  static String _mb(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return FutureBuilder(
      future: _sizes,
      builder: (context, snapshot) {
        final s = snapshot.data;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                s == null
                    ? 'Measuring…'
                    : [
                        'Your books: ${_mb(s.library)}',
                        'Downloaded from Drive: ${_mb(s.downloaded)}',
                        'Covers: ${_mb(s.covers)}',
                        'Catalog cache: ${_mb(s.other)}',
                      ].join('\n'),
                style: text.bodyMedium?.copyWith(height: 1.7),
              ),
              const SizedBox(height: Space.sm),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                  onPressed: _clearDownloaded,
                  child: const Text('Clear downloaded copies'),
                ),
              ),
              Text(
                'Books stored in your Drive download again when you open them. Notes and '
                'positions stay.',
                style: text.bodySmall,
              ),
            ],
          ),
        );
      },
    );
  }
}
