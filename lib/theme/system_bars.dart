import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Status and navigation bars: transparent, so the page shows through, with icons that
/// contrast with it. Flutter's `SystemUiOverlayStyle.dark` and `.light` presets paint the
/// navigation bar solid black, so they are not used.
SystemUiOverlayStyle systemBarsFor(Brightness background) {
  final icons = background == Brightness.light ? Brightness.dark : Brightness.light;
  return SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: icons,
    statusBarBrightness: background,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarIconBrightness: icons,
    systemNavigationBarContrastEnforced: false,
    systemStatusBarContrastEnforced: false,
  );
}
