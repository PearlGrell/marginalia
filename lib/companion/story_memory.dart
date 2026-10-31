import 'dart:convert';
import 'dart:io';

import 'book_memory.dart';
import 'companion.dart';
import 'conversation.dart' show chapterLabel;
import 'people.dart';
import 'retrieval.dart';

/// What the companion remembers of the book at the end of a chapter: the story so far, in a
/// few sentences, and who the main people are. Written once each chapter is finished (by the
/// phone's model), each from the one before and the chapter's summary, so it never holds
/// anything past that chapter's end. Kept for every chapter, so going back in the book uses
/// what was known then.
class StorySnapshot {
  const StorySnapshot({required this.story, this.people = const {}});

  factory StorySnapshot.fromJson(Map<String, Object?> json) => StorySnapshot(
    story: json['s'] as String? ?? '',
    people: {
      for (final MapEntry(:key, :value) in ((json['p'] as Map?) ?? const {}).entries)
        if (value is String) key as String: value,
    },
  );

  final String story;

  /// A line or two on each main character, by name.
  final Map<String, String> people;

  Map<String, Object?> toJson() => {'s': story, if (people.isNotEmpty) 'p': people};

  /// What's known of [name] (whatever its case), or null.
  String? profileOf(String name) {
    final wanted = name.trim().toLowerCase();
    for (final MapEntry(:key, :value) in people.entries) {
      if (key.toLowerCase() == wanted) return value;
    }
    // "Darcy" for "Mr. Darcy", and the other way round.
    for (final MapEntry(:key, :value) in people.entries) {
      final k = key.toLowerCase();
      if (k.split(' ').contains(wanted) || wanted.split(' ').contains(k)) return value;
    }
    return null;
  }
}

/// The snapshots in `story.json` of the book kept in [dir], by section key.
Future<Map<int, StorySnapshot>> readStories(String dir) async {
  final file = File('$dir/story.json');
  if (!await file.exists()) return {};
  try {
    return {
      for (final MapEntry(:key, :value) in (jsonDecode(await file.readAsString()) as Map).entries)
        if (value is Map) int.parse(key as String): StorySnapshot.fromJson(value.cast<String, Object?>()),
    };
  } on FormatException {
    return {};
  }
}

Future<void> writeStories(String dir, Map<int, StorySnapshot> stories) async {
  await File('$dir/story.json').writeAsString(
    jsonEncode({for (final MapEntry(:key, :value) in stories.entries) '$key': value.toJson()}),
  );
}

/// The snapshot to use at the reader's page: the latest written for a chapter before the one
/// they're in ([before], the story chapters finished up to here). Null if there's none.
StorySnapshot? storyBefore(Map<int, StorySnapshot> stories, Iterable<StoryChapter> before) {
  StorySnapshot? found;
  for (final c in before) {
    if (stories[c.key] case final s?) found = s;
  }
  return found;
}

/// The prompt that carries the story on through [chapter], from the story before it and the
/// chapter's [summary] (public for tests).
String storyPrompt({
  required String title,
  String? authors,
  required String? before,
  required StoryChapter chapter,
  required String summary,
}) => [
  'You keep track of the story of "$title"${authors == null || authors.isEmpty ? '' : ' by $authors'} '
      'for someone reading it.',
  if (before != null && before.trim().isNotEmpty) 'The story so far:\n${before.trim()}',
  'What happens next, in ${chapterLabel(chapter.number, chapter.title)}:\n${summary.trim()}',
  'Write the story so far, up to the end of this chapter, in at most five plain sentences: the main '
      'characters, what has happened to them and where things stand now. Keep what matters from before. '
      'Use only what is written here. No introduction, no lists.',
].join('\n\n');

/// The prompt for who [name] is at the end of [chapter], from what was known before and the
/// chapter's own sentences about them (public for tests).
String profilePrompt({
  required String title,
  required String name,
  required String? before,
  required StoryChapter chapter,
  required List<String> sentences,
}) => [
  'From "$title".',
  if (before != null && before.trim().isNotEmpty) 'What we knew of $name:\n${before.trim()}',
  'What ${chapterLabel(chapter.number, chapter.title)} says about $name:\n${[for (final s in sentences) '- $s'].join('\n')}',
  'In one or two plain sentences, say who $name is and what they have done so far. Use only what is '
      'written here. No introduction.',
].join('\n\n');

/// The people to keep a profile of after a chapter: the most named in it, at most [max].
List<String> chapterPeople(List<String> chapterText, {int max = 4}) {
  final index = BookIndex([for (final t in chapterText) (chapter: 0, text: t)]);
  return [for (final p in peopleIn(index, limit: max, atLeast: 3)) p.name];
}

/// The sentences of [chapterText] that name [name], at most [max], within [budget] characters.
List<String> sentencesAbout(List<String> chapterText, String name, {int max = 8, int budget = 1400}) {
  final pattern = RegExp('(?<![\\p{L}])${RegExp.escape(name)}(?![\\p{L}])', unicode: true);
  final out = <String>[];
  var length = 0;
  for (final p in chapterText) {
    for (final s in sentencesOf(p)) {
      if (!pattern.hasMatch(s) || s.length > 400) continue;
      if (length + s.length > budget || out.length >= max) return out;
      out.add(s);
      length += s.length;
    }
  }
  return out;
}

/// Writes the snapshots the book's finished chapters don't have yet, in order (each needs the
/// one before), with [generate] (the phone's model). The story for each; who's who only for
/// the last (catching up on a long book, the rest would be a lot of writing for nothing).
/// Stops at the first chapter without a summary yet, or when the model gives no answer.
/// [onWritten] after each.
Future<void> catchUpStories({
  required String dir,
  required String title,
  String? authors,
  required List<StoryChapter> sections,
  required List<KeptParagraph> paragraphs,
  required List<int> placed,
  required Set<int> finished,
  required Map<int, String> summaries,
  required Future<String?> Function(String prompt, int maxTokens) generate,
  void Function()? onWritten,
}) async {
  final stories = await readStories(dir);
  final order = finished.toList()..sort();
  StorySnapshot? previous;
  for (final i in order) {
    final chapter = sections[i];
    if (stories[chapter.key] case final known?) {
      previous = known;
      continue;
    }
    final summary = summaries[chapter.key];
    if (summary == null) return;
    final last = i == order.last;
    final String story;
    if (summary.trim().isEmpty) {
      // Nothing happens in it to tell.
      story = previous?.story ?? '';
    } else {
      final written = await generate(
        storyPrompt(title: title, authors: authors, before: previous?.story, chapter: chapter, summary: summary),
        200,
      );
      if (written == null || written.trim().isEmpty) return;
      story = tidyAnswer(written);
    }
    final people = {...?previous?.people};
    if (last) {
      final text = [for (final (j, p) in paragraphs.indexed) if (placed[j] == i) p.text];
      for (final name in chapterPeople(text)) {
        final about = sentencesAbout(text, name);
        if (about.length < 2) continue;
        final profile = await generate(
          profilePrompt(title: title, name: name, before: previous?.profileOf(name), chapter: chapter, sentences: about),
          90,
        );
        if (profile != null && profile.trim().isNotEmpty) people[name] = tidyAnswer(profile);
      }
    }
    final snapshot = StorySnapshot(story: story, people: people);
    stories[chapter.key] = snapshot;
    await writeStories(dir, stories);
    previous = snapshot;
    onWritten?.call();
  }
}
