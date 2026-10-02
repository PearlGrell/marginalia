import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

import '../dictionary/dictionary_pack.dart';
import '../dictionary/foreign_dictionary.dart';
import '../theme/tokens.dart';
import '../translate/translate_sheet.dart' show pickTranslateLanguage;
import '../translate/translation.dart';
import '../listen/kokoro.dart';
import 'voices.dart';

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

class _VoiceLanguage extends Notifier<String> {
  @override
  String build() {
    final device = PlatformDispatcher.instance.locale.languageCode;
    return sampleLines.containsKey(device) ? device : 'en';
  }

  void set(String language) => state = language;
}

final _phoneVoicesProvider = FutureProvider.family<List<PhoneVoice>, String>(
  (ref, language) => ref.watch(voicesProvider).forLanguage(language),
);

class _VoicesSection extends ConsumerStatefulWidget {
  const _VoicesSection();

  @override
  ConsumerState<_VoicesSection> createState() => _VoicesSectionState();
}

class _VoicesSectionState extends ConsumerState<_VoicesSection> {
  /// The phone voice or Kokoro voice whose sample is playing.
  String? _playing;

  @override
  void dispose() {
    ref.read(voicesProvider).stop();
    super.dispose();
  }

  Future<void> _sampleNatural(KokoroVoice voice, String language) async {
    final key = 'k${voice.speaker}';
    final kokoro = ref.read(kokoroProvider.notifier);
    if (_playing == key) {
      await kokoro.stop();
      setState(() => _playing = null);
      return;
    }
    setState(() => _playing = key);
    try {
      await kokoro.sample(voice, sampleLines[voice.baseLanguage] ?? sampleLines['en']!);
    } catch (_) {
      // Stopped, or the model couldn't load: the button resets either way.
    }
    if (mounted && _playing == key) setState(() => _playing = null);
  }

