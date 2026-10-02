import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/local_store.dart';
import '../theme/reader_theme.dart';
import '../theme/tokens.dart';
import 'page_turn/turn_painters.dart';

/// Reading faces. [css] is the family Readium uses (see `ReadingFonts.kt`); [preview] the
/// Flutter family for showing it in settings.
enum ReadingFont {
  publisher('Book', null, null),
  literata('Literata', 'Literata', 'Literata'),
  sourceSerif('Source Serif', 'Source Serif 4', 'SourceSerif4'),
  garamond('Garamond', 'EB Garamond', 'EBGaramond'),
  atkinson('Atkinson', 'Atkinson Hyperlegible', 'AtkinsonHyperlegible'),
  openDyslexic('OpenDyslexic', 'OpenDyslexic', null);

  const ReadingFont(this.label, this.css, this.preview);

  final String label;
  final String? css;
  final String? preview;
}

/// When the night page is used.
enum PageMode {
  /// Follows the phone's light and dark setting.
  system('Match phone'),
  light('Day'),
  dark('Night'),

  /// Night between [ReaderPreferences.nightStart] and [ReaderPreferences.nightEnd].
  scheduled('Scheduled');

  const PageMode(this.label);

  final String label;
}

/// Two pages side by side (paged reading only).
enum PageColumns {
  /// Two on a wide screen (a tablet, or a phone held sideways), one otherwise.
  auto('Auto', 'auto'),
  one('One', '1'),
  two('Two', '2');

  const PageColumns(this.label, this.readium);

  final String label;
  final String readium;
}

/// How books look and turn. Saved on the device and synced with the account.
@immutable
class ReaderPreferences {
  const ReaderPreferences({
    this.pageMode = PageMode.system,
    this.lightTheme = ReaderTheme.paper,
    this.darkTheme = ReaderTheme.dark,
    this.customPage = defaultCustomPage,
    this.customInk = defaultCustomInk,
    this.nightStart = 21 * 60,
    this.nightEnd = 7 * 60,
    this.font = ReadingFont.literata,
    this.fontScale = 1.0,
    this.lineHeight = 1.5,
    this.margins = 1.0,
    this.justify = true,
    this.hyphenate = true,
    this.publisherStyles = true,
    this.scroll = false,
    this.columns = PageColumns.auto,
    this.turnStyle = TurnStyle.curl,
    this.haptics = true,
    this.tapToTurn = true,
    this.volumeKeys = false,
    this.keepScreenOn = false,
  });

  static const defaultCustomPage = 0xFFE6ECE2;
  static const defaultCustomInk = 0xFF26302A;

  final PageMode pageMode;

  /// The day page: a light preset, Cover, or Custom.
  final ReaderTheme lightTheme;

  /// The night page: a dark preset, Cover, or Custom.
  final ReaderTheme darkTheme;

  /// The reader's own page and ink colors (ARGB), for [ReaderTheme.custom].
  final int customPage;
  final int customInk;

  /// Minutes after midnight when the night page starts and ends, for [PageMode.scheduled].
  final int nightStart;
  final int nightEnd;

  final ReadingFont font;

  /// 1.0 is the book's own size.
  final double fontScale;
  final double lineHeight;

  /// Multiplier on Readium's page gutter.
  final double margins;
  final bool justify;
  final bool hyphenate;

  /// Keep the book's own layout. Line spacing, justification and hyphenation only apply when
  /// this is off.
  final bool publisherStyles;

  /// Continuous scroll instead of pages.
  final bool scroll;
  final PageColumns columns;
  final TurnStyle turnStyle;

  /// A light tick on each page turn.
  final bool haptics;

  /// Taps on the left and right of the page turn it; otherwise any tap shows the controls.
  final bool tapToTurn;
  final bool volumeKeys;
  final bool keepScreenOn;

  static const minFontScale = 0.75;
  static const maxFontScale = 2.5;
  static const minLineHeight = 1.2;
  static const maxLineHeight = 2.0;
  static const minMargins = 0.5;
  static const maxMargins = 2.0;

  PageColors get customColors =>
      PageColors.from(label: 'Custom', page: Color(customPage), ink: Color(customInk));

  /// Whether it's night by the schedule at [now].
  bool isNightAt(DateTime now) {
    final minute = now.hour * 60 + now.minute;
    if (nightStart == nightEnd) return false;
    return nightStart < nightEnd
        ? minute >= nightStart && minute < nightEnd
        : minute >= nightStart || minute < nightEnd;
  }

