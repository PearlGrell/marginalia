import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/reader_theme.dart';
import '../theme/tokens.dart';
import 'reader_preferences.dart';

/// Build a page theme: pick or mix the page color and the ink, with a live preview and a
/// readability check.
class CustomThemeScreen extends ConsumerStatefulWidget {
  const CustomThemeScreen({super.key});

  @override
  ConsumerState<CustomThemeScreen> createState() => _CustomThemeScreenState();
}

class _CustomThemeScreenState extends ConsumerState<CustomThemeScreen> {
  late HSLColor _page;
  late Color _ink;
  bool _autoInk = false;

  static const _pages = [
    Color(0xFFF7F1E3), // cream
    Color(0xFFF4E4E1), // rose
    Color(0xFFE6ECE2), // sage
    Color(0xFFE1EEEC), // mint
    Color(0xFFE3EAF3), // sky
    Color(0xFFECE6F2), // lavender
    Color(0xFF2B3138), // slate
    Color(0xFF1B2433), // navy
    Color(0xFF1E2A22), // forest
    Color(0xFF2A1F2B), // plum
  ];

  static const _inks = [
    Color(0xFF1F1B16), // ink
    Color(0xFF3B2A1E), // walnut
    Color(0xFF1E2B44), // navy
    Color(0xFF203326), // forest
    Color(0xFFE8E1D4), // parchment
    Color(0xFFD4D9DE), // mist
    Color(0xFFF2E6C9), // candle
    Color(0xFFCFE3D3), // mint
  ];

  @override
  void initState() {
    super.initState();
    final prefs = ref.read(readerPreferencesProvider);
    _page = HSLColor.fromColor(Color(prefs.customPage));
    _ink = Color(prefs.customInk);
  }

  Color get _pageColor => _page.toColor();

  /// An ink that reads well on the page: the page's hue, very dark or very light.
  static Color contrastingInk(Color page) {
    final hsl = HSLColor.fromColor(page);
    final dark = ThemeData.estimateBrightnessForColor(page) == Brightness.light;
    return hsl.withSaturation((hsl.saturation * 0.5).clamp(0.0, 0.35)).withLightness(dark ? 0.12 : 0.88).toColor();
  }

  void _setPage(HSLColor page) => setState(() {
    _page = page;
    if (_autoInk) _ink = contrastingInk(page.toColor());
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = PageColors.from(label: 'Custom', page: _pageColor, ink: _ink);
    final contrast = colors.contrast;
    final readable = contrast >= 4.5;

    Widget label(String s) => Padding(
      padding: const EdgeInsets.only(top: Space.xl, bottom: Space.sm),
      child: Text(s.toUpperCase(), style: text.labelSmall),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Custom page'),
        actions: [
          TextButton(
            onPressed: () {
              ref.read(readerPreferencesProvider.notifier).saveCustom(_pageColor, _ink);
              Navigator.pop(context);
            },
            child: const Text('Use'),
          ),
          const SizedBox(width: Space.sm),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, Space.xxxl),
        children: [
          // ---- Preview ----
          AnimatedContainer(
            duration: Motion.quick,
            padding: const EdgeInsets.all(Space.xl),
            decoration: BoxDecoration(
              color: colors.page,
              borderRadius: BorderRadius.circular(Radii.lg),
              border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Chapter One',
                  style: TextStyle(fontFamily: FontFamilies.display, fontSize: 22, color: colors.ink),
                ),
                const SizedBox(height: Space.md),
                Text(
                  'It was a bright cold day in April, and the clocks were striking thirteen. '
                  'The hallway smelt of boiled cabbage and old rag mats.',
                  style: TextStyle(fontFamily: FontFamilies.reading, fontSize: 16, height: 1.55, color: colors.ink),
                ),
                const SizedBox(height: Space.lg),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '12 min left in chapter',
                        style: TextStyle(fontFamily: FontFamilies.ui, fontSize: 11.5, color: colors.muted),
                      ),
                    ),
                    Text('34%', style: TextStyle(fontFamily: FontFamilies.ui, fontSize: 11.5, color: colors.muted)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: Space.sm),
          Row(
            children: [
              Icon(
                readable ? Icons.check_circle_outline : Icons.warning_amber_rounded,
                size: 18,
                color: readable ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.error,
              ),
              const SizedBox(width: Space.xs),
              Expanded(
                child: Text(
                  'Contrast ${contrast.toStringAsFixed(1)} : 1 · '
                  '${readable ? (contrast >= 7 ? 'very easy to read' : 'easy to read') : 'hard to read for long'}'
                  ' · ${colors.brightness == Brightness.dark ? 'a night page' : 'a day page'}',
                  style: text.bodySmall,
                ),
              ),
            ],
          ),

          // ---- Page ----
          label('Page'),
          _Swatches(
            colors: _pages,
            selected: _pageColor,
            onPick: (c) => _setPage(HSLColor.fromColor(c)),
          ),
          _HslSlider(
            label: 'Hue',
            value: _page.hue,
            max: 360,
            onChanged: (v) => _setPage(_page.withHue(v)),
          ),
          _HslSlider(
            label: 'Color',
            value: _page.saturation,
            onChanged: (v) => _setPage(_page.withSaturation(v)),
          ),
          _HslSlider(
            label: 'Lightness',
            value: _page.lightness,
            onChanged: (v) => _setPage(_page.withLightness(v)),
          ),

          // ---- Ink ----
          label('Text'),
          _Swatches(
            colors: _inks,
            selected: _autoInk ? null : _ink,
            onPick: (c) => setState(() {
              _autoInk = false;
              _ink = c;
            }),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Match the page'),
            subtitle: const Text('A dark or light shade of the page color'),
            value: _autoInk,
            onChanged: (on) => setState(() {
              _autoInk = on;
              if (on) _ink = contrastingInk(_pageColor);
            }),
          ),
          const SizedBox(height: Space.md),
          Text(
            'A light page becomes your day page and a dark one your night page. '
            'Highlights adjust to it.',
            style: text.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _Swatches extends StatelessWidget {
  const _Swatches({required this.colors, required this.selected, required this.onPick});

  final List<Color> colors;
  final Color? selected;
  final ValueChanged<Color> onPick;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: Space.sm,
      runSpacing: Space.sm,
      children: [
        for (final c in colors)
          Semantics(
            button: true,
            selected: c.toARGB32() == selected?.toARGB32(),
            child: GestureDetector(
              onTap: () => onPick(c),
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: c.toARGB32() == selected?.toARGB32() ? scheme.onSurface : scheme.outlineVariant,
                    width: c.toARGB32() == selected?.toARGB32() ? 2.5 : 1,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _HslSlider extends StatelessWidget {
  const _HslSlider({required this.label, required this.value, required this.onChanged, this.max = 1});

  final String label;
  final double value;
  final double max;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 84, child: Text(label, style: Theme.of(context).textTheme.bodyMedium)),
        Expanded(child: Slider(value: value.clamp(0, max), max: max, onChanged: onChanged)),
      ],
    );
  }
}
