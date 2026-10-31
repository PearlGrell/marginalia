import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/database.dart';
import '../data/library.dart';
import '../share/share_sheet.dart';
import '../theme/tokens.dart';
import 'clubs.dart';

/// Asks for a club's code (or link), then opens it.
Future<void> joinClubByCode(BuildContext context) async {
  final controller = TextEditingController();
  final code = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Join a book club'),
      content: TextField(
        controller: controller,
        autofocus: true,
        textCapitalization: TextCapitalization.characters,
        decoration: const InputDecoration(hintText: 'ABCD-EFGH-JKLM'),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Open')),
      ],
    ),
  );
  controller.dispose();
  if (code != null && code.trim().isNotEmpty && context.mounted) {
    context.push('/club/${normalizeClubCode(code)}');
  }
}

/// Starts a club around [book] and opens it.
Future<void> startClub(BuildContext context, WidgetRef ref, Book book) async {
  final controller = TextEditingController(text: '${book.title} club');
  final name = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Read it together'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Friends who join see the highlights and notes you share, right in the page, and can talk about them.'),
          const SizedBox(height: Space.md),
          TextField(controller: controller, decoration: const InputDecoration(labelText: 'Club name')),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Start')),
      ],
    ),
  );
  controller.dispose();
  if (name == null || name.trim().isEmpty || !context.mounted) return;
  try {
    final club = await ref.read(clubServiceProvider).create(book, name: name.trim());
    if (context.mounted) context.push('/club/${club.code}');
  } on ClubException catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
  }
}

/// The book's clubs on its page, and ways to start or join one.
class BookClubsSection extends ConsumerWidget {
  const BookClubsSection({super.key, required this.book});

  final Book book;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final clubs = ref.watch(clubsForBookProvider(book.id));
    return Wrap(
      spacing: Space.sm,
      runSpacing: Space.sm,
      children: [
        for (final club in clubs)
          ActionChip(
            avatar: const Icon(Icons.groups_outlined, size: 18),
            label: Text(club.name),
            onPressed: () => context.push('/club/${club.code}'),
          ),
        ActionChip(
          avatar: const Icon(Icons.add, size: 18),
          label: const Text('Read it together'),
          onPressed: () => startClub(context, ref, book),
        ),
        ActionChip(
          avatar: const Icon(Icons.vpn_key_outlined, size: 18),
          label: const Text('Join with a code'),
          onPressed: () => joinClubByCode(context),
        ),
      ],
    );
  }
}

/// Every club this reader is in.
class ClubsScreen extends ConsumerWidget {
  const ClubsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final clubs = ref.watch(myClubsProvider).value ?? const <Club>[];
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Book clubs'),
        actions: [
          IconButton(tooltip: 'Join with a code', icon: const Icon(Icons.vpn_key_outlined), onPressed: () => joinClubByCode(context)),
        ],
      ),
      body: clubs.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(Space.xl),
              child: Text(
                'Read a book with friends: start a club from the book’s page ("Read it together"), '
                'or join one with the code a friend sends you.',
                textAlign: TextAlign.center,
                style: text.bodyLarge,
              ),
            )
          : ListView(
              children: [
                for (final club in clubs)
                  ListTile(
                    leading: const Icon(Icons.groups_outlined),
                    title: Text(club.name),
                    subtitle: Text(club.title),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => context.push('/club/${club.code}'),
                  ),
              ],
            ),
    );
  }
}

/// A club: what it's reading, who's in it, and what they've shared. To someone not in it
/// yet (from an invitation), a way to join.
class ClubScreen extends ConsumerStatefulWidget {
  const ClubScreen({super.key, required this.code});

  final String code;

  @override
  ConsumerState<ClubScreen> createState() => _ClubScreenState();
}

class _ClubScreenState extends ConsumerState<ClubScreen> {
  late final Future<Club> _club = ref.read(clubServiceProvider).find(widget.code);
  bool _joining = false;

