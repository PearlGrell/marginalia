import 'package:flutter_test/flutter_test.dart';
import 'package:marginalia/dictionary/dictionary.dart';

void main() {
  test('base forms undo regular inflections', () {
    expect(baseForms('cities'), contains('city'));
    expect(baseForms('walked'), contains('walk'));
    expect(baseForms('hoped'), contains('hope'));
    expect(baseForms('running'), contains('run'));
    expect(baseForms('happier'), contains('happy'));
    expect(baseForms('boxes'), contains('box'));
  });

  test('short words are left alone', () {
    expect(baseForms('is'), isEmpty);
  });
}
