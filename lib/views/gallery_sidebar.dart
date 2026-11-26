import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../models/capture_item.dart';
import '../services/storage_service.dart';
// Gene - Nov, 25, 2026: Imported date grouping utility for tray date rails and 7-day archive end card.
import '../utils/capture_date_group.dart';
import '../utils/image_eviction.dart';
import '../utils/snip_theme.dart';

// Gene - Nov, 17, 2026: Default initial batch size and scroll-load increment for horizontal screenshot history pagination.
const int kGalleryInitialBatchSize = 20;
const int kGalleryBatchIncrement = 20;

// Gene - Nov, 08, 2026: Added GalleryMediaFilter enum and upgraded GallerySidebar to StatefulWidget for All/Images/Videos filtering, video badges, and inline title rename.
enum GalleryMediaFilter { all, images, videos }

// Old implementation:
// class GallerySidebar extends StatelessWidget {
class GallerySidebar extends StatefulWidget {
  final List<CaptureItem> items;
  final CaptureItem? activeItem;
  final ValueChanged<CaptureItem> onSelectItem;
  final ValueChanged<CaptureItem> onDeleteItem;
  final VoidCallback onClose;
  final VoidCallback? onOpenLibraryLocation;
  final ValueChanged<CaptureItem>? onRevealItemInFolder;
  // Gene - Nov, 08, 2026: Added optional onRenameItem callback for inline capture/recording title editing.
  final void Function(CaptureItem item, String newTitle)? onRenameItem;

  final double zoomScale;
  final ValueChanged<double>? onZoomScaleChanged;
  // Gene - Nov, 20, 2026: Dynamic upper zoom bound for long panoramic captures.
  final double maxZoom;

  /// Bumped whenever the active capture's file is rewritten in place (crop,
  /// flatten, flood fill, undo/redo). Keys the active item's thumbnail so it
  /// re-decodes — the other thumbnails keep their cached bitmaps untouched.
  final int imageRevision;

  // Gene - Oct, 27, 2026: Added isOpen and onToggleCollapse to support keeping the header bar visible when collapsed.
  final bool isOpen;
  final VoidCallback? onToggleCollapse;

  // Gene - Nov, 17, 2026: Added initialBatchSize, batchIncrement, and onLoadMore for incremental scroll pagination.
  final int initialBatchSize;
  final int batchIncrement;
  final VoidCallback? onLoadMore;

  // Gene - Nov, 25, 2026: Added olderCount, onBrowseArchive, and nowOverride for 7-day tray scoping and date-grouped archive access.
  final int olderCount;
  final VoidCallback? onBrowseArchive;

  @visibleForTesting
  final DateTime? nowOverride;

  // Gene - Oct, 27, 2026: Updated constructor to accept isOpen and onToggleCollapse.
  // ...
  // Gene - Nov, 17, 2026: Added initialBatchSize, batchIncrement, and onLoadMore parameters to GallerySidebar constructor.
  // ...
  // Gene - Nov, 25, 2026: Added olderCount, onBrowseArchive, and nowOverride parameters to GallerySidebar constructor.
  // Old implementation:
  // const GallerySidebar({
  //   super.key,
  //   required this.items,
  //   required this.activeItem,
  //   required this.onSelectItem,
  //   required this.onDeleteItem,
  //   required this.onClose,
  //   this.onOpenLibraryLocation,
  //   this.onRevealItemInFolder,
  //   this.onRenameItem,
  //   this.zoomScale = 1.0,
  //   this.onZoomScaleChanged,
  //   // Gene - Nov, 20, 2026: Dynamic upper zoom bound for long panoramic captures.
  //   this.maxZoom = 4.0,
  //   this.imageRevision = 0,
  //   this.isOpen = true,
  //   this.onToggleCollapse,
  //   this.initialBatchSize = kGalleryInitialBatchSize,
  //   this.batchIncrement = kGalleryBatchIncrement,
  //   this.onLoadMore,
  // });
  const GallerySidebar({
    super.key,
    required this.items,
    required this.activeItem,
    required this.onSelectItem,
    required this.onDeleteItem,
    required this.onClose,
    this.onOpenLibraryLocation,
    this.onRevealItemInFolder,
    this.onRenameItem,
    this.zoomScale = 1.0,
    this.onZoomScaleChanged,
    // Gene - Nov, 20, 2026: Dynamic upper zoom bound for long panoramic captures.
    this.maxZoom = 4.0,
    this.imageRevision = 0,
    this.isOpen = true,
    this.onToggleCollapse,
    this.initialBatchSize = kGalleryInitialBatchSize,
    this.batchIncrement = kGalleryBatchIncrement,
    this.onLoadMore,
    this.olderCount = 0,
    this.onBrowseArchive,
    this.nowOverride,
  });

  @override
  State<GallerySidebar> createState() => _GallerySidebarState();
}

// Gene - Nov, 25, 2026: Sealed entry model interleaving date group headers, capture cards, and the end-of-list archive/folder card.
sealed class _GalleryListEntry {
  const _GalleryListEntry();
}

class _GalleryDateHeaderEntry extends _GalleryListEntry {
  final DateTime day;
  final String key;
  final String shortLabel;
  final String subLabel;
  final int totalCount;

  const _GalleryDateHeaderEntry({
    required this.day,
    required this.key,
    required this.shortLabel,
    required this.subLabel,
    required this.totalCount,
  });
}

class _GalleryCaptureEntry extends _GalleryListEntry {
  final CaptureItem item;

  const _GalleryCaptureEntry(this.item);
}

class _GalleryArchiveEndEntry extends _GalleryListEntry {
  final int olderCount;

  const _GalleryArchiveEndEntry({required this.olderCount});
}

class _GallerySidebarState extends State<GallerySidebar> {
  GalleryMediaFilter _filter = GalleryMediaFilter.all;
  String? _editingItemId;
  final TextEditingController _renameController = TextEditingController();

