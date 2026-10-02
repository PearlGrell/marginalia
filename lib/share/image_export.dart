import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'file_export.dart';

const _device = MethodChannel('marginalia/device');

/// Renders the [RepaintBoundary] under [key] to a PNG in the share cache, at [pixelRatio]
/// times its layout size (a 360 × 640 card at 3 is 1080 × 1920, a story).
Future<String> renderToPng(GlobalKey key, String name, {double pixelRatio = 3}) async {
  await WidgetsBinding.instance.endOfFrame;
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: pixelRatio);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  final file = await shareableFile(name);
  await file.writeAsBytes(png!.buffer.asUint8List(), flush: true);
  return file.path;
}

/// Saves a PNG to Pictures/Marginalia and opens it in the photo viewer. Returns false if it
/// couldn't be saved.
Future<bool> saveImageToGallery(String path) async =>
    await _device.invokeMethod<bool>('saveImage', {
      'path': path,
      'name': 'marginalia-${DateTime.now().millisecondsSinceEpoch}.png',
    }) ??
    false;

/// The Android share sheet with a PNG.
Future<void> shareImageFile(String path) => _device.invokeMethod('shareImage', {'path': path});

/// Save and Share buttons for an image card under [card].
class ImageCardActions extends StatefulWidget {
  const ImageCardActions({super.key, required this.card, required this.fileName, this.beforeRender});

  final GlobalKey card;
  final String fileName;

  /// Waits for anything the card shows (images) to be ready.
  final Future<void> Function()? beforeRender;

  @override
  State<ImageCardActions> createState() => _ImageCardActionsState();
}

class _ImageCardActionsState extends State<ImageCardActions> {
  bool _busy = false;

  Future<String> _render() async {
    await widget.beforeRender?.call();
    return renderToPng(widget.card, widget.fileName);
  }

  Future<void> _run(Future<void> Function(String path) action) async {
    setState(() => _busy = true);
    try {
      await action(await _render());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: _busy ? null : () => _run(shareImageFile),
            child: const Text('Share…'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton.icon(
            icon: const Icon(Icons.download_outlined, size: 18),
            label: const Text('Save'),
            onPressed: _busy
                ? null
                : () => _run((path) async {
                    final messenger = ScaffoldMessenger.of(context);
                    final saved = await saveImageToGallery(path);
                    messenger.showSnackBar(
                      SnackBar(content: Text(saved ? 'Saved to Pictures/Marginalia' : "Couldn't save the image")),
                    );
                  }),
          ),
        ),
      ],
    );
  }
}

/// Whether a cover file is there to show.
bool coverExists(String? path) => path != null && File(path).existsSync();
