import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/library.dart';
import '../readium/readium.dart';
import '../storage/local_store.dart';
import '../theme/tokens.dart';

final annotationsProvider = StreamProvider.family<List<Annotation>, String>(
  (ref, bookId) => ref.watch(databaseProvider).watchAnnotations(bookId),
);

/// Text selected in the reader, with what the selection menu was used for.
class ReaderSelection {
  const ReaderSelection({
    required this.action,
    required this.locatorJson,
    this.text,
    this.before,
    this.after,
    this.chapterTitle,
    this.progression,
    this.paragraphId,
    this.paragraphText,
  });

  factory ReaderSelection.fromMap(Map<Object?, Object?> map) => ReaderSelection(
    action: map['action']! as String,
    locatorJson: map['locator']! as String,
    text: map['text'] as String?,
    before: map['before'] as String?,
    after: map['after'] as String?,
    chapterTitle: map['chapterTitle'] as String?,
    progression: (map['progression'] as num?)?.toDouble(),
    paragraphId: map['paragraphId'] as String?,
    paragraphText: map['paragraphText'] as String?,
  );

  /// highlight, note, define, translate or copy.
  final String action;
  final String locatorJson;
  final String? text;
  final String? before;
  final String? after;
  final String? chapterTitle;
  final double? progression;

  /// For translate: the paragraph around the selection, marked so a translation can be shown
  /// under it.
  final String? paragraphId;
  final String? paragraphText;
}

extension AnnotationLook on Annotation {
  HighlightColor get highlightColor =>
      HighlightColor.values.where((c) => c.name == color).firstOrNull ?? HighlightColor.yellow;

  /// Whether this bookmark is on the page at [location].
  bool isOnPage(ReaderLocation location) {
    if (position != null && location.position != null) return position == location.position;
    final a = progression;
    final b = location.totalProgression;
    return locatorHref == location.href && a != null && b != null && (a - b).abs() < 0.001;
  }

  String? get locatorHref => RegExp(r'"href"\s*:\s*"([^"]*)"').firstMatch(locator)?.group(1);
}

/// Creating and changing a book's annotations.
class AnnotationStore {
  AnnotationStore(this._db, this._store);

  final AppDatabase _db;
  final LocalStore _store;

  static const _colorKey = 'reader.highlightColor';

  static String _newId() => DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  /// The color of the last highlight, used for the next one.
  HighlightColor get lastColor =>
      HighlightColor.values.where((c) => c.name == _store.readJson(_colorKey)).firstOrNull ??
      HighlightColor.yellow;

  Future<String> addHighlight(String bookId, ReaderSelection s, {String? note}) async {
    final id = _newId();
    final now = DateTime.now();
    await _db.saveAnnotation(
      AnnotationsCompanion.insert(
        id: id,
        bookId: bookId,
        type: note == null ? AnnotationType.highlight : AnnotationType.note,
        locator: s.locatorJson,
        selectedText: Value(s.text),
        textBefore: Value(s.before),
        textAfter: Value(s.after),
        color: Value(lastColor.name),
        note: Value(note),
        chapterTitle: Value(s.chapterTitle),
        progression: Value(s.progression),
        createdAt: now,
        updatedAt: now,
      ),
    );
    return id;
  }

  Future<void> setColor(String id, HighlightColor color) async {
    await _store.writeJson(_colorKey, color.name);
    await _db.updateAnnotation(id, AnnotationsCompanion(color: Value(color.name)));
  }

  /// An empty note turns a note back into a plain highlight.
  Future<void> setNote(String id, String note) {
    final trimmed = note.trim();
    return _db.updateAnnotation(
      id,
      AnnotationsCompanion(
        note: Value(trimmed.isEmpty ? null : trimmed),
        type: Value(trimmed.isEmpty ? AnnotationType.highlight : AnnotationType.note),
      ),
    );
  }