  // Gene - Nov, 17, 2026: Scroll pagination state, memoized file existence map, and cached filtered item list.
  final ScrollController _scrollController = ScrollController();
  late int _visibleLimit;
  final Map<String, bool> _fileExistsCache = <String, bool>{};
  List<CaptureItem>? _cachedFilteredItems;
  List<CaptureItem>? _lastItemsRef;
  int? _lastItemsLength;
  GalleryMediaFilter? _lastFilter;

  @override
  void initState() {
    super.initState();
    _visibleLimit = widget.initialBatchSize;
    _scrollController.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(covariant GallerySidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageRevision != widget.imageRevision &&
        widget.activeItem != null) {
      _fileExistsCache.remove(widget.activeItem!.filePath);
      if (widget.activeItem!.thumbnailPath != null) {
        _fileExistsCache.remove(widget.activeItem!.thumbnailPath);
      }
      _cachedFilteredItems = null;
    }
    if (oldWidget.items != widget.items ||
        oldWidget.items.length != widget.items.length ||
        oldWidget.activeItem != widget.activeItem) {
      _cachedFilteredItems = null;
    }
  }

  // Gene - Nov, 17, 2026: Dispose horizontal scroll controller alongside rename controller.
  // Old implementation:
  // @override
  // void dispose() {
  //   _renameController.dispose();
  //   super.dispose();
  // }
  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _renameController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    // Gene - Nov, 22, 2026: Allow loading more when filtered/non-scrollable list reaches end (maxScrollExtent <= 0) as well as near right edge.
    // Old implementation:
    // if (pos.pixels <= 0 || pos.pixels < pos.maxScrollExtent - 300) return;
    if (pos.maxScrollExtent > 0 && pos.pixels < pos.maxScrollExtent - 300) {
      return;
    }

