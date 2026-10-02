import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../cloud/account.dart';
import '../data/database.dart';
import '../data/library.dart';
import '../theme/tokens.dart';
import 'share_sheet.dart';
import 'share_service.dart';

/// Asks for a share code and opens it.
Future<void> enterShareCode(BuildContext context) async {
  final code = await showDialog<String>(context: context, builder: (_) => const _CodeDialog());
  if (code != null && code.trim().isNotEmpty && context.mounted) {
    context.push('/share/${ShareService.normalizeCode(code)}');
  }
}

class _CodeDialog extends StatefulWidget {
  const _CodeDialog();

  @override
  State<_CodeDialog> createState() => _CodeDialogState();
}

class _CodeDialogState extends State<_CodeDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Enter a code'),
    content: TextField(
      controller: _controller,
      autofocus: true,
      textCapitalization: TextCapitalization.characters,
      decoration: const InputDecoration(hintText: 'ABCD-EFGH-JKLM'),
      onSubmitted: (v) => Navigator.pop(context, v),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      TextButton(onPressed: () => Navigator.pop(context, _controller.text), child: const Text('Open')),
    ],
  );
}

/// "Shared with you" at the top of Discover.
class SharedWithYouRow extends ConsumerWidget {
  const SharedWithYouRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(accountProvider).signedIn) return const SizedBox.shrink();
    final shares = ref.watch(receivedSharesProvider).value ?? const <Share>[];
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.gutter, Space.xl, Space.sm, Space.sm),
          child: Row(
            children: [
              Expanded(child: Text('Shared with you', style: text.titleLarge)),
              TextButton.icon(
                icon: const Icon(Icons.vpn_key_outlined, size: 18),
                label: const Text('Enter a code'),
                onPressed: () => enterShareCode(context),
              ),
            ],
          ),
        ),
        if (shares.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            child: Text(
              'When friends or family share books with you, they appear here.',
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          )
        else
          SizedBox(
            height: 96,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
              itemCount: shares.length,
              separatorBuilder: (_, _) => const SizedBox(width: Space.md),
              itemBuilder: (context, i) {
                final share = shares[i];
                return InkWell(
                  borderRadius: BorderRadius.circular(Radii.lg),
                  onTap: () => context.push('/share/${share.code}'),
                  child: Container(
                    width: 240,
                    padding: const EdgeInsets.all(Space.md),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainer,
                      borderRadius: BorderRadius.circular(Radii.lg),
                      border: Border.all(color: scheme.outlineVariant),
                    ),
                    child: Row(
                      children: [
                        _SharedCover(book: share.books.firstOrNull, width: 44),
                        const SizedBox(width: Space.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(share.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: text.titleSmall),
                              Text(
                                'From ${share.ownerName}'
                                '${share.books.length > 1 ? ' · ${share.books.length} books' : ''}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: text.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _SharedCover extends StatelessWidget {
  const _SharedCover({required this.book, required this.width});

  final SharedBook? book;
  final double width;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final url = book?.coverUrl;
    final placeholder = Container(
      color: Color(book?.coverColor ?? scheme.surfaceContainerHighest.toARGB32()),
      alignment: Alignment.center,
      child: Icon(Icons.menu_book_outlined, size: width / 2.4, color: scheme.onSurfaceVariant),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(Radii.sm),
      child: SizedBox(
        width: width,
        height: width * 1.5,
        child: url == null
            ? placeholder
            : Image.network(url, fit: BoxFit.cover, errorBuilder: (_, _, _) => placeholder),
      ),
    );
  }
}

/// One share: its books, each to add to the library.
class SharedScreen extends ConsumerStatefulWidget {
  const SharedScreen({super.key, required this.code});

  final String code;

  @override
  ConsumerState<SharedScreen> createState() => _SharedScreenState();
}

class _SharedScreenState extends ConsumerState<SharedScreen> {
  Future<Share>? _share;
  final _progress = <String, double>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    if (!ref.read(accountProvider).signedIn) return;
    // Opening a share keeps it under "Shared with you".
    _share = ref.read(shareServiceProvider).redeem(widget.code).then((share) {
      ref.invalidate(receivedSharesProvider);
      return share;
    });
  }

  Future<void> _add(Share share, SharedBook book) async {
    setState(() => _progress[book.bookId] = 0);
    try {
      await ref.read(shareServiceProvider).addToLibrary(
        share,
        book,
        onProgress: (p) => mounted ? setState(() => _progress[book.bookId] = p) : null,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _progress.remove(book.bookId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    if (!ref.watch(accountProvider).signedIn) {
      return Scaffold(
        appBar: AppBar(),
        body: Padding(
          padding: const EdgeInsets.all(Space.gutter),
          child: Text('Sign in under Settings to open shared books.', style: text.bodyLarge),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(),
      body: FutureBuilder<Share>(
        future: _share,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Padding(
              padding: const EdgeInsets.all(Space.gutter),
              child: Text('${snapshot.error}', style: text.bodyLarge),
            );
          }
          final share = snapshot.data;
          if (share == null) return const Center(child: CircularProgressIndicator());
          return ListView(
            padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.xxxl),
            children: [
              Text(share.title, style: text.headlineMedium),
              const SizedBox(height: Space.xs),
              Text('Shared by ${share.ownerName}', style: text.bodyLarge?.copyWith(color: muted)),
              const SizedBox(height: Space.xl),
              for (final book in share.books) _bookRow(share, book),
              const SizedBox(height: Space.lg),
              TextButton.icon(
                icon: const Icon(Icons.close),
                label: const Text('Remove from Shared with you'),
                onPressed: () async {
                  await ref.read(shareServiceProvider).forget(share);
                  ref.invalidate(receivedSharesProvider);
                  if (context.mounted) context.pop();
                },
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _bookRow(Share share, SharedBook book) {
    final text = Theme.of(context).textTheme;
    final copy = ref.watch(bookProvider(book.bookId)).value;
    final inLibrary = copy != null && !copy.deleted;
    final progress = _progress[book.bookId];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.sm),
      child: Row(
        children: [
          _SharedCover(book: book, width: 52),
          const SizedBox(width: Space.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(book.title, style: text.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
                if (book.authors.isNotEmpty) Text(book.authors.join(', '), style: text.bodySmall),
                if (progress != null) ...[
                  const SizedBox(height: Space.xs),
                  LinearProgressIndicator(value: progress == 0 ? null : progress, minHeight: 2),
                ],
              ],
            ),
          ),
          const SizedBox(width: Space.sm),
          if (inLibrary)
            TextButton(onPressed: () => context.push('/read/${book.bookId}'), child: const Text('Read'))
          else
            FilledButton(
              onPressed: progress != null ? null : () => _add(share, book),
              child: const Text('Add'),
            ),
        ],
      ),
    );
  }
}

/// Everything this user has shared, with a way to stop each.
class SharedByYouScreen extends ConsumerWidget {
  const SharedByYouScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shares = ref.watch(mySharesProvider);
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Shared by you')),
      body: switch (shares) {
        AsyncData(value: final list) when list.isEmpty => Padding(
          padding: const EdgeInsets.all(Space.gutter),
          child: Text(
            "You haven't shared anything yet. Share a book from its page, or a whole collection.",
            style: text.bodyLarge,
          ),
        ),
        AsyncData(value: final list) => ListView.separated(
          itemCount: list.length,
          separatorBuilder: (_, _) => const Divider(indent: Space.gutter, endIndent: Space.gutter),
          itemBuilder: (context, i) {
            final share = list[i];
            return ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: Space.gutter, vertical: Space.xs),
              leading: _SharedCover(book: share.books.firstOrNull, width: 36),
              title: Text(share.title),
              subtitle: Text('${share.code} · ${share.books.length} ${share.books.length == 1 ? 'book' : 'books'}'),
              trailing: PopupMenuButton<String>(
                onSelected: (action) async {
                  if (action == 'send') {
                    await shareText(shareMessage(share));
                  } else if (action == 'stop') {
                    await ref.read(shareServiceProvider).revoke(share);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'send', child: Text('Send again')),
                  PopupMenuItem(value: 'stop', child: Text('Stop sharing')),
                ],
              ),
            );
          },
        ),
        AsyncError(:final error) => Padding(
          padding: const EdgeInsets.all(Space.gutter),
          child: Text('$error', style: text.bodyMedium),
        ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

/// The books of a collection, for sharing it.
Future<List<Book>> collectionBooks(WidgetRef ref, String collectionId) =>
    ref.read(databaseProvider).watchBooks(LibraryQuery(collectionId: collectionId)).first;
