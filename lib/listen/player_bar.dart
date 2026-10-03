import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/reader_theme.dart';
import '../theme/tokens.dart';
import 'listen_controller.dart';

/// Reading aloud, docked under the page: every control is in the bar itself. Tapping a line
/// in the page reads on from there.
class PlayerBar extends ConsumerStatefulWidget {
  const PlayerBar({super.key, required this.theme});

  final PageColors theme;

  @override
  ConsumerState<PlayerBar> createState() => _PlayerBarState();
}

class _PlayerBarState extends ConsumerState<PlayerBar> {
  /// The row of voices is open.
  bool _choosingVoice = false;
  Future<List<Voice>>? _voices;

  PageColors get theme => widget.theme;

  static String _speed(double s) => s == s.roundToDouble() ? '${s.toInt()}×' : '$s×';

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(listenProvider);
    final listen = ref.read(listenProvider.notifier);
    final speeds = ListenController.speeds;
    final speedIndex = speeds.indexOf(state.speed);
    final muted = theme.ink.withValues(alpha: 0.6);
    final small = TextStyle(fontFamily: FontFamilies.ui, fontSize: 12.5, color: theme.ink);

    Widget transport(IconData icon, String tooltip, VoidCallback onPressed) =>
        IconButton(tooltip: tooltip, color: theme.ink, icon: Icon(icon), onPressed: onPressed);

    Widget chip({required Widget child, VoidCallback? onTap, bool on = false}) => Material(
      color: on ? theme.ink.withValues(alpha: 0.12) : Colors.transparent,
      shape: StadiumBorder(side: BorderSide(color: theme.ink.withValues(alpha: on ? 0.0 : 0.18))),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), child: child),
      ),
    );

    return Material(
      color: theme.page,
      child: Container(
        decoration: BoxDecoration(border: Border(top: BorderSide(color: theme.ink.withValues(alpha: 0.08)))),
        padding: const EdgeInsets.fromLTRB(Space.sm, Space.xs, Space.sm, Space.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                transport(Icons.skip_previous, 'Previous chapter', listen.previousChapter),
                transport(Icons.fast_rewind_outlined, 'Previous sentence', listen.previousSentence),
                IconButton.filled(
                  tooltip: state.playing ? 'Pause' : 'Play',
                  iconSize: 30,
                  style: IconButton.styleFrom(backgroundColor: theme.ink, foregroundColor: theme.page),
                  icon: Icon(state.playing ? Icons.pause : Icons.play_arrow),
                  onPressed: listen.togglePlay,
                ),
                transport(Icons.fast_forward_outlined, 'Next sentence', listen.nextSentence),
                transport(Icons.skip_next, 'Next chapter', listen.nextChapter),
              ],
            ),
            const SizedBox(height: Space.xs),
            Row(
              children: [
                // Speed, stepped with − and +.
                chip(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      GestureDetector(
                        onTap: speedIndex > 0 ? () => listen.setSpeed(speeds[speedIndex - 1]) : null,
                        child: Icon(Icons.remove, size: 16, color: speedIndex > 0 ? theme.ink : muted),
                      ),
                      SizedBox(
                        width: 44,
                        child: Text(
                          _speed(state.speed),
                          textAlign: TextAlign.center,
                          style: small.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                      GestureDetector(
                        onTap: speedIndex < speeds.length - 1 && speedIndex >= 0
                            ? () => listen.setSpeed(speeds[speedIndex + 1])
                            : null,
                        child: Icon(Icons.add, size: 16, color: speedIndex < speeds.length - 1 ? theme.ink : muted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: Space.sm),
                // Sleep timer: each tap moves to the next setting.
                chip(
                  on: state.sleep != SleepTimer.off,
                  onTap: listen.nextSleep,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.bedtime_outlined, size: 16, color: theme.ink),
                      const SizedBox(width: 4),
                      Text(state.sleep == SleepTimer.off ? 'Sleep' : state.sleep.label, style: small),
                    ],
                  ),
                ),
                const SizedBox(width: Space.sm),
                // Voice: opens the row of voices below.
                Flexible(
                  child: chip(
                    on: _choosingVoice,
                    onTap: () => setState(() {
                      _choosingVoice = !_choosingVoice;
                      if (_choosingVoice) _voices = listen.voices();
                    }),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.record_voice_over_outlined, size: 16, color: theme.ink),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            state.voice?.name ?? 'Voice',
                            style: small,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Stop listening',
                  color: theme.ink,
                  icon: const Icon(Icons.close),
                  onPressed: listen.stop,
                ),
              ],
            ),
            if (_choosingVoice)
              SizedBox(
                height: 44,
                child: FutureBuilder<List<Voice>>(
                  future: _voices,
                  builder: (context, snapshot) {
                    final voices = snapshot.data;
                    if (voices == null) {
                      return const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)));
                    }
                    return ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      itemCount: voices.length,
                      separatorBuilder: (_, _) => const SizedBox(width: Space.sm),
                      itemBuilder: (context, i) {
                        final v = voices[i];
                        final selected = v.voice.speaker == state.voice?.speaker;
                        return chip(
                          on: selected,
                          onTap: () async {
                            await listen.setVoice(v);
                            if (mounted) setState(() => _choosingVoice = false);
                          },
                          child: Text(
                            '${v.voice.name}${v.voice.featured ? ' ★' : ''}',
                            style: small.copyWith(fontWeight: selected ? FontWeight.w600 : null),
                          ),
                        );
                      },
                    );
                  },
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('Tap a line to read from there', style: small.copyWith(fontSize: 11, color: muted)),
              ),
          ],
        ),
      ),
    );
  }
}
