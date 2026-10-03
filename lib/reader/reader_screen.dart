import 'dart:async';
import 'dart:io';
import 'dart:math' show Random;
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../cloud/sync_service.dart';
import '../data/database.dart';
import '../data/library.dart';
import '../readium/readium.dart';
import '../readium/readium_view.dart';
import '../theme/app_theme.dart';
import '../theme/reader_theme.dart';
import '../theme/system_bars.dart';
import '../theme/tokens.dart';
import 'device_controls.dart';
import 'page_turn/page_turner.dart';
import 'page_turn/turn_painters.dart';
import '../listen/listen_controller.dart';
import '../listen/kokoro.dart';
import '../listen/player_bar.dart';
import '../share/share_sheet.dart' show shareText;
import '../share/story_card.dart';
import '../stats/reading_stats.dart';
import '../storage/local_store.dart';
import '../translate/translate_sheet.dart';
import '../notes/note_actions.dart';
import '../words/review.dart' show contextSentence;
import 'annotations.dart';
import 'dictionary_sheet.dart';
import 'footnote_sheet.dart';
import 'reader_preferences.dart';
import 'reader_sheets.dart';
import 'search_sheet.dart';
import 'reading_state.dart';

class ReaderScreen extends ConsumerStatefulWidget {
  const ReaderScreen({super.key, required this.bookId, this.at});

  /// The library book to open.
  final String bookId;

  /// A place to open at (Readium Locator JSON), such as a note's; otherwise the last place.
  final String? at;