  @override
  Widget build(BuildContext context) {
    final language = ref.watch(_voiceLanguageProvider);
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final languageName = TranslateLanguageName.fromCode(language)?.label ?? language;
    final kokoro = ref.watch(kokoroProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Listen reads with natural Kokoro voices, which run on your phone with no connection. '
          'Until they are downloaded, or for a language they don’t speak, it uses your phone’s own voices.',
          style: text.bodySmall?.copyWith(color: muted),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Language'),
          trailing: Text(languageName, style: text.titleSmall),
          onTap: () async {
            final picked = await pickTranslateLanguage(
              context,
              selected: TranslateLanguageName.fromCode(language),
            );
            if (picked != null) ref.read(_voiceLanguageProvider.notifier).set(picked.bcpCode);
          },
        ),
        _naturalVoices(context, language, languageName, kokoro),
        const SizedBox(height: Space.sm),
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            initiallyExpanded: !kokoro.installed,
            title: const Text('Phone voices'),
            subtitle: Text(
              kokoro.installed ? 'Used for languages the natural voices don’t speak' : 'Used until natural voices are downloaded',
              style: text.bodySmall,
            ),
            children: [_phoneVoices(context, language, languageName)],
          ),
        ),
      ],
    );
  }

  Widget _naturalVoices(BuildContext context, String language, String languageName, KokoroState kokoro) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final notifier = ref.read(kokoroProvider.notifier);
    final listen = ref.read(listenVoicesProvider);

    final Widget body = switch (kokoro.status) {
      KokoroStatus.installed => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Use natural voices'),
            value: listen.preferNatural,
            onChanged: (on) async {
              await listen.setPreferNatural(on);
              setState(() {});
            },
          ),
          if (!KokoroVoice.speaks(language))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Space.sm),
              child: Text(
                'The natural voices don’t speak $languageName; books in it use the phone voices below.',
                style: text.bodyMedium,
              ),
            )
          else
            for (final voice in KokoroVoice.forLanguage(language))
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: IconButton(
                  tooltip: 'Play a sample',
                  icon: Icon(_playing == 'k${voice.speaker}' ? Icons.stop_circle_outlined : Icons.play_circle_outline),
                  onPressed: () => _sampleNatural(voice, language),
                ),
                title: Text(voice.name),
                subtitle: Text('${voice.accent} ${voice.gender}${voice.featured ? ' · one of the best' : ''}'),
                trailing: listen.kokoroFor(language).speaker == voice.speaker
                    ? Icon(Icons.check, color: scheme.primary)
                    : TextButton(
                        onPressed: () async {
                          await listen.setKokoro(voice);
                          setState(() {});
                        },
                        child: const Text('Use'),
                      ),
              ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Remove natural voices?'),
                    content: const Text('This frees ${KokoroPack.installedSizeLabel}. Listen goes back to your phone’s voices.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                      TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
                    ],
                  ),
                );
                if (ok == true) await notifier.remove();
              },
              child: const Text('Remove natural voices'),
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
                TextButton(onPressed: notifier.cancel, child: const Text('Cancel')),
            ],
          ),
        ],
      ),
      KokoroStatus.notInstalled || KokoroStatus.failed => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            icon: const Icon(Icons.download_outlined),
            label: const Text('Download natural voices (${KokoroPack.downloadSizeLabel})'),
            onPressed: notifier.install,
          ),
          const SizedBox(height: Space.xs),
          Text(
            '54 voices for English (American and British), Spanish, French, Hindi, Italian, '
            'Japanese, Brazilian Portuguese and Chinese. Takes ${KokoroPack.installedSizeLabel} once unpacked; Wi-Fi recommended.',
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

    return Container(
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.record_voice_over_outlined, size: 20, color: scheme.primary),
              const SizedBox(width: Space.sm),
              Text('Natural voices', style: text.titleMedium),
              const SizedBox(width: Space.sm),
              Text('Kokoro', style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
            ],
          ),
          const SizedBox(height: Space.sm),
          body,
        ],
      ),
    );
  }

  Widget _phoneVoices(BuildContext context, String language, String languageName) {
    final voices = ref.watch(_phoneVoicesProvider(language));
    final store = ref.read(voicesProvider);
    final chosen = store.defaultFor(language)?.id;
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        switch (voices) {
          AsyncData(value: final list) when list.isEmpty => Padding(
            padding: const EdgeInsets.symmetric(vertical: Space.sm),
            child: Text('No $languageName voices on this phone yet.', style: text.bodyMedium),
          ),
          AsyncData(value: final list) => Column(
            children: [
              for (final (i, voice) in list.indexed)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: IconButton(
                    tooltip: 'Play a sample',
                    icon: Icon(_playing == voice.id ? Icons.stop_circle_outlined : Icons.play_circle_outline),
                    onPressed: !voice.installed
                        ? null
                        : () async {
                            if (_playing == voice.id) {
                              await store.stop();
                              setState(() => _playing = null);
                            } else {
                              setState(() => _playing = voice.id);
                              await store.sample(voice);
                            }
                          },
                  ),
                  title: Text(voice.name.isEmpty ? 'Voice ${i + 1}' : 'Voice ${i + 1} · ${voice.name}'),
                  subtitle: Text(
                    [
                      '${voice.quality} quality',
                      voice.network ? 'needs a connection' : 'offline',
                      if (!voice.installed) 'not downloaded',
                    ].join(' · '),
                  ),
                  trailing: voice.id == chosen
                      ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary)
                      : TextButton(
                          onPressed: !voice.installed
                              ? null
                              : () async {
                                  await store.setDefault(voice);
                                  setState(() {});
                                },
                          child: const Text('Use'),
                        ),
                ),
            ],
          ),
          AsyncError() => Text("Couldn't list voices.", style: text.bodyMedium),
          _ => const Padding(
            padding: EdgeInsets.all(Space.md),
            child: Center(child: CircularProgressIndicator()),
          ),
        },
        const SizedBox(height: Space.sm),
        OutlinedButton.icon(
          icon: const Icon(Icons.download_outlined),
          label: const Text('Get more phone voices'),
          onPressed: () async {
            await store.installMore();
            // Back from the engine's screen: list again.
            ref.invalidate(_phoneVoicesProvider(language));
          },
        ),
        const SizedBox(height: Space.xs),
        Text(
          'Opens your speech engine (usually Speech Services by Google), where voices for '
          'each language can be downloaded.',
          style: text.bodySmall?.copyWith(color: muted),
        ),
      ],
    );
  }
}
