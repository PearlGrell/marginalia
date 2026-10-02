import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marginalia/listen/kokoro.dart';

void main() {
  test('the voice table matches the model (54 speakers, in id order) and the Kotlin side', () {
    expect(KokoroVoice.all.length, 54);
    for (final (i, v) in KokoroVoice.all.indexed) {
      expect(v.speaker, i);
    }
    // From the model's own metadata (speaker_names in kokoro-int8-multi-lang-v1_0).
    expect(KokoroVoice.all[15].id, 'am_liam');
    expect(KokoroVoice.all[30].id, 'ff_siwis');
    expect(KokoroVoice.all[53].id, 'em_santa');

    final kotlin = File('android/app/src/main/kotlin/app/marginalia/listen/Kokoro.kt').readAsStringSync();
    final list = RegExp(r'val speakers = listOf\(([^)]*)\)', dotAll: true).firstMatch(kotlin)![1]!;
    final names = [for (final m in RegExp(r'"([a-z_]+)"').allMatches(list)) m[1]];
    expect(names, [for (final v in KokoroVoice.all) v.id]);
  });

  test('voices for a language, the regional ones and the best first', () {
    final british = KokoroVoice.forLanguage('en-GB');
    expect(british.first.accent, 'British');
    expect(british.first.id, 'bf_emma');
    final american = KokoroVoice.forLanguage('en');
    expect(american.length, 28);
    expect(american.first.featured, isTrue);
    expect(KokoroVoice.forLanguage('es').map((v) => v.id), containsAll(['ef_dora', 'em_alex', 'em_santa']));
    expect(KokoroVoice.forLanguage('de'), isEmpty);
  });

  test('defaults and what Kokoro speaks', () {
    expect(KokoroVoice.defaultFor('en').id, 'am_liam');
    expect(KokoroVoice.defaultFor('en-GB').id, 'bf_emma');
    expect(KokoroVoice.defaultFor('pt-BR').id, 'pf_dora');
    expect(KokoroVoice.defaultFor(null).id, 'am_liam');
    expect(KokoroVoice.speaks('fr-CA'), isTrue);
    expect(KokoroVoice.speaks('de'), isFalse);
    expect(KokoroVoice.all[15].name, 'Liam');
    expect(KokoroVoice.all[15].gender, 'male');
  });
}