  /// This reader's progress, told to the club once when the screen opens.
  bool _reported = false;

  void _reportProgress(Club club, Book copy) {
    if (_reported) return;
    _reported = true;
    ref.read(clubServiceProvider).reportProgress(club.code, copy.progress).catchError((_) {});
  }

  Future<void> _join(Club club) async {
    setState(() => _joining = true);
    try {
      await ref.read(clubServiceProvider).join(club);
    } on ClubException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  Future<void> _leave(Club club, {required bool owner}) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(owner ? 'Close ${club.name}?' : 'Leave ${club.name}?'),
        content: Text(owner ? 'It closes for everyone in it.' : 'Your notes in it stay until you unshare them.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(owner ? 'Close' : 'Leave')),
        ],
      ),
    );
    if (sure != true) return;
    await ref.read(clubServiceProvider).leave(club);
    if (mounted) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<Club>(
      future: _club,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Scaffold(
            appBar: AppBar(),
            body: Center(
              child: Padding(padding: const EdgeInsets.all(Space.xl), child: Text('${snapshot.error}', textAlign: TextAlign.center)),
            ),
          );
        }
        final club = snapshot.data;
        if (club == null) return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
        final member = (ref.watch(myClubsProvider).value ?? const <Club>[]).any((c) => c.code == club.code);
        final me = ref.watch(clubServiceProvider).myUid;
        final copy = ref.watch(_bookProvider(club.bookId)).value;
        if (member && copy != null) _reportProgress(club, copy);
        return Scaffold(
          appBar: AppBar(
            title: Text(club.name),
            actions: [
              if (member)
                IconButton(
                  tooltip: 'Invite',
                  icon: const Icon(Icons.person_add_alt_outlined),
                  onPressed: () => shareText(
                    'Read “${club.title}” with me in Marginalia: ${club.link}\n(or join with the code ${club.code})',
                  ),
                ),
              if (member)
                IconButton(
                  tooltip: club.ownerUid == me ? 'Close the club' : 'Leave',
                  icon: const Icon(Icons.logout),
                  onPressed: () => _leave(club, owner: club.ownerUid == me),
                ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, Space.xxxl),
            children: [
              Text('Reading', style: text.labelSmall),
              Text(club.title, style: text.headlineSmall),
              const SizedBox(height: Space.md),
              if (!member)
                FilledButton(
                  onPressed: _joining ? null : () => _join(club),
                  child: Text(_joining ? 'Joining…' : 'Join the club'),
                )
              else if (copy != null)
                FilledButton.icon(
                  icon: const Icon(Icons.menu_book_outlined),
                  label: const Text('Open the book'),
                  onPressed: () => context.push('/read/${copy.id}'),
                ),
              if (copy == null)
                Padding(
                  padding: const EdgeInsets.only(top: Space.sm),
                  child: Text(
                    'This book isn’t in your library yet. The club reads one file together: ask for a share link, '
                    'or add the same edition.',
                    style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
              if (member) ...[
                const SizedBox(height: Space.xl),
                _Schedule(club: club, owner: club.ownerUid == me, progress: copy?.progress),
                const SizedBox(height: Space.xl),
                _Members(code: club.code),
                const SizedBox(height: Space.xl),
                Text('Shared', style: text.titleMedium),
                const SizedBox(height: Space.sm),
                _Notes(code: club.code),
              ],
            ],
          ),
        );
      },
    );
  }
}

final _bookProvider = StreamProvider.family<Book?, String>(
  (ref, id) => ref.watch(databaseProvider).watchBook(id),
);

final _membersProvider = StreamProvider.family<List<ClubMember>, String>(
  (ref, code) => ref.watch(clubServiceProvider).members(code),
);

final _scheduleProvider = StreamProvider.family<List<ClubMilestone>, String>(
  (ref, code) => ref.watch(clubServiceProvider).schedule(code),
);

