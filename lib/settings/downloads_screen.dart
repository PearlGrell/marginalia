
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../companion/companion_sheet.dart' show confirmGemmaDownload;
import '../companion/gemma.dart';
import '../dictionary/dictionary_pack.dart';
import '../dictionary/foreign_dictionary.dart';
import '../theme/tokens.dart';
import '../translate/translate_sheet.dart' show pickTranslateLanguage;
import '../translate/translation.dart';

/// Everything the app downloads for offline use: the dictionary, translation languages and
/// the reading companion's model. This is the one place to add or remove them.
class DownloadsScreen extends StatelessWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Downloads')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, Space.xxxl),
        children: const [
          _Section('Dictionary'),
          _DictionarySection(),
          SizedBox(height: Space.lg),
          _ForeignDictionariesSection(),
          SizedBox(height: Space.xl),
          Divider(),
          _Section('Translation'),
          _TranslationSection(),
          SizedBox(height: Space.xl),
          Divider(),
          _Section('Reading companion'),
          _GemmaSection(),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: Space.lg, bottom: Space.sm),
    child: Text(title.toUpperCase(), style: Theme.of(context).textTheme.labelSmall),
  );
}

// ---- Dictionary ----

class _DictionarySection extends ConsumerWidget {
  const _DictionarySection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pack = ref.watch(dictionaryPackProvider);
    final notifier = ref.read(dictionaryPackProvider.notifier);
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('English', style: text.titleMedium),
        Text(
          'Open English WordNet: about 135,000 words, each meaning as noun, verb, adjective or '
          'adverb, with examples and synonyms. Used by Define.',
          style: text.bodySmall?.copyWith(color: muted),
        ),
        const SizedBox(height: Space.md),
        switch (pack.status) {
          PackStatus.installed => Row(
            children: [
              Icon(Icons.check_circle_outline, size: 18, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: Space.sm),
              Expanded(child: Text('Downloaded', style: text.labelLarge)),
              TextButton(onPressed: notifier.remove, child: const Text('Remove')),
            ],
          ),
          PackStatus.downloading || PackStatus.building => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(value: pack.progress, minHeight: 3),
              const SizedBox(height: Space.xs),
              Text(
                pack.status == PackStatus.downloading ? 'Downloading…' : 'Preparing it on your phone…',
                style: text.bodySmall,
              ),
            ],
          ),
          PackStatus.notInstalled || PackStatus.failed => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.download_outlined),
                label: const Text('Download (${DictionaryPack.downloadSizeLabel})'),
                onPressed: notifier.install,
              ),
              if (pack.error case final error?)
                Padding(
                  padding: const EdgeInsets.only(top: Space.sm),
                  child: Text(error, style: text.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error)),
                ),
            ],
          ),
        },
      ],
    );
  }
}

/// Dictionaries from other languages into English, for books in those languages.
class _ForeignDictionariesSection extends ConsumerWidget {
  const _ForeignDictionariesSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final packs = ref.watch(foreignPacksProvider);
    final catalogue = ref.watch(freeDictCatalogueProvider);
    final notifier = ref.read(foreignPacksProvider.notifier);
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final all = catalogue.value ?? const <FreeDictPack>[];
    final installed = [for (final p in all) if (packs.installed.contains(p.code3)) p];
    final busy = [for (final p in all) if (packs.progress.containsKey(p.code3)) p];

    Future<void> add() async {
      final choice = await showModalBottomSheet<FreeDictPack>(
        context: context,
        isScrollControlled: true,
        builder: (context) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          builder: (context, scroll) => ListView(
            controller: scroll,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.sm),
                child: Text('Dictionaries into English', style: Theme.of(context).textTheme.headlineSmall),
              ),
              for (final p in all)
                if (!packs.installed.contains(p.code3))
                  ListTile(
                    title: Text(p.language),
                    subtitle: Text('${_thousands(p.headwords)} words · ${p.sizeLabel}'),
                    trailing: const Icon(Icons.download_outlined),
                    onTap: () => Navigator.pop(context, p),
                  ),
            ],
          ),
        ),
      );
      if (choice != null) await notifier.install(choice);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Other languages', style: text.titleMedium),
        Text(
          'FreeDict dictionaries into English, for books in other languages. Define uses the '
          'one matching the book.',
          style: text.bodySmall?.copyWith(color: muted),
        ),
        for (final p in installed)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.check_circle_outline, size: 20),
            title: Text('${p.language} → English'),
            subtitle: Text('${_thousands(p.headwords)} words'),
            trailing: TextButton(onPressed: () => notifier.remove(p.code3), child: const Text('Remove')),
          ),
        for (final p in busy)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('${p.language} → English'),
            subtitle: LinearProgressIndicator(value: packs.progress[p.code3], minHeight: 2),
          ),
        for (final MapEntry(:key, :value) in packs.errors.entries)
          Text('${FreeDictPack.names[key] ?? key}: $value', style: text.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error)),
        const SizedBox(height: Space.sm),
        switch (catalogue) {
          AsyncError() => Text("Couldn't load the list of dictionaries. Check your connection.", style: text.bodySmall),
          _ => OutlinedButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('Add a language'),
            onPressed: catalogue.hasValue ? add : null,
          ),
        },
      ],
    );
  }

  static String _thousands(int n) => n >= 1000 ? '${(n / 1000).toStringAsFixed(n >= 10000 ? 0 : 1)}k' : '$n';
}