  /// Day or night, as the page mode decides.
  Brightness slot(Brightness platform, DateTime now) => switch (pageMode) {
    PageMode.light => Brightness.light,
    PageMode.dark => Brightness.dark,
    PageMode.system => platform,
    PageMode.scheduled => isNightAt(now) ? Brightness.dark : Brightness.light,
  };

  /// The page theme in effect.
  ReaderTheme resolveTheme(Brightness platform, {DateTime? now}) =>
      slot(platform, now ?? DateTime.now()) == Brightness.dark ? darkTheme : lightTheme;

  /// The page colors in effect, for a book with [coverColor].
  PageColors resolvePage(Brightness platform, {DateTime? now, Color? coverColor}) {
    final slot = this.slot(platform, now ?? DateTime.now());
    return colorsFor(slot == Brightness.dark ? darkTheme : lightTheme, slot, coverColor: coverColor);
  }

  /// [theme]'s colors when used for the day or night page ([slot]).
  PageColors colorsFor(ReaderTheme theme, Brightness slot, {Color? coverColor}) => switch (theme) {
    ReaderTheme.cover => PageColors.tinted(coverColor ?? Palette.oxblood, slot),
    ReaderTheme.custom => customColors,
    _ => theme.preset!,
  };

  ReaderPreferences copyWith({
    PageMode? pageMode,
    ReaderTheme? lightTheme,
    ReaderTheme? darkTheme,
    int? customPage,
    int? customInk,
    int? nightStart,
    int? nightEnd,
    ReadingFont? font,
    double? fontScale,
    double? lineHeight,
    double? margins,
    bool? justify,
    bool? hyphenate,
    bool? publisherStyles,
    bool? scroll,
    PageColumns? columns,
    TurnStyle? turnStyle,
    bool? haptics,
    bool? tapToTurn,
    bool? volumeKeys,
    bool? keepScreenOn,
  }) => ReaderPreferences(
    pageMode: pageMode ?? this.pageMode,
    lightTheme: lightTheme ?? this.lightTheme,
    darkTheme: darkTheme ?? this.darkTheme,
    customPage: customPage ?? this.customPage,
    customInk: customInk ?? this.customInk,
    nightStart: (nightStart ?? this.nightStart).clamp(0, 24 * 60 - 1),
    nightEnd: (nightEnd ?? this.nightEnd).clamp(0, 24 * 60 - 1),
    font: font ?? this.font,
    fontScale: (fontScale ?? this.fontScale).clamp(minFontScale, maxFontScale),
    lineHeight: (lineHeight ?? this.lineHeight).clamp(minLineHeight, maxLineHeight),
    margins: (margins ?? this.margins).clamp(minMargins, maxMargins),
    justify: justify ?? this.justify,
    hyphenate: hyphenate ?? this.hyphenate,
    publisherStyles: publisherStyles ?? this.publisherStyles,
    scroll: scroll ?? this.scroll,
    columns: columns ?? this.columns,
    turnStyle: turnStyle ?? this.turnStyle,
    haptics: haptics ?? this.haptics,
    tapToTurn: tapToTurn ?? this.tapToTurn,
    volumeKeys: volumeKeys ?? this.volumeKeys,
    keepScreenOn: keepScreenOn ?? this.keepScreenOn,
  );

  /// What Readium renders (see `PreferencesMapper.kt`), for the page colors in effect.
  Map<String, Object?> toReadium(PageColors colors) => {
    'theme': colors.readiumTheme,
    'backgroundColor': colors.page.toARGB32(),
    'textColor': colors.ink.toARGB32(),
    'fontFamily': font.css,
    'fontSize': fontScale,
    'pageMargins': margins,
    'scroll': scroll,
    'publisherStyles': publisherStyles,
    if (!scroll) 'columnCount': columns.readium,
    if (!publisherStyles) ...{
      'lineHeight': lineHeight,
      'textAlign': justify ? 'justify' : 'start',
      'hyphens': hyphenate,
    },
    // White illustrations glare on dark pages; dim them. (On light pages they're blended
    // into the paper, see ReaderStyles.kt.)
    'imageFilter': colors.brightness == Brightness.dark ? 'darken' : null,
  };

  Map<String, Object?> toJson() => {
    'themeMode': pageMode.name,
    'lightTheme': lightTheme.name,
    'darkTheme': darkTheme.name,
    'customPage': customPage,
    'customInk': customInk,
    'nightStart': nightStart,
    'nightEnd': nightEnd,
    'font': font.name,
    'fontScale': fontScale,
    'lineHeight': lineHeight,
    'margins': margins,
    'justify': justify,
    'hyphenate': hyphenate,
    'publisherStyles': publisherStyles,
    'scroll': scroll,
    'columns': columns.name,
    'turnStyle': turnStyle.name,
    'haptics': haptics,
    'tapToTurn': tapToTurn,
    'volumeKeys': volumeKeys,
    'keepScreenOn': keepScreenOn,
  };

