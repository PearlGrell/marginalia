import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cloud/account.dart';
import '../data/database.dart';
import '../theme/tokens.dart';
import 'share_service.dart';

/// Opens Android's share sheet with [text].
Future<void> shareText(String text) =>
    const MethodChannel('marginalia/device').invokeMethod('shareText', {'text': text});

String shareMessage(Share share) =>
    '${share.ownerName} shared “${share.title}” with you on Marginalia.\n\n'
    'Open: ${share.link}\n'
    'Or in Marginalia, go to Discover → Shared with you → Enter a code: ${share.code}';

/// Share [books] (one book, or a collection titled [title]) with friends or family.
Future<void> showShareSheet(BuildContext context, {required List<Book> books, required String title}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _ShareSheet(books: books, title: title),
  );
}

class _ShareSheet extends ConsumerStatefulWidget {
  const _ShareSheet({required this.books, required this.title});

  final List<Book> books;
  final String title;

  @override
  ConsumerState<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends ConsumerState<_ShareSheet> {
  bool _allowed = false;
  bool _working = false;
  String? _step;
  String? _error;
  Share? _share;

  Future<void> _create() async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final share = await ref.read(shareServiceProvider).create(
        widget.books,
        title: widget.title,
        onStep: (s) => mounted ? setState(() => _step = s) : null,
      );
      ref.invalidate(mySharesProvider);
      setState(() => _share = share);
    } on ShareException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = "Sharing didn't finish: $e");
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurfaceVariant;
    final signedIn = ref.watch(accountProvider).signedIn;
    final share = _share;
    final count = widget.books.length;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(share == null ? 'Share with someone' : 'Ready to send', style: text.headlineSmall),
            const SizedBox(height: Space.xs),
            Text(
              count == 1 ? widget.title : '${widget.title} · $count books',
              style: text.bodyLarge?.copyWith(color: muted),
            ),
            const SizedBox(height: Space.lg),
            if (!signedIn)
              Text('Sign in under Settings to share books.', style: text.bodyLarge)
            else if (share != null) ...[
              Text('Their code', style: text.labelSmall, textAlign: TextAlign.center),
              const SizedBox(height: Space.sm),
              SelectableText(
                share.code,
                textAlign: TextAlign.center,
                style: text.headlineMedium?.copyWith(fontFamily: FontFamilies.ui, letterSpacing: 2),
              ),
              const SizedBox(height: Space.sm),
              Text(
                'Anyone with this code can add ${count == 1 ? 'the book' : 'these books'} to their '
                'library. Stop sharing any time in Settings → Shared by you.',
                textAlign: TextAlign.center,
                style: text.bodySmall?.copyWith(color: muted),
              ),
              const SizedBox(height: Space.lg),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.copy_outlined, size: 18),
                      label: const Text('Copy'),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: shareMessage(share)));
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
                      },
                    ),
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: FilledButton.icon(
                      icon: const Icon(Icons.send_outlined, size: 18),
                      label: const Text('Send'),
                      onPressed: () => shareText(shareMessage(share)),
                    ),
                  ),
                ],
              ),
            ] else ...[
              Text(
                'A copy of ${count == 1 ? 'the book' : 'each book'} goes to a “Marginalia shared” '
                'folder in your Google Drive, readable by anyone with the code you send. Your '
                'notes and highlights stay private.',
                style: text.bodyMedium,
              ),
              const SizedBox(height: Space.md),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _allowed,
                onChanged: _working ? null : (v) => setState(() => _allowed = v ?? false),
                title: const Text("I'm allowed to share these books"),
                subtitle: const Text('For example: public domain, Creative Commons, or your own writing'),
              ),
              if (_working) ...[
                const LinearProgressIndicator(minHeight: 2),
                const SizedBox(height: Space.xs),
                Text(_step ?? 'Preparing…', style: text.bodySmall),
              ],
              if (_error case final error?)
                Padding(
                  padding: const EdgeInsets.only(top: Space.sm),
                  child: Text(error, style: text.bodySmall?.copyWith(color: scheme.error)),
                ),
              const SizedBox(height: Space.md),
              FilledButton.icon(
                icon: const Icon(Icons.ios_share),
                label: const Text('Create a share code'),
                onPressed: _allowed && !_working ? _create : null,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
