import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Small key-value storage on the device, for settings and per-book reading state until the
/// local database arrives with the library (milestone 3).
class LocalStore {
  LocalStore(this._prefs);

  static Future<LocalStore> open() async => LocalStore(
    await SharedPreferencesWithCache.create(
      cacheOptions: const SharedPreferencesWithCacheOptions(),
    ),
  );

  final SharedPreferencesWithCache _prefs;

  Object? readJson(String key) {
    final raw = _prefs.getString(key);
    if (raw == null) return null;
    try {
      return jsonDecode(raw);
    } on FormatException {
      return null;
    }
  }

  Future<void> writeJson(String key, Object? value) => _prefs.setString(key, jsonEncode(value));

  double? readDouble(String key) => _prefs.getDouble(key);

  Future<void> writeDouble(String key, double value) => _prefs.setDouble(key, value);

  Future<void> remove(String key) => _prefs.remove(key);
}

/// Overridden in `main` with the opened store.
final localStoreProvider = Provider<LocalStore>(
  (ref) => throw UnimplementedError('localStoreProvider is overridden in main'),
);
