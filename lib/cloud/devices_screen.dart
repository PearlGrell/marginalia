import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/tokens.dart';
import 'sync_engine.dart';
import 'sync_service.dart';

/// The phones and tablets syncing this library, with a way to forget old ones.
class DevicesScreen extends ConsumerStatefulWidget {
  const DevicesScreen({super.key});

  @override
  ConsumerState<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends ConsumerState<DevicesScreen> {
  late Future<List<SyncedDevice>> _devices = ref.read(syncProvider.notifier).devices();

  Future<void> _forget(SyncedDevice device) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Forget ${device.name}?'),
        content: const Text(
          'It leaves this list, and its reading positions are no longer offered on other devices. '
          'Notes and changes made on it stay. If it syncs again, it comes back.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Forget')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(syncProvider.notifier).forgetDevice(device.id);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't forget it: $e")));
    }
    setState(() => _devices = ref.read(syncProvider.notifier).devices());
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Scaffold(
      appBar: AppBar(title: const Text('Your devices')),
      body: RefreshIndicator(
        onRefresh: () async {
          final next = ref.read(syncProvider.notifier).devices();
          setState(() => _devices = next);
          await next;
        },
        child: FutureBuilder<List<SyncedDevice>>(
          future: _devices,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return ListView(
                padding: const EdgeInsets.all(Space.gutter),
                children: [Text("Couldn't load your devices. Pull to try again.", style: text.bodyLarge)],
              );
            }
            final devices = snapshot.data;
            if (devices == null) return const Center(child: CircularProgressIndicator());
            return ListView(
              padding: const EdgeInsets.only(bottom: Space.xxxl),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, Space.md),
                  child: Text(
                    'Every device signed in to this account appears here once it has synced.',
                    style: text.bodyMedium?.copyWith(color: muted),
                  ),
                ),
                if (devices.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(Space.gutter),
                    child: Text('No devices yet: sync once to add this one.', style: text.bodyLarge),
                  ),
                for (final d in devices)
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: Space.gutter),
                    leading: Icon(d.isThisDevice ? Icons.smartphone : Icons.devices_other_outlined),
                    title: Text(d.isThisDevice ? '${d.name} (this phone)' : d.name),
                    subtitle: Text(d.lastSyncAt == null ? 'Never synced' : 'Last synced ${_ago(d.lastSyncAt!)}'),
                    trailing: d.isThisDevice
                        ? null
                        : TextButton(onPressed: () => _forget(d), child: const Text('Forget')),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 2) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} minutes ago';
    if (d.inDays < 1) return '${d.inHours} ${d.inHours == 1 ? 'hour' : 'hours'} ago';
    if (d.inDays < 30) return '${d.inDays} ${d.inDays == 1 ? 'day' : 'days'} ago';
    return 'on ${t.day}/${t.month}/${t.year}';
  }
}
