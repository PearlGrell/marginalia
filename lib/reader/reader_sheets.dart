import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../readium/readium.dart';
import '../theme/reader_theme.dart';
import '../theme/tokens.dart';
import 'page_turn/turn_painters.dart';
import 'reader_preferences.dart';
import '../data/database.dart';
import 'annotations.dart';
import 'custom_theme_screen.dart';

/// Where to go from the navigation sheet.
sealed class NavigationTarget {
  const NavigationTarget();
}

class GoToHref extends NavigationTarget {
  const GoToHref(this.href);

  final String href;
}

class GoToLocator extends NavigationTarget {
  const GoToLocator(this.locatorJson);

  final String locatorJson;
}

/// Open a highlight or note for editing.
class EditAnnotation extends NavigationTarget {
  const EditAnnotation(this.id);

  final String id;
}

/// Share a highlight or note as a story card.
class ShareAnnotation extends NavigationTarget {
  const ShareAnnotation(this.id);

  final String id;
}

/// Share a highlight or note as a link.
class ShareAnnotationLink extends NavigationTarget {
  const ShareAnnotationLink(this.id);

  final String id;
}

/// Export the book's highlights and notes.
class ExportBookNotes extends NavigationTarget {
  const ExportBookNotes();
}

/// Contents, bookmarks, and the book's notebook of highlights and notes, as tabs.
Future<NavigationTarget?> showNavigationSheet(
  BuildContext context, {
  required List<TocEntry> toc,
  required List<Annotation> annotations,
  required String? currentHref,
  required void Function(Annotation) onDelete,
  required void Function(Annotation, HighlightColor) onRecolor,
}) {
  return showModalBottomSheet<NavigationTarget>(
    context: context,
    isScrollControlled: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.92,
      builder: (context, scroll) => _NavigationSheet(
        scroll: scroll,
        toc: toc,
        annotations: annotations,
        currentHref: currentHref,
        onDelete: onDelete,
        onRecolor: onRecolor,
      ),
    ),
  );
}

class _NavigationSheet extends StatefulWidget {
  const _NavigationSheet({
    required this.scroll,
    required this.toc,
    required this.annotations,
    required this.currentHref,
    required this.onDelete,
    required this.onRecolor,
  });

  final ScrollController scroll;
  final List<TocEntry> toc;
  final List<Annotation> annotations;
  final String? currentHref;
  final void Function(Annotation) onDelete;
  final void Function(Annotation, HighlightColor) onRecolor;

  @override
  State<_NavigationSheet> createState() => _NavigationSheetState();
}

class _NavigationSheetState extends State<_NavigationSheet> {
  late List<Annotation> _bookmarks = [
    for (final a in widget.annotations)
      if (a.type == AnnotationType.bookmark) a,
  ];
  late List<Annotation> _notes = [
    for (final a in widget.annotations)
      if (a.type != AnnotationType.bookmark) a,
  ];
  int _tab = 0;

