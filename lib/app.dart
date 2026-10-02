import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'cloud/account.dart';
import 'cloud/account_screen.dart';
import 'cloud/devices_screen.dart';
import 'cloud/drive_books_screen.dart';
import 'cloud/sync_screen.dart';
import 'cloud/sync_service.dart';
import 'discover/catalog_book_screen.dart';
import 'discover/discover_screen.dart';
import 'data/database.dart';
import 'data/library.dart';
import 'library/book_detail_screen.dart';
import 'library/collections_screen.dart';
import 'library/edit_book_screen.dart';
import 'library/library_screen.dart';
import 'library/watched_folders.dart';
import 'notes/notes_screen.dart';
import 'reader/reader_screen.dart';
import 'theme/app_theme.dart';
import 'settings/app_settings.dart';
import 'settings/downloads_screen.dart';
import 'settings/settings_screen.dart';
import 'share/quote_screen.dart';
import 'stats/stats_screen.dart';
import 'share/shared_screens.dart';
import 'theme/system_bars.dart';
import 'words/review_screen.dart';

final _rootNavigator = GlobalKey<NavigatorState>();

final _router = GoRouter(
  navigatorKey: _rootNavigator,
  routes: [
    // The tabs keep their own scroll position and stacks.
    StatefulShellRoute.indexedStack(
      builder: (context, state, shell) => _Tabs(shell: shell),
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/',
              builder: (context, state) => const LibraryScreen(),
              // Opened from links and the home-screen widget too: nested here, Back from
              // them lands in the library rather than leaving the app.
              routes: [
                GoRoute(
                  path: 'read/:id',
                  parentNavigatorKey: _rootNavigator,
                  builder: (context, state) => ReaderScreen(
                    bookId: state.pathParameters['id']!,
                    at: state.uri.queryParameters['at'],
                  ),
                ),
                GoRoute(
                  path: 'share/:code',
                  parentNavigatorKey: _rootNavigator,
                  builder: (context, state) => SharedScreen(code: state.pathParameters['code']!),
                ),
                GoRoute(
                  path: 'quote/:code',
                  parentNavigatorKey: _rootNavigator,
                  builder: (context, state) => QuoteScreen(code: state.pathParameters['code']!),
                ),
              ],
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(path: '/collections', builder: (context, state) => const CollectionsScreen()),
          ],
        ),
        StatefulShellBranch(
          routes: [GoRoute(path: '/notes', builder: (context, state) => const NotesScreen())],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(path: '/discover', builder: (context, state) => const DiscoverScreen()),
          ],
        ),
      ],
    ),
    // Everything else opens full screen, above the tabs.
    GoRoute(
      path: '/discover/list',
      parentNavigatorKey: _rootNavigator,
      builder: (context, state) => CatalogListScreen(
        title: state.uri.queryParameters['title'] ?? '',
        query: state.uri.queryParameters['query'] ?? '',
      ),
    ),
    GoRoute(
      path: '/discover/book/:id',
      parentNavigatorKey: _rootNavigator,
      builder: (context, state) => CatalogBookScreen(id: int.parse(state.pathParameters['id']!)),
    ),
    GoRoute(
      path: '/book/:id',
      parentNavigatorKey: _rootNavigator,
      builder: (context, state) => BookDetailScreen(bookId: state.pathParameters['id']!),
    ),
    GoRoute(
      path: '/book/:id/edit',
      parentNavigatorKey: _rootNavigator,
      builder: (context, state) => EditBookScreen(bookId: state.pathParameters['id']!),
    ),
    GoRoute(
      path: '/collections/:id',
      parentNavigatorKey: _rootNavigator,
      builder: (context, state) => CollectionScreen(collectionId: state.pathParameters['id']!),
    ),
    GoRoute(
      path: '/account',
      parentNavigatorKey: _rootNavigator,
      builder: (context, state) => const AccountScreen(),
    ),
    GoRoute(
      path: '/account/drive',
      parentNavigatorKey: _rootNavigator,
      builder: (context, state) => const DriveBooksScreen(),
    ),
    GoRoute(
      path: '/account/devices',
      parentNavigatorKey: _rootNavigator,
      builder: (context, state) => const DevicesScreen(),
    ),
    GoRoute(
      path: '/settings',
      parentNavigatorKey: _rootNavigator,
      builder: (context, state) => const SettingsScreen(),
    ),
    GoRoute(
      path: '/settings/shared',
      parentNavigatorKey: _rootNavigator,
      builder: (context, state) => const SharedByYouScreen(),
    ),
    GoRoute(
      path: '/settings/folders',
      parentNavigatorKey: _rootNavigator,
      builder: (context, state) => const WatchedFoldersScreen(),
    ),
    GoRoute(
      path: '/settings/downloads',
      parentNavigatorKey: _rootNavigator,
      builder: (context, state) => const DownloadsScreen(),
    ),
    GoRoute(
      path: '/sync',
      parentNavigatorKey: _rootNavigator,
      pageBuilder: (context, state) =>
          const MaterialPage(fullscreenDialog: true, child: SyncScreen()),
    ),
    GoRoute(
      path: '/stats',
      parentNavigatorKey: _rootNavigator,
      builder: (context, state) => const StatsScreen(),
    ),
    GoRoute(
      path: '/words/review',
      parentNavigatorKey: _rootNavigator,
      builder: (context, state) => const ReviewScreen(),
    ),
  ],
);