// ---- Translation ----

class _TranslationSection extends ConsumerWidget {
  const _TranslationSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(translationProvider);
    final translation = ref.read(translationProvider.notifier);
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final downloaded = [...state.downloaded]..sort((a, b) => a.label.compareTo(b.label));

    Future<void> add() async {
      final picked = await pickTranslateLanguage(context);
      if (picked == null || state.downloaded.contains(picked)) return;
      if (!await translation.download(picked) && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("${picked.label} couldn't be downloaded.")),
        );
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Translate selected text offline with Google ML Kit. Download the book’s language and '
          'yours; each is about 30 MB.',
          style: text.bodySmall?.copyWith(color: muted),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Translate into'),
          trailing: Text(state.target.label, style: text.titleSmall),
          onTap: () async {
            final picked = await pickTranslateLanguage(context, selected: state.target);
            if (picked != null) await translation.setTarget(picked);
          },
        ),
        for (final language in downloaded)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.check_circle_outline, size: 20),
            title: Text(language.label),
            trailing: TextButton(
              onPressed: () => translation.delete(language),
              child: const Text('Remove'),
            ),
          ),
        for (final language in state.downloading)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(language.label),
            subtitle: const LinearProgressIndicator(minHeight: 2),
          ),
        if (!downloaded.contains(state.target) && !state.downloading.contains(state.target))
          Padding(
            padding: const EdgeInsets.only(bottom: Space.sm),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.download_outlined),
              label: Text('Download ${state.target.label}'),
              onPressed: () => translation.download(state.target),
            ),
          ),
        OutlinedButton.icon(icon: const Icon(Icons.add), label: const Text('Add a language'), onPressed: add),
      ],
    );
  }
}

// ---- Reading companion ----

/// Gemma, for "Ask about the book" on phones without Gemini Nano, or in its larger size for
/// better answers on phones with the memory for it.
class _GemmaSection extends ConsumerStatefulWidget {
  const _GemmaSection();

  @override
  ConsumerState<_GemmaSection> createState() => _GemmaSectionState();
}

class _GemmaSectionState extends ConsumerState<_GemmaSection> {
  /// The phone's memory, for which size to suggest.
  double? _memoryGb;

  @override
  void initState() {
    super.initState();
    ref.read(gemmaProvider.notifier).phoneMemoryGb().then((gb) {
      if (mounted) setState(() => _memoryGb = gb);
    });
  }

  @override
  Widget build(BuildContext context) {
    final gemma = ref.watch(gemmaProvider);
    final pack = ref.read(gemmaProvider.notifier);
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    // 8 GB phones report a little under 8.
    final roomy = (_memoryGb ?? 0) >= 7.2;

    Future<void> download(GemmaSize size) async {
      if (await confirmGemmaDownload(context, size: size)) await pack.install(size);
    }

    Widget offer(GemmaSize size) => ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.download_outlined, size: 20),
      title: Text('${size.label} · ${size.sizeLabel}'),
      subtitle: Text(switch (size) {
        GemmaSize.small => 'Quick, for any phone',
        GemmaSize.large => roomy
            ? 'Much better answers and summaries. Recommended for this phone'
            : 'Much better answers, but needs a phone with 8 GB of memory; this one has '
                  '${(_memoryGb ?? 0).toStringAsFixed(0)} GB',
      }),
      trailing: OutlinedButton(onPressed: gemma.busy ? null : () => download(size), child: const Text('Get')),
    );

    final installed = gemma.size;
    final Widget body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (installed != null)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.check_circle_outline, size: 20),
            title: Text(installed.label),
            subtitle: Text('${installed.sizeLabel} on this phone'),
            trailing: TextButton(
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Remove Gemma?'),
                    content: Text(
                      'This frees ${installed.sizeLabel}. Ask about the book will show passages only until '
                      'you download it again.',
                    ),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep')),
                      FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
                    ],
                  ),
                );
                if (ok == true) await pack.remove();
              },
              child: const Text('Remove'),
            ),
          ),
        if (gemma.downloading case final size?) ...[
          Text('Downloading ${size.label}… ${((gemma.progress ?? 0) * 100).round()}%', style: text.bodySmall),
          const SizedBox(height: Space.xs),
          LinearProgressIndicator(value: gemma.progress, minHeight: 3),
          Align(alignment: Alignment.centerRight, child: TextButton(onPressed: pack.cancel, child: const Text('Cancel'))),
          if (installed != null)
            Text(
              '${installed.label} keeps answering until it’s done, then makes way for it.',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
        ] else
          for (final size in GemmaSize.values)
            if (size != installed) offer(size),
        if (gemma.error case final error?)
          Padding(
            padding: const EdgeInsets.only(top: Space.sm),
            child: Text(error, style: text.bodySmall?.copyWith(color: scheme.error)),
          ),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Ask about the book answers in plain words with Gemini Nano on phones that have it. Any '
          'phone can use Gemma, a model that runs on the phone: the small one for any phone, or '
          'the larger, much better one on phones with 8 GB of memory. When Gemma 3n is here, it '
          'answers instead of Gemini Nano.',
          style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: Space.sm),
        body,
      ],
    );
  }
}