/// Who's in the club, each with how far through the book they are, furthest first.
class _Members extends ConsumerWidget {
  const _Members({required this.code});

  final String code;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final members = [...ref.watch(_membersProvider(code)).value ?? const <ClubMember>[]]
      ..sort((a, b) => (b.progress ?? -1).compareTo(a.progress ?? -1));
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Members', style: text.titleMedium),
        const SizedBox(height: Space.sm),
        for (final m in members)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Space.xs),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor: memberColor(m.uid),
                  child: Text(
                    m.name.isEmpty ? '?' : m.name.characters.first.toUpperCase(),
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodyMedium),
                      const SizedBox(height: 4),
                      LinearProgressIndicator(
                        value: m.progress ?? 0,
                        minHeight: 3,
                        color: memberColor(m.uid),
                        backgroundColor: scheme.outlineVariant,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: Space.md),
                SizedBox(
                  width: 40,
                  child: Text(
                    m.progress == null ? '–' : '${(m.progress! * 100).round()}%',
                    textAlign: TextAlign.end,
                    style: text.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The club's reading schedule: milestones by date, which this reader has reached, and the
/// next one. Its owner adds and removes them.
class _Schedule extends ConsumerWidget {
  const _Schedule({required this.club, required this.owner, required this.progress});

  final Club club;
  final bool owner;

  /// This reader's progress through their copy, if they have it.
  final double? progress;

  Future<void> _add(BuildContext context, WidgetRef ref, List<ClubMilestone> schedule) async {
    final added = await showDialog<ClubMilestone>(context: context, builder: (context) => const _MilestoneDialog());
    if (added == null) return;
    await _save(context, ref, [...schedule, added]);
  }

  Future<void> _save(BuildContext context, WidgetRef ref, List<ClubMilestone> schedule) async {
    try {
      await ref.read(clubServiceProvider).setSchedule(club.code, schedule);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e is ClubException ? e.message : 'The schedule couldn’t be saved.')));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final schedule = ref.watch(_scheduleProvider(club.code)).value ?? const <ClubMilestone>[];
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final localizations = MaterialLocalizations.of(context);
    final now = DateTime.now();
    final next = progress == null ? null : nextMilestone(schedule, progress!, now);
    if (schedule.isEmpty && !owner) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text('Schedule', style: text.titleMedium)),
            if (owner)
              TextButton.icon(
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Milestone'),
                onPressed: () => _add(context, ref, schedule),
              ),
          ],
        ),
        if (schedule.isEmpty)
          Text(
            'Set where the club should be by when (“Up to chapter 10 by Sunday”), and everyone sees how they’re doing.',
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        if (next != null)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.sm),
            child: Text(
              next.late
                  ? 'Behind: “${next.milestone.label}” was due ${localizations.formatMediumDate(next.milestone.due)}.'
                  : 'Next: “${next.milestone.label}” by ${localizations.formatMediumDate(next.milestone.due)}. '
                        '${(((next.milestone.fraction - progress!) * 100).clamp(0, 100)).round()}% to go.',
              style: text.bodyMedium?.copyWith(color: next.late ? scheme.error : scheme.primary),
            ),
          ),
        for (final (i, m) in schedule.indexed)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(
              progress != null && progress! + 0.005 >= m.fraction ? Icons.check_circle : Icons.radio_button_unchecked,
              color: progress != null && progress! + 0.005 >= m.fraction ? scheme.primary : scheme.outline,
            ),
            title: Text(m.label),
            subtitle: Text('${localizations.formatMediumDate(m.due)} · ${(m.fraction * 100).round()}% through'),
            trailing: owner
                ? IconButton(
                    tooltip: 'Remove',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => _save(context, ref, [...schedule]..removeAt(i)),
                  )
                : null,
          ),
      ],
    );
  }
}

/// A new milestone: what it's called, how far through the book, and by when.
class _MilestoneDialog extends StatefulWidget {
  const _MilestoneDialog();

