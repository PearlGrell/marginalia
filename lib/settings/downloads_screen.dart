import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../dictionary/dictionary_pack.dart';
import '../dictionary/foreign_dictionary.dart';
import '../theme/tokens.dart';
import '../translate/translate_sheet.dart' show pickTranslateLanguage;
import '../translate/translation.dart';
import '../listen/kokoro.dart';

/// Everything the app downloads for offline use: the dictionary, translation languages and
/// reading voices. This is the one place to add or remove them.
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
          _Section('Voices for Listen'),
          _VoicesSection(),
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

// ---- Voices ----

final _voiceLanguageProvider = NotifierProvider<_VoiceLanguage, String>(_VoiceLanguage.new);

/// Which language's voices are listed: the phone's, if Kokoro speaks it.
class _VoiceLanguage extends Notifier<String> {
  @override
  String build() {
    final locale = PlatformDispatcher.instance.locale;
    if (locale.languageCode == 'en') return locale.countryCode == 'GB' ? 'en-GB' : 'en-US';
    return kokoroLanguages.map((l) => l.$1).firstWhere(
      (code) => code.split('-').first == locale.languageCode,
      orElse: () => 'en-US',
    );
  }

  void set(String language) => state = language;
}

class _VoicesSection extends ConsumerStatefulWidget {
  const _VoicesSection();

  @override
  ConsumerState<_VoicesSection> createState() => _VoicesSectionState();
}

class _VoicesSectionState extends ConsumerState<_VoicesSection> {
  /// The voice whose sample is playing or being made.
  int? _playing;
  late final KokoroPack _kokoro = ref.read(kokoroProvider.notifier);

  @override
  void dispose() {
    if (_playing != null) _kokoro.stop();
    super.dispose();
  }

  Future<void> _sample(KokoroVoice voice) async {
    if (_playing == voice.speaker) {
      setState(() => _playing = null);
      await _kokoro.stop();
      return;
    }
    setState(() => _playing = voice.speaker);
    try {
      await _kokoro.sample(voice, sampleLines[voice.baseLanguage] ?? sampleLines['en']!);
    } catch (e) {
      if (mounted && _playing == voice.speaker) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't play ${voice.name}: $e")));
      }
    }
    if (mounted && _playing == voice.speaker) setState(() => _playing = null);
  }

  @override
  Widget build(BuildContext context) {
    final language = ref.watch(_voiceLanguageProvider);
    final kokoro = ref.watch(kokoroProvider);
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final listen = ref.read(listenVoicesProvider);
    final languageName = kokoroLanguages.firstWhere((l) => l.$1 == language, orElse: () => kokoroLanguages.first).$2;

    final Widget body = switch (kokoro.status) {
      KokoroStatus.installed => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Language'),
            trailing: Text(languageName, style: text.titleSmall),
            onTap: () async {
              final picked = await showModalBottomSheet<String>(
                context: context,
                builder: (context) => SafeArea(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final (code, name) in kokoroLanguages)
                        ListTile(
                          title: Text(name),
                          trailing: code == language ? const Icon(Icons.check) : null,
                          onTap: () => Navigator.pop(context, code),
                        ),
                    ],
                  ),
                ),
              );
              if (picked != null) ref.read(_voiceLanguageProvider.notifier).set(picked);
            },
          ),
          for (final voice in KokoroVoice.forLanguage(language))
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: IconButton(
                tooltip: _playing == voice.speaker ? 'Stop' : 'Play a sample',
                icon: Icon(_playing == voice.speaker ? Icons.stop_circle_outlined : Icons.play_circle_outline),
                onPressed: () => _sample(voice),
              ),
              title: Text(voice.name),
              subtitle: Text('${voice.accent} ${voice.gender}${voice.featured ? ' · one of the best' : ''}'),
              trailing: listen.kokoroFor(voice.language).speaker == voice.speaker
                  ? Icon(Icons.check, color: scheme.primary)
                  : TextButton(
                      onPressed: () async {
                        await listen.setKokoro(voice);
                        setState(() {});
                      },
                      child: const Text('Use'),
                    ),
            ),
          const SizedBox(height: Space.xs),
          Text(
            'The first sample in a language takes a few seconds while the voices load.',
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Remove the voices?'),
                    content: const Text(
                      'This frees ${KokoroPack.installedSizeLabel}. Listen won’t work until you download them again.',
                    ),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                      TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
                    ],
                  ),
                );
                if (ok == true) await _kokoro.remove();
              },
              child: const Text('Remove voices'),
            ),
          ),
        ],
      ),
      KokoroStatus.downloading || KokoroStatus.unpacking => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LinearProgressIndicator(value: kokoro.progress, minHeight: 3),
          const SizedBox(height: Space.xs),
          Row(
            children: [
              Expanded(
                child: Text(
                  kokoro.status == KokoroStatus.downloading
                      ? 'Downloading… ${((kokoro.progress ?? 0) * 100).round()}%'
                      : 'Unpacking on your phone… ${((kokoro.progress ?? 0) * 100).round()}%',
                  style: text.bodySmall,
                ),
              ),
              if (kokoro.status == KokoroStatus.downloading)
                TextButton(onPressed: _kokoro.cancel, child: const Text('Cancel')),
            ],
          ),
        ],
      ),
      KokoroStatus.notInstalled || KokoroStatus.failed => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            icon: const Icon(Icons.download_outlined),
            label: const Text('Download voices (${KokoroPack.downloadSizeLabel})'),
            onPressed: _kokoro.install,
          ),
          const SizedBox(height: Space.xs),
          Text(
            '54 natural voices for English (American and British), Spanish, French, Hindi, Italian, '
            'Japanese, Brazilian Portuguese and Chinese. They run on your phone, with no '
            'connection. Takes ${KokoroPack.installedSizeLabel} once unpacked; Wi-Fi recommended.',
            style: text.bodySmall,
          ),
          if (kokoro.error case final error?)
            Padding(
              padding: const EdgeInsets.only(top: Space.sm),
              child: Text(error, style: text.bodySmall?.copyWith(color: scheme.error)),
            ),
        ],
      ),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Listen reads with Kokoro, natural-sounding voices that run on your phone.',
          style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: Space.sm),
        body,
      ],
    );
  }
}
