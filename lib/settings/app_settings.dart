import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/local_store.dart';

/// Light, dark, or following the phone, for the app around the books (the reader's page
/// theme is its own setting).
class AppThemeMode extends Notifier<ThemeMode> {
  static const _key = 'app.themeMode';

  @override
  ThemeMode build() {
    final saved = ref.read(localStoreProvider).readJson(_key);
    return ThemeMode.values.where((m) => m.name == saved).firstOrNull ?? ThemeMode.system;
  }

  Future<void> set(ThemeMode mode) async {
    state = mode;
    await ref.read(localStoreProvider).writeJson(_key, mode.name);
  }
}

final appThemeModeProvider = NotifierProvider<AppThemeMode, ThemeMode>(AppThemeMode.new);