  @override
  State<_MilestoneDialog> createState() => _MilestoneDialogState();
}

class _MilestoneDialogState extends State<_MilestoneDialog> {
  final _label = TextEditingController();
  double _fraction = 0.25;
  DateTime _due = DateTime.now().add(const Duration(days: 7));

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    final label = _label.text.trim();
    return AlertDialog(
      title: const Text('Add a milestone'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _label,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Where to', hintText: 'Up to chapter 10'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: Space.md),
          Text('${(_fraction * 100).round()}% through the book'),
          Slider(
            value: _fraction,
            divisions: 20,
            onChanged: (v) => setState(() => _fraction = v),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.event_outlined),
            label: Text('By ${localizations.formatMediumDate(_due)}'),
            onPressed: () async {
              final now = DateTime.now();
              final picked = await showDatePicker(
                context: context,
                initialDate: _due,
                firstDate: DateTime(now.year, now.month, now.day),
                lastDate: now.add(const Duration(days: 730)),
              );
              if (picked != null) setState(() => _due = DateTime(picked.year, picked.month, picked.day, 23, 59));
            },
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: label.isEmpty || _fraction <= 0
              ? null
              : () => Navigator.pop(context, ClubMilestone(label: label, fraction: _fraction, due: _due)),
          child: const Text('Add'),
        ),
      ],
    );
  }
}

class _Notes extends ConsumerWidget {
  const _Notes({required this.code});

  final String code;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notes = ref.watch(clubNotesProvider(code)).value ?? const <ClubNote>[];
    final text = Theme.of(context).textTheme;
    if (notes.isEmpty) {
      return Text(
        'Nothing shared yet. Tap a highlight while reading and share it with the club.',
        style: text.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      );
    }
    return Column(children: [for (final n in notes) _NoteCard(note: n)]);
  }
}

final _reactionsProvider = StreamProvider.family<Map<String, String>, (String, String)>(
  (ref, key) => ref.watch(clubServiceProvider).reactions(key.$1, key.$2),
);

class _Reactions extends ConsumerWidget {
  const _Reactions({required this.note});

  final ClubNote note;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reactions = ref.watch(_reactionsProvider((note.club, note.id))).value ?? const <String, String>{};
    if (reactions.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(reactionSummary(reactions), style: Theme.of(context).textTheme.labelMedium),
    );
  }
}

/// The reactions to pick from, this reader's own shown picked; tapping it again takes it back.
class _ReactionPicker extends ConsumerWidget {
  const _ReactionPicker({required this.note});

  final ClubNote note;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.watch(clubServiceProvider);
    final reactions = ref.watch(_reactionsProvider((note.club, note.id))).value ?? const <String, String>{};
    final mine = reactions[service.myUid];
    return Wrap(
      spacing: Space.xs,
      runSpacing: Space.xs,
      children: [
        for (final emoji in clubReactions)
          ChoiceChip(
            showCheckmark: false,
            label: Text([emoji, if (reactions.values.where((e) => e == emoji).length case final n when n > 0) '$n'].join(' ')),
            selected: mine == emoji,
            onSelected: (_) async {
              try {
                await service.react(note.club, note.id, mine == emoji ? null : emoji);
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(e is ClubException ? e.message : 'That reaction couldn’t be saved.')),
                  );
                }
              }
            },
          ),
      ],
    );
  }
}

class _NoteCard extends StatelessWidget {
  const _NoteCard({required this.note});

