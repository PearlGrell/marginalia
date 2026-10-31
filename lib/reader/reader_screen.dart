import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cloud/sync_service.dart';
import '../clubs/club_screens.dart';
import '../clubs/clubs.dart';
import '../companion/book_memory.dart';
import '../companion/companion_sheet.dart';
import '../companion/explain.dart';
import '../companion/previously.dart';
import '../data/database.dart';
import '../data/library.dart';
import '../readium/readium.dart';
import '../readium/readium_view.dart';
import '../theme/app_theme.dart';
import '../theme/reader_theme.dart';
import '../theme/system_bars.dart';
import '../theme/tokens.dart';
import '../util/root_messenger.dart';
import 'device_controls.dart';
import 'page_turn/page_turner.dart';
import 'page_turn/turn_painters.dart';
import '../listen/listen_controller.dart';
import '../listen/player_bar.dart';
import '../share/share_sheet.dart' show shareText;
import '../stats/stats_screen.dart' show sessionsProvider;
import '../share/page_card.dart';
import '../stats/reading_stats.dart';
import '../storage/local_store.dart';
import '../translate/translate_sheet.dart';
import '../notes/note_actions.dart';
import '../words/review.dart' show contextSentence;
import 'annotations.dart';
import 'chapter_progress.dart';
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

  /// Keeps the book for the companion as it's read (see [BookKeeper]).
  BookKeeper? _keeper;
  String? _error;
  ReadiumViewController? _controller;
  ReaderLocation? _location;
  List<Annotation> _annotations = const [];

  /// What was last drawn, to skip redundant updates.
  String? _sentHighlights;
  bool _chromeVisible = false;

  /// The status bar, pulled down over the page for a moment: the clock steps aside for it.
  bool _systemBarsShown = false;

  /// While dragging the progress slider.
  double? _scrubValue;

  /// Text is selected in the page.
  bool _selecting = false;

  /// When the last selection ended: the tap that ended it reaches the page a moment later, and
  /// mustn't turn it.
  DateTime? _selectionEndedAt;

  /// Text selected in the page, or not: kept with when it ended.
  void _setSelecting(bool selecting) {
    if (selecting == _selecting) return;
    if (!selecting) _selectionEndedAt = DateTime.now();
    setState(() => _selecting = selecting);
  }

  /// A moment after a touch ends, the page is asked whether text is selected, and Flutter
  /// follows: if a start or end was missed, touches would otherwise go to the wrong place (a
  /// handle dragged turning the page, or pages that won't turn).
  Timer? _selectionCheck;

  void _checkSelectionSoon() {
    _selectionCheck?.cancel();
    _selectionCheck = Timer(const Duration(milliseconds: 450), () async {
      final controller = _controller;
      if (controller == null || !mounted) return;
      final selected = await controller.hasSelection();
      if (mounted) _setSelecting(selected);
    });
  }

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

  /// Back after a while away: a reminder of the story so far, once the page is known.
  bool _offerPreviously = false;
  ({String heading, String text})? _previously;
  int? _previouslyAt;

  /// The clubs reading this book, told how far the reader got when the book closes.
  List<Club> _clubs = const [];
  late final ClubService _clubService;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _state = ref.read(readingStateProvider);
    _db = ref.read(databaseProvider);
    _listen = ref.read(listenProvider.notifier);
    _sync = ref.read(syncProvider.notifier);
    _clubService = ref.read(clubServiceProvider);
    ref.listenManual(clubsForBookProvider(widget.bookId), (_, next) => _clubs = next, fireImmediately: true);
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
    SystemChrome.setSystemUIChangeCallback((shown) async {
      if (mounted && shown != _systemBarsShown) setState(() => _systemBarsShown = shown);
    });
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
    // Away from a book they've started for most of a day: remind them where the story is.
    final away = book.lastReadAt ?? book.lastOpenedAt;
    _offerPreviously = widget.at == null &&
        book.progress > 0.01 &&
        away != null &&
        DateTime.now().difference(away) > const Duration(hours: 8);
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
      // The companion keeps the book as it's read, a page at a time (EPUBs: text to keep).
      if (!publication.isFixedLayout) {
        final summaries = ref.read(chapterSummariesProvider.notifier);
        final title = book.title;
        final authors = book.authors.join(', ');
        _keeper = BookKeeper(
          bookId: widget.bookId,
          publication: publication,
          title: title,
          authors: authors,
          onChapterFinished: () => summaries.catchUp(bookId: widget.bookId, title: title, authors: authors),
        );
      }
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
    final progress = _location?.totalProgression;
    if (progress != null) {
      for (final club in _clubs) {
        unawaited(_clubService.reportProgress(club.code, progress).catchError((_) {}));
      }
    }
    // The book closes with the reader, so reading aloud stops too.
    if (_listen.isActive) _listen.stop();
    _lifecycle.dispose();
    _keeper?.flush();
    _keeper?.close();
    _endSession(recap: true);
    _clock?.cancel();
    _selectionCheck?.cancel();
    SystemChrome.setSystemUIChangeCallback(null);
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
      position: location.position,
    );
    _learnPace(location.position);
    _keeper?.reached(location);
    if (_offerPreviously && _keeper != null) {
      _offerPreviously = false;
      unawaited(_showPreviously(location));
    } else if (_previously != null && (location.position == null || (location.position! - (_previouslyAt ?? 0)).abs() >= 2)) {
      // Reading on: the reminder has done its job.
      _previously = null;
    }
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
      position: _location?.position,
    );
  }

  /// Ends the sitting; with [recap] (closing the book), says what it came to.
  void _endSession({bool recap = false}) {
    final session = _session;
    _session = null;
    if (session == null) return;
    final record = session.finish(
      DateTime.now(),
      deviceName: ref.read(localStoreProvider).readJson('device.name') as String?,
    );
    if (record == null) return;
    _db.saveSession(record);
    if (recap) _showRecap(session);
  }

  Future<void> _showRecap(SessionRecorder session) async {
    final words = await _db.countWords(session.bookId, since: session.startedAt);
    final text = sittingRecap(
      seconds: session.active.inSeconds,
      fromPage: session.startPosition,
      toPage: session.endPosition,
      words: words,
    );
    rootMessenger.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('This sitting: $text')));
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
    // Picking an action ends the selection, even if the page never said so: otherwise the
    // page keeps every touch once the sheet for the action closes.
    _setSelecting(false);
    switch (selection.action) {
      case 'copy':
        await Clipboard.setData(ClipboardData(text: selection.text ?? ''));
        _say('Copied');
      case 'share':
        if ((selection.text?.trim() ?? '').isNotEmpty && mounted) await _shareSelection(selection);
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
      case 'who':
        final name = selection.text?.trim() ?? '';
        if (name.isNotEmpty && mounted) await _ask(name: name);
      case 'explain':
        final text = selection.text?.trim() ?? '';
        if (text.isNotEmpty && mounted) await _explain(selection);
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

  /// A highlight tapped in the page: the reader's own to edit, or a friend's to talk about.
  Future<void> _onHighlightTapped(String id) async {
    if (ClubNote.parseDecorationId(id) case (final club, final noteId)) {
      final note = ref.read(clubNotesProvider(club)).value?.where((n) => n.id == noteId).firstOrNull;
      if (note != null && mounted) await showClubNoteSheet(context, note);
      return;
    }
    await _editAnnotation(id);
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
      extra: annotation.selectedText == null ? null : ClubShareRow(annotation: annotation),
      onCopy: () {
        Clipboard.setData(ClipboardData(text: annotation.selectedText ?? ''));
        Navigator.pop(context);
        _say('Copied');
      },
    );
  }

  /// Selected text, as an image of its page or as plain text.
  Future<void> _shareSelection(ReaderSelection selection) async {
    final quote = selection.text!.trim();
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
              subtitle: const Text('The passage on its page, story-sized'),
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
      await showPageShareSheet(
        context,
        PageCardContent(
          excerpt: PageExcerpt.fromJson(selection.pageContext) ??
              PageExcerpt.around(selection.before, quote, selection.after),
          title: title,
          author: authors.join(', '),
          coverColor: _coverColor,
          coverPath: book?.coverPath,
        ),
        reading: _pageColors,
      );
    } else {
      await shareText('“$quote”\n— $title${authors.isEmpty ? '' : ', ${authors.join(', ')}'}');
    }
  }

  /// A highlight as an image of its page, with the book's title, author and cover.
  Future<void> _shareStory(String annotationId) async {
    final annotation = await _db.getAnnotation(annotationId);
    final quote = annotation?.selectedText;
    if (annotation == null || quote == null || !mounted) return;
    final book = _book;
    await showPageShareSheet(
      context,
      PageCardContent(
        excerpt: PageExcerpt.around(annotation.textBefore, quote, annotation.textAfter),
        title: book?.title ?? _publication?.title ?? '',
        author: (book?.authors ?? _publication?.authors ?? const []).join(', '),
        coverColor: _coverColor,
        coverPath: book?.coverPath,
      ),
      reading: _pageColors,
    );
  }

  /// The page colors the book is being read in.
  PageColors get _pageColors => ref
      .read(readerPreferencesProvider)
      .resolvePage(MediaQuery.platformBrightnessOf(context), coverColor: _coverColor);

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

  /// Draws highlights and notes in the page colors in effect, and what book-club friends
  /// have shared (in each one's color), when any of them changes.
  void _syncHighlights(Brightness pageBrightness, List<ClubNote> others) {
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
      for (final n in others)
        {
          'id': n.decorationId,
          'locator': n.locator,
          'color': memberColor(n.authorUid).withValues(alpha: 0.35).toARGB32(),
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
    // A tap while text is selected only clears it; nor does the tap that just cleared one
    // (it comes here a moment after) turn the page or show the controls.
    if (_selecting) {
      _setSelecting(false);
      unawaited(_controller?.clearSelection());
      return;
    }
    final ended = _selectionEndedAt;
    if (ended != null && DateTime.now().difference(ended) < const Duration(milliseconds: 700)) return;
    // Listening, a tap on text reads from there, whatever else is showing. The very edges
    // still turn pages.
    final controller = _controller;
    if (_listen.isActive && controller != null && point.dx > 0.08 && point.dx < 0.92) {
      final locator = await controller.locatorAt(point);
      if (locator != null) {
        HapticFeedback.selectionClick();
        if (_chromeVisible) setState(() => _chromeVisible = false);
        await _listen.readFrom(locator);
        return;
      }
    }
    // With the controls showing, a tap anywhere on the page just puts them away (rather
    // than turning the page underneath them).
    if (_chromeVisible) {
      setState(() => _chromeVisible = false);
      return;
    }
    _pageTurner.currentState?.tapAt(point.dx, y: point.dy);
  }

  /// The reminder of the story so far, from what the companion kept, never past [location].
  Future<void> _showPreviously(ReaderLocation location) async {
    final keeper = _keeper;
    final place = keeper?.placeOf(location);
    if (keeper == null || place == null) return;
    try {
      final data = await keeper.memory.load(place: place, title: _book?.title ?? keeper.title, authors: keeper.authors);
      final previously = previouslyOn(data);
      if (!mounted || previously == null) return;
      setState(() {
        _previously = previously;
        _previouslyAt = location.position;
      });
    } catch (_) {
      // Nothing kept yet to remind them of.
    }
  }

  /// What a selected passage means, from the phone's model, with the story so far (never past
  /// this page) for context.
  Future<void> _explain(ReaderSelection selection) async {
    final keeper = _keeper;
    final location = _location;
    final place = location == null ? null : keeper?.placeOf(location);
    String? story;
    if (keeper != null && place != null) {
      try {
        story = (await keeper.memory.load(place: place, title: keeper.title, authors: keeper.authors)).story?.story;
      } catch (_) {
        // Explained without it.
      }
    }
    if (!mounted) return;
    final selected = selection.text!.trim();
    await showExplainSheet(
      context,
      selected: selected,
      paragraph: selection.paragraphText ?? [selection.before, selected, selection.after].whereType<String>().join(' '),
      title: _book?.title ?? _publication?.title ?? '',
      authors: _book?.authors.join(', '),
      story: story,
    );
  }

  /// Who someone is, or a recap: from the book up to this page.
  Future<void> _ask({String? name}) async {
    final publication = _publication;
    final keeper = _keeper;
    final location = _location;
    final place = location == null ? null : keeper?.placeOf(location);
    if (publication == null || keeper == null || place == null) return;
    if (_chromeVisible) _toggleChrome();
    // The page on screen kept first, so the companion has it.
    await keeper.flush();
    if (!mounted) return;
    await showCompanionSheet(
      context,
      bookId: widget.bookId,
      place: place,
      title: _book?.title ?? publication.title,
      authors: _book?.authors.join(', '),
      name: name,
    );
  }

  Future<void> _startListening() async {
    final publication = _publication;
    if (publication == null) return;
    if (_chromeVisible) _toggleChrome();
    // From the first sentence that starts on this page, not the top of its paragraph.
    final start = await _controller?.firstVisibleSentence() ?? _location?.locatorJson;
    final error = await _listen.start(
      publication.id,
      start,
      language: _book?.language ?? publication.language,
    );
    if (error != null) _say(error);
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
    _syncHighlights(theme.brightness, ref.watch(othersNotesProvider(widget.bookId)));

    final listening = ref.watch(listenProvider.select((s) => s.active));
    ref.listen(listenProvider.select((s) => (s.sentenceLocator, s.following)), (previous, next) {
      final (locator, following) = next;
      // Coming back to the voice moves to it; otherwise only a new sentence does.
      if (locator == previous?.$1 && (following == previous?.$2 || !following)) return;
      _controller?.setSpokenSentence(locator, theme.ink.withValues(alpha: 0.18).toARGB32(), follow: following);
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
          body: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: _onPointerDown,
            onPointerUp: _onPointerUp,
            onPointerCancel: (_) {
              _touch = null;
              _checkSelectionSoon();
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                Column(
                  children: [
                    if (_publication != null) _buildHeader(theme, showClock: prefs.showClock),
                    Expanded(child: _buildPages(prefs, theme, readium)),
                    if (listening) PlayerBar(theme: theme),
                    if (_publication != null) _buildFooter(theme),
                  ],
                ),
                if (_search.index != null && !_chromeVisible) _buildSearchBar(theme),
                if (_previously case final previously? when !_chromeVisible && !_selecting)
                  Positioned(
                    left: Space.gutter,
                    right: Space.gutter,
                    bottom: MediaQuery.viewPaddingOf(context).bottom + 40,
                    child: PreviouslyCard(
                      heading: previously.heading,
                      text: previously.text,
                      page: theme.page,
                      ink: theme.ink,
                      muted: theme.muted,
                      onClose: () => setState(() => _previously = null),
                      onMore: () {
                        setState(() => _previously = null);
                        _ask();
                      },
                    ),
                  ),
                _buildTopBar(theme),
                _buildBottomPanel(theme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Color? get _coverColor => _book?.coverColor == null ? null : Color(_book!.coverColor!);

  /// Where and when a touch began, to tell a tap from a long press or a drag.
  ({Offset at, DateTime when})? _touch;

  void _onPointerDown(PointerDownEvent event) => _touch = (at: event.position, when: DateTime.now());

  /// A tap anywhere while text is selected (the page, the bands around it) ends the selection,
  /// as a tap outside selected text does everywhere else. The selection's own menu and handles
  /// aren't Flutter's, so touching them doesn't come here; a long press (choosing other text)
  /// or a drag doesn't count.
  void _onPointerUp(PointerUpEvent event) {
    final touch = _touch;
    _touch = null;
    _checkSelectionSoon();
    if (touch == null) return;
    final tap = (event.position - touch.at).distance < 12 && DateTime.now().difference(touch.when) < const Duration(milliseconds: 350);
    if (!tap) return;
    if (_selecting) {
      _controller?.clearSelection();
      _setSelecting(false);
    } else if (!_chromeVisible && _previously == null) {
      unawaited(_recoverTap(event.position));
    }
  }

  /// A tap on the page with nothing selected that the page may have swallowed: Readium only
  /// reports taps while no text is selected, and a selection can be left behind where it can't
  /// be seen (in a chapter beside the one shown). If one was, it's cleared, and the tap does what
  /// it would have done.
  Future<void> _recoverTap(Offset position) async {
    final controller = _controller;
    if (controller == null) return;
    if (!await controller.clearStaleSelection() || !mounted) return;
    final size = MediaQuery.sizeOf(context);
    await _onPageTap(Offset(position.dx / size.width, position.dy / size.height));
  }

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
          // Scrolling moves the text itself; side taps and swipes jump a screen. PDF and
          // comic pages move themselves too.
          style: prefs.scroll || publication.isFixedLayout ? TurnStyle.none : prefs.turnStyle,
          pageBack: theme.pageBack,
          rightToLeft: publication.isRightToLeft,
          haptics: prefs.haptics,
          tapToTurn: prefs.tapToTurn,
          enabled: !_selecting,
          onCenterTap: _toggleChrome,
          // Turning by hand while listening: the page stops following the voice.
          onTurned: _listen.stopFollowing,
          child: ReadiumView(
            publicationId: publication.id,
            preferences: readium,
            scroll: prefs.scroll,
            nativeGestures: publication.isFixedLayout,
            initialLocatorJson: _initialLocator,
            onCreated: (controller) => setState(() {
              _controller = controller;
              _sentPreferences = readium;
              _sentHighlights = null;
            }),
            onLocationChanged: _onLocationChanged,
            onTap: _onPageTap,
            onSelection: _onSelection,
            onHighlightTapped: _onHighlightTapped,
            onFootnote: _onFootnote,
            selecting: _selecting,
            onSelectionActive: _setSelecting,
          ),
        ),
        if (prefs.brightnessSwipe && !prefs.scroll && !_selecting)
          Positioned.fill(child: _BrightnessEdge(device: _device, theme: theme)),
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

  /// The band above the page: as tall as the notch (or 26 for the clock on phones without
  /// one), with the time in its corner beside the camera, where the status bar's clock would
  /// be. The system bars stay hidden while reading; when one is pulled down, the time fades.
  Widget _buildHeader(PageColors theme, {required bool showClock}) {
    final inset = MediaQuery.viewPaddingOf(context).top;
    final height = showClock && inset < 26 ? 26.0 : inset;
    if (height == 0) return const SizedBox.shrink();
    if (!showClock) return SizedBox(height: height);
    // A camera in the left corner: the time goes on the right.
    final width = MediaQuery.sizeOf(context).width;
    final cameraLeft = MediaQuery.displayFeaturesOf(context).any(
      (f) => f.type == ui.DisplayFeatureType.cutout && f.bounds.top <= height && f.bounds.center.dx < width / 3,
    );
    return SizedBox(
      height: height,
      child: AnimatedOpacity(
        opacity: _systemBarsShown ? 0 : 1,
        duration: const Duration(milliseconds: 150),
        child: Align(
          alignment: cameraLeft ? Alignment.centerRight : Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            child: _Clock(
              style: TextStyle(
                fontFamily: FontFamilies.ui,
                fontSize: 12,
                color: theme.muted,
                fontFeatures: const [ui.FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Where the reader is in the chapter, and progress through the book, quiet under the page.
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
                child: Text(
                  _chapterProgress() ?? '',
                  style: style,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (total != null) Text('  ${(total * 100).round()}%', style: style),
            ],
          ),
        ),
      ),
    );
  }

  String? _chapterProgress() {
    final location = _location;
    final publication = _publication;
    if (location == null || publication == null) return null;
    return chapterProgress(
      publication,
      href: location.href,
      position: location.position,
      progression: location.progression,
      secondsPerPosition: _state.secondsPerPosition,
    );
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
                  // PDF and comics have no text to search.
                  if (!(_publication?.isFixedLayout ?? false))
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

  /// "4 h left in the book · done by Friday at your pace", for the bottom panel.
  String? _bookTimeLeft() {
    final position = _location?.position;
    final chapters = _publication?.chapters;
    if (position == null || chapters == null || chapters.isEmpty) return null;
    final sessions = ref.watch(sessionsProvider).value ?? const <ReadingSession>[];
    final now = DateTime.now();
    return bookTimeLeft(
      positionsLeft: chapters.last.end - position,
      secondsPerPosition: _state.secondsPerPosition,
      secondsReadByDay: secondsByDay([for (final s in sessions) (startedAt: s.startedAt, seconds: s.seconds)], now),
      now: now,
    );
  }

  Widget _buildBottomPanel(PageColors theme) {
    final text = Theme.of(context).textTheme;
    final total = _scrubValue ?? _location?.totalProgression ?? 0;
    final chapter = _location?.title;
    final bookLeft = _scrubValue == null ? _bookTimeLeft() : null;

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
                  if (bookLeft != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        bookLeft,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(color: theme.muted),
                      ),
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
                      if (!(_publication?.isFixedLayout ?? false))
                        _ChromeButton(
                          icon: Icons.auto_awesome_outlined,
                          label: 'Ask',
                          color: theme.ink,
                          onPressed: () => _ask(),
                        ),
                      if (!(_publication?.isFixedLayout ?? false))
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

  // A view that never answers (closed mid-turn, a page that never settles) mustn't hold a
  // turn, and its pictures, on screen: no picture, or no move, after a few seconds.
  static const _wait = Duration(seconds: 3);

  @override
  Future<ui.Image?> snapshot() => _controller.snapshot().timeout(_wait, onTimeout: () => null);

  @override
  Future<bool> goForward() => _controller.goForward().timeout(_wait, onTimeout: () => false);

  @override
  Future<bool> goBackward() => _controller.goBackward().timeout(_wait, onTimeout: () => false);

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

  /// Icon over label, in an equal share of the row: four fit on a narrow phone, at any text size.
  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: color,
          padding: const EdgeInsets.symmetric(vertical: Space.sm),
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22),
            const SizedBox(height: 4),
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
          ],
        ),
      ),
    );
  }
}

/// The time of day, in the device's 12 or 24 hour style, changing on the minute.
class _Clock extends StatefulWidget {
  const _Clock({required this.style});

  final TextStyle style;

  @override
  State<_Clock> createState() => _ClockState();
}

class _ClockState extends State<_Clock> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _scheduleTick();
  }

  void _scheduleTick() {
    final now = DateTime.now();
    final nextMinute = DateTime(now.year, now.month, now.day, now.hour, now.minute + 1);
    _timer = Timer(nextMinute.difference(now), () {
      if (!mounted) return;
      setState(() {});
      _scheduleTick();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final time = MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.now(),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
    return Text(time, style: widget.style, maxLines: 1);
  }
}

/// A strip down the page's left edge: sliding along it sets the screen's brightness, with
/// the level showing while it moves.
class _BrightnessEdge extends StatefulWidget {
  const _BrightnessEdge({required this.device, required this.theme});

  final DeviceControls device;
  final PageColors theme;

  @override
  State<_BrightnessEdge> createState() => _BrightnessEdgeState();
}

class _BrightnessEdgeState extends State<_BrightnessEdge> {
  /// The brightness being set, while sliding.
  double? _level;
  double _start = 0.5;
  double _travel = 0;

  Future<void> _begin() async {
    _travel = 0;
    _start = _level ?? await widget.device.brightness();
    if (mounted) setState(() => _level = _start);
  }

  void _move(DragUpdateDetails details) {
    if (_level == null) return;
    // Up is brighter; the full range is most of the screen's height.
    _travel -= details.delta.dy / (context.size!.height * 0.7);
    final level = (_start + _travel).clamp(0.01, 1.0);
    setState(() => _level = level);
    widget.device.setBrightness(level);
  }

  void _end() {
    Future<void>.delayed(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _level = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final level = _level;
    final theme = widget.theme;
    return Stack(
      children: [
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: 28,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onVerticalDragStart: (_) => _begin(),
            onVerticalDragUpdate: _move,
            onVerticalDragEnd: (_) => _end(),
            onVerticalDragCancel: _end,
          ),
        ),
        Center(
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: level == null ? 0 : 1,
              duration: Motion.quick,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.sm),
                decoration: BoxDecoration(
                  color: theme.ink.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(Radii.lg),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.brightness_6_outlined, size: 18, color: theme.page),
                    const SizedBox(width: Space.sm),
                    Text(
                      '${((level ?? 0) * 100).round()}%',
                      style: TextStyle(fontFamily: FontFamilies.ui, color: theme.page, fontSize: 14),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