  Future<void> addBookmark(String bookId, ReaderLocation location) {
    final now = DateTime.now();
    return _db.saveAnnotation(
      AnnotationsCompanion.insert(
        id: _newId(),
        bookId: bookId,
        type: AnnotationType.bookmark,
        locator: location.locatorJson,
        chapterTitle: Value(location.title),
        progression: Value(location.totalProgression),
        position: Value(location.position),
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  Future<void> delete(String id) => _db.deleteAnnotation(id);

  /// Bookmarks from before the annotations table were kept in key-value storage.
  Future<void> migrateLegacyBookmarks(String bookId) async {
    final key = 'book.bookmarks.$bookId';
    final list = _store.readJson(key);
    if (list is! List || list.isEmpty) return;
    for (final item in list.whereType<Map<String, Object?>>()) {
      final created = DateTime.fromMillisecondsSinceEpoch(item['createdAt'] as int? ?? 0);
      await _db.saveAnnotation(
        AnnotationsCompanion.insert(
          id: item['id']! as String,
          bookId: bookId,
          type: AnnotationType.bookmark,
          locator: item['locator']! as String,
          chapterTitle: Value(item['chapterTitle'] as String?),
          progression: Value((item['progression'] as num?)?.toDouble()),
          position: Value(item['position'] as int?),
          createdAt: created,
          updatedAt: created,
        ),
      );
    }
    await _store.remove(key);
  }
}

final annotationStoreProvider = Provider<AnnotationStore>(
  (ref) => AnnotationStore(ref.watch(databaseProvider), ref.watch(localStoreProvider)),
);

/// Edit a highlight or note: its color and note, or copy or delete it.
Future<void> showAnnotationSheet(
  BuildContext context, {
  required Annotation annotation,
  required AnnotationStore store,
  bool editNote = false,
  required VoidCallback onCopy,
  VoidCallback? onShareStory,
  VoidCallback? onShareLink,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: _AnnotationSheet(
        annotation: annotation,
        store: store,
        editNote: editNote,
        onCopy: onCopy,
        onShareStory: onShareStory,
        onShareLink: onShareLink,
      ),
    ),
  );
}

class _AnnotationSheet extends StatefulWidget {
  const _AnnotationSheet({
    required this.annotation,
    required this.store,
    required this.editNote,
    required this.onCopy,
    this.onShareStory,
    this.onShareLink,
  });

  final Annotation annotation;
  final AnnotationStore store;
  final bool editNote;
  final VoidCallback onCopy;

  /// Share the passage as a story card.
  final VoidCallback? onShareStory;

  /// Send it as a link.
  final VoidCallback? onShareLink;

  @override
  State<_AnnotationSheet> createState() => _AnnotationSheetState();
}

class _AnnotationSheetState extends State<_AnnotationSheet> {
  late HighlightColor _color = widget.annotation.highlightColor;
  late final _note = TextEditingController(text: widget.annotation.note ?? '');
  bool _deleted = false;

  @override
  void dispose() {
    // Closing the sheet any way keeps what was typed.
    if (!_deleted && _note.text.trim() != (widget.annotation.note ?? '')) {
      widget.store.setNote(widget.annotation.id, _note.text);
    }
    _note.dispose();
    super.dispose();
  }

  void _pick(HighlightColor color) {
    setState(() => _color = color);
    widget.store.setColor(widget.annotation.id, color);
  }

  Future<void> _delete() async {
    _deleted = true;
    await widget.store.delete(widget.annotation.id);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final brightness = Theme.of(context).brightness;
    final hasNote = widget.annotation.note?.isNotEmpty ?? false;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(hasNote || widget.editNote ? 'Note' : 'Highlight', style: text.headlineSmall),
            const SizedBox(height: Space.md),
            if (widget.annotation.selectedText case final quote?)
              Container(
                padding: const EdgeInsets.fromLTRB(Space.md, Space.sm, Space.md, Space.sm),
                decoration: BoxDecoration(
                  color: _color.resolve(brightness).withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(Radii.sm),
                  border: Border(left: BorderSide(color: _color.resolve(brightness), width: 4)),
                ),
                child: Text(
                  quote.trim(),
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodyLarge?.copyWith(fontFamily: FontFamilies.reading, height: 1.5),
                ),
              ),
            const SizedBox(height: Space.xl),
            Text('COLOR', style: text.labelSmall),
            const SizedBox(height: Space.sm),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (final color in HighlightColor.values)
                  Semantics(
                    button: true,
                    selected: color == _color,
                    label: '${color.name} highlight',
                    child: InkResponse(
                      onTap: () => _pick(color),
                      radius: 30,
                      child: Column(
                        children: [
                          AnimatedContainer(
                            duration: Motion.quick,
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: color.resolve(brightness),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: color == _color ? scheme.onSurface : Colors.transparent,
                                width: 2.5,
                              ),
                            ),
                            child: color == _color
                                ? Icon(Icons.check, size: 22, color: scheme.onSurface)
                                : null,
                          ),
                          const SizedBox(height: Space.xs),
                          Text(
                            color.name[0].toUpperCase() + color.name.substring(1),
                            style: text.labelSmall?.copyWith(
                              color: color == _color ? scheme.onSurface : null,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: Space.xl),
            Text('NOTE', style: text.labelSmall),
            const SizedBox(height: Space.sm),
            TextField(
              controller: _note,
              autofocus: widget.editNote,
              minLines: 3,
              maxLines: 8,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: 'Add your thoughts…',
                filled: true,
                fillColor: scheme.surfaceContainer,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Radii.md),
                  borderSide: BorderSide(color: scheme.outlineVariant),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Radii.md),
                  borderSide: BorderSide(color: scheme.outlineVariant),
                ),
              ),
            ),
            const SizedBox(height: Space.lg),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton.icon(
                  onPressed: widget.onCopy,
                  icon: const Icon(Icons.copy_outlined, size: 18),
                  label: const Text('Copy'),
                ),
                if (widget.onShareStory case final share?)
                  TextButton.icon(
                    onPressed: () {
                      // Keep the note being typed, then hand over to the story sheet.
                      if (_note.text.trim() != (widget.annotation.note ?? '')) {
                        widget.store.setNote(widget.annotation.id, _note.text);
                      }
                      Navigator.pop(context);
                      share();
                    },
                    icon: const Icon(Icons.auto_awesome_mosaic_outlined, size: 18),
                    label: const Text('Story'),
                  ),
                if (widget.onShareLink case final link?)
                  TextButton.icon(
                    onPressed: () {
                      if (_note.text.trim() != (widget.annotation.note ?? '')) {
                        widget.store.setNote(widget.annotation.id, _note.text);
                      }
                      Navigator.pop(context);
                      link();
                    },
                    icon: const Icon(Icons.link, size: 18),
                    label: const Text('Link'),
                  ),
                TextButton.icon(
                  onPressed: _delete,
                  icon: Icon(Icons.delete_outline, size: 18, color: scheme.error),
                  label: Text('Delete', style: TextStyle(color: scheme.error)),
                ),
              ],
            ),
            const SizedBox(height: Space.sm),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }
}
