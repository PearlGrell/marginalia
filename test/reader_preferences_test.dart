import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marginalia/reader/page_turn/turn_painters.dart';
import 'package:marginalia/reader/reader_preferences.dart';
import 'package:marginalia/data/database.dart';
import 'package:marginalia/reader/annotations.dart';
import 'package:marginalia/readium/readium.dart';
import 'package:marginalia/theme/reader_theme.dart';

void main() {
  group('ReaderPreferences', () {
    test('survive a save and load', () {
      const prefs = ReaderPreferences(
        pageMode: PageMode.scheduled,
        lightTheme: ReaderTheme.cover,
        darkTheme: ReaderTheme.custom,
        customPage: 0xFF1B2433,
        customInk: 0xFFD4D9DE,
        nightStart: 22 * 60 + 30,
        nightEnd: 6 * 60,
        columns: PageColumns.two,
        font: ReadingFont.garamond,
        fontScale: 1.3,
        lineHeight: 1.8,
        margins: 1.5,
        justify: false,
        hyphenate: false,
        publisherStyles: false,
        scroll: true,
        turnStyle: TurnStyle.fade,
        haptics: false,
        tapToTurn: false,
        volumeKeys: true,
        keepScreenOn: true,
      );
      final restored = ReaderPreferences.fromJson(prefs.toJson());
      expect(restored.toJson(), prefs.toJson());
    });

    test('unknown or missing values fall back to defaults', () {
      final restored = ReaderPreferences.fromJson({'font': 'comic-sans', 'fontScale': 99});
      expect(restored.font, ReadingFont.literata);
      expect(restored.fontScale, ReaderPreferences.maxFontScale);
    });

    test('following the phone picks the light or dark page', () {
      const prefs = ReaderPreferences(lightTheme: ReaderTheme.sepia, darkTheme: ReaderTheme.oled);
      expect(prefs.resolveTheme(Brightness.light), ReaderTheme.sepia);
      expect(prefs.resolveTheme(Brightness.dark), ReaderTheme.oled);
      expect(
        prefs.copyWith(pageMode: PageMode.light).resolveTheme(Brightness.dark),
        ReaderTheme.sepia,
      );
    });

    test('earlier builds saved the mode as themeMode, and it still loads', () {
      final restored = ReaderPreferences.fromJson({'themeMode': 'dark', 'lightTheme': 'sepia'});
      expect(restored.pageMode, PageMode.dark);
      expect(restored.lightTheme, ReaderTheme.sepia);
      expect(restored.columns, PageColumns.auto);
    });

    test('a timed night runs across midnight', () {
      const prefs = ReaderPreferences(pageMode: PageMode.scheduled, nightStart: 21 * 60, nightEnd: 7 * 60);
      expect(prefs.isNightAt(DateTime(2026, 1, 1, 22)), isTrue);
      expect(prefs.isNightAt(DateTime(2026, 1, 1, 3)), isTrue);
      expect(prefs.isNightAt(DateTime(2026, 1, 1, 7)), isFalse);
      expect(prefs.isNightAt(DateTime(2026, 1, 1, 12)), isFalse);
      expect(prefs.resolveTheme(Brightness.light, now: DateTime(2026, 1, 1, 23)), prefs.darkTheme);
      // And a night inside one day (say, a nap page from 13:00 to 15:00).
      final nap = prefs.copyWith(nightStart: 13 * 60, nightEnd: 15 * 60);
      expect(nap.isNightAt(DateTime(2026, 1, 1, 14)), isTrue);
      expect(nap.isNightAt(DateTime(2026, 1, 1, 16)), isFalse);
    });

    test('the cover page takes the book tint, light by day and dark at night', () {
      const prefs = ReaderPreferences(lightTheme: ReaderTheme.cover, darkTheme: ReaderTheme.cover);
      const tint = Color(0xFF2F4A3A);
      final day = prefs.resolvePage(Brightness.light, coverColor: tint);
      final night = prefs.resolvePage(Brightness.dark, coverColor: tint);
      expect(day.brightness, Brightness.light);
      expect(night.brightness, Brightness.dark);
      expect(day.contrast, greaterThan(7));
      expect(night.contrast, greaterThan(7));
      // Without a cover tint it still has colors.
      expect(prefs.resolvePage(Brightness.light).page, isNot(day.page));
    });

    test('a custom page goes to the day or night slot its brightness belongs to', () {
      const dark = ReaderPreferences(customPage: 0xFF1B2433, customInk: 0xFFD4D9DE);
      expect(dark.customColors.brightness, Brightness.dark);
      expect(dark.customColors.contrast, greaterThan(4.5));
      const light = ReaderPreferences();
      expect(light.customColors.brightness, Brightness.light);
    });

    test("spacing reaches Readium only without the book's own layout", () {
      const prefs = ReaderPreferences(lineHeight: 1.8);
      expect(prefs.toReadium(ReaderTheme.paper.preset!).containsKey('lineHeight'), isFalse);
      final custom = prefs.copyWith(publisherStyles: false).toReadium(ReaderTheme.paper.preset!);
      expect(custom['lineHeight'], 1.8);
      expect(custom['textAlign'], 'justify');
    });

    test('two pages side by side only apply to paged reading', () {
      const prefs = ReaderPreferences(columns: PageColumns.two);
      expect(prefs.toReadium(ReaderTheme.paper.preset!)['columnCount'], '2');
      expect(prefs.copyWith(scroll: true).toReadium(ReaderTheme.paper.preset!).containsKey('columnCount'), isFalse);
    });
  });

  group('Bookmark annotations', () {
    ReaderLocation at(int? position, {double? total, String href = 'a.xhtml'}) => ReaderLocation(
      locatorJson: '{"href":"$href","type":"application/xhtml+xml"}',
      href: href,
      position: position,
      totalProgression: total,
    );

    Annotation bookmarkAt(ReaderLocation l) => Annotation(
      id: '1',
      bookId: 'b',
      type: AnnotationType.bookmark,
      locator: l.locatorJson,
      position: l.position,
      progression: l.totalProgression,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      deleted: false,
      dirty: false,
    );

    test('match the page by position', () {
      final bookmark = bookmarkAt(at(12, total: 0.3));
      expect(bookmark.isOnPage(at(12, total: 0.31)), isTrue);
      expect(bookmark.isOnPage(at(13, total: 0.3)), isFalse);
    });

    test('fall back to chapter and progression without positions', () {
      final bookmark = bookmarkAt(at(null, total: 0.5));
      expect(bookmark.isOnPage(at(null, total: 0.5004)), isTrue);
      expect(bookmark.isOnPage(at(null, total: 0.52)), isFalse);
      expect(bookmark.isOnPage(at(null, total: 0.5, href: 'b.xhtml')), isFalse);
    });
  });
}