  static String _path(String href) => href.split('#').first;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.md),
          child: SegmentedButton<int>(
            showSelectedIcon: false,
            segments: [
              const ButtonSegment(value: 0, label: Text('Contents')),
              ButtonSegment(
                value: 1,
                label: Text(_bookmarks.isEmpty ? 'Bookmarks' : 'Bookmarks · ${_bookmarks.length}'),
              ),
              ButtonSegment(
                value: 2,
                label: Text(_notes.isEmpty ? 'Notes' : 'Notes · ${_notes.length}'),
              ),
            ],
            selected: {_tab},
            onSelectionChanged: (s) => setState(() => _tab = s.first),
          ),
        ),
        const Divider(),
        Expanded(
          child: switch (_tab) {
            0 => _contents(text),
            1 => _bookmarkList(text),
            _ => _noteList(text),
          },
        ),
      ],
    );
  }

  Widget _contents(TextTheme text) {
    final entries = <(TocEntry, int)>[];
    void flatten(List<TocEntry> list, int depth) {
      for (final entry in list) {
        entries.add((entry, depth));
        flatten(entry.children, depth + 1);
      }
    }

    flatten(widget.toc, 0);
    final current = widget.currentHref == null ? null : _path(widget.currentHref!);
    final scheme = Theme.of(context).colorScheme;

    if (entries.isEmpty) {
      return _Empty('This book has no table of contents.', scroll: widget.scroll);
    }
    return ListView.builder(
      controller: widget.scroll,
      itemCount: entries.length,
      itemBuilder: (context, i) {
        final (entry, depth) = entries[i];
        final isCurrent = _path(entry.href) == current;
        return ListTile(
          contentPadding: EdgeInsets.only(left: Space.gutter + depth * Space.lg, right: Space.gutter),
          title: Text(
            entry.title,
            style: text.bodyLarge?.copyWith(
              fontWeight: isCurrent ? FontWeight.w600 : null,
              color: isCurrent ? scheme.primary : null,
            ),
          ),
          onTap: () => Navigator.of(context).pop(GoToHref(entry.href)),
        );
      },
    );
  }

  Widget _bookmarkList(TextTheme text) {
    if (_bookmarks.isEmpty) {
      return _Empty(
        'No bookmarks yet. Tap the bookmark at the top of a page to keep your place.',
        scroll: widget.scroll,
      );
    }
    return ListView.builder(
      controller: widget.scroll,
      itemCount: _bookmarks.length,
      itemBuilder: (context, i) {
        final bookmark = _bookmarks[i];
        final percent = bookmark.progression == null
            ? ''
            : '${(bookmark.progression! * 100).round()}% · ';
        return ListTile(
          contentPadding: const EdgeInsets.only(left: Space.gutter, right: Space.sm),
          leading: Icon(Icons.bookmark, color: Theme.of(context).colorScheme.primary),
          title: Text(bookmark.chapterTitle ?? 'Bookmark'),
          subtitle: Text('$percent${_date(bookmark.createdAt)}'),
          trailing: IconButton(
            icon: const Icon(Icons.close, size: 20),
            tooltip: 'Remove bookmark',
            onPressed: () {
              widget.onDelete(bookmark);
              setState(() => _bookmarks = [..._bookmarks]..removeAt(i));
            },
          ),
          onTap: () => Navigator.of(context).pop(GoToLocator(bookmark.locator)),
        );
      },
    );
  }

  /// The notebook: highlights and notes in reading order.
  Widget _noteList(TextTheme text) {
    if (_notes.isEmpty) {
      return _Empty(
        'Select text while reading to highlight it or add a note. They gather here.',
        scroll: widget.scroll,
      );
    }
    final brightness = Theme.of(context).brightness;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return ListView.separated(
      controller: widget.scroll,
      padding: const EdgeInsets.only(bottom: Space.xl),
      itemCount: _notes.length + 1,
      separatorBuilder: (_, i) => i == 0 ? const SizedBox.shrink() : const Divider(indent: Space.gutter, endIndent: Space.gutter),
      itemBuilder: (context, index) {
        if (index == 0) {
          return Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: Space.sm),
              child: TextButton.icon(
                icon: const Icon(Icons.ios_share, size: 18),
                label: const Text('Export as Markdown or PDF'),
                onPressed: () => Navigator.of(context).pop(const ExportBookNotes()),
              ),
            ),
          );
        }
        final a = _notes[index - 1];
        final where = [
          if (a.chapterTitle case final c? when c.isNotEmpty) c,
          if (a.progression case final p?) '${(p * 100).round()}%',
        ].join(' · ');
        return InkWell(
          onTap: () => Navigator.of(context).pop(GoToLocator(a.locator)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.sm, Space.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 3,
                  height: 44,
                  margin: const EdgeInsets.only(right: Space.md, top: 2),
                  color: a.highlightColor.resolve(brightness),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (a.selectedText case final quote?)
                        Text(
                          quote.trim(),
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodyLarge?.copyWith(fontFamily: FontFamilies.reading),
                        ),
                      if (a.note case final note? when note.isNotEmpty) ...[
                        const SizedBox(height: Space.xs),
                        Text(note, style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
                      ],
                      if (where.isNotEmpty) ...[
                        const SizedBox(height: Space.xs),
                        Text(where, style: text.bodySmall?.copyWith(color: muted)),
                      ],
                    ],
                  ),
                ),
                PopupMenuButton<Object>(
                  tooltip: 'Change',
                  onSelected: (choice) {
                    if (choice is HighlightColor) {
                      widget.onRecolor(a, choice);
                      setState(
                        () => _notes = [
                          for (final n in _notes) n.id == a.id ? n.copyWith(color: Value(choice.name)) : n,
                        ],
                      );
                    } else if (choice == 'edit') {
                      Navigator.of(context).pop(EditAnnotation(a.id));
                    } else if (choice == 'story') {
                      Navigator.of(context).pop(ShareAnnotation(a.id));
                    } else if (choice == 'link') {
                      Navigator.of(context).pop(ShareAnnotationLink(a.id));
                    } else if (choice == 'delete') {
                      widget.onDelete(a);
                      setState(() => _notes = [..._notes]..removeWhere((n) => n.id == a.id));
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      enabled: false,
                      child: Text('COLOR', style: text.labelSmall),
                    ),
                    for (final color in HighlightColor.values)
                      PopupMenuItem(
                        value: color,
                        child: Row(
                          children: [
                            Container(
                              width: 18,
                              height: 18,
                              decoration: BoxDecoration(
                                color: color.resolve(brightness),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: Space.md),
                            Text(color.name[0].toUpperCase() + color.name.substring(1)),
                            if (a.highlightColor == color) ...[
                              const Spacer(),
                              const Icon(Icons.check, size: 18),
                            ],
                          ],
                        ),
                      ),
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      value: 'edit',
                      child: Text(a.note?.isNotEmpty == true ? 'Edit note' : 'Add a note'),
                    ),
                    const PopupMenuItem(value: 'story', child: Text('Share as image')),
                    const PopupMenuItem(value: 'link', child: Text('Share as link')),
                    const PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  static String _date(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec', //
    ];
    final day = '${d.day} ${months[d.month - 1]}';
    return d.year == DateTime.now().year ? day : '$day ${d.year}';
  }
}

