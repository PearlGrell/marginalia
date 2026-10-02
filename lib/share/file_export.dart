import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../theme/tokens.dart';

const _device = MethodChannel('marginalia/device');

/// Lets the reader choose where on the phone to keep [path] (the Android file picker).
/// Returns false if they cancelled or it couldn't be written.
Future<bool> saveToDevice(String path, {required String name, required String mimeType}) async =>
    await _device.invokeMethod<bool>('saveDocument', {'path': path, 'name': name, 'mime': mimeType}) ?? false;

/// The Android share sheet with a file.
Future<void> shareFile(String path, {required String mimeType}) =>
    _device.invokeMethod('shareFile', {'path': path, 'mime': mimeType});

/// A temporary file in the shared cache folder (which the share sheet may read).
Future<File> shareableFile(String name) async {
  final dir = Directory('${(await getTemporaryDirectory()).path}/share');
  await dir.create(recursive: true);
  return File('${dir.path}/$name');
}

/// Writes [bytes] as [name] and asks whether to save it to the phone or send it.
Future<void> offerFile(
  BuildContext context, {
  required String name,
  required String mimeType,
  required Uint8List bytes,
  String? title,
}) async {
  final file = await shareableFile(name);
  await file.writeAsBytes(bytes, flush: true);
  if (!context.mounted) return;
  await offerExistingFile(context, path: file.path, name: name, mimeType: mimeType, title: title);
}

/// Asks whether to save [path] to the phone or send it.
Future<void> offerExistingFile(
  BuildContext context, {
  required String path,
  required String name,
  required String mimeType,
  String? title,
}) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (context) {
      final text = Theme.of(context).textTheme;
      final size = File(path).lengthSync();
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title ?? 'Export ready', style: text.headlineSmall),
                  Text('$name · ${_size(size)}', style: text.bodySmall),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.save_alt),
              title: const Text('Save to the phone…'),
              subtitle: const Text('Choose a folder, such as Downloads'),
              onTap: () async {
                final messenger = ScaffoldMessenger.of(context);
                Navigator.pop(context);
                final saved = await saveToDevice(path, name: name, mimeType: mimeType);
                if (saved) messenger.showSnackBar(SnackBar(content: Text('Saved $name')));
              },
            ),
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: const Text('Send…'),
              subtitle: const Text('Email, Drive, messages'),
              onTap: () {
                Navigator.pop(context);
                shareFile(path, mimeType: mimeType);
              },
            ),
            const SizedBox(height: Space.sm),
          ],
        ),
      );
    },
  );
}

String _size(int bytes) {
  if (bytes < 1024) return '$bytes bytes';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// "Pride and Prejudice: Notes" → "Pride and Prejudice - Notes", safe as a file name.
String safeFileName(String name) {
  final cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|\n\r\t]+'), ' - ').replaceAll(RegExp(r'\s+'), ' ').trim();
  final short = cleaned.length > 80 ? cleaned.substring(0, 80).trim() : cleaned;
  return short.isEmpty ? 'Marginalia' : short;
}