  @override
  ConsumerState<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends ConsumerState<ReaderScreen> {
  static const _readium = Readium();

  final _pageTurner = GlobalKey<PageTurnerState>();
  late final DeviceControls _device;
  late final ReadingStateStore _state;
  late final AppDatabase _db;
  late final ListenController _listen;
  late final SyncController _sync;
  String? _initialLocator;
  Book? _book;

  PublicationInfo? _publication;
  String? _error;
  ReadiumViewController? _controller;
  ReaderLocation? _location;
  List<Annotation> _annotations = const [];

  /// What was last drawn, to skip redundant updates.
  String? _sentHighlights;
  bool _chromeVisible = false;

  /// While dragging the progress slider.
  double? _scrubValue;

  /// Text is selected in the page.
  bool _selecting = false;

  /// While the book downloads from Drive on first open.
  double? _downloadProgress;
  bool _missingFile = false;

  /// The Readium preferences last sent to the view.
  Map<String, Object?>? _sentPreferences;

  /// For learning the reader's pace: when the current position was reached.
  int? _pacePosition;
  DateTime _paceStart = DateTime.now();

  /// The last search in this book, and the result being looked at.
  final _search = BookSearch();

  /// A jump to a search result is under way: the next position change is that jump, not the
  /// reader moving on.
  bool _jumpingToResult = false;

  /// Re-checks the page colors each minute while night is on a schedule.
  Timer? _clock;

  /// This sitting with the book, for stats and streaks.
  SessionRecorder? _session;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _state = ref.read(readingStateProvider);
    _db = ref.read(databaseProvider);
    _listen = ref.read(listenProvider.notifier);
    _sync = ref.read(syncProvider.notifier);
    ref.read(annotationStoreProvider).migrateLegacyBookmarks(widget.bookId);
    ref.listenManual(
      annotationsProvider(widget.bookId),
      (_, next) => setState(() => _annotations = next.value ?? _annotations),
      fireImmediately: true,
    );
    _device = DeviceControls(
      onVolumeKey: (forward) => _pageTurner.currentState?.turn(forward: forward),
    );
    final prefs = ref.read(readerPreferencesProvider);
    _device.setKeepScreenOn(prefs.keepScreenOn);
    _device.setVolumeKeysTurnPages(prefs.volumeKeys);
    _setImmersive(true);
    // Leaving the app ends the sitting; coming back starts another.
    _lifecycle = AppLifecycleListener(
      onHide: _endSession,
      onShow: () {
        if (_publication != null) _startSession();
      },
    );
    _clock = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted && ref.read(readerPreferencesProvider).pageMode == PageMode.scheduled) setState(() {});
    });
    _open();
  }

  Future<void> _open() async {
    final book = await _db.getBook(widget.bookId);
    if (book == null) {
      if (mounted) setState(() => _error = 'This book is no longer in your library.');
      return;
    }
    _book = book;
    var path = book.filePath;
    if (path == null || !await File(path).exists()) {
      // First time on this device: fetch it from the user's Drive.
      if (book.driveFileId != null) {
        setState(() => _downloadProgress = 0);
        try {
          // Done when the download says so, or as soon as the file is saved for the book,
          // whichever comes first (the download call can be slow to finish after saving).
          path = await Future.any([
            ref.read(syncProvider.notifier).ensureFile(
              book,
              onProgress: (p) => mounted ? setState(() => _downloadProgress = p) : null,
            ),
            _fileArrives(book.id),
          ]);
        } catch (_) {
          path = null;
        }
        if (!mounted) return;
        setState(() => _downloadProgress = null);
        // Open it fresh, exactly as if it had always been on this phone.
        if (path != null) return _open();
      } else {
        path = null;
      }
    }
    if (path == null) {
      if (mounted) {
        setState(() {
          _missingFile = true;
          _error = book.driveFileId == null
              ? "This book's file isn't on this phone and wasn't uploaded. "
                    'Link your own copy and your notes will land in the right places.'
              : "This book couldn't be downloaded. Check your connection and try again.";
        });
      }
      return;
    }
    _initialLocator = widget.at ?? book.lastLocator;
    await _db.updateBook(
      book.id,
      BooksCompanion(
        lastOpenedAt: Value(DateTime.now()),
        lastReadAt: Value(DateTime.now()),
        // Opening a book you haven't started, or meant to read, means you're reading it.
        status: book.status == null || book.status == ReadingStatus.wantToRead
            ? const Value(ReadingStatus.reading)
            : const Value.absent(),
      ),
    );
    unawaited(_offerNewerPosition(book));
    // Bring in notes and bookmarks made on other devices; they appear as they arrive.
    unawaited(_sync.syncNow());
    try {
      final publication = await _readium.open(path);
      if (!mounted) {
        await _readium.close(publication.id);
        return;
      }
      setState(() => _publication = publication);
      _startSession();
    } on ReadiumException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  /// Completes with the book's file once it's saved on this phone.
  Future<String> _fileArrives(String bookId) async {
    await for (final book in _db.watchBook(bookId)) {
      final path = book?.filePath;
      if (path != null && await File(path).exists()) return path;
    }
    // The stream ended (the screen closed): never complete.
    return Completer<String>().future;
  }

  /// "Pixel 8 is at 34%. Jump there?" The page never moves on its own.
  Future<void> _offerNewerPosition(Book book) async {
    final remote = await ref.read(syncProvider.notifier).newerProgressElsewhere(book);
    if (remote == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 10),
        content: Text('${remote.deviceName} is at ${(remote.percent * 100).round()}%. Jump there?'),
        action: SnackBarAction(
          label: 'Jump',
          onPressed: () => _controller?.goToLocator(remote.locatorJson),
        ),
      ),
    );
  }

  Future<void> _linkFile() async {
    final book = _book;
    if (book == null) return;
    final ok = await ref.read(libraryImporterProvider.notifier).linkFile(book);
    if (!mounted) return;
    if (ok) {
      setState(() {
        _error = null;
        _missingFile = false;
      });
      await _open();
    } else {
      _say("That file is a different book (or edition), so it can't be linked.");
    }
  }

  @override
  void dispose() {
    // Reading progress and notes go out shortly after closing the book.
    _sync.scheduleSoon();
    // The book closes with the reader, so reading aloud stops too.
    if (_listen.isActive) _listen.stop();
    _lifecycle.dispose();
    _endSession();
    _clock?.cancel();
    _controller?.dispose();
    _device.dispose();
    final id = _publication?.id;
    if (id != null) _readium.close(id);
    _setImmersive(false);
    super.dispose();
  }

  void _setImmersive(bool immersive) {
    SystemChrome.setEnabledSystemUIMode(
      immersive ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
  }

  /// The controls slide over the page. The system bars stay hidden throughout: showing them
  /// would resize the page view and make Readium lay the chapter out again.
  void _toggleChrome() => setState(() => _chromeVisible = !_chromeVisible);

  void _onLocationChanged(ReaderLocation location) {
    if (_jumpingToResult) {
      _jumpingToResult = false;
    } else if (_search.index != null && !_chromeVisible) {
      // Reading on from a search result: the underline goes, the results stay.
      _controller?.markSearchResult(null, 0);
    }
    final previous = _pacePosition;
    _session?.activity(
      DateTime.now(),
      advanced: previous == null || location.position == null ? 0 : location.position! - previous,
      progress: location.totalProgression,
    );
    _learnPace(location.position);
    setState(() => _location = location);
    _db.updateBook(
      widget.bookId,
      BooksCompanion(
        lastLocator: Value(location.locatorJson),
        progress: Value(location.totalProgression ?? _book?.progress ?? 0),
        lastOpenedAt: Value(DateTime.now()),
        lastReadAt: Value(DateTime.now()),
      ),
    );
  }

  void _startSession() {
    _endSession();
    _session = SessionRecorder(
      bookId: widget.bookId,
      now: DateTime.now(),
      progress: _location?.totalProgression ?? _book?.progress,
    );
  }

  void _endSession() {
    final session = _session;
    _session = null;
    if (session == null) return;
    final record = session.finish(
      DateTime.now(),
      id: '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${Random().nextInt(1 << 20).toRadixString(36)}',
      deviceName: ref.read(localStoreProvider).readJson('device.name') as String?,
    );
    if (record != null) _db.saveSession(record);
  }

  /// Times each step forward through the book to estimate time left.
  void _learnPace(int? position) {
    final previous = _pacePosition;
    if (position == null || position == previous) return;
    final now = DateTime.now();
    if (previous != null) {
      final advanced = position - previous;
      if (advanced >= 1 && advanced <= 3) _state.recordPage(now.difference(_paceStart), advanced);
    }
    _pacePosition = position;
    _paceStart = now;
  }

  // ---- Actions ----

  List<Annotation> get _bookmarks =>
      _annotations.where((a) => a.type == AnnotationType.bookmark).toList();

  bool get _onBookmarkedPage {
    final location = _location;
    return location != null && _bookmarks.any((b) => b.isOnPage(location));
  }

  void _toggleBookmark() {
    final location = _location;
    if (location == null) return;
    final store = ref.read(annotationStoreProvider);
    final here = _bookmarks.where((b) => b.isOnPage(location)).toList();
    if (here.isEmpty) {
      store.addBookmark(widget.bookId, location);
    } else {
      for (final b in here) {
        store.delete(b.id);
      }
    }
    HapticFeedback.selectionClick();
  }

  Future<void> _onSelection(Map<Object?, Object?> raw) async {
    final selection = ReaderSelection.fromMap(raw);
    final store = ref.read(annotationStoreProvider);
    switch (selection.action) {
      case 'copy':
        await Clipboard.setData(ClipboardData(text: selection.text ?? ''));
        _say('Copied');
      case 'share':
        final quote = selection.text?.trim() ?? '';
        if (quote.isNotEmpty && mounted) await _shareSelection(quote);
      case 'highlight':
        final id = await store.addHighlight(widget.bookId, selection);
        HapticFeedback.selectionClick();
        if (mounted) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                content: const Text('Highlighted · tap it any time to change'),
                action: SnackBarAction(label: 'Edit', onPressed: () => _editAnnotation(id)),
              ),
            );
        }
      case 'note':
        final id = await store.addHighlight(widget.bookId, selection);
        await _editAnnotation(id, editNote: true);
      case 'define':
        final word = selection.text?.trim() ?? '';
        if (word.isNotEmpty && mounted) {
          await showDefinitionSheet(
            context,
            word,
            bookId: widget.bookId,
            language: _book?.language ?? _publication?.language,
            sentence: contextSentence(selection.before, word, selection.after),
          );
        }
      case 'translate':
        final text = selection.text?.trim() ?? '';
        final paragraphId = selection.paragraphId;
        if (text.isNotEmpty && mounted) {
          await showTranslateSheet(
            context,
            text,
            bookLanguage: _publication?.language,
            paragraph: selection.paragraphText,
            onShowInPage: paragraphId == null || _controller == null
                ? null
                : (translation) => _controller!.insertTranslation(paragraphId, translation),
          );
        }
    }
  }

  Future<void> _editAnnotation(String id, {bool editNote = false}) async {
    final annotation = await _db.getAnnotation(id);
    if (annotation == null || !mounted) return;
    await showAnnotationSheet(
      context,
      annotation: annotation,
      store: ref.read(annotationStoreProvider),
      editNote: editNote,
      onShareStory: annotation.selectedText == null ? null : () => _shareStory(annotation.id),
      onShareLink: annotation.selectedText == null ? null : () => shareNoteLink(context, ref, annotation),
      onCopy: () {
        Clipboard.setData(ClipboardData(text: annotation.selectedText ?? ''));
        Navigator.pop(context);
        _say('Copied');
      },
    );
  }

  /// Selected text, as a story image or as plain text.
  Future<void> _shareSelection(String quote) async {
    final book = _book;
    final title = book?.title ?? _publication?.title ?? '';
    final authors = book?.authors ?? _publication?.authors ?? const <String>[];
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.auto_awesome_mosaic_outlined),
              title: const Text('Share as an image'),
              subtitle: const Text('A story-sized card with the cover'),
              onTap: () => Navigator.pop(context, 'image'),
            ),
            ListTile(
              leading: const Icon(Icons.short_text),
              title: const Text('Share as text'),
              subtitle: const Text('The passage, with the title and author'),
              onTap: () => Navigator.pop(context, 'text'),
            ),
            const SizedBox(height: Space.sm),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'image') {
      await showStorySheet(
        context,
        StoryContent(
          quote: quote,
          title: title,
          author: authors.join(', '),
          accent: ref.read(annotationStoreProvider).lastColor.onLight,
          coverColor: book?.coverColor == null ? null : Color(book!.coverColor!),
          coverPath: book?.coverPath,
        ),
      );
    } else {
      await shareText('“$quote”\n— $title${authors.isEmpty ? '' : ', ${authors.join(', ')}'}');
    }
  }

  /// The passage as a story card, with the book's title, author and cover tint.
  Future<void> _shareStory(String annotationId) async {
    final annotation = await _db.getAnnotation(annotationId);
    final quote = annotation?.selectedText;
    if (annotation == null || quote == null || !mounted) return;
    final book = _book;
    await showStorySheet(
      context,
      StoryContent(
        quote: quote,
        note: annotation.note,
        title: book?.title ?? _publication?.title ?? '',
        author: (book?.authors ?? _publication?.authors ?? const []).join(', '),
        accent: annotation.highlightColor.onLight,
        coverColor: book?.coverColor == null ? null : Color(book!.coverColor!),
        coverPath: book?.coverPath,
      ),
    );
  }

  // ---- Search ----

  static const _searchMark = Color(0xFFB0473F);

  Future<void> _openSearch() async {
    final controller = _controller;
    if (controller == null) return;
    final index = await showSearchSheet(context, controller: controller, search: _search);
    if (index != null) await _goToResult(index);
  }

  Future<void> _goToResult(int index) async {
    final controller = _controller;
    if (controller == null || index < 0 || index >= _search.results.length) return;
    final result = _search.results[index];
    setState(() {
      _search.index = index;
      _chromeVisible = false;
    });
    _jumpingToResult = true;
    await controller.goToLocator(result.locatorJson);
    await controller.markSearchResult(result.locatorJson, _searchMark.toARGB32());
  }

  void _closeSearch() {
    _controller?.markSearchResult(null, 0);
    setState(() => _search.index = null);
  }

  Future<void> _onFootnote(Footnote note) async {
    final go = await showFootnoteSheet(context, note);
    if (go == true && note.href != null) await _controller?.goToHref(note.href!);
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 2)));
  }

  Future<void> _showNavigation() async {
    final publication = _publication;
    if (publication == null) return;
    final store = ref.read(annotationStoreProvider);
    final target = await showNavigationSheet(
      context,
      toc: publication.toc,
      annotations: _annotations,
      currentHref: _location?.href,
      onDelete: (a) => store.delete(a.id),
      onRecolor: (a, color) => store.setColor(a.id, color),
    );
    if (target == null) return;
    final controller = _controller;
    switch (target) {
      case GoToHref(:final href):
        await controller?.goToHref(href);
      case GoToLocator(:final locatorJson):
        await controller?.goToLocator(locatorJson);
      case EditAnnotation(:final id):
        await _editAnnotation(id);
        return;
      case ShareAnnotation(:final id):
        await _shareStory(id);
        return;
      case ShareAnnotationLink(:final id):
        final annotation = await _db.getAnnotation(id);
        if (annotation != null && mounted) await shareNoteLink(context, ref, annotation);
        return;
      case ExportBookNotes():
        if (mounted) await exportNotes(context, ref, bookId: widget.bookId);
        return;
    }
    if (mounted && _chromeVisible) _toggleChrome();
  }

  /// Draws highlights and notes in the page colors in effect, when either changes.
  void _syncHighlights(Brightness pageBrightness) {
    final controller = _controller;
    if (controller == null) return;
    final highlights = [
      for (final a in _annotations)
        if (a.type != AnnotationType.bookmark)
          {
            'id': a.id,
            'locator': a.locator,
            'color': a.highlightColor.resolve(pageBrightness).toARGB32(),
          },
    ];
    final signature = '$pageBrightness ${[for (final h in highlights) '${h['id']}:${h['color']}']}';
    if (signature == _sentHighlights) return;
    _sentHighlights = signature;
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.setHighlights(highlights));
  }

  /// While listening, a tap on a line reads on from there; otherwise taps turn pages or show
  /// the controls.
  Future<void> _onPageTap(Offset point) async {
    // A tap clears any selection, even if the page never said the selection ended.
    if (_selecting) setState(() => _selecting = false);
    // With the controls showing, a tap anywhere on the page just puts them away (rather
    // than turning the page or jumping the voice underneath them).
    if (_chromeVisible) {
      setState(() => _chromeVisible = false);
      return;
    }
    final controller = _controller;
    if (_listen.isActive && controller != null) {
      final locator = await controller.locatorAt(point);
      if (locator != null) {
        HapticFeedback.selectionClick();
        await _listen.readFrom(locator);
        return;
      }
    }
    _pageTurner.currentState?.tapAt(point.dx);
  }

  Future<void> _startListening() async {
    final publication = _publication;
    if (publication == null) return;
    if (_chromeVisible) _toggleChrome();
    final error = await _listen.start(
      publication.id,
      _location?.locatorJson,
      language: _book?.language ?? publication.language,
    );
    if (error == ListenController.needsVoices) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: const Text('Listen needs its voices: a one-time download (${KokoroPack.downloadSizeLabel})'),
            action: SnackBarAction(label: 'Download', onPressed: () => context.push('/settings/downloads')),
          ),
        );
    } else if (error != null) {
      _say(error);
    }
  }

  /// Sends preferences to the view when what it should render changes, including when the
  /// phone switches between light and dark while following it.
  void _syncPreferences(Map<String, Object?> readium) {
    final controller = _controller;
    if (controller == null || mapEquals(readium, _sentPreferences)) return;
    _sentPreferences = readium;
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.setPreferences(readium));
  }

  // ---- Building ----

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(readerPreferencesProvider);
    final theme = prefs.resolvePage(MediaQuery.platformBrightnessOf(context), coverColor: _coverColor);
    final readium = prefs.toReadium(theme);
    _syncPreferences(readium);
    _syncHighlights(theme.brightness);

    final listening = ref.watch(listenProvider.select((s) => s.active));
    ref.listen(listenProvider.select((s) => s.sentenceLocator), (_, locator) {
      _controller?.setSpokenSentence(locator, theme.ink.withValues(alpha: 0.18).toARGB32());
    });
    ref.listen(listenProvider.select((s) => s.active), (_, active) {
      if (!active) _controller?.setSpokenSentence(null, 0);
    });

    ref.listen(readerPreferencesProvider, (previous, next) {
      if (previous?.keepScreenOn != next.keepScreenOn) _device.setKeepScreenOn(next.keepScreenOn);
      if (previous?.volumeKeys != next.volumeKeys) _device.setVolumeKeysTurnPages(next.volumeKeys);
    });

    final chromeTheme = theme.brightness == Brightness.light ? AppTheme.light() : AppTheme.dark();

    return Theme(
      data: chromeTheme,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: systemBarsFor(theme.brightness),
        child: Scaffold(
          backgroundColor: theme.page,
          body: Stack(
            fit: StackFit.expand,
            children: [
              Column(
                children: [
                  Expanded(child: _buildPages(prefs, theme, readium)),
                  if (listening) PlayerBar(theme: theme),
                  if (_publication != null) _buildFooter(theme),
                ],
              ),
              if (_search.index != null && !_chromeVisible) _buildSearchBar(theme),
              _buildTopBar(theme),
              _buildBottomPanel(theme),
            ],
          ),
        ),
      ),
    );
  }

  Color? get _coverColor => _book?.coverColor == null ? null : Color(_book!.coverColor!);

  Widget _buildPages(ReaderPreferences prefs, PageColors theme, Map<String, Object?> readium) {
    final publication = _publication;

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Space.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'This book could not be opened',
                style: TextStyle(fontFamily: FontFamilies.display, fontSize: 22, color: theme.ink),
              ),
              const SizedBox(height: Space.sm),
              Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: theme.muted)),
              const SizedBox(height: Space.xl),
              if (_missingFile && _book?.driveFileId == null)
                FilledButton(onPressed: _linkFile, child: const Text('Link your copy'))
              else if (_missingFile)
                FilledButton(
                  onPressed: () {
                    setState(() {
                      _error = null;
                      _missingFile = false;
                    });
                    _open();
                  },
                  child: const Text('Try again'),
                ),
              const SizedBox(height: Space.sm),
              OutlinedButton(
                onPressed: () => Navigator.of(context).maybePop(),
                child: const Text('Back'),
              ),
            ],
          ),
        ),
      );
    }
    if (_downloadProgress case final progress?) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Downloading from your Drive',
              style: TextStyle(fontFamily: FontFamilies.ui, fontSize: 15, color: theme.ink),
            ),
            const SizedBox(height: Space.md),
            SizedBox(
              width: 180,
              child: LinearProgressIndicator(value: progress == 0 ? null : progress, minHeight: 2),
            ),
          ],
        ),
      );
    }
    if (publication == null) return const SizedBox.shrink();

    return Stack(
      fit: StackFit.expand,
      children: [
        PageTurner(
          key: _pageTurner,
          source: _controller == null ? null : _ReadiumPageSource(_controller!),
          // _sentPreferences only changes identity when the rendering does.
          pageKey: (_location?.locatorJson, _sentPreferences),
          // Scrolling moves the text itself; side taps and swipes jump a screen.
          style: prefs.scroll ? TurnStyle.none : prefs.turnStyle,
          pageBack: theme.pageBack,
          rightToLeft: publication.isRightToLeft,
          haptics: prefs.haptics,
          tapToTurn: prefs.tapToTurn,
          enabled: !_selecting,
          onCenterTap: _toggleChrome,
          child: ReadiumView(
            publicationId: publication.id,
            preferences: readium,
            scroll: prefs.scroll,
            initialLocatorJson: _initialLocator,
            onCreated: (controller) => setState(() {
              _controller = controller;
              _sentPreferences = readium;
              _sentHighlights = null;
            }),
            onLocationChanged: _onLocationChanged,
            onTap: _onPageTap,
            onSelection: _onSelection,
            onHighlightTapped: _editAnnotation,
            onFootnote: _onFootnote,
            selecting: _selecting,
            onSelectionActive: (active) => setState(() => _selecting = active),
          ),
        ),
        Positioned(
          top: 0,
          right: Space.gutter,
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: _onBookmarkedPage ? 1 : 0,
              duration: Motion.quick,
              child: const _Ribbon(),
            ),
          ),
        ),
      ],
    );
  }

  /// Time left in the chapter and progress through the book, quiet under the page.
  Widget _buildFooter(PageColors theme) {
    final location = _location;
    final style = TextStyle(
      fontFamily: FontFamilies.ui,
      fontSize: 11.5,
      color: theme.muted,
      fontFeatures: const [ui.FontFeature.tabularFigures()],
    );
    final total = location?.totalProgression;
    return SafeArea(
      top: false,
      child: SizedBox(
        height: 30,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
          child: Row(
            children: [
              Expanded(
                child: Text(_timeLeftInChapter() ?? '', style: style, maxLines: 1),
              ),
              if (total != null) Text('${(total * 100).round()}%', style: style),
            ],
          ),
        ),
      ),
    );
  }

  String? _timeLeftInChapter() {
    final location = _location;
    final chapter = location == null ? null : _publication?.chapterFor(location.href);
    final progression = location?.progression;
    // A cover, preface or contents page is too short to time.
    if (chapter == null || progression == null || chapter.count <= 1) return null;
    final remaining = chapter.count * (1 - progression.clamp(0.0, 1.0));
    final minutes = (remaining * _state.secondsPerPosition / 60).round();
    if (minutes < 1) return 'Less than a minute left in chapter';
    if (minutes < 60) return '$minutes min left in chapter';
    final hours = minutes ~/ 60;
    final rest = minutes % 60;
    return rest == 0 ? '$hours h left in chapter' : '$hours h $rest min left in chapter';
  }

  Widget _buildTopBar(PageColors theme) {
    final title = _book?.title ?? _publication?.title ?? '';
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: _ChromeSlide(
        visible: _chromeVisible,
        fromTop: true,
        child: Material(
          color: theme.page,
          child: SafeArea(
            bottom: false,
            child: Container(
              height: 56,
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: theme.ink.withValues(alpha: 0.08))),
              ),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back),
                    color: theme.ink,
                    tooltip: 'Back',
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(color: theme.ink),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.search),
                    color: theme.ink,
                    tooltip: 'Search this book',
                    onPressed: _controller == null ? null : _openSearch,
                  ),
                  IconButton(
                    icon: Icon(_onBookmarkedPage ? Icons.bookmark : Icons.bookmark_border),
                    color: _onBookmarkedPage ? Theme.of(context).colorScheme.primary : theme.ink,
                    tooltip: _onBookmarkedPage ? 'Remove bookmark' : 'Bookmark this page',
                    onPressed: _location == null ? null : _toggleBookmark,
                  ),
                  const SizedBox(width: Space.xs),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Steps through search results: "3 of 42", previous, next, close.
  Widget _buildSearchBar(PageColors theme) {
    final index = _search.index!;
    final count = _search.results.length;
    final style = TextStyle(fontFamily: FontFamilies.ui, fontSize: 13, color: theme.page);
    return Positioned(
      left: 0,
      right: 0,
      bottom: MediaQuery.paddingOf(context).bottom + 40,
      child: Center(
        child: Material(
          color: theme.ink,
          elevation: 3,
          borderRadius: BorderRadius.circular(Radii.pill),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Previous result',
                color: theme.page,
                icon: const Icon(Icons.chevron_left),
                onPressed: index > 0 ? () => _goToResult(index - 1) : null,
              ),
              InkWell(
                onTap: _openSearch,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Space.xs, vertical: Space.sm),
                  child: Text('${index + 1} of $count${_search.hitLimit ? '+' : ''}', style: style),
                ),
              ),
              IconButton(
                tooltip: 'Next result',
                color: theme.page,
                icon: const Icon(Icons.chevron_right),
                onPressed: index < count - 1 ? () => _goToResult(index + 1) : null,
              ),
              IconButton(
                tooltip: 'Close search',
                color: theme.page,
                icon: const Icon(Icons.close, size: 20),
                onPressed: _closeSearch,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomPanel(PageColors theme) {
    final text = Theme.of(context).textTheme;
    final total = _scrubValue ?? _location?.totalProgression ?? 0;
    final chapter = _location?.title;

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: _ChromeSlide(
        visible: _chromeVisible,
        fromTop: false,
        child: Material(
          color: theme.page,
          child: SafeArea(
            top: false,
            child: Container(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: theme.ink.withValues(alpha: 0.08))),
              ),
              padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, Space.sm),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          chapter ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodyMedium?.copyWith(color: theme.ink),
                        ),
                      ),
                      Text(
                        '${(total * 100).round()}%',
                        style: text.labelMedium?.copyWith(
                          color: theme.muted,
                          fontFeatures: const [ui.FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  Slider(
                    value: total.clamp(0.0, 1.0),
                    onChanged: (v) => setState(() => _scrubValue = v),
                    onChangeEnd: (v) async {
                      await _controller?.goToProgression(v);
                      if (mounted) setState(() => _scrubValue = null);
                    },
                    activeColor: theme.ink,
                    inactiveColor: theme.ink.withValues(alpha: 0.15),
                    thumbColor: theme.ink,
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _ChromeButton(
                        icon: Icons.format_list_bulleted,
                        label: 'Contents',
                        color: theme.ink,
                        onPressed: _showNavigation,
                      ),
                      _ChromeButton(
                        icon: Icons.text_fields,
                        label: 'Display',
                        color: theme.ink,
                        onPressed: () => showDisplaySheet(context, coverColor: _coverColor),
                      ),
                      _ChromeButton(
                        icon: Icons.headphones_outlined,
                        label: 'Listen',
                        color: theme.ink,
                        onPressed: _startListening,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReadiumPageSource implements PageSource {
  _ReadiumPageSource(this._controller);

  final ReadiumViewController _controller;

  @override
  Future<ui.Image?> snapshot() => _controller.snapshot();

  @override
  Future<bool> goForward() => _controller.goForward();

  @override
  Future<bool> goBackward() => _controller.goBackward();

  @override
  bool operator ==(Object other) =>
      other is _ReadiumPageSource && identical(other._controller, _controller);

  @override
  int get hashCode => _controller.hashCode;
}

/// The bookmark ribbon hanging from the top edge of a bookmarked page.
class _Ribbon extends StatelessWidget {
  const _Ribbon();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(14, 30),
      painter: _RibbonPainter(Theme.of(context).colorScheme.primary),
    );
  }
}

class _RibbonPainter extends CustomPainter {
  _RibbonPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..lineTo(size.width, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(size.width / 2, size.height - size.width * 0.45)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_RibbonPainter old) => old.color != color;
}

/// Slides reader chrome in from its edge.
class _ChromeSlide extends StatelessWidget {
  const _ChromeSlide({required this.visible, required this.fromTop, required this.child});

  final bool visible;
  final bool fromTop;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedSlide(
        offset: visible ? Offset.zero : Offset(0, fromTop ? -1 : 1),
        duration: Motion.standard,
        curve: Motion.emphasized,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: Motion.standard,
          child: child,
        ),
      ),
    );
  }
}

class _ChromeButton extends StatelessWidget {
  const _ChromeButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
      label: Text(label),
      style: TextButton.styleFrom(foregroundColor: color),
    );
  }
}
