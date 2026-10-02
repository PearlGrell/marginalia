import 'package:flutter/material.dart';

import 'tokens.dart';

/// The colors a page is drawn with: the book itself and the reader chrome around it,
/// independently of the app's light or dark theme.
@immutable
class PageColors {
  const PageColors({
    required this.label,
    required this.page,
    required this.ink,
    required this.muted,
    required this.pageBack,
    required this.brightness,
  });

  /// A page in [page] and [ink], the rest derived from them.
  factory PageColors.from({required String label, required Color page, required Color ink}) {
    final brightness = ThemeData.estimateBrightnessForColor(page);
    return PageColors(
      label: label,
      page: page,
      ink: ink,
      muted: Color.lerp(ink, page, 0.45)!,
      pageBack: Color.lerp(page, brightness == Brightness.dark ? Colors.black : ink, 0.07)!,
      brightness: brightness,
    );
  }

  /// A page tinted by a book's cover: a whisper of it on paper by day, a deeper wash by night.
  factory PageColors.tinted(Color tint, Brightness brightness) {
    if (brightness == Brightness.light) {
      final page = Color.lerp(const Color(0xFFF8F4EC), tint, 0.11)!;
      return PageColors(
        label: 'Cover',
        page: page,
        ink: Color.lerp(Palette.ink, tint, 0.18)!,
        muted: Color.lerp(Palette.inkMuted, tint, 0.3)!,
        pageBack: Color.lerp(page, tint, 0.12)!,
        brightness: Brightness.light,
      );
    }
    final page = Color.lerp(const Color(0xFF1A1816), tint, 0.2)!;
    return PageColors(
      label: 'Cover',
      page: page,
      ink: Color.lerp(const Color(0xFFDCD4C7), tint, 0.1)!,
      muted: Color.lerp(Palette.chalkMuted, tint, 0.2)!,
      pageBack: Color.lerp(page, Colors.black, 0.25)!,
      brightness: Brightness.dark,
    );
  }

  final String label;

  /// Page background.
  final Color page;

  /// Body text.
  final Color ink;

  /// Secondary text in the reader chrome (page numbers, chapter title).
  final Color muted;

  /// The back of a page as it curls over.
  final Color pageBack;

  final Brightness brightness;

  /// Readium's base theme, which the page and ink colors refine.
  String get readiumTheme => brightness == Brightness.dark ? 'dark' : 'light';

  /// Contrast between [ink] and [page], 1 to 21 (WCAG); body text wants 4.5 or more.
  double get contrast {
    final a = ink.computeLuminance();
    final b = page.computeLuminance();
    final (hi, lo) = a > b ? (a, b) : (b, a);
    return (hi + 0.05) / (lo + 0.05);
  }

  @override
  bool operator ==(Object other) =>
      other is PageColors &&
      other.label == label &&
      other.page == page &&
      other.ink == ink &&
      other.muted == muted &&
      other.pageBack == pageBack &&
      other.brightness == brightness;

  @override
  int get hashCode => Object.hash(label, page, ink, muted, pageBack, brightness);
}

/// Page themes. The four presets have fixed colors; [cover] takes its tint from the book
/// being read, and [custom] uses the colors the reader built.
enum ReaderTheme {
  paper(
    PageColors(
      label: 'Paper',
      page: Palette.paper,
      ink: Palette.ink,
      muted: Palette.inkMuted,
      pageBack: Color(0xFFEDE6DA),
      brightness: Brightness.light,
    ),
  ),
  sepia(
    PageColors(
      label: 'Sepia',
      page: Color(0xFFF1E5CF),
      ink: Color(0xFF3B2F22),
      muted: Color(0xFF7D6A55),
      pageBack: Color(0xFFE6D7BC),
      brightness: Brightness.light,
    ),
  ),
  dark(
    PageColors(
      label: 'Dark',
      page: Palette.charcoal,
      ink: Color(0xFFDCD4C7),
      muted: Palette.chalkMuted,
      pageBack: Color(0xFF221F1C),
      brightness: Brightness.dark,
    ),
  ),
  oled(
    PageColors(
      label: 'Black',
      page: Color(0xFF000000),
      ink: Color(0xFFC9C2B6),
      muted: Color(0xFF857D72),
      pageBack: Color(0xFF141210),
      brightness: Brightness.dark,
    ),
  ),
  cover(null),
  custom(null);

  const ReaderTheme(this.preset);

  /// The colors of a preset; null for [cover] and [custom], which are worked out per book
  /// and from the reader's own colors.
  final PageColors? preset;

  String get label => preset?.label ?? (this == cover ? 'Cover' : 'Custom');

  /// The brightness a preset is made for; null when it depends (see [preset]).
  Brightness? get brightness => preset?.brightness;
}
