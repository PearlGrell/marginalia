import 'package:flutter/material.dart';
import 'system_bars.dart';
import 'tokens.dart';

/// Material 3 for its components and accessibility, fully re-themed: no tonal purple
/// surfaces, no elevation tints, flat ink-on-paper chrome.
abstract final class AppTheme {
  static ThemeData light() => _build(
    brightness: Brightness.light,
    surface: Palette.paper,
    raised: Palette.paperRaised,
    sunken: Palette.paperSunken,
    onSurface: Palette.ink,
    muted: Palette.inkMuted,
    hairline: Palette.hairline,
    accent: Palette.oxblood,
    fill: Palette.oxblood,
  );

  static ThemeData dark() => _build(
    brightness: Brightness.dark,
    surface: Palette.charcoal,
    raised: Palette.charcoalRaised,
    sunken: Palette.charcoalSunken,
    onSurface: Palette.chalk,
    muted: Palette.chalkMuted,
    hairline: Palette.hairlineDark,
    accent: Palette.oxbloodLight,
    fill: Palette.maroonFill,
  );

  static ThemeData _build({
    required Brightness brightness,
    required Color surface,
    required Color raised,
    required Color sunken,
    required Color onSurface,
    required Color muted,
    required Color hairline,
    // Maroon for text and icons.
    required Color accent,
    // Maroon for filled things (buttons, FAB, selected chips), with [onFill] on it.
    required Color fill,
  }) {
    const onFill = Palette.onMaroon;
    final light = brightness == Brightness.light;
    // A soft maroon wash, for selected-but-quiet things (the tab indicator, tonal buttons).
    final wash = Color.alphaBlend(fill.withValues(alpha: light ? 0.12 : 0.32), surface);
    final scheme = ColorScheme(
      brightness: brightness,
      primary: light ? fill : accent,
      onPrimary: light ? onFill : Palette.charcoal,
      primaryContainer: wash,
      onPrimaryContainer: light ? fill : accent,
      secondary: onSurface,
      onSecondary: surface,
      tertiary: light ? fill : accent,
      onTertiary: light ? onFill : Palette.charcoal,
      error: const Color(0xFFB3261E),
      onError: Colors.white,
      surface: surface,
      onSurface: onSurface,
      onSurfaceVariant: muted,
      secondaryContainer: wash,
      onSecondaryContainer: light ? fill : accent,
      surfaceContainerLowest: sunken,
      surfaceContainerLow: surface,
      surfaceContainer: raised,
      surfaceContainerHigh: raised,
      surfaceContainerHighest: raised,
      outline: muted,
      outlineVariant: hairline,
      inverseSurface: onSurface,
      onInverseSurface: surface,
      shadow: Colors.black,
      scrim: Colors.black,
      surfaceTint: Colors.transparent,
    );

    final text = _textTheme(onSurface, muted);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: surface,
      canvasColor: surface,
      fontFamily: FontFamilies.ui,
      textTheme: text,
      splashFactory: InkRipple.splashFactory,
      dividerTheme: DividerThemeData(color: hairline, thickness: 1, space: 1),
      appBarTheme: AppBarTheme(
        backgroundColor: surface,
        foregroundColor: onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: text.titleLarge,
        systemOverlayStyle: systemBarsFor(brightness),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: raised,
        modalBackgroundColor: raised,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        showDragHandle: true,
        dragHandleColor: hairline,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.lg)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: fill,
          foregroundColor: onFill,
          textStyle: text.labelLarge,
          padding: const EdgeInsets.symmetric(horizontal: Space.xl, vertical: Space.md),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: onSurface,
          side: BorderSide(color: hairline),
          textStyle: text.labelLarge,
          padding: const EdgeInsets.symmetric(horizontal: Space.xl, vertical: Space.md),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: accent, textStyle: text.labelLarge),
      ),
      iconTheme: IconThemeData(color: onSurface, size: 22),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 64,
        indicatorColor: wash,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected) ? (light ? fill : accent) : muted,
            size: 22,
          ),
        ),
        labelTextStyle: WidgetStateTextStyle.resolveWith(
          (states) => text.labelMedium!.copyWith(
            color: states.contains(WidgetState.selected) ? (light ? fill : accent) : muted,
            fontWeight: states.contains(WidgetState.selected) ? FontWeight.w600 : null,
          ),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: fill,
        foregroundColor: onFill,
        elevation: 2,
        highlightElevation: 4,
        extendedTextStyle: text.labelLarge,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.lg)),
      ),
      chipTheme: ChipThemeData(
        // Selected: solid maroon. Otherwise: a hairline outline on the page.
        // Unselected chips get a light fill and a firm outline, so they read as buttons.
        color: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? fill : sunken,
        ),
        labelStyle: WidgetStateTextStyle.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? text.labelMedium!.copyWith(color: onFill, fontWeight: FontWeight.w600)
              : text.labelMedium!.copyWith(color: onSurface),
        ),
        side: WidgetStateBorderSide.resolveWith(
          (states) => BorderSide(
            color: states.contains(WidgetState.selected) ? fill : onSurface.withValues(alpha: light ? 0.28 : 0.32),
          ),
        ),
        iconTheme: IconThemeData(color: light ? fill : accent, size: 16),
        checkmarkColor: onFill,
        deleteIconColor: muted,
        showCheckmark: false,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: muted,
        textColor: onSurface,
        titleTextStyle: text.bodyLarge,
        subtitleTextStyle: text.bodySmall,
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: light ? fill : accent,
        inactiveTrackColor: hairline,
        thumbColor: light ? fill : accent,
        overlayColor: fill.withValues(alpha: 0.12),
        trackHeight: 2,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          side: WidgetStatePropertyAll(BorderSide(color: hairline)),
          textStyle: WidgetStatePropertyAll(text.labelMedium),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected) ? fill : Colors.transparent,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected) ? onFill : onSurface,
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: onSurface,
        contentTextStyle: text.bodyMedium?.copyWith(color: surface),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: light ? fill : accent,
        linearTrackColor: hairline,
        circularTrackColor: Colors.transparent,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? onFill : muted,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? fill : hairline,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? fill : muted.withValues(alpha: 0.5),
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? fill : Colors.transparent,
        ),
        checkColor: const WidgetStatePropertyAll(onFill),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: light ? fill : accent,
        selectionColor: fill.withValues(alpha: 0.25),
        selectionHandleColor: light ? fill : accent,
      ),
    );
  }

  static TextTheme _textTheme(Color ink, Color muted) {
    TextStyle display(double size, double height, {FontWeight weight = FontWeight.w400}) =>
        TextStyle(
          fontFamily: FontFamilies.display,
          fontSize: size,
          height: height,
          fontWeight: weight,
          color: ink,
          letterSpacing: -0.2,
          // Fraunces' optical size axis follows the font size; keep it soft, not wonky.
          fontVariations: [
            FontVariation('opsz', size.clamp(9, 144)),
            const FontVariation('SOFT', 50),
            const FontVariation('WONK', 0),
          ],
        );
    TextStyle ui(double size, double height, FontWeight weight, {Color? color}) => TextStyle(
      fontFamily: FontFamilies.ui,
      fontSize: size,
      height: height,
      fontWeight: weight,
      color: color ?? ink,
    );

    return TextTheme(
      displayLarge: display(52, 1.05, weight: FontWeight.w300),
      displayMedium: display(40, 1.1, weight: FontWeight.w300),
      displaySmall: display(32, 1.15),
      headlineLarge: display(28, 1.2),
      headlineMedium: display(24, 1.25),
      headlineSmall: display(21, 1.3),
      titleLarge: display(19, 1.3, weight: FontWeight.w500),
      titleMedium: ui(16, 1.35, FontWeight.w500),
      titleSmall: ui(14, 1.35, FontWeight.w500),
      bodyLarge: ui(16, 1.5, FontWeight.w400),
      bodyMedium: ui(14, 1.45, FontWeight.w400),
      bodySmall: ui(12.5, 1.4, FontWeight.w400, color: muted),
      labelLarge: ui(14, 1.2, FontWeight.w500),
      labelMedium: ui(12.5, 1.2, FontWeight.w500),
      labelSmall: ui(11, 1.2, FontWeight.w500, color: muted).copyWith(letterSpacing: 0.6),
    );
  }
}
