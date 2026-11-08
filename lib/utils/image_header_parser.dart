// Gene - Nov, 08, 2026: Created fast 24-byte PNG/JPEG header parser to read image dimensions in <0.1ms without decoding full bitmaps.
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Fast header-only dimension reader for PNG and JPEG files.
///
/// Avoids reading and decoding multi-megabyte Retina screenshots via
/// `package:image` just to inspect `(width, height)`.
class ImageHeaderParser {
  const ImageHeaderParser._();

  /// Parses `(width, height)` from an in-memory byte slice (PNG or JPEG).
  /// Returns null if the header is not recognized or truncated.
  static ({int width, int height})? parseHeaderBytes(Uint8List bytes) {
    if (bytes.length >= 24 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0D &&
        bytes[5] == 0x0A &&
        bytes[6] == 0x1A &&
        bytes[7] == 0x0A &&
        bytes[12] == 0x49 &&
        bytes[13] == 0x48 &&
        bytes[14] == 0x44 &&
        bytes[15] == 0x52) {
      final bd = ByteData.sublistView(bytes, 16, 24);
      final width = bd.getUint32(0, Endian.big);
      final height = bd.getUint32(4, Endian.big);
      if (width > 0 && height > 0) {
        return (width: width, height: height);
      }
    }

    // JPEG SOI marker (0xFF, 0xD8)
    if (bytes.length >= 4 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
      int offset = 2;
      while (offset + 8 < bytes.length) {
        if (bytes[offset] != 0xFF) {
          offset++;
          continue;
        }
        // Skip padding 0xFF bytes
        while (offset < bytes.length && bytes[offset] == 0xFF) {
          offset++;
        }
        if (offset >= bytes.length) break;
        final marker = bytes[offset];
        offset++;

        // Standalone markers without payload
        if (marker == 0xD8 ||
            marker == 0xD9 ||
            (marker >= 0xD0 && marker <= 0xD7) ||
            marker == 0x01) {
          continue;
        }

        if (offset + 1 >= bytes.length) break;
        final segLength = (bytes[offset] << 8) | bytes[offset + 1];
        if (segLength < 2) break;

        // SOF0..SOF3, SOF5..SOF7, SOF9..SOF11, SOF13..SOF15
        final isSof =
            (marker >= 0xC0 && marker <= 0xC3) ||
            (marker >= 0xC5 && marker <= 0xC7) ||
            (marker >= 0xC9 && marker <= 0xCB) ||
            (marker >= 0xCD && marker <= 0xCF);
        if (isSof) {
          if (offset + 6 < bytes.length) {
            final height = (bytes[offset + 3] << 8) | bytes[offset + 4];
            final width = (bytes[offset + 5] << 8) | bytes[offset + 6];
            if (width > 0 && height > 0) {
              return (width: width, height: height);
            }
          }
          break;
        }

        offset += segLength;
      }
    }

    return null;
  }

  /// Reads image dimensions from [filePath] using header bytes first (`<0.1ms`
  /// for PNG), falling back to a worker-isolate decode only if needed.
  static Future<({int width, int height})?> readDimensions(
    String filePath,
  ) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;

      final raf = await file.open(mode: FileMode.read);
      try {
        // Read first 64 KB (24 bytes is enough for PNG; 64 KB covers EXIF in JPEGs)
        final headerBytes = await raf.read(65536);
        final parsed = parseHeaderBytes(headerBytes);
        if (parsed != null) return parsed;
      } finally {
        await raf.close();
      }

      // Fallback for non-standard image containers
      final fullBytes = await file.readAsBytes();
      final decoded = await compute(img.decodeImage, fullBytes);
      if (decoded != null && decoded.width > 0 && decoded.height > 0) {
        return (width: decoded.width, height: decoded.height);
      }
    } catch (e) {
      debugPrint('SnipSnap ImageHeaderParser error: $e');
    }
    return null;
  }
}