class _Empty extends StatelessWidget {
  const _Empty(this.message, {required this.scroll});

  final String message;
  final ScrollController scroll;

  @override
  Widget build(BuildContext context) {
    return ListView(
      controller: scroll,
      padding: const EdgeInsets.all(Space.xxl),
      children: [
        Text(
          message,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// Page, type, layout and reading settings. [coverColor] is the open book's tint, for the
/// Cover page.
Future<void> showDisplaySheet(BuildContext context, {Color? coverColor}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.92,
      builder: (context, scroll) => ReaderSettingsList(scroll: scroll, coverColor: coverColor),
    ),
  );
}

/// Page, type, layout and reading settings: the Display sheet in a book, and Settings →
/// Reading outside one.
class ReaderSettingsList extends ConsumerWidget {
  const ReaderSettingsList({super.key, this.scroll, this.inSheet = true, this.coverColor});

  final ScrollController? scroll;

  /// In the reader's sheet, a link leads to Settings for downloads.
  final bool inSheet;

  /// The open book's tint, to preview the Cover page with.
  final Color? coverColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(readerPreferencesProvider);
    final notifier = ref.read(readerPreferencesProvider.notifier);
    final text = Theme.of(context).textTheme;
    final platform = MediaQuery.platformBrightnessOf(context);
    final now = DateTime.now();
    final slot = prefs.slot(platform, now);
    final current = prefs.resolveTheme(platform, now: now);
    final automatic = prefs.pageMode == PageMode.system || prefs.pageMode == PageMode.scheduled;

    Widget section(String title) => Padding(
      padding: const EdgeInsets.only(top: Space.xl, bottom: Space.sm),
      child: Text(title.toUpperCase(), style: text.labelSmall),
    );

    void openCustom() => Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const CustomThemeScreen()),
    );

    return ListView(
      controller: scroll,
      padding: EdgeInsets.fromLTRB(Space.gutter, inSheet ? 0 : Space.md, Space.gutter, Space.xxl),
      children: [
        // ---- Page ----
        Text('PAGE', style: text.labelSmall),
        const SizedBox(height: Space.sm),
        SizedBox(
          height: 72,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: ReaderTheme.values.length,
            separatorBuilder: (_, _) => const SizedBox(width: Space.sm),
            itemBuilder: (context, i) {
              final theme = ReaderTheme.values[i];
              return _ThemeSwatch(
                colors: prefs.colorsFor(theme, slot, coverColor: coverColor),
                label: theme.label,
                selected: current == theme,
                // While switching by itself, the page for the other time is marked too.
                paired: automatic && current != theme && (theme == prefs.lightTheme || theme == prefs.darkTheme),
                onTap: () {
                  if (theme == ReaderTheme.custom && current == theme) {
                    openCustom();
                  } else {
                    notifier.chooseTheme(theme, showing: slot);
                  }
                },
              );
            },
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.palette_outlined),
          title: const Text('Custom page'),
          subtitle: const Text('Your own page and text colors'),
          trailing: const Icon(Icons.chevron_right),
          onTap: openCustom,
        ),
        Text('Day and night', style: text.bodySmall),
        const SizedBox(height: Space.xs),
        SegmentedButton<PageMode>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: PageMode.system, label: Text('Phone')),
            ButtonSegment(value: PageMode.light, label: Text('Day')),
            ButtonSegment(value: PageMode.dark, label: Text('Night')),
            ButtonSegment(value: PageMode.scheduled, label: Text('Timed')),
          ],
          selected: {prefs.pageMode},
          onSelectionChanged: (s) => notifier.update((p) => p.copyWith(pageMode: s.first)),
        ),
        const SizedBox(height: Space.xs),
        Text(
          switch (prefs.pageMode) {
            PageMode.system => 'Follows your phone: ${prefs.lightTheme.label} by day, ${prefs.darkTheme.label} at night',
            PageMode.light => 'Always ${prefs.lightTheme.label}',
            PageMode.dark => 'Always ${prefs.darkTheme.label}',
            PageMode.scheduled =>
              '${prefs.darkTheme.label} from ${_time(prefs.nightStart)} to ${_time(prefs.nightEnd)}, '
                  '${prefs.lightTheme.label} the rest of the day',
          },
          style: text.bodySmall,
        ),
        if (prefs.pageMode == PageMode.scheduled)
          Row(
            children: [
              Expanded(
                child: _TimeButton(
                  label: 'Night from',
                  minutes: prefs.nightStart,
                  onChanged: (m) => notifier.update((p) => p.copyWith(nightStart: m)),
                ),
              ),
              const SizedBox(width: Space.sm),
              Expanded(
                child: _TimeButton(
                  label: 'Until',
                  minutes: prefs.nightEnd,
                  onChanged: (m) => notifier.update((p) => p.copyWith(nightEnd: m)),
                ),
              ),
            ],
          ),

        // ---- Type ----
        section('Type'),
        SizedBox(
          height: 70,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: ReadingFont.values.length,
            separatorBuilder: (_, _) => const SizedBox(width: Space.sm),
            itemBuilder: (context, i) {
              final font = ReadingFont.values[i];
              return _FontChip(
                font: font,
                selected: prefs.font == font,
                onTap: () => notifier.update((p) => p.copyWith(font: font)),
              );
            },
          ),
        ),
        const SizedBox(height: Space.sm),
        _Stepper(
          label: 'Size',
          value: '${(prefs.fontScale * 100).round()}%',
          onLess: prefs.fontScale <= ReaderPreferences.minFontScale
              ? null
              : () => notifier.update((p) => p.copyWith(fontScale: p.fontScale - 0.1)),
          onMore: prefs.fontScale >= ReaderPreferences.maxFontScale
              ? null
              : () => notifier.update((p) => p.copyWith(fontScale: p.fontScale + 0.1)),
        ),

        // ---- Layout ----
        section('Layout'),
        _Stepper(
          label: 'Margins',
          value: _marginLabel(prefs.margins),
          onLess: prefs.margins <= ReaderPreferences.minMargins
              ? null
              : () => notifier.update((p) => p.copyWith(margins: p.margins - 0.25)),
          onMore: prefs.margins >= ReaderPreferences.maxMargins
              ? null
              : () => notifier.update((p) => p.copyWith(margins: p.margins + 0.25)),
        ),
        if (!prefs.scroll) ...[
          const SizedBox(height: Space.sm),
          Text('Two pages side by side', style: text.bodySmall),
          const SizedBox(height: Space.xs),
          SegmentedButton<PageColumns>(
            showSelectedIcon: false,
            segments: [
              for (final c in PageColumns.values) ButtonSegment(value: c, label: Text(c.label)),
            ],
            selected: {prefs.columns},
            onSelectionChanged: (s) => notifier.update((p) => p.copyWith(columns: s.first)),
          ),
          const SizedBox(height: Space.xs),
          Text(
            switch (prefs.columns) {
              PageColumns.auto => 'Two pages on a tablet or with the phone sideways',
              PageColumns.one => 'Always one page',
              PageColumns.two => 'Always two pages, even upright',
            },
            style: text.bodySmall,
          ),
          const SizedBox(height: Space.sm),
        ],
        _Toggle(
          title: "Book's own layout",
          subtitle: prefs.publisherStyles
              ? 'Spacing, alignment and hyphenation follow the book'
              : 'Using your spacing, alignment and hyphenation',
          value: prefs.publisherStyles,
          onChanged: (on) => notifier.update((p) => p.copyWith(publisherStyles: on)),
        ),
        _Stepper(
          label: 'Line spacing',
          value: prefs.lineHeight.toStringAsFixed(1),
          dimmed: prefs.publisherStyles,
          onLess: prefs.lineHeight <= ReaderPreferences.minLineHeight
              ? null
              : () => notifier.updateLayout((p) => p.copyWith(lineHeight: p.lineHeight - 0.1)),
          onMore: prefs.lineHeight >= ReaderPreferences.maxLineHeight
              ? null
              : () => notifier.updateLayout((p) => p.copyWith(lineHeight: p.lineHeight + 0.1)),
        ),
        _Toggle(
          title: 'Justify text',
          value: prefs.justify,
          dimmed: prefs.publisherStyles,
          onChanged: (on) => notifier.updateLayout((p) => p.copyWith(justify: on)),
        ),
        _Toggle(
          title: 'Hyphenate',
          value: prefs.hyphenate,
          dimmed: prefs.publisherStyles,
          onChanged: (on) => notifier.updateLayout((p) => p.copyWith(hyphenate: on)),
        ),

        // ---- Reading ----
        section('Reading'),
        SegmentedButton<bool>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: false, label: Text('Pages')),
            ButtonSegment(value: true, label: Text('Scroll')),
          ],
          selected: {prefs.scroll},
          onSelectionChanged: (s) => notifier.update((p) => p.copyWith(scroll: s.first)),
        ),
        if (!prefs.scroll) ...[
          const SizedBox(height: Space.md),
          Text('Page turn', style: text.bodySmall),
          const SizedBox(height: Space.xs),
          SegmentedButton<TurnStyle>(
            showSelectedIcon: false,
            segments: [
              for (final style in TurnStyle.values)
                ButtonSegment(value: style, label: Text(style.label)),
            ],
            selected: {prefs.turnStyle},
            onSelectionChanged: (s) => notifier.update((p) => p.copyWith(turnStyle: s.first)),
          ),
        ],
        const SizedBox(height: Space.sm),
        _Toggle(
          title: 'Tap the sides to turn pages',
          subtitle: prefs.tapToTurn
              ? 'Left goes back, right goes on; the middle shows controls'
              : 'Any tap shows controls; swipe to turn',
          value: prefs.tapToTurn,
          onChanged: (on) => notifier.update((p) => p.copyWith(tapToTurn: on)),
        ),
        _Toggle(
          title: 'Volume keys turn pages',
          value: prefs.volumeKeys,
          onChanged: (on) => notifier.update((p) => p.copyWith(volumeKeys: on)),
        ),
        _Toggle(
          title: 'Haptic tick on page turn',
          value: prefs.haptics,
          onChanged: (on) => notifier.update((p) => p.copyWith(haptics: on)),
        ),
        _Toggle(
          title: 'Keep screen on',
          subtitle: 'While a book is open',
          value: prefs.keepScreenOn,
          onChanged: (on) => notifier.update((p) => p.copyWith(keepScreenOn: on)),
        ),
        if (inSheet)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.download_outlined),
            title: const Text('Dictionary, translation and voices'),
            subtitle: const Text('Downloads in Settings'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.pop(context);
              context.push('/settings/downloads');
            },
          ),
      ],
    );
  }

  static String _time(int minutes) =>
      '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';

  static String _marginLabel(double m) => switch (m) {
    <= 0.6 => 'Narrow',
    <= 0.9 => 'Snug',
    <= 1.1 => 'Medium',
    <= 1.5 => 'Wide',
    _ => 'Widest',
  };
}

