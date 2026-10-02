import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cloud/sync_service.dart';
import '../data/library.dart';
import '../storage/local_store.dart';
import '../theme/tokens.dart';

/// A folder whose new EPUBs come into the library by themselves.
class WatchedFolder {
  const WatchedFolder({required this.uri, required this.name, this.seen = const {}, this.lastScan, this.error});

  factory WatchedFolder.fromJson(Map<String, Object?> json) => WatchedFolder(
    uri: json['uri']! as String,
    name: json['name'] as String? ?? 'Folder',
    seen: {...((json['seen'] as List?) ?? const []).cast<String>()},
    lastScan: json['lastScan'] == null ? null : DateTime.fromMillisecondsSinceEpoch(json['lastScan']! as int),
    error: json['error'] as String?,
  );

  final String uri;
  final String name;

  /// Files already looked at (see [fileKey]), so each is imported once.
  final Set<String> seen;
  final DateTime? lastScan;
  final String? error;

  Map<String, Object?> toJson() => {
    'uri': uri,
    'name': name,
    'seen': seen.toList(),
    'lastScan': lastScan?.millisecondsSinceEpoch,
    'error': error,
  };

  WatchedFolder copyWith({Set<String>? seen, DateTime? lastScan, String? error, bool clearError = false}) =>
      WatchedFolder(
        uri: uri,
        name: name,
        seen: seen ?? this.seen,
        lastScan: lastScan ?? this.lastScan,
        error: clearError ? null : (error ?? this.error),
      );

  /// A file changes key when it's replaced, so an updated EPUB is imported again.
  static String fileKey(Map<Object?, Object?> file) => '${file['uri']}|${file['size']}|${file['modified']}';

  /// "primary:Books/Calibre" → "Books/Calibre".
  static String nameOf(String treeUri) {
    final decoded = Uri.decodeComponent(treeUri.split('/tree/').last.split('/document/').first);
    final colon = decoded.indexOf(':');
    final path = colon < 0 ? decoded : decoded.substring(colon + 1);
    return path.isEmpty ? 'Phone storage' : path;
  }
}

/// Folders the reader asked to watch. They're checked when the app opens or comes back,
/// at most every few minutes; new EPUBs are imported (duplicates are skipped as always).
class WatchedFolders extends Notifier<List<WatchedFolder>> {
  static const _key = 'library.watchedFolders';
  static const _channel = MethodChannel('marginalia/library');
  static const _minGap = Duration(minutes: 5);

  bool _scanning = false;

  @override
  List<WatchedFolder> build() {
    final list = ref.read(localStoreProvider).readJson(_key);
    return [
      for (final item in (list as List?) ?? const [])
        if (item is Map<String, Object?>) WatchedFolder.fromJson(item),
    ];
  }

  Future<void> _save(List<WatchedFolder> folders) async {
    state = folders;
    await ref.read(localStoreProvider).writeJson(_key, [for (final f in folders) f.toJson()]);
  }

  /// Picks a folder to watch, and imports what's in it now. Returns the number added.
  Future<int?> add() async {
    final uri = await _channel.invokeMethod<String>('pickFolder');
    if (uri == null || state.any((f) => f.uri == uri)) return null;
    await _save([...state, WatchedFolder(uri: uri, name: WatchedFolder.nameOf(uri))]);
    return scan(force: true);
  }

  Future<void> remove(String uri) => _save([for (final f in state) if (f.uri != uri) f]);

  /// Looks for new books in every folder; returns how many were added.
  Future<int> scan({bool force = false}) async {
    if (_scanning || state.isEmpty) return 0;
    final now = DateTime.now();
    if (!force && state.every((f) => f.lastScan != null && now.difference(f.lastScan!) < _minGap)) return 0;
    _scanning = true;
    var added = 0;
    try {
      final importer = ref.read(libraryImporterProvider.notifier);
      for (final folder in [...state]) {
        List<Map<Object?, Object?>> files;
        try {
          files = await _channel.invokeListMethod<Map<Object?, Object?>>('scanFolder', {'uri': folder.uri}) ?? const [];
        } on PlatformException {
          await _replace(folder.copyWith(lastScan: now, error: "Can't open this folder any more. Remove it and add it again."));
          continue;
        }
        final fresh = [for (final f in files) if (!folder.seen.contains(WatchedFolder.fileKey(f))) f];
        if (fresh.isNotEmpty && !ref.read(libraryImporterProvider).running) {
          final result = await importer.importUris([
            for (final f in fresh) (uri: f['uri']! as String, name: f['name']! as String),
          ]);
          added += result.added;
        }
        // Remember every file there now; forget ones that are gone.
        await _replace(folder.copyWith(seen: {for (final f in files) WatchedFolder.fileKey(f)}, lastScan: now, clearError: true));
      }
    } finally {
      _scanning = false;
    }
    if (added > 0) unawaited(ref.read(syncProvider.notifier).scheduleSoon());
    return added;
  }

  Future<void> _replace(WatchedFolder folder) =>
      _save([for (final f in state) f.uri == folder.uri ? folder : f]);
}

final watchedFoldersProvider = NotifierProvider<WatchedFolders, List<WatchedFolder>>(WatchedFolders.new);

class WatchedFoldersScreen extends ConsumerStatefulWidget {
  const WatchedFoldersScreen({super.key});

  @override
  ConsumerState<WatchedFoldersScreen> createState() => _WatchedFoldersScreenState();
}

class _WatchedFoldersScreenState extends ConsumerState<WatchedFoldersScreen> {
  bool _busy = false;

  Future<void> _run(Future<int?> Function() action) async {
    setState(() => _busy = true);
    try {
      final added = await action();
      if (added != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(added == 0 ? 'No new books' : '$added ${added == 1 ? 'book' : 'books'} added')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final folders = ref.watch(watchedFoldersProvider);
    final notifier = ref.read(watchedFoldersProvider.notifier);
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Watched folders'),
        actions: [
          if (folders.isNotEmpty)
            IconButton(
              tooltip: 'Check now',
              icon: const Icon(Icons.refresh),
              onPressed: _busy ? null : () => _run(() => notifier.scan(force: true)),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : () => _run(notifier.add),
        icon: const Icon(Icons.create_new_folder_outlined),
        label: const Text('Watch a folder'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 120),
        children: [
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, Space.md),
            child: Text(
              'EPUBs you put in these folders (from a download, Calibre, a USB cable) join your '
              'library by themselves, each time Marginalia opens. Books already in your library '
              'are skipped.',
              style: text.bodyMedium?.copyWith(color: muted),
            ),
          ),
          for (final f in folders)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: Space.gutter),
              leading: Icon(f.error == null ? Icons.folder_outlined : Icons.folder_off_outlined),
              title: Text(f.name),
              subtitle: Text(
                f.error ??
                    [
                      '${f.seen.length} ${f.seen.length == 1 ? 'book' : 'books'}',
                      if (f.lastScan case final t?) 'checked ${_ago(t)}',
                    ].join(' · '),
              ),
              trailing: IconButton(
                tooltip: 'Stop watching',
                icon: const Icon(Icons.close),
                onPressed: () => notifier.remove(f.uri),
              ),
            ),
        ],
      ),
    );
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    return '${d.inDays} ${d.inDays == 1 ? 'day' : 'days'} ago';
  }
}