class _Tabs extends ConsumerStatefulWidget {
  const _Tabs({required this.shell});

  final StatefulNavigationShell shell;

  @override
  ConsumerState<_Tabs> createState() => _TabsState();
}

class _TabsState extends ConsumerState<_Tabs> {
  bool _syncedThisLaunch = false;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // Changes go out shortly after the app is left.
    _lifecycle = AppLifecycleListener(
      onHide: () => ref.read(syncProvider.notifier).scheduleSoon(),
      onResume: _checkFolders,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkFolders());
    // The home-screen widget follows the book being read.
    ref.listenManual(continueReadingProvider, (_, next) => _updateWidget(next.value), fireImmediately: true);
    ref.listenManual(accountProvider, (_, account) {
      if (!account.signedIn || _syncedThisLaunch) return;
      _syncedThisLaunch = true;
      ref.read(syncProvider.notifier).schedulePeriodic();
      context.push('/sync');
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  String? _widgetShown;

  Future<void> _updateWidget(Book? book) async {
    final signature = book == null
        ? 'none'
        : '${book.id}|${book.title}|${(book.progress * 100).round()}|${book.coverPath}|${book.authors.join()}';
    if (signature == _widgetShown) return;
    _widgetShown = signature;
    try {
      await const MethodChannel('marginalia/device').invokeMethod('updateWidget', {
        'bookId': book?.id,
        'title': book?.title,
        'author': book == null || book.authors.isEmpty ? null : book.authors.join(', '),
        'progress': book?.progress ?? 0,
        'coverPath': book?.coverPath,
      });
    } on MissingPluginException {
      // In tests.
    }
  }

  /// New books in watched folders come in when the app opens or comes back.
  Future<void> _checkFolders() async {
    final added = await ref.read(watchedFoldersProvider.notifier).scan();
    if (added > 0 && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$added new ${added == 1 ? 'book' : 'books'} from your watched folders')),
      );
    }
  }

  StatefulNavigationShell get shell => widget.shell;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: shell,
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant)),
        ),
        child: NavigationBar(
          selectedIndex: shell.currentIndex,
          onDestinationSelected: (i) => shell.goBranch(i, initialLocation: i == shell.currentIndex),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.auto_stories_outlined),
              selectedIcon: Icon(Icons.auto_stories),
              label: 'Library',
            ),
            NavigationDestination(
              icon: Icon(Icons.collections_bookmark_outlined),
              selectedIcon: Icon(Icons.collections_bookmark),
              label: 'Collections',
            ),
            NavigationDestination(
              icon: Icon(Icons.format_quote_outlined),
              selectedIcon: Icon(Icons.format_quote),
              label: 'Notes',
            ),
            NavigationDestination(
              icon: Icon(Icons.explore_outlined),
              selectedIcon: Icon(Icons.explore),
              label: 'Discover',
            ),
          ],
        ),
      ),
    );
  }
}

class MarginaliaApp extends ConsumerWidget {
  const MarginaliaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'Marginalia',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ref.watch(appThemeModeProvider),
      routerConfig: _router,
      // Screens without an app bar still need the bars to match the app theme.
      builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: systemBarsFor(Theme.of(context).brightness),
        child: child!,
      ),
    );
  }
}
