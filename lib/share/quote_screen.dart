import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../cloud/account.dart';
import '../theme/tokens.dart';
import 'quote_service.dart';
import 'story_card.dart';

/// A highlight someone shared as a link.
class QuoteScreen extends ConsumerStatefulWidget {
  const QuoteScreen({super.key, required this.code});

  final String code;

  @override
  ConsumerState<QuoteScreen> createState() => _QuoteScreenState();
}

class _QuoteScreenState extends ConsumerState<QuoteScreen> {
  Future<SharedQuote>? _quote;

  @override
  void initState() {
    super.initState();
    if (ref.read(accountProvider).signedIn) _quote = ref.read(quoteServiceProvider).open(widget.code);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    if (!ref.watch(accountProvider).signedIn) {
      return Scaffold(
        appBar: AppBar(),
        body: Padding(
          padding: const EdgeInsets.all(Space.gutter),
          child: Text('Sign in under Settings to open shared highlights.', style: text.bodyLarge),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(),
      body: FutureBuilder<SharedQuote>(
        future: _quote,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Padding(
              padding: const EdgeInsets.all(Space.gutter),
              child: Text('${snapshot.error}', style: text.bodyLarge),
            );
          }
          final quote = snapshot.data;
          if (quote == null) return const Center(child: CircularProgressIndicator());
          final accent = (HighlightColor.values.where((c) => c.name == quote.color).firstOrNull ?? HighlightColor.yellow)
              .resolve(Theme.of(context).brightness);
          return ListView(
            padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.xxxl),
            children: [
              Text('${quote.ownerName} shared a passage', style: text.labelLarge?.copyWith(color: scheme.onSurfaceVariant)),
              const SizedBox(height: Space.lg),
              Container(
                padding: const EdgeInsets.only(left: Space.lg),
                decoration: BoxDecoration(border: Border(left: BorderSide(color: accent, width: 4))),
                child: SelectableText(
                  quote.quote.trim(),
                  style: text.titleLarge?.copyWith(fontFamily: FontFamilies.reading, height: 1.5, fontWeight: FontWeight.w400),
                ),
              ),
              if (quote.note case final note? when note.trim().isNotEmpty) ...[
                const SizedBox(height: Space.lg),
                Text(note.trim(), style: text.bodyLarge?.copyWith(fontStyle: FontStyle.italic)),
              ],
              const SizedBox(height: Space.xl),
              Text(quote.title, style: text.titleMedium),
              if (quote.authors.isNotEmpty) Text(quote.authors.join(', '), style: text.bodyMedium),
              const SizedBox(height: Space.xl),
              Wrap(
                spacing: Space.sm,
                runSpacing: Space.sm,
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.copy_outlined, size: 18),
                    label: const Text('Copy'),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: '“${quote.quote.trim()}” — ${quote.title}'));
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
                    },
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.auto_awesome_mosaic_outlined, size: 18),
                    label: const Text('Share as image'),
                    onPressed: () => showStorySheet(
                      context,
                      StoryContent(
                        quote: quote.quote,
                        note: quote.note,
                        title: quote.title,
                        author: quote.authors.join(', '),
                        accent: (HighlightColor.values.where((c) => c.name == quote.color).firstOrNull ??
                                HighlightColor.yellow)
                            .onLight,
                        coverColor: quote.coverColor == null ? null : Color(quote.coverColor!),
                      ),
                    ),
                  ),
                  FilledButton.icon(
                    icon: const Icon(Icons.search, size: 18),
                    label: const Text('Find the book'),
                    onPressed: () => context.push(
                      '/discover/list?title=${Uri.encodeComponent(quote.title)}&query=${Uri.encodeComponent(quote.title)}',
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}
