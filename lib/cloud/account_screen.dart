import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../theme/tokens.dart';
import 'account.dart';
import 'drive_store.dart';
import 'sync_service.dart';

class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;

    return Scaffold(
      appBar: AppBar(title: const Text('Account and sync')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, Space.xxxl),
        children: [
          if (!account.configured) ...[
            Text('Sync is not set up in this build', style: text.headlineSmall),
            const SizedBox(height: Space.sm),
            Text(
              'Everything works on this phone. To sync across devices, this build needs a '
              'Firebase project; see docs/cloud-setup.md.',
              style: text.bodyLarge?.copyWith(color: muted),
            ),
          ] else if (!account.signedIn)
            _SignedOut(account: account)
          else
            _SignedIn(account: account.account!),
        ],
      ),
    );
  }
}

class _SignedOut extends ConsumerWidget {
  const _SignedOut({required this.account});

  final AccountState account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Your library, on every device', style: text.headlineSmall),
        const SizedBox(height: Space.sm),
        Text(
          'Sign in with Google to keep books, highlights, notes, bookmarks and your place in '
          'step across your phones and tablets.',
          style: text.bodyLarge?.copyWith(color: muted),
        ),
        const SizedBox(height: Space.lg),
        Text(
          'Book files go to a hidden folder in your own Google Drive and count against its '
          'free space. Your library details and notes are kept in Marginalia’s database, '
          'readable only by you.',
          style: text.bodyMedium?.copyWith(color: muted),
        ),
        const SizedBox(height: Space.xl),
        FilledButton.icon(
          onPressed: account.busy ? null : () => ref.read(accountProvider.notifier).signIn(),
          icon: const Icon(Icons.login),
          label: Text(account.busy ? 'Signing in…' : 'Sign in with Google'),
        ),
        if (account.error case final error?)
          Padding(
            padding: const EdgeInsets.only(top: Space.md),
            child: Text(error, style: text.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error)),
          ),
      ],
    );
  }
}

class _SignedIn extends ConsumerWidget {
  const _SignedIn({required this.account});

  final Account account;

  static const _limits = <int?>[null, 1, 2, 5, 10];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final sync = ref.watch(syncProvider);
    final limitBytes = ref.watch(uploadLimitProvider);
    final limitGb = limitBytes == null ? null : limitBytes ~/ (1024 * 1024 * 1024);

    String last() {
      final at = sync.lastSyncedAt;
      if (at == null) return 'Not synced yet';
      final minutes = DateTime.now().difference(at).inMinutes;
      if (minutes < 1) return 'Synced just now';
      if (minutes < 60) return 'Synced $minutes min ago';
      if (minutes < 60 * 24) return 'Synced ${minutes ~/ 60} h ago';
      return 'Synced ${at.day}/${at.month}/${at.year}';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            CircleAvatar(
              radius: 26,
              backgroundImage: account.photoUrl == null ? null : NetworkImage(account.photoUrl!),
              child: account.photoUrl == null ? Text((account.name ?? '?').substring(0, 1)) : null,
            ),
            const SizedBox(width: Space.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(account.name ?? 'Signed in', style: text.titleLarge),
                  if (account.email case final email?) Text(email, style: text.bodySmall),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: Space.xl),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(sync.running ? (sync.step ?? 'Syncing…') : last()),
          subtitle: sync.error != null
              ? Text(sync.error!)
              : sync.report == null
              ? null
              : Text(_reportLine(sync.report!.summary, sync.report!.uploadSkip)),
          trailing: sync.running
              ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
              : TextButton(
                  onPressed: () => ref.read(syncProvider.notifier).syncNow(promptForDrive: true),
                  child: const Text('Sync now'),
                ),
        ),
        const Divider(),
        const SizedBox(height: Space.md),
        Text('BOOK FILES IN YOUR DRIVE', style: text.labelSmall),
        const SizedBox(height: Space.sm),
        Text(
          'No book is uploaded while your Drive has less than 1 GB free, so Gmail and Photos keep '
          'working. You can set a lower limit of your own.',
          style: text.bodySmall?.copyWith(color: muted),
        ),
        const SizedBox(height: Space.sm),
        Wrap(
          spacing: Space.sm,
          children: [
            for (final gb in _limits)
              ChoiceChip(
                label: Text(gb == null ? 'No limit' : '$gb GB'),
                selected: gb == limitGb,
                onSelected: (_) => ref
                    .read(uploadLimitProvider.notifier)
                    .set(gb == null ? null : gb * 1024 * 1024 * 1024),
              ),
          ],
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.cloud_outlined),
          title: const Text('Books in your Drive'),
          subtitle: const Text('What is uploaded, and what is waiting'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/account/drive'),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.devices_outlined),
          title: const Text('Your devices'),
          subtitle: const Text('Phones and tablets syncing this library'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/account/devices'),
        ),
        const SizedBox(height: Space.sm),
        OutlinedButton.icon(
          icon: const Icon(Icons.download_outlined),
          label: const Text('Download all books to this phone'),
          onPressed: () async {
            final messenger = ScaffoldMessenger.of(context);
            messenger.showSnackBar(const SnackBar(content: Text('Downloading your books…')));
            final count = await ref.read(syncProvider.notifier).downloadAll();
            messenger.showSnackBar(SnackBar(content: Text('$count books downloaded')));
          },
        ),
        const SizedBox(height: Space.xl),
        const Divider(),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.logout),
          title: const Text('Sign out'),
          subtitle: const Text('Books and notes stay on this phone'),
          onTap: () async {
            await ref.read(syncProvider.notifier).cancelBackground();
            await ref.read(accountProvider.notifier).signOut();
          },
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.delete_forever_outlined, color: Theme.of(context).colorScheme.error),
          title: const Text('Delete cloud data'),
          subtitle: const Text('Removes your library, notes and book files from the cloud'),
          onTap: () => _confirmDelete(context, ref),
        ),
      ],
    );
  }

  static String _reportLine(String summary, UploadSkip? skip) => switch (skip) {
    UploadSkip.driveLow => '$summary · some books stay on this phone: Drive has under 1 GB free',
    UploadSkip.overLimit => '$summary · some books stay on this phone: your limit is reached',
    null => summary,
  };

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete cloud data?'),
        content: const Text(
          'Your library, highlights, notes, reading positions and the book files in your Drive '
          'will be deleted from the cloud, for every device. Books on this phone stay.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (sure != true) return;
    await ref.read(syncProvider.notifier).deleteCloudData();
    await ref.read(accountProvider.notifier).signOut();
  }
}