    final filtered = _filteredItems;
    final total = filtered.length;
    final currentVisible = _effectiveItemCount(filtered);
    if (_visibleLimit < total || currentVisible < total) {
      final base = _visibleLimit > currentVisible
          ? _visibleLimit
          : currentVisible;
      setState(() {
        _visibleLimit = (base + widget.batchIncrement).clamp(0, total);
      });
    }
    if (_visibleLimit >= total) {
      widget.onLoadMore?.call();
    }
  }

  int _effectiveItemCount(List<CaptureItem> filtered) {
    var limit = _visibleLimit;
    if (widget.activeItem != null) {
      final activeIdx = filtered.indexWhere(
        (i) => i.id == widget.activeItem!.id,
      );
      if (activeIdx >= limit) {
        limit = activeIdx + 1;
      }
    }
    return filtered.length < limit ? filtered.length : limit;
  }

  bool _cachedFileExists(String? path) {
    if (path == null || path.isEmpty) return false;
    return _fileExistsCache.putIfAbsent(path, () => File(path).existsSync());
  }

  // Gene - Nov, 17, 2026: Cache filtered item list so frequent rebuilds during zoom/canvas drags do not reallocate.
  // Old implementation:
  // List<CaptureItem> get _filteredItems {
  //   return switch (_filter) {
  //     GalleryMediaFilter.all => widget.items,
  //     GalleryMediaFilter.images =>
  //       widget.items.where((i) => !i.isVideo).toList(),
  //     GalleryMediaFilter.videos =>
  //       widget.items.where((i) => i.isVideo).toList(),
  //   };
  // }
  List<CaptureItem> get _filteredItems {
    if (_cachedFilteredItems != null &&
        identical(_lastItemsRef, widget.items) &&
        _lastItemsLength == widget.items.length &&
        _lastFilter == _filter) {
      return _cachedFilteredItems!;
    }
    final computed = switch (_filter) {
      GalleryMediaFilter.all => widget.items,
      GalleryMediaFilter.images =>
        widget.items.where((i) => !i.isVideo).toList(),
      GalleryMediaFilter.videos =>
        widget.items.where((i) => i.isVideo).toList(),
    };
    _cachedFilteredItems = computed;
    _lastItemsRef = widget.items;
    _lastItemsLength = widget.items.length;
    _lastFilter = _filter;
    return computed;
  }

  String _formatDurationBadge(int? durationMs) {
    final secs = ((durationMs ?? 0) / 1000).round().clamp(0, 359999);
    final mins = secs ~/ 60;
    final rem = (secs % 60).toString().padLeft(2, '0');
    return '$mins:$rem';
  }

  void _startInlineRename(CaptureItem item) {
    if (widget.onRenameItem == null) return;
    setState(() {
      _editingItemId = item.id;
      _renameController.text = item.title;
    });
  }

  // Gene - Nov, 17, 2026: Invalidate filtered list cache on inline rename so filtered tabs update immediately even when items is mutated in place.
  // Old implementation:
  // void _commitInlineRename(CaptureItem item) {
  //   final trimmed = _renameController.text.trim();
  //   setState(() {
  //     _editingItemId = null;
  //   });
  //   if (trimmed.isNotEmpty && trimmed != item.title) {
  //     widget.onRenameItem?.call(item, trimmed);
  //   }
  // }
  void _commitInlineRename(CaptureItem item) {
    final trimmed = _renameController.text.trim();
    setState(() {
      _editingItemId = null;
      if (trimmed.isNotEmpty && trimmed != item.title) {
        _cachedFilteredItems = null;
      }
    });
    if (trimmed.isNotEmpty && trimmed != item.title) {
      widget.onRenameItem?.call(item, trimmed);
    }
  }

  String _formatTime(DateTime date) {
    final hour = date.hour.toString().padLeft(2, '0');
    final minute = date.minute.toString().padLeft(2, '0');
    final second = date.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }

  // Gene - Nov, 25, 2026: Build date-grouped list entries and optional end-of-list archive/folder action card.
  List<_GalleryListEntry> _buildEntries(List<CaptureItem> filtered) {
    final visibleCount = _effectiveItemCount(filtered);
    if (visibleCount <= 0) return const <_GalleryListEntry>[];

    final totalCountsByDay = <DateTime, int>{};
    for (final item in filtered) {
      final day = calendarDay(item.createdAt);
      totalCountsByDay[day] = (totalCountsByDay[day] ?? 0) + 1;
    }

    final groups = groupCapturesByDate(
      filtered.take(visibleCount).toList(),
      now: widget.nowOverride,
    );
    final entries = <_GalleryListEntry>[];
    for (final group in groups) {
      entries.add(
        _GalleryDateHeaderEntry(
          day: group.day,
          key: group.key,
          shortLabel: group.shortLabel,
          subLabel: group.subLabel,
          totalCount: totalCountsByDay[group.day] ?? group.items.length,
        ),
      );
      for (final item in group.items) {
        entries.add(_GalleryCaptureEntry(item));
      }
    }

    final reachedEnd =
        visibleCount >= filtered.length && widget.onLoadMore == null;
    if (reachedEnd &&
        (widget.olderCount > 0 || widget.onBrowseArchive != null)) {
      entries.add(_GalleryArchiveEndEntry(olderCount: widget.olderCount));
    }
    return entries;
  }

  void _openFolder() {
    if (widget.onOpenLibraryLocation != null) {
      widget.onOpenLibraryLocation!();
    } else {
      StorageService.openLibraryFolder();
    }
  }

  Widget _buildDateGroupHeader(
    SnipTheme t,
    _GalleryDateHeaderEntry entry, {
    required bool isFirst,
  }) {
    return Container(
      key: ValueKey('gallery-date-group-${entry.key}'),
      width: 68,
      margin: EdgeInsets.only(left: isFirst ? 0 : 6, right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: t.border, width: t.hairline),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.calendar_today_rounded, size: 12, color: t.inkMuted),
          const SizedBox(height: 4),
          Text(
            entry.shortLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: t.ink,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(
            entry.subLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(color: t.inkMuted, fontSize: 9),
          ),
          const SizedBox(height: 4),
          DecoratedBox(
            decoration: BoxDecoration(
              color: t.selectedFill,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              child: Text(
                '${entry.totalCount}',
                style: TextStyle(
                  color: t.ink,
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildArchiveEndCard(SnipTheme t, _GalleryArchiveEndEntry entry) {
    final title = entry.olderCount > 0 ? 'Older Captures' : 'All History';
    final subtitle = entry.olderCount > 0
        ? '${entry.olderCount} more by date'
        : 'Browse by date';

    return Container(
      key: const ValueKey('gallery-older-history-card'),
      width: 154,
      margin: const EdgeInsets.only(left: 6, right: 4),
      decoration: BoxDecoration(
        color: t.surfaceRaised,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: t.borderStrong, width: t.hairline),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          hoverColor: t.hoverFill,
          onTap: widget.onBrowseArchive ?? _openFolder,
          child: Padding(
            padding: const EdgeInsets.all(7),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(Icons.history_rounded, size: 15, color: t.ink),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: t.ink,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Icon(
                      Icons.arrow_forward_rounded,
                      size: 13,
                      color: t.inkMuted,
                    ),
                  ],
                ),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.inkMuted, fontSize: 9.5),
                ),
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    key: const ValueKey('gallery-older-open-folder'),
                    borderRadius: BorderRadius.circular(4),
                    hoverColor: t.hoverFill,
                    onTap: _openFolder,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: t.surface,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: t.border, width: t.hairline),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 3,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.folder_open_rounded,
                              size: 11,
                              color: t.ink,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'Open Folder',
                              style: TextStyle(
                                color: t.ink,
                                fontSize: 9.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(SnipTheme t) {
    if (widget.items.isEmpty && widget.olderCount == 0) {
      return Center(
        child: Text(
          'No captures yet. Click "Snip" to start!',
          textAlign: TextAlign.center,
          // Was a fixed Colors.white38 regardless of mode — same
          // pre-existing light-mode legibility bug as the close
          // button above (white38 on near-white is unreadable).
          style: TextStyle(color: t.inkMuted, fontSize: 13),
        ),
      );
    }

    final message = widget.items.isEmpty
        ? 'No captures in the last 7 days.'
        : 'No matching items in this filter.';
    return Center(
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 10,
        runSpacing: 6,
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: t.inkMuted, fontSize: 12.5),
          ),
          if (widget.olderCount > 0 && widget.onBrowseArchive != null)
            OutlinedButton.icon(
              key: const ValueKey('gallery-empty-browse-older'),
              onPressed: widget.onBrowseArchive,
              icon: Icon(Icons.history_rounded, size: 14, color: t.ink),
              label: Text(
                widget.items.isEmpty
                    ? 'Browse ${widget.olderCount} older by date'
                    : 'Browse older by date',
                style: TextStyle(color: t.ink, fontSize: 11.5),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: t.borderStrong),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                minimumSize: const Size(0, 28),
              ),
            ),
          if (widget.items.isEmpty && widget.olderCount > 0)
            OutlinedButton.icon(
              key: const ValueKey('gallery-empty-open-folder'),
              onPressed: _openFolder,
              icon: Icon(Icons.folder_open_rounded, size: 14, color: t.ink),
              label: Text(
                'Open Folder',
                style: TextStyle(color: t.ink, fontSize: 11.5),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: t.border),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                minimumSize: const Size(0, 28),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = SnipTheme.of(context);
    final sliderThemeData = SliderThemeData(
      activeTrackColor: t.ink,
      inactiveTrackColor: t.border,
      thumbColor: t.ink,
      trackHeight: 3,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
    );

    // Gene - Oct, 27, 2026: Changed Container to AnimatedContainer and height to isOpen ? 145 : 32 so the header bar remains visible when collapsed.
    // Old implementation:
    // return Container(
    //   height: 145,
    //   decoration: BoxDecoration(
    //     color: t.surface,
    //     border: Border(top: BorderSide(color: t.border)),
    //   ),
    //   child: Column(
    //     children: [
    // Gene - Nov, 08, 2026: Updated build to use widget.* in _GallerySidebarState, added All/Images/Videos filter pills, video thumbnail/play/duration badges, and inline title rename.
    final filtered = _filteredItems;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      height: widget.isOpen ? 145 : 33,
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(top: BorderSide(color: t.border)),
      ),
      child: ClipRect(
        child: Column(
          children: [
            // Snagit-style Tray Sub-Header Bar
            Container(
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: t.surfaceRaised,
                border: Border(bottom: BorderSide(color: t.border)),
              ),
              child: Row(
                children: [
                  // Screenshots Gallery Header
                  // Gene - Oct, 27, 2026: Made the Screenshots title and small chevron icon clickable to hide/unhide the gallery.
                  // Old implementation:
                  // Icon(Icons.photo_library_rounded, color: t.ink, size: 15),
                  // const SizedBox(width: 6),
                  // Text(
                  //   'Screenshots',
                  //   style: TextStyle(
                  //     color: t.ink,
                  //     fontSize: 12,
                  //     fontWeight: FontWeight.bold,
                  //   ),
                  // ),
                  Tooltip(
                    message: widget.isOpen
                        ? 'Hide Screenshots Tray (Cmd+H)'
                        : 'Show Screenshots Tray (Cmd+H)',
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(6),
                        hoverColor: t.hoverFill,
                        onTap: widget.onToggleCollapse ?? widget.onClose,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 3,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                widget.isOpen
                                    ? Icons.keyboard_arrow_down_rounded
                                    : Icons.keyboard_arrow_up_rounded,
                                color: t.ink,
                                size: 16,
                              ),
                              const SizedBox(width: 4),
                              Icon(
                                Icons.photo_library_rounded,
                                color: t.ink,
                                size: 15,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                'Screenshots',
                                style: TextStyle(
                                  color: t.ink,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),

                  // Open Screenshots Library Folder Button
                  Tooltip(
                    message:
                        'Open Screenshots Library Folder in Finder/Explorer',
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(6),
                        hoverColor: t.hoverFill,
                        onTap: () {
                          if (widget.onOpenLibraryLocation != null) {
                            widget.onOpenLibraryLocation!();
                          } else {
                            StorageService.openLibraryFolder();
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: t.surfaceRaised,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: t.border),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.folder_open_rounded,
                                size: 13,
                                color: t.ink,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                'Open Folder',
                                style: TextStyle(
                                  color: t.ink,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),

                  // Gene - Nov, 08, 2026: Media filter pills (All / Images / Videos) in tray sub-header.
                  for (final entry in const [
                    (GalleryMediaFilter.all, 'All'),
                    (GalleryMediaFilter.images, 'Images'),
                    (GalleryMediaFilter.videos, 'Videos'),
                  ]) ...[
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          key: ValueKey('gallery-filter-${entry.$1.name}'),
                          borderRadius: BorderRadius.circular(5),
                          hoverColor: t.hoverFill,
                          // Gene - Nov, 17, 2026: Reset pagination window and scroll offset when switching media filter.
                          // Old implementation:
                          // onTap: () => setState(() => _filter = entry.$1),
                          onTap: () {
                            setState(() {
                              _filter = entry.$1;
                              _visibleLimit = widget.initialBatchSize;
                              _cachedFilteredItems = null;
                            });
                            if (_scrollController.hasClients) {
                              _scrollController.jumpTo(0.0);
                            }
                            // Gene - Nov, 22, 2026: Trigger onLoadMore when switching to a sparse filter (e.g. Videos) whose matches on page 1 are below initialBatchSize.
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (!mounted) return;
                              if (_filteredItems.length <
                                  widget.initialBatchSize) {
                                widget.onLoadMore?.call();
                              }
                            });
                          },
                          child: DecoratedBox(
                            decoration: t.controlDecoration(
                              active: _filter == entry.$1,
                              exclusive: false,
                              radius: 5,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 2,
                              ),
                              child: Text(
                                entry.$2,
                                style: TextStyle(
                                  color: t.controlForeground(
                                    active: _filter == entry.$1,
                                    exclusive: false,
                                  ),
                                  fontSize: 10.5,
                                  fontWeight: _filter == entry.$1
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],

                  const Spacer(),

                  // Middle: Zoom Slider Controls in the Sub-Header Bar of Screenshot History Tray
                  if (widget.onZoomScaleChanged != null) ...[
                    IconButton(
                      icon: const Icon(Icons.remove_rounded, size: 14),
                      // inkFaint, not inkMuted, for the *disabled* edge — the
                      // token doc reserves inkFaint for dividers and disabled
                      // text, and header_bar.dart's identical zoom stepper
                      // already uses it. inkMuted is the secondary-but-enabled
                      // tone and stays that way at the reset button below.
                      color: widget.zoomScale > 0.2 ? t.ink : t.inkFaint,
                      tooltip: 'Zoom Out',
                      // Gene - Nov, 20, 2026: Respect dynamic widget.maxZoom for panoramic images and scale steps above 400%.
                      // Old implementation:
                      // onPressed: widget.zoomScale > 0.2
                      //     ? () => widget.onZoomScaleChanged!(
                      //         (widget.zoomScale - 0.25).clamp(0.2, 4.0),
                      //       )
                      //     : null,
                      onPressed: widget.zoomScale > 0.2
                          ? () {
                              final upper = widget.maxZoom >= 0.2
                                  ? widget.maxZoom
                                  : 4.0;
                              final step = widget.zoomScale > 4.25
                                  ? widget.zoomScale * 0.2
                                  : 0.25;
                              widget.onZoomScaleChanged!(
                                (widget.zoomScale - step).clamp(0.2, upper),
                              );
                            }
                          : null,
                      constraints: const BoxConstraints(
                        minWidth: 24,
                        minHeight: 24,
                      ),
                      padding: EdgeInsets.zero,
                    ),
                    SizedBox(
                      width: 200,
                      child: SliderTheme(
                        data: sliderThemeData,
                        // Old implementation:
                        // child: Slider(
                        //   value: widget.zoomScale.clamp(0.2, 4.0),
                        //   min: 0.2,
                        //   max: 4.0,
                        //   onChanged: widget.onZoomScaleChanged,
                        // ),
                        child: Slider(
                          value: widget.zoomScale.clamp(
                            0.2,
                            widget.maxZoom >= 0.2 ? widget.maxZoom : 4.0,
                          ),
                          min: 0.2,
                          max: widget.maxZoom >= 0.2 ? widget.maxZoom : 4.0,
                          onChanged: widget.onZoomScaleChanged,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.add_rounded, size: 14),
                      // Old implementation:
                      // color: widget.zoomScale < 4.0 ? t.ink : t.inkFaint,
                      // tooltip: 'Zoom In',
                      // onPressed: widget.zoomScale < 4.0
                      //     ? () => widget.onZoomScaleChanged!(
                      //         (widget.zoomScale + 0.25).clamp(0.2, 4.0),
                      //       )
                      //     : null,
                      color:
                          widget.zoomScale <
                              (widget.maxZoom >= 0.2 ? widget.maxZoom : 4.0)
                          ? t.ink
                          : t.inkFaint,
                      tooltip: 'Zoom In',
                      onPressed:
                          widget.zoomScale <
                              (widget.maxZoom >= 0.2 ? widget.maxZoom : 4.0)
                          ? () {
                              final upper = widget.maxZoom >= 0.2
                                  ? widget.maxZoom
                                  : 4.0;
                              final step = widget.zoomScale >= 4.0
                                  ? widget.zoomScale * 0.25
                                  : 0.25;
                              widget.onZoomScaleChanged!(
                                (widget.zoomScale + step).clamp(0.2, upper),
                              );
                            }
                          : null,
                      constraints: const BoxConstraints(
                        minWidth: 24,
                        minHeight: 24,
                      ),
                      padding: EdgeInsets.zero,
                    ),
                    const SizedBox(width: 4),
                    Tooltip(
                      message: 'Reset Zoom to 100%',
                      child: InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: () => widget.onZoomScaleChanged!(1.0),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          // A non-exclusive "selected" readout, not the app's
                          // one exclusive-active control — controlDecoration's
                          // non-exclusive shape (selectedFill highlight, not
                          // an activeFill knockout plate).
                          decoration: t.controlDecoration(
                            active: widget.zoomScale == 1.0,
                            exclusive: false,
                            radius: 6,
                          ),
                          child: Text(
                            '${(widget.zoomScale * 100).round()}%',
                            style: TextStyle(
                              color: t.controlForeground(
                                active: widget.zoomScale == 1.0,
                                exclusive: false,
                              ),
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 2),
                    IconButton(
                      icon: const Icon(
                        Icons.center_focus_strong_rounded,
                        size: 14,
                      ),
                      // Deliberately inkMuted, unlike the two steppers above:
                      // this button is never disabled (onPressed is
                      // unconditional). The dimmer tone says "you are not at
                      // 100%", an enabled secondary state — inkFaint would both
                      // lie about interactivity and drop to 2.72:1 in light.
                      color: widget.zoomScale == 1.0 ? t.ink : t.inkMuted,
                      tooltip: 'Reset Zoom (100%)',
                      onPressed: () => widget.onZoomScaleChanged!(1.0),
                      constraints: const BoxConstraints(
                        minWidth: 24,
                        minHeight: 24,
                      ),
                      padding: EdgeInsets.zero,
                    ),
                  ],

                  const Spacer(),

                  // Right: Resolution & Close Button
                  if (widget.activeItem != null &&
                      widget.activeItem!.width > 0 &&
                      widget.activeItem!.height > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: t.surfaceRaised,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: t.border),
                      ),
                      child: Text(
                        '${widget.activeItem!.width} x ${widget.activeItem!.height}',
                        style: TextStyle(
                          color: t.inkMuted,
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  const SizedBox(width: 8),

                  // Right: Controls & Hide Button
                  // Gene - Oct, 27, 2026: Updated right toggle button to toggle between hide (chevron down) and show (chevron up).
                  // Old implementation:
                  // IconButton(
                  //   icon: Icon(Icons.close_rounded, color: t.inkMuted, size: 16),
                  //   padding: EdgeInsets.zero,
                  //   constraints: const BoxConstraints(
                  //     minWidth: 24,
                  //     minHeight: 24,
                  //   ),
                  //   tooltip: 'Hide Screenshots Tray',
                  //   onPressed: onClose,
                  // ),
                  IconButton(
                    icon: Icon(
                      widget.isOpen
                          ? Icons.keyboard_arrow_down_rounded
                          : Icons.keyboard_arrow_up_rounded,
                      color: t.inkMuted,
                      size: 18,
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 24,
                      minHeight: 24,
                    ),
                    tooltip: widget.isOpen
                        ? 'Hide Screenshots Tray'
                        : 'Show Screenshots Tray',
                    onPressed: widget.onToggleCollapse ?? widget.onClose,
                  ),
                ],
              ),
            ),

            // Horizontal Captures List
            // Gene - Oct, 27, 2026: Only render the thumbnail list if isOpen is true.
            // Gene - Nov, 13, 2026: Wrap expanded tray content in ClipRect + OverflowBox so 33 <-> 145px collapse/expand animations and short viewports never squish cards into a RenderFlex overflow.
            // Old implementation:
            // if (widget.isOpen)
            //   Expanded(
            //     child: filtered.isEmpty
            //         ? Center(...)
            //         : ListView.builder(...),
            //   ),
            if (widget.isOpen)
              Expanded(
                child: ClipRect(
                  child: LayoutBuilder(
                    builder: (context, trayConstraints) {
                      final trayHeight = trayConstraints.maxHeight < 112.0
                          ? 112.0
                          : trayConstraints.maxHeight;
                      return OverflowBox(
                        alignment: Alignment.topLeft,
                        minWidth: trayConstraints.maxWidth,
                        maxWidth: trayConstraints.maxWidth,
                        minHeight: trayHeight,
                        maxHeight: trayHeight,
                        // Gene - Nov, 25, 2026: Render date group headers, capture cards, and end-of-list archive/folder card (with dedicated 7-day empty state).
                        // Old implementation:
                        // child: filtered.isEmpty
                        //     ? Center(
                        //         child: Text(
                        //           widget.items.isEmpty
                        //               ? 'No captures yet. Click "Snip" to start!'
                        //               : 'No matching items in this filter.',
                        //           textAlign: TextAlign.center,
                        //           style: TextStyle(
                        //             color: t.inkMuted,
                        //             fontSize: 13,
                        //           ),
                        //         ),
                        //       )
                        //     : ListView.builder(
                        //         controller: _scrollController,
                        //         scrollDirection: Axis.horizontal,
                        //         padding: const EdgeInsets.symmetric(
                        //           horizontal: 10,
                        //           vertical: 8,
                        //         ),
                        //         itemCount: _effectiveItemCount(filtered),
                        //         itemBuilder: (context, index) {
                        //           final item = filtered[index];
                        child: filtered.isEmpty
                            ? _buildEmptyState(t)
                            : Builder(
                                builder: (context) {
                                  final entries = _buildEntries(filtered);
                                  return ListView.builder(
                                    // Gene - Nov, 17, 2026: Attached _scrollController and capped itemCount to _effectiveItemCount(filtered) for lazy pagination.
                                    controller: _scrollController,
                                    scrollDirection: Axis.horizontal,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 8,
                                    ),
                                    itemCount: entries.length,
                                    itemBuilder: (context, index) {
                                      final entry = entries[index];
                                      if (entry is _GalleryDateHeaderEntry) {
                                        return _buildDateGroupHeader(
                                          t,
                                          entry,
                                          isFirst: index == 0,
                                        );
                                      }
                                      if (entry is _GalleryArchiveEndEntry) {
                                        return _buildArchiveEndCard(t, entry);
                                      }
                                      final item =
                                          (entry as _GalleryCaptureEntry).item;
                                      final isSelected =
                                          widget.activeItem?.id == item.id;
                                      final displayPath =
                                          (item.isVideo &&
                                              item.thumbnailPath != null &&
                                              item.thumbnailPath!.isNotEmpty)
                                          ? item.thumbnailPath!
                                          : item.filePath;
                                      // Gene - Nov, 17, 2026: Use memoized _cachedFileExists instead of synchronous File.existsSync() per item on every rebuild.
                                      // Old implementation:
                                      // final fileExists = !item.isVideo
                                      //     ? File(displayPath).existsSync()
                                      //     : (item.thumbnailPath != null &&
                                      //           File(
                                      //             item.thumbnailPath!,
                                      //           ).existsSync());
                                      final fileExists = !item.isVideo
                                          ? _cachedFileExists(displayPath)
                                          : _cachedFileExists(
                                              item.thumbnailPath,
                                            );

                                      /*
                      // The selected capture is a non-exclusive highlight
                      // (selectedFill, ink foreground) — not the exclusive
                      // ink/onActive knockout plate, which stays reserved
                      // for the tool sidebar's single active tool. Rows are
                      // borderless: no separate hairline strengthens on
                      // selection or hover, only the fill changes (hover is
                      // wired below via InkWell's own hoverColor, painted
                      // into the transparent Material that sits between this
                      // Container and that InkWell — see the note there).
                      final cardBg = isSelected
                          ? t.selectedFill
                          : t.surfaceRaised;

                      return Container(
                        width: 150,
                        margin: const EdgeInsets.only(right: 8),
                        decoration: BoxDecoration(
                          color: cardBg,
                          borderRadius: BorderRadius.circular(6),
                        ),
                      */
                                      // Gene - Oct, 04, 2026: Enhanced card selection highlight with high-contrast borderStrong frame and subtle resting hairline border.
                                      final cardBg = isSelected
                                          ? t.selectedFill
                                          : t.surfaceRaised;
                                      final cardBorder = isSelected
                                          ? Border.all(
                                              color: t.borderStrong,
                                              width: 2.0,
                                            )
                                          : Border.all(
                                              color: t.border,
                                              width: t.hairline,
                                            );

                                      return Container(
                                        width: 150,
                                        margin: const EdgeInsets.only(right: 8),
                                        decoration: BoxDecoration(
                                          color: cardBg,
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                          border: cardBorder,
                                        ),
                                        // The Material is what makes `hoverColor` below
                                        // actually render. Ink paints into its nearest
                                        // ancestor Material, and without this one that is
                                        // the Scaffold's — behind both this Container's
                                        // opaque cardBg and the tray background, so the
                                        // wash was drawn and never seen. Sitting inside the
                                        // Container, this transparent Material puts the ink
                                        // on top of cardBg instead. Same shape as the "Open
                                        // Folder" button above.
                                        child: Material(
                                          color: Colors.transparent,
                                          child: InkWell(
                                            borderRadius: BorderRadius.circular(
                                              6,
                                            ),
                                            hoverColor: t.hoverFill,
                                            onTap: () =>
                                                widget.onSelectItem(item),
                                            child: Padding(
                                              padding: const EdgeInsets.all(5),
                                              // Gene - Nov, 13, 2026: Guard card footer with LayoutBuilder so tight vertical constraints never cause a Column RenderFlex overflow.
                                              child: LayoutBuilder(
                                                builder: (context, cardConstraints) {
                                                  final showFooter =
                                                      cardConstraints
                                                          .maxHeight >=
                                                      36.0;
                                                  return Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      // Thumbnail Image + Extension Pill Badge
                                                      Expanded(
                                                        child: Stack(
                                                          children: [
                                                            Positioned.fill(
                                                              child: ClipRRect(
                                                                borderRadius:
                                                                    BorderRadius.circular(
                                                                      4,
                                                                    ),
                                                                child: ColoredBox(
                                                                  color:
                                                                      t.canvas,
                                                                  child:
                                                                      fileExists
                                                                      ? Image.file(
                                                                          File(
                                                                            displayPath,
                                                                          ),
                                                                          // Re-key only the active
                                                                          // item when its file is
                                                                          // rewritten in place, so
                                                                          // just that one thumbnail
                                                                          // re-decodes.
                                                                          key: ValueKey(
                                                                            isSelected
                                                                                ? '$displayPath#${widget.imageRevision}'
                                                                                : displayPath,
                                                                          ),
                                                                          fit: BoxFit
                                                                              .cover,
                                                                          // Thumbnails are ~170px
                                                                          // wide; decoding the full
                                                                          // Retina capture for each
                                                                          // one wastes memory and
                                                                          // makes cache misses
                                                                          // visibly janky.
                                                                          cacheWidth:
                                                                              kGalleryThumbnailCacheWidth,
                                                                          gaplessPlayback:
                                                                              true,
                                                                          errorBuilder:
                                                                              (
                                                                                ctx,
                                                                                err,
                                                                                stack,
                                                                              ) => Center(
                                                                                child: Icon(
                                                                                  Icons.broken_image_rounded,
                                                                                  color: t.inkMuted,
                                                                                  size: 20,
                                                                                ),
                                                                              ),
                                                                        )
                                                                      : Center(
                                                                          child: Icon(
                                                                            item.isVideo
                                                                                ? Icons.videocam_rounded
                                                                                : Icons.image_not_supported_rounded,
                                                                            color:
                                                                                t.inkMuted,
                                                                            size:
                                                                                20,
                                                                          ),
                                                                        ),
                                                                ),
                                                              ),
                                                            ),
                                                            // Gene - Nov, 08, 2026: Center play icon and bottom-left duration badge for video items.
                                                            if (item
                                                                .isVideo) ...[
                                                              Center(
                                                                child: DecoratedBox(
                                                                  decoration: BoxDecoration(
                                                                    color:
                                                                        t.ink,
                                                                    shape: BoxShape
                                                                        .circle,
                                                                  ),
                                                                  child: Padding(
                                                                    padding:
                                                                        const EdgeInsets.all(
                                                                          3,
                                                                        ),
                                                                    child: Icon(
                                                                      Icons
                                                                          .play_arrow_rounded,
                                                                      size: 14,
                                                                      color: t
                                                                          .onActive,
                                                                    ),
                                                                  ),
                                                                ),
                                                              ),
                                                              Positioned(
                                                                bottom: 3,
                                                                left: 3,
                                                                child: DecoratedBox(
                                                                  decoration: BoxDecoration(
                                                                    color:
                                                                        t.ink,
                                                                    borderRadius:
                                                                        BorderRadius.circular(
                                                                          3,
                                                                        ),
                                                                  ),
                                                                  child: Padding(
                                                                    padding: const EdgeInsets.symmetric(
                                                                      horizontal:
                                                                          4,
                                                                      vertical:
                                                                          1,
                                                                    ),
                                                                    child: Text(
                                                                      _formatDurationBadge(
                                                                        item.durationMs,
                                                                      ),
                                                                      style: TextStyle(
                                                                        color: t
                                                                            .onActive,
                                                                        fontSize:
                                                                            9,
                                                                        fontWeight:
                                                                            FontWeight.bold,
                                                                      ),
                                                                    ),
                                                                  ),
                                                                ),
                                                              ),
                                                            ],
                                                            // Gene - Oct, 04, 2026: Added distinct checkmark indicator badge for the selected capture thumbnail.
                                                            if (isSelected)
                                                              Positioned(
                                                                top: 4,
                                                                left: 4,
                                                                child: Container(
                                                                  padding:
                                                                      const EdgeInsets.all(
                                                                        2,
                                                                      ),
                                                                  decoration: BoxDecoration(
                                                                    color:
                                                                        t.ink,
                                                                    shape: BoxShape
                                                                        .circle,
                                                                    boxShadow: [
                                                                      BoxShadow(
                                                                        color: Colors
                                                                            .black
                                                                            .withValues(
                                                                              alpha: 0.25,
                                                                            ),
                                                                        blurRadius:
                                                                            3,
                                                                        offset:
                                                                            const Offset(
                                                                              0,
                                                                              1,
                                                                            ),
                                                                      ),
                                                                    ],
                                                                  ),
                                                                  child: Icon(
                                                                    Icons
                                                                        .check_rounded,
                                                                    size: 11,
                                                                    color: t
                                                                        .onActive,
                                                                  ),
                                                                ),
                                                              ),
                                                            // Snagit-style Extension Badge in bottom right
                                                            Positioned(
                                                              bottom: 3,
                                                              right: 3,
                                                              child: Container(
                                                                padding:
                                                                    const EdgeInsets.symmetric(
                                                                      horizontal:
                                                                          4,
                                                                      vertical:
                                                                          1,
                                                                    ),
                                                                decoration: BoxDecoration(
                                                                  // This badge sits directly on top
                                                                  // of the thumbnail — arbitrary
                                                                  // screenshot content, same as
                                                                  // editor_canvas.dart's dimension
                                                                  // badges — so it uses the same
                                                                  // "ink mark plate, onActive
                                                                  // knockout text" pattern rather
                                                                  // than a fixed black/white pair.
                                                                  color: t.ink,
                                                                  borderRadius:
                                                                      BorderRadius.circular(
                                                                        3,
                                                                      ),
                                                                ),
                                                                child: Text(
                                                                  p
                                                                      .extension(
                                                                        item.filePath,
                                                                      )
                                                                      .replaceAll(
                                                                        '.',
                                                                        '',
                                                                      ),
                                                                  style: TextStyle(
                                                                    color: t
                                                                        .onActive,
                                                                    fontSize: 9,
                                                                    fontWeight:
                                                                        FontWeight
                                                                            .bold,
                                                                  ),
                                                                ),
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                      if (showFooter) ...[
                                                        const SizedBox(
                                                          height: 4,
                                                        ),
                                                        // Title and delete button
                                                        Row(
                                                          children: [
                                                            Expanded(
                                                              child:
                                                                  _editingItemId ==
                                                                      item.id
                                                                  ? SizedBox(
                                                                      height:
                                                                          22,
                                                                      child: TextField(
                                                                        controller:
                                                                            _renameController,
                                                                        autofocus:
                                                                            true,
                                                                        style: TextStyle(
                                                                          color:
                                                                              t.ink,
                                                                          fontSize:
                                                                              10,
                                                                          fontWeight:
                                                                              FontWeight.w600,
                                                                        ),
                                                                        decoration: InputDecoration(
                                                                          isDense:
                                                                              true,
                                                                          contentPadding: const EdgeInsets.symmetric(
                                                                            horizontal:
                                                                                4,
                                                                            vertical:
                                                                                2,
                                                                          ),
                                                                          border: OutlineInputBorder(
                                                                            borderSide: BorderSide(
                                                                              color: t.borderStrong,
                                                                            ),
                                                                          ),
                                                                        ),
                                                                        onSubmitted:
                                                                            (
                                                                              _,
                                                                            ) => _commitInlineRename(
                                                                              item,
                                                                            ),
                                                                        onTapOutside:
                                                                            (
                                                                              _,
                                                                            ) => _commitInlineRename(
                                                                              item,
                                                                            ),
                                                                      ),
                                                                    )
                                                                  : GestureDetector(
                                                                      onSecondaryTap:
                                                                          widget.onRenameItem !=
                                                                              null
                                                                          ? () => _startInlineRename(
                                                                              item,
                                                                            )
                                                                          : null,
                                                                      child: Column(
                                                                        crossAxisAlignment:
                                                                            CrossAxisAlignment.start,
                                                                        children: [
                                                                          Text(
                                                                            item.title,
                                                                            maxLines:
                                                                                1,
                                                                            overflow:
                                                                                TextOverflow.ellipsis,
                                                                            style: TextStyle(
                                                                              color: t.ink,
                                                                              fontSize: 10,
                                                                              fontWeight: FontWeight.w600,
                                                                            ),
                                                                          ),
                                                                          Text(
                                                                            _formatTime(
                                                                              item.createdAt,
                                                                            ),
                                                                            style: TextStyle(
                                                                              color: t.inkMuted,
                                                                              fontSize: 9,
                                                                            ),
                                                                          ),
                                                                        ],
                                                                      ),
                                                                    ),
                                                            ),
                                                            if (widget.onRenameItem !=
                                                                    null &&
                                                                _editingItemId !=
                                                                    item.id)
                                                              IconButton(
                                                                key: ValueKey(
                                                                  'rename-item-${item.id}',
                                                                ),
                                                                icon: const Icon(
                                                                  Icons
                                                                      .edit_outlined,
                                                                  size: 13,
                                                                ),
                                                                color:
                                                                    t.inkMuted,
                                                                hoverColor:
                                                                    t.hoverFill,
                                                                tooltip:
                                                                    'Rename capture',
                                                                onPressed: () =>
                                                                    _startInlineRename(
                                                                      item,
                                                                    ),
                                                                padding:
                                                                    EdgeInsets
                                                                        .zero,
                                                                // Gene - Nov, 8, 2026: Added M3 shrinkWrap style so gallery card action buttons do not overflow the 138x84 card under useMaterial3: true
                                                                style: IconButton.styleFrom(
                                                                  minimumSize:
                                                                      const Size(
                                                                        18,
                                                                        18,
                                                                      ),
                                                                  maximumSize:
                                                                      const Size(
                                                                        20,
                                                                        20,
                                                                      ),
                                                                  padding:
                                                                      EdgeInsets
                                                                          .zero,
                                                                  tapTargetSize:
                                                                      MaterialTapTargetSize
                                                                          .shrinkWrap,
                                                                ),
                                                                constraints:
                                                                    const BoxConstraints(
                                                                      minWidth:
                                                                          18,
                                                                      minHeight:
                                                                          18,
                                                                    ),
                                                              ),
                                                            IconButton(
                                                              icon: const Icon(
                                                                Icons
                                                                    .folder_open_rounded,
                                                                size: 14,
                                                              ),
                                                              color: t.inkMuted,
                                                              hoverColor:
                                                                  t.hoverFill,
                                                              tooltip:
                                                                  'Reveal in Finder / Explorer',
                                                              onPressed: () {
                                                                if (widget
                                                                        .onRevealItemInFolder !=
                                                                    null) {
                                                                  widget
                                                                      .onRevealItemInFolder!(
                                                                    item,
                                                                  );
                                                                } else {
                                                                  StorageService.revealFileInFolder(
                                                                    item.filePath,
                                                                  );
                                                                }
                                                              },
                                                              padding:
                                                                  EdgeInsets
                                                                      .zero,
                                                              style: IconButton.styleFrom(
                                                                minimumSize:
                                                                    const Size(
                                                                      18,
                                                                      18,
                                                                    ),
                                                                maximumSize:
                                                                    const Size(
                                                                      20,
                                                                      20,
                                                                    ),
                                                                padding:
                                                                    EdgeInsets
                                                                        .zero,
                                                                tapTargetSize:
                                                                    MaterialTapTargetSize
                                                                        .shrinkWrap,
                                                              ),
                                                              constraints:
                                                                  const BoxConstraints(
                                                                    minWidth:
                                                                        20,
                                                                    minHeight:
                                                                        20,
                                                                  ),
                                                            ),
                                                            IconButton(
                                                              icon: const Icon(
                                                                Icons
                                                                    .delete_outline_rounded,
                                                                size: 14,
                                                              ),
                                                              // The one sanctioned chromatic
                                                              // exception — never an inline red.
                                                              color: t.controlForeground(
                                                                active: false,
                                                                tone:
                                                                    SnipControlTone
                                                                        .danger,
                                                              ),
                                                              hoverColor: t
                                                                  .danger
                                                                  .withValues(
                                                                    alpha: 0.15,
                                                                  ),
                                                              tooltip:
                                                                  'Delete Capture',
                                                              onPressed: () =>
                                                                  widget
                                                                      .onDeleteItem(
                                                                        item,
                                                                      ),
                                                              padding:
                                                                  EdgeInsets
                                                                      .zero,
                                                              style: IconButton.styleFrom(
                                                                minimumSize:
                                                                    const Size(
                                                                      18,
                                                                      18,
                                                                    ),
                                                                maximumSize:
                                                                    const Size(
                                                                      20,
                                                                      20,
                                                                    ),
                                                                padding:
                                                                    EdgeInsets
                                                                        .zero,
                                                                tapTargetSize:
                                                                    MaterialTapTargetSize
                                                                        .shrinkWrap,
                                                              ),
                                                              constraints:
                                                                  const BoxConstraints(
                                                                    minWidth:
                                                                        20,
                                                                    minHeight:
                                                                        20,
                                                                  ),
                                                            ),
                                                          ],
                                                        ),
                                                      ],
                                                    ],
                                                  );
                                                },
                                              ),
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  );
                                },
                              ),
                      );
                    },
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
