import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/tokens.dart';
import 'account.dart';
import 'sync_engine.dart';
import 'sync_service.dart';

/// Shown briefly on opening while the library catches up with other devices: what is
/// happening, what has arrived, and each step ticking off. Closes by itself when done;
/// "Read offline" closes it straight away.
class SyncScreen extends ConsumerStatefulWidget {
  const SyncScreen({super.key});

  @override
  ConsumerState<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends ConsumerState<SyncScreen> {
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    if (!ref.read(accountProvider).signedIn) return _close();
    // A sync may already be running (started from elsewhere): follow it rather than wait
    // for a second one that won't start.
    final SyncReport? report;
    if (ref.read(syncProvider).running) {
      final done = Completer<SyncReport?>();
      final sub = ref.listenManual(syncProvider, (_, s) {
        if (!s.running && !done.isCompleted) done.complete(s.report);
      });
      report = await done.future;
      sub.close();
    } else {
      report = await ref.read(syncProvider.notifier).syncNow();
    }
    if (!mounted || ref.read(syncProvider).error != null) return; // Errors stay, with options.
    await Future<void>.delayed(
      Duration(milliseconds: report == null || report.summary == 'Up to date' ? 700 : 1600),
    );
    _close();
  }

  void _close() {
    if (_closing || !mounted) return;
    _closing = true;
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final sync = ref.watch(syncProvider);
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final steps = sync.steps.where((s) => s != 'Starting').toList();
    final done = !sync.running && sync.error == null && sync.report != null;
    final failed = sync.error != null;
    final counts = sync.live ?? sync.report;

    final title = failed
        ? "Couldn't finish syncing"
        : done
        ? 'All caught up'
        : 'Syncing your library';
    final subtitle = failed
        ? sync.error!
        : done
        ? sync.report!.summary
        : (sync.step == null || sync.step == 'Starting' ? 'Connecting…' : sync.step!);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: Space.xl, vertical: Space.xxl),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Column(
                children: [
                  _Mark(done: done, failed: failed),
                  const SizedBox(height: Space.xl),
                  Text(title, style: text.headlineMedium, textAlign: TextAlign.center),
                  const SizedBox(height: Space.sm),
                  AnimatedSwitcher(
                    duration: Motion.quick,
                    child: Text(
                      subtitle,
                      key: ValueKey(subtitle),
                      textAlign: TextAlign.center,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyLarge?.copyWith(
                        color: failed ? scheme.error : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(height: Space.xl),
                  Row(
                    children: [
                      _Count(label: 'New books', value: counts?.newBooks ?? 0),
                      _Count(label: 'Notes', value: counts?.notes ?? 0),
                      _Count(label: 'Uploaded', value: counts?.uploaded ?? 0),
                    ],
                  ),
                  if (steps.isNotEmpty) ...[
                    const SizedBox(height: Space.xl),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.md),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainer,
                        borderRadius: BorderRadius.circular(Radii.lg),
                        border: Border.all(color: scheme.outlineVariant),
                      ),
                      child: Column(
                        children: [
                          for (final (i, step) in steps.indexed)
                            _StepRow(
                              label: step,
                              state: i < steps.length - 1 || done
                                  ? _StepState.done
                                  : failed
                                  ? _StepState.failed
                                  : _StepState.running,
                            ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: Space.xl),
                  if (failed)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        FilledButton(onPressed: _run, child: const Text('Try again')),
                        const SizedBox(width: Space.md),
                        OutlinedButton(onPressed: _close, child: const Text('Continue')),
                      ],
                    )
                  else if (!done)
                    TextButton(onPressed: _close, child: const Text('Read offline')),
                  if (sync.lastSyncedAt case final last? when !done) ...[
                    const SizedBox(height: Space.sm),
                    Text(
                      'Last synced ${_ago(last)}',
                      style: text.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _ago(DateTime at) {
    final minutes = DateTime.now().difference(at).inMinutes;
    if (minutes < 1) return 'just now';
    if (minutes < 60) return '$minutes min ago';
    if (minutes < 60 * 24) return '${minutes ~/ 60} h ago';
    return '${at.day}/${at.month}/${at.year}';
  }
}

/// The app's logo: an open book with a reader's marks and a ribbon (assets/brand/mark.svg).
class AppMark extends StatelessWidget {
  const AppMark({super.key, this.size = 48});

  final double size;

  @override
  Widget build(BuildContext context) => Image.asset(
    'assets/brand/mark-1024.png',
    width: size,
    height: size,
    filterQuality: FilterQuality.medium,
    semanticLabel: 'Marginalia',
  );
}

/// The logo inside a ring that turns while syncing, then a tick (or a cloud, if it failed).
class _Mark extends StatelessWidget {
  const _Mark({required this.done, required this.failed});

  final bool done;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 104,
      height: 104,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox.expand(
            child: CircularProgressIndicator(
              value: done || failed ? 1 : null,
              strokeWidth: 3,
              color: failed ? scheme.error : scheme.primary,
              backgroundColor: scheme.outlineVariant,
            ),
          ),
          AnimatedSwitcher(
            duration: Motion.standard,
            child: failed || done
                ? Container(
                    key: ValueKey(failed),
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(color: scheme.surfaceContainer, shape: BoxShape.circle),
                    child: Icon(
                      failed ? Icons.cloud_off_outlined : Icons.check,
                      size: 36,
                      color: failed ? scheme.error : scheme.primary,
                    ),
                  )
                : const AppMark(size: 78),
          ),
        ],
      ),
    );
  }
}

class _Count extends StatelessWidget {
  const _Count({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Expanded(
      child: Column(
        children: [
          TweenAnimationBuilder<int>(
            tween: IntTween(begin: 0, end: value),
            duration: Motion.standard,
            builder: (context, v, _) => Text('$v', style: text.headlineSmall),
          ),
          const SizedBox(height: Space.xxs),
          Text(label.toUpperCase(), style: text.labelSmall),
        ],
      ),
    );
  }
}

enum _StepState { running, done, failed }

class _StepRow extends StatelessWidget {
  const _StepRow({required this.label, required this.state});

  final String label;
  final _StepState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.xs),
      child: Row(
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: switch (state) {
              _StepState.running => const Padding(
                padding: EdgeInsets.all(3),
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              _StepState.done => Icon(Icons.check, size: 18, color: scheme.primary),
              _StepState.failed => Icon(Icons.close, size: 18, color: scheme.error),
            },
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.bodyMedium?.copyWith(
                color: state == _StepState.running ? scheme.onSurface : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
