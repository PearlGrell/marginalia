import 'package:flutter/material.dart';

import '../readium/readium.dart';
import '../theme/tokens.dart';
import '../util/html_text.dart';

/// A footnote's text over the page, so reading doesn't jump away. Returns true to go to the
/// note in place instead.
Future<bool?> showFootnoteSheet(BuildContext context, Footnote note) {
  final body = htmlToText(note.html);
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (context) {
      final text = Theme.of(context).textTheme;
      return ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.6),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.md),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('NOTE', style: text.labelSmall),
                const SizedBox(height: Space.sm),
                Flexible(
                  child: SingleChildScrollView(
                    child: SelectableText(
                      body.isEmpty ? 'This note is empty.' : body,
                      style: text.bodyLarge?.copyWith(fontFamily: FontFamilies.reading, height: 1.55),
                    ),
                  ),
                ),
                const SizedBox(height: Space.md),
                Row(
                  children: [
                    if (note.href != null)
                      TextButton.icon(
                        icon: const Icon(Icons.open_in_new, size: 18),
                        label: const Text('Go to note'),
                        onPressed: () => Navigator.pop(context, true),
                      ),
                    const Spacer(),
                    FilledButton(onPressed: () => Navigator.pop(context, false), child: const Text('Done')),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
