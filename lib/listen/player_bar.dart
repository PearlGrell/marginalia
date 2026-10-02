import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/reader_theme.dart';
import '../theme/tokens.dart';
import 'listen_controller.dart';

/// Controls for reading aloud, docked under the page while listening.
class PlayerBar extends ConsumerWidget {
  const PlayerBar({super.key, required this.theme});

  final PageColors theme;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(listenProvider);
    final listen = ref.read(listenProvider.notifier);
    final text = Theme.of(context).textTheme;
    final label = TextStyle(fontFamily: FontFamilies.ui, fontSize: 12, color: theme.ink);

    String speed(double s) => s == s.roundToDouble() ? '${s.toInt()}×' : '$s×';

    return Material(
      color: theme.page,
      child: Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: theme.ink.withValues(alpha: 0.08))),
        ),
        padding: const EdgeInsets.fromLTRB(Space.sm, Space.xs, Space.sm, Space.xs),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Previous chapter',
              color: theme.ink,
              icon: const Icon(Icons.skip_previous),
              onPressed: listen.previousChapter,
            ),
            IconButton(
              tooltip: 'Previous sentence',
              color: theme.ink,
              icon: const Icon(Icons.fast_rewind_outlined),
              onPressed: listen.previousSentence,
            ),
            IconButton.filled(
              tooltip: state.playing ? 'Pause' : 'Play',
              style: IconButton.styleFrom(backgroundColor: theme.ink, foregroundColor: theme.page),
              icon: Icon(state.playing ? Icons.pause : Icons.play_arrow),
              onPressed: listen.togglePlay,
            ),
            IconButton(
              tooltip: 'Next sentence',
              color: theme.ink,
              icon: const Icon(Icons.fast_forward_outlined),
              onPressed: listen.nextSentence,
            ),
            IconButton(
              tooltip: 'Next chapter',
              color: theme.ink,
              icon: const Icon(Icons.skip_next),
              onPressed: listen.nextChapter,
            ),
            const Spacer(),
            PopupMenuButton<double>(
              tooltip: 'Speed',
              initialValue: state.speed,
              onSelected: listen.setSpeed,
              itemBuilder: (_) => [
                for (final s in ListenController.speeds)
                  CheckedPopupMenuItem(value: s, checked: s == state.speed, child: Text(speed(s))),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.md),
                child: Text(speed(state.speed), style: label.copyWith(fontWeight: FontWeight.w600)),
              ),
            ),
            PopupMenuButton<Object>(
              tooltip: 'More',
              icon: Icon(
                state.sleep == SleepTimer.off ? Icons.more_vert : Icons.bedtime_outlined,
                color: theme.ink,
              ),
              onSelected: (choice) async {
                if (choice is SleepTimer) {
                  listen.setSleep(choice);
                } else if (choice == 'voice') {
                  await _pickVoice(context, listen);
                } else if (choice == 'stop') {
                  await listen.stop();
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(enabled: false, child: Text('SLEEP TIMER', style: text.labelSmall)),
                for (final s in SleepTimer.values)
                  CheckedPopupMenuItem(value: s, checked: s == state.sleep, child: Text(s.label)),
                const PopupMenuDivider(),
                const PopupMenuItem(value: 'voice', child: Text('Voice')),
                const PopupMenuItem(value: 'stop', child: Text('Stop listening')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickVoice(BuildContext context, ListenController listen) async {
    final voices = await listen.voices();
    if (!context.mounted) return;
    final choice = await showModalBottomSheet<Voice>(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (context, scroll) => ListView(
          controller: scroll,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.sm),
              child: Text('Voice', style: Theme.of(context).textTheme.headlineSmall),
            ),
            if (voices.isEmpty)
              const Padding(
                padding: EdgeInsets.all(Space.gutter),
                child: Text('No voices for this language.'),
              ),
            for (final v in voices)
              ListTile(
                title: Text(v.name),
                subtitle: Text(v.voice.featured ? 'One of the best' : v.voice.accent),
                trailing: v.selected ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, v),
              ),
          ],
        ),
      ),
    );
    if (choice != null) await listen.setVoice(choice);
  }
}