class _ThemeSwatch extends StatelessWidget {
  const _ThemeSwatch({
    required this.colors,
    required this.label,
    required this.selected,
    required this.paired,
    required this.onTap,
  });

  final PageColors colors;
  final String label;
  final bool selected;
  final bool paired;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: '$label page',
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: Motion.quick,
          width: 64,
          decoration: BoxDecoration(
            color: colors.page,
            borderRadius: BorderRadius.circular(Radii.md),
            border: Border.all(
              color: selected || paired ? scheme.onSurface : scheme.outlineVariant,
              width: selected ? 2 : 1,
            ),
          ),
          alignment: Alignment.center,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'Aa',
                style: TextStyle(fontFamily: FontFamilies.reading, fontSize: 18, color: colors.ink),
              ),
              Text(
                label,
                style: TextStyle(fontFamily: FontFamilies.ui, fontSize: 11, color: colors.muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A time of day, tapped to change.
class _TimeButton extends StatelessWidget {
  const _TimeButton({required this.label, required this.minutes, required this.onChanged});

  final String label;
  final int minutes;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final time = TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label, style: Theme.of(context).textTheme.bodySmall),
      subtitle: Text(time.format(context), style: Theme.of(context).textTheme.titleMedium),
      onTap: () async {
        final picked = await showTimePicker(context: context, initialTime: time);
        if (picked != null) onChanged(picked.hour * 60 + picked.minute);
      },
    );
  }
}

