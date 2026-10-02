import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

import '../storage/local_store.dart';

extension TranslateLanguageName on TranslateLanguage {
  /// "french" → "French".
  String get label => name[0].toUpperCase() + name.substring(1);

  /// A BCP 47 code such as "fr" or "en-GB", from a book's metadata.
  static TranslateLanguage? fromCode(String? code) {
    if (code == null) return null;
    final base = code.split(RegExp('[-_]')).first.toLowerCase();
    return TranslateLanguage.values.where((l) => l.bcpCode == base).firstOrNull;
  }
}

class TranslationState {
  const TranslationState({
    this.downloaded = const {},
    this.downloading = const {},
    required this.target,
  });

  /// Languages whose models are on the phone (about 30 MB each).
  final Set<TranslateLanguage> downloaded;
  final Set<TranslateLanguage> downloading;

  /// The language to translate into.
  final TranslateLanguage target;

  TranslationState copyWith({
    Set<TranslateLanguage>? downloaded,
    Set<TranslateLanguage>? downloading,
    TranslateLanguage? target,
  }) => TranslationState(
    downloaded: downloaded ?? this.downloaded,
    downloading: downloading ?? this.downloading,
    target: target ?? this.target,
  );
}

/// Offline translation with Google ML Kit: each language's model is downloaded once, then
/// translation runs on the phone with no connection.
class Translation extends Notifier<TranslationState> {
  static const _targetKey = 'translate.target';
  final _models = OnDeviceTranslatorModelManager();

  @override
  TranslationState build() {
    final saved = TranslateLanguageName.fromCode(
      ref.read(localStoreProvider).readJson(_targetKey) as String?,
    );
    final device = TranslateLanguageName.fromCode(PlatformDispatcher.instance.locale.languageCode);
    unawaited(refresh());
    return TranslationState(target: saved ?? device ?? TranslateLanguage.english);
  }

  Future<void> refresh() async {
    final downloaded = <TranslateLanguage>{};
    for (final language in TranslateLanguage.values) {
      if (await _models.isModelDownloaded(language.bcpCode)) downloaded.add(language);
    }
    state = state.copyWith(downloaded: downloaded);
  }

  Future<void> setTarget(TranslateLanguage language) async {
    state = state.copyWith(target: language);
    await ref.read(localStoreProvider).writeJson(_targetKey, language.bcpCode);
  }

  /// Downloads [language]'s model (on any connection). Returns false if it failed.
  Future<bool> download(TranslateLanguage language) async {
    if (state.downloaded.contains(language)) return true;
    state = state.copyWith(downloading: {...state.downloading, language});
    try {
      final ok = await _models.downloadModel(language.bcpCode, isWifiRequired: false);
      state = state.copyWith(
        downloaded: ok ? {...state.downloaded, language} : state.downloaded,
        downloading: {...state.downloading}..remove(language),
      );
      return ok;
    } catch (_) {
      state = state.copyWith(downloading: {...state.downloading}..remove(language));
      return false;
    }
  }

  Future<void> delete(TranslateLanguage language) async {
    await _models.deleteModel(language.bcpCode);
    state = state.copyWith(downloaded: {...state.downloaded}..remove(language));
  }

  Future<String> translate(String text, TranslateLanguage from, TranslateLanguage to) async {
    final translator = OnDeviceTranslator(sourceLanguage: from, targetLanguage: to);
    try {
      return await translator.translateText(text);
    } finally {
      await translator.close();
    }
  }
}

final translationProvider = NotifierProvider<Translation, TranslationState>(Translation.new);
