import 'dart:io';
import 'package:flutter/painting.dart';

/// Decode width used by the gallery tray's thumbnails. Shared with the
/// eviction helper below because `cacheWidth` wraps `FileImage` in a
/// [ResizeImage], which caches under its own key — evicting the bare
/// `FileImage` alone would leave the resized thumbnail entry stale.
const int kGalleryThumbnailCacheWidth = 360;

/// Evicts every cached bitmap for [path] after its file was rewritten in
/// place: the full-resolution `FileImage` entry and the gallery's resized
/// thumbnail entry. Targeted on purpose — a global `imageCache.clear()`
/// forces every other thumbnail to re-decode too, which is visible jank.
Future<void> evictImageFileFromCaches(String path) async {
  final provider = FileImage(File(path));
  await provider.evict();
  await ResizeImage(provider, width: kGalleryThumbnailCacheWidth).evict();
}