class _FontChip extends StatelessWidget {
  const _FontChip({required this.font, required this.selected, required this.onTap});

  final ReadingFont font;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: '${font.label} font',
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: Motion.quick,
          width: 92,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.md),
            border: Border.all(
              color: selected ? scheme.onSurface : scheme.outlineVariant,
              width: selected ? 2 : 1,
            ),
          ),
          alignment: Alignment.center,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'Ag',
                style: TextStyle(
                  fontFamily: font.preview ?? FontFamilies.ui,
                  fontSize: 20,
                  color: scheme.onSurface,
                ),
              ),
              Text(
                font.label,
                style: TextStyle(
                  fontFamily: FontFamilies.ui,
                  fontSize: 11,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A setting stepped with − and +.
class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.label,
    required this.value,
    required this.onLess,
    required this.onMore,
    this.dimmed = false,
  });

  final String label;
  final String value;
  final VoidCallback? onLess;
  final VoidCallback? onMore;

  /// Faded while it won't apply (it still works, and turns the book's layout off).
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Opacity(
      opacity: dimmed ? 0.5 : 1,
      child: Row(
        children: [
          Expanded(child: Text(label, style: text.bodyLarge)),
          IconButton(onPressed: onLess, icon: const Icon(Icons.remove), tooltip: 'Less'),
          SizedBox(
            width: 64,
            child: Text(value, textAlign: TextAlign.center, style: text.titleSmall),
          ),
          IconButton(onPressed: onMore, icon: const Icon(Icons.add), tooltip: 'More'),
        ],
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.dimmed = false,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: dimmed ? 0.5 : 1,
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle!),
        value: value,
        onChanged: onChanged,
      ),
    );
  }
}
