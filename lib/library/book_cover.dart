import 'dart:io';

import 'package:flutter/material.dart';

import '../data/database.dart';
import '../theme/tokens.dart';

/// A book's cover at 2:3, or a typeset stand-in when the book has none.
class BookCover extends StatelessWidget {
  const BookCover({super.key, required this.book, this.width = 120, this.heroTag});

  final Book book;
  final double width;

  /// Set where the cover flies between the shelf and the book's page.
  final Object? heroTag;

  @override
  Widget build(BuildContext context) {
    final height = width * 1.5;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final path = book.coverPath;
    final Widget face = path == null
        ? _TypesetCover(book: book, width: width)
        : Image.file(
            File(path),
            width: width,
            height: height,
            fit: BoxFit.cover,
            cacheWidth: (width * dpr).round(),
            errorBuilder: (_, _, _) => _TypesetCover(book: book, width: width),
          );

    final cover = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.sm),
        boxShadow: const [
          BoxShadow(color: Color(0x26000000), blurRadius: 8, offset: Offset(0, 3)),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: face,
    );
    final tag = heroTag;
    return tag == null ? cover : Hero(tag: tag, child: cover);
  }
}

/// Title in the display face on a muted block whose color comes from the book's id, so each
/// book keeps its own.
class _TypesetCover extends StatelessWidget {
  const _TypesetCover({required this.book, required this.width});

  final Book book;
  final double width;

  static const _blocks = [
    Color(0xFF2F4A3A), Color(0xFF5B3A32), Color(0xFF34465E), Color(0xFF6B5A3A), //
    Color(0xFF4A3550), Color(0xFF3D4F4F), Color(0xFF6E3B3B), Color(0xFF3F3A2E),
  ];

  @override
  Widget build(BuildContext context) {
    final color = _blocks[book.id.codeUnits.fold(0, (a, b) => a + b) % _blocks.length];
    final scale = width / 120;
    return Container(
      color: color,
      padding: EdgeInsets.all(10 * scale),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            book.title,
            maxLines: 5,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: FontFamilies.display,
              fontSize: 15 * scale,
              height: 1.15,
              color: const Color(0xFFF1E9D8),
            ),
          ),
          const Spacer(),
          if (book.authors.isNotEmpty)
            Text(
              book.authors.first.toUpperCase(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: FontFamilies.ui,
                fontSize: 8 * scale,
                letterSpacing: 1.2,
                color: const Color(0xFFD9C9A8),
              ),
            ),
        ],
      ),
    );
  }
}