  final ClubNote note;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final color = memberColor(note.authorUid);
    return InkWell(
      onTap: () => showClubNoteSheet(context, note),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(width: 4, height: 56, color: color),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (note.quote case final quote?)
                    Text(quote, maxLines: 3, overflow: TextOverflow.ellipsis, style: text.bodyMedium?.copyWith(fontFamily: FontFamilies.reading)),
                  if (note.note case final n? when n.isNotEmpty) Text(n, maxLines: 2, overflow: TextOverflow.ellipsis, style: text.bodyMedium),
                  Text(
                    [note.authorName, ?note.chapterTitle].join(' · '),
                    style: text.labelSmall?.copyWith(color: color),
                  ),
                  _Reactions(note: note),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A shared highlight or note, and the club's talk about it.
Future<void> showClubNoteSheet(BuildContext context, ClubNote note) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: _ClubNoteSheet(note: note),
  ),
);

final _commentsProvider = StreamProvider.family<List<ClubComment>, (String, String)>(
  (ref, key) => ref.watch(clubServiceProvider).comments(key.$1, key.$2),
);

class _ClubNoteSheet extends ConsumerStatefulWidget {
  const _ClubNoteSheet({required this.note});

  final ClubNote note;

  @override
  ConsumerState<_ClubNoteSheet> createState() => _ClubNoteSheetState();
}

class _ClubNoteSheetState extends ConsumerState<_ClubNoteSheet> {
  final _comment = TextEditingController();

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _comment.text.trim();
    if (text.isEmpty) return;
    _comment.clear();
    try {
      await ref.read(clubServiceProvider).comment(widget.note.club, widget.note.id, text);
    } on ClubException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final note = widget.note;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final comments = ref.watch(_commentsProvider((note.club, note.id))).value ?? const <ClubComment>[];
    final color = memberColor(note.authorUid);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, Space.md),
          children: [
            Text(note.authorName, style: text.titleMedium?.copyWith(color: color)),
            if (note.chapterTitle case final c?) Text(c, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: Space.md),
            if (note.quote case final quote?)
              Container(
                padding: const EdgeInsets.all(Space.md),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  border: Border(left: BorderSide(color: color, width: 4)),
                  borderRadius: BorderRadius.circular(Radii.sm),
                ),
                child: Text(quote, style: text.bodyLarge?.copyWith(fontFamily: FontFamilies.reading, height: 1.5)),
              ),
            if (note.note case final n? when n.isNotEmpty)
              Padding(padding: const EdgeInsets.only(top: Space.md), child: Text(n, style: text.bodyLarge)),
            const SizedBox(height: Space.md),
            _ReactionPicker(note: note),
            const SizedBox(height: Space.lg),
            for (final c in comments)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.sm),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: '${c.authorName}  ', style: text.labelLarge?.copyWith(color: memberColor(c.authorUid))),
                      TextSpan(text: c.text, style: text.bodyMedium),
                    ],
                  ),
                ),
              ),
            TextField(
              controller: _comment,
              textCapitalization: TextCapitalization.sentences,
              onSubmitted: (_) => _send(),
              decoration: InputDecoration(
                hintText: 'Say something about it…',
                suffixIcon: IconButton(icon: const Icon(Icons.send), onPressed: _send),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// In a highlight's sheet: share it with each of the book's clubs, or stop sharing it.
class ClubShareRow extends ConsumerWidget {
  const ClubShareRow({super.key, required this.annotation});

  final Annotation annotation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final clubs = ref.watch(clubsForBookProvider(annotation.bookId));
    if (clubs.isEmpty) return const SizedBox.shrink();
    final service = ref.read(clubServiceProvider);
    return Padding(
      padding: const EdgeInsets.only(top: Space.md),
      child: Wrap(
        spacing: Space.sm,
        runSpacing: Space.sm,
        children: [
          for (final club in clubs)
            FilterChip(
              avatar: const Icon(Icons.groups_outlined, size: 18),
              label: Text('Shared in ${club.name}'),
              selected: (ref.watch(clubNotesProvider(club.code)).value ?? const <ClubNote>[]).any((n) => n.id == annotation.id),
              onSelected: (on) => on ? service.share(club, annotation) : service.unshare(club, annotation.id),
            ),
        ],
      ),
    );
  }
}
