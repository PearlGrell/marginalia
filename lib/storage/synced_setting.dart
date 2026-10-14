import 'local_store.dart';

/// A setting that follows the account: kept in the [LocalStore] under [key] with the time it
/// changed, and sent to (and taken from) the account's [field] by the sync engine, the newer
/// one winning.
class SyncedSetting {
  const SyncedSetting._(this.key, this.field);

  /// Daily minutes and books a year.
  static const goals = SyncedSetting._('reading.goals', 'goals');

  /// The OPDS catalogs added to Discover.
  static const catalogs = SyncedSetting._('discover.catalogs', 'catalogs');

  static const all = [goals, catalogs];

  final String key;
  final String field;

  String get changedKey => '$key.changedAt';

  Object? read(LocalStore store) => store.readJson(key);

  /// Saves [value] as changed now, so the next sync sends it.
  Future<void> write(LocalStore store, Object? value) async {
    await store.writeJson(key, value);
    await store.writeJson(changedKey, DateTime.now().millisecondsSinceEpoch);
  }

  DateTime changedAt(LocalStore store) =>
      DateTime.fromMillisecondsSinceEpoch(store.readJson(changedKey) as int? ?? 0);

  /// Takes [value] from the account, as changed at [at] (not to be sent back).
  Future<void> receive(LocalStore store, Object? value, DateTime at) async {
    await store.writeJson(key, value);
    await store.writeJson(changedKey, at.millisecondsSinceEpoch);
  }
}