  factory ReaderPreferences.fromJson(Map<String, Object?> json) {
    const d = ReaderPreferences();
    T pick<T extends Enum>(List<T> values, Object? name, T fallback) =>
        values.where((v) => v.name == name).firstOrNull ?? fallback;
    return d.copyWith(
      // Saved as "themeMode" by earlier builds, with the same names.
      pageMode: pick(PageMode.values, json['themeMode'], d.pageMode),
      lightTheme: pick(ReaderTheme.values, json['lightTheme'], d.lightTheme),
      darkTheme: pick(ReaderTheme.values, json['darkTheme'], d.darkTheme),
      customPage: (json['customPage'] as num?)?.toInt(),
      customInk: (json['customInk'] as num?)?.toInt(),
      nightStart: (json['nightStart'] as num?)?.toInt(),
      nightEnd: (json['nightEnd'] as num?)?.toInt(),
      font: pick(ReadingFont.values, json['font'], d.font),
      fontScale: (json['fontScale'] as num?)?.toDouble(),
      lineHeight: (json['lineHeight'] as num?)?.toDouble(),
      margins: (json['margins'] as num?)?.toDouble(),
      justify: json['justify'] as bool?,
      hyphenate: json['hyphenate'] as bool?,
      publisherStyles: json['publisherStyles'] as bool?,
      scroll: json['scroll'] as bool?,
      columns: pick(PageColumns.values, json['columns'], d.columns),
      turnStyle: pick(TurnStyle.values, json['turnStyle'], d.turnStyle),
      haptics: json['haptics'] as bool?,
      tapToTurn: json['tapToTurn'] as bool?,
      volumeKeys: json['volumeKeys'] as bool?,
      keepScreenOn: json['keepScreenOn'] as bool?,
    );
  }
}

class ReaderPreferencesNotifier extends Notifier<ReaderPreferences> {
  static const _key = 'reader.preferences';

  @override
  ReaderPreferences build() {
    final json = ref.read(localStoreProvider).readJson(_key);
    return json is Map<String, Object?>
        ? ReaderPreferences.fromJson(json)
        : const ReaderPreferences();
  }

  void update(ReaderPreferences Function(ReaderPreferences) change) {
    state = change(state);
    final store = ref.read(localStoreProvider);
    store.writeJson(_key, state.toJson());
    // For sync: reader settings follow the account.
    store.writeJson('settings.changedAt', DateTime.now().millisecondsSinceEpoch);
  }

  /// Uses [theme] for the day or night page. A preset (and Custom) goes where its brightness
  /// belongs; Cover goes to whichever is showing ([showing]). Unless the page mode switches
  /// by itself, it also switches to that page.
  void chooseTheme(ReaderTheme theme, {required Brightness showing}) => update((p) {
    final slot = switch (theme) {
      ReaderTheme.cover => showing,
      ReaderTheme.custom => p.customColors.brightness,
      _ => theme.brightness!,
    };
    final light = slot == Brightness.light;
    final automatic = p.pageMode == PageMode.system || p.pageMode == PageMode.scheduled;
    return p.copyWith(
      lightTheme: light ? theme : null,
      darkTheme: light ? null : theme,
      pageMode: automatic ? null : (light ? PageMode.light : PageMode.dark),
    );
  });

  /// Saves the custom colors and uses them for the page their brightness belongs to.
  void saveCustom(Color page, Color ink) {
    update((p) => p.copyWith(customPage: page.toARGB32(), customInk: ink.toARGB32()));
    // If it moved between light and dark, it leaves the other page.
    final brightness = state.customColors.brightness;
    update((p) {
      if (brightness == Brightness.light && p.darkTheme == ReaderTheme.custom) {
        return p.copyWith(darkTheme: ReaderTheme.dark);
      }
      if (brightness == Brightness.dark && p.lightTheme == ReaderTheme.custom) {
        return p.copyWith(lightTheme: ReaderTheme.paper);
      }
      return p;
    });
    chooseTheme(ReaderTheme.custom, showing: brightness);
  }

  /// Spacing, justification and hyphenation need the book's own layout off.
  void updateLayout(ReaderPreferences Function(ReaderPreferences) change) =>
      update((p) => change(p).copyWith(publisherStyles: false));
}

final readerPreferencesProvider =
    NotifierProvider<ReaderPreferencesNotifier, ReaderPreferences>(ReaderPreferencesNotifier.new);
