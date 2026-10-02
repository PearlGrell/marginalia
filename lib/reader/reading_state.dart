import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/local_store.dart';

/// The reader's pace on this device, for time-left estimates.
class ReadingStateStore {
  ReadingStateStore(this._store);

  final LocalStore _store;

  static const _paceKey = 'reader.secondsPerPosition';

  /// Seconds the reader spends on one Readium position. Starts from about 250 words a
  /// minute (a position is roughly 170 words).
  double get secondsPerPosition => _store.readDouble(_paceKey) ?? 40;

  /// Folds one observed page into the pace, ignoring pages skimmed or left open.
  Future<void> recordPage(Duration spent, int positions) {
    if (positions <= 0) return Future.value();
    final seconds = spent.inMilliseconds / 1000 / positions;
    if (seconds < 4 || seconds > 300) return Future.value();
    final updated = secondsPerPosition * 0.85 + seconds * 0.15;
    return _store.writeDouble(_paceKey, updated);
  }
}

final readingStateProvider = Provider<ReadingStateStore>(
  (ref) => ReadingStateStore(ref.watch(localStoreProvider)),
);
