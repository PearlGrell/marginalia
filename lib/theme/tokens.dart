import 'package:flutter/material.dart';

/// Design tokens: the single source for colors, type families and spacing.
///
/// The look is ink on warm paper. Covers carry the color; the UI stays quiet, with one
/// accent (oxblood) used sparingly.
abstract final class Palette {
  // Light: paper and ink.
  static const paper = Color(0xFFF7F3EC);
  static const paperRaised = Color(0xFFFBF8F3);
  static const paperSunken = Color(0xFFEFE9DF);
  static const ink = Color(0xFF1C1A17);
  static const inkMuted = Color(0xFF6B645A);
  static const hairline = Color(0xFFE2DACC);

  // Dark: warm charcoal.
  static const charcoal = Color(0xFF161412);
  static const charcoalRaised = Color(0xFF201D1A);
  static const charcoalSunken = Color(0xFF100E0D);
  static const chalk = Color(0xFFE8E1D5);
  static const chalkMuted = Color(0xFF9A9186);
  static const hairlineDark = Color(0xFF2E2A26);

  // The one accent: a deep maroon. [oxblood] fills on light, [maroonFill] fills on dark,
  // [oxbloodLight] is maroon text and icons on dark.
  static const oxblood = Color(0xFF6B1E2B);
  static const oxbloodLight = Color(0xFFE3A6AE);
  static const maroonFill = Color(0xFF8E3443);
  static const onMaroon = Color(0xFFFBF2F0);
}

abstract final class FontFamilies {
  /// Titles and display text.
  static const display = 'Fraunces';

  /// UI text.
  static const ui = 'IBMPlexSans';

  /// Default reading face.
  static const reading = 'Literata';
}

/// 4-point spacing scale.
abstract final class Space {
  static const xxs = 2.0;
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
  static const xxxl = 48.0;

  /// Side gutter for screens.
  static const gutter = 20.0;
}

abstract final class Radii {
  static const sm = 4.0;
  static const md = 8.0;
  static const lg = 14.0;
  static const pill = 999.0;
}

abstract final class Motion {
  static const quick = Duration(milliseconds: 150);
  static const standard = Duration(milliseconds: 260);
  static const turn = Duration(milliseconds: 420);
  static const emphasized = Curves.easeOutCubic;
}

/// The five highlight colors, tuned separately for light and dark pages.
enum HighlightColor {
  yellow(Color(0xFFF2D46B), Color(0xFF8A7424)),
  green(Color(0xFFA9D3A0), Color(0xFF3F6B44)),
  blue(Color(0xFF9DC3E6), Color(0xFF34587A)),
  pink(Color(0xFFECAAC1), Color(0xFF7A3D55)),
  orange(Color(0xFFF2B47C), Color(0xFF8A5426));

  const HighlightColor(this.onLight, this.onDark);

  final Color onLight;
  final Color onDark;

  Color resolve(Brightness pageBrightness) =>
      pageBrightness == Brightness.dark ? onDark : onLight;
}
