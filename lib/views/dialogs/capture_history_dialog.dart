// Gene - Nov, 25, 2026: Added CaptureHistoryDialog to browse all/older captures grouped by calendar date or jump to the Captures folder.
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../../models/capture_item.dart';
import '../../services/storage_service.dart';
import '../../utils/capture_date_group.dart';
import '../../utils/image_eviction.dart';
import '../../utils/snip_theme.dart';
import '../gallery_sidebar.dart' show GalleryMediaFilter;

typedef ArchiveHistoryPageLoader =
    Future<({List<CaptureItem> items, int dbCount, bool hasMore})> Function({
      DateTime? before,
      required int limit,
      required int offset,
    });

class CaptureHistoryDialog extends StatefulWidget {
  final DateTime recentCutoff;
  final int olderCount;
  final CaptureItem? activeItem;
  final int imageRevision;
  final ValueChanged<CaptureItem> onSelectItem;
  final Future<void> Function(CaptureItem) onDeleteItem;
  final VoidCallback? onOpenLibraryLocation;
  final ValueChanged<CaptureItem>? onRevealItemInFolder;
  final ArchiveHistoryPageLoader? loadPage;

  @visibleForTesting
  final DateTime? nowOverride;

  const CaptureHistoryDialog({
    super.key,
    required this.recentCutoff,
    required this.olderCount,
    this.activeItem,
    this.imageRevision = 0,
    required this.onSelectItem,
    required this.onDeleteItem,
    this.onOpenLibraryLocation,
    this.onRevealItemInFolder,
    this.loadPage,
    this.nowOverride,
  });

  @override
  State<CaptureHistoryDialog> createState() => _CaptureHistoryDialogState();
}

class _CaptureHistoryDialogState extends State<CaptureHistoryDialog> {
  static const int _pageSize = 60;

  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  final Map<String, bool> _fileExistsCache = <String, bool>{};
  final Set<String> _collapsedDayKeys = <String>{};
  final List<CaptureItem> _items = <CaptureItem>[];

  late bool _showOlderOnly;
  GalleryMediaFilter _mediaFilter = GalleryMediaFilter.all;
  String _searchQuery = '';
  int _dbOffset = 0;
  bool _hasMore = true;
  bool _isLoading = false;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _showOlderOnly = widget.olderCount > 0;
    _scrollController.addListener(_onScroll);
    _loadNextPage(reset: true);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients || _isLoading || !_hasMore) return;
    final pos = _scrollController.position;
    if (pos.maxScrollExtent > 0 && pos.pixels >= pos.maxScrollExtent - 250) {
      _loadNextPage();
    }
  }

  Future<void> _loadNextPage({bool reset = false}) async {
    if (!reset && (_isLoading || !_hasMore)) return;
    final generation = reset ? ++_loadGeneration : _loadGeneration;
    final offset = reset ? 0 : _dbOffset;
    setState(() {
      if (reset) {
        _items.clear();
        _dbOffset = 0;
        _hasMore = true;
      }
      _isLoading = true;
    });

    final loader = widget.loadPage ?? StorageService.loadArchiveHistoryPage;
    final page = await loader(
      before: _showOlderOnly ? widget.recentCutoff : null,
      limit: _pageSize,
      offset: offset,
    );
    if (!mounted || generation != _loadGeneration) return;

    final existingIds = _items.map((c) => c.id).toSet();
    final fresh = page.items.where((c) => !existingIds.contains(c.id)).toList();

    setState(() {
      _items.addAll(fresh);
      _dbOffset = offset + page.dbCount;
      _hasMore = page.hasMore;
      _isLoading = false;
    });
  }

  bool _cachedFileExists(String? path) {
    if (path == null || path.isEmpty) return false;
    return _fileExistsCache.putIfAbsent(path, () => File(path).existsSync());
  }

  List<CaptureItem> get _visibleItems {
    final query = _searchQuery.trim().toLowerCase();
    return _items.where((item) {
      final matchesMedia = switch (_mediaFilter) {
        GalleryMediaFilter.all => true,
        GalleryMediaFilter.images => !item.isVideo,
        GalleryMediaFilter.videos => item.isVideo,
      };
      if (!matchesMedia) return false;
      if (query.isEmpty) return true;
      if (item.title.toLowerCase().contains(query)) return true;
      final day = calendarDay(item.createdAt);
      final longLabel = formatDateGroupLongLabel(
        day,
        now: widget.nowOverride,
      ).toLowerCase();
      final key = formatDateGroupKey(day);
      return longLabel.contains(query) || key.contains(query);
    }).toList();
  }

  String _formatTime(DateTime date) {
    final hour = date.hour.toString().padLeft(2, '0');
    final minute = date.minute.toString().padLeft(2, '0');
    final second = date.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }

  String _formatDurationBadge(int durationMs) {
    final secs = (durationMs / 1000).round().clamp(0, 359999);
    final mins = secs ~/ 60;
    final rem = (secs % 60).toString().padLeft(2, '0');
    return '$mins:$rem';
  }

  Future<void> _handleDelete(CaptureItem item) async {
    await widget.onDeleteItem(item);
    if (!mounted) return;
    setState(() {
      _items.removeWhere((c) => c.id == item.id);
    });
  }

  void _openFolder() {
    if (widget.onOpenLibraryLocation != null) {
      widget.onOpenLibraryLocation!();
    } else {
      StorageService.openLibraryFolder();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = SnipTheme.of(context);
    final size = MediaQuery.sizeOf(context);
    final dialogWidth = math.min(920.0, size.width * 0.86);
    final dialogHeight = math.min(660.0, size.height * 0.82);

    final filtered = _visibleItems;
    final groups = groupCapturesByDate(filtered, now: widget.nowOverride);

    return Dialog(
      backgroundColor: t.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: t.border),
      ),
      child: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: Column(
          children: [
            // Header
            Container(
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: t.surfaceRaised,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(14),
                ),
                border: Border(bottom: BorderSide(color: t.border)),
              ),
              child: Row(
                children: [
                  Icon(Icons.history_rounded, color: t.ink, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    'Capture History',
                    style: TextStyle(
                      color: t.ink,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '${filtered.length} shown',
                    style: TextStyle(color: t.inkMuted, fontSize: 12),
                  ),
                  const Spacer(),
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      key: const ValueKey('history-dialog-open-folder'),
                      borderRadius: BorderRadius.circular(6),
                      hoverColor: t.hoverFill,
                      onTap: _openFolder,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: t.surface,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: t.border),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.folder_open_rounded,
                              size: 14,
                              color: t.ink,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Open Folder',
                              style: TextStyle(
                                color: t.ink,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    key: const ValueKey('history-dialog-close'),
                    icon: Icon(
                      Icons.close_rounded,
                      color: t.inkMuted,
                      size: 18,
                    ),
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                    padding: EdgeInsets.zero,
                  ),
                ],
              ),
            ),

            // Toolbar: Scope toggle, media filter pills, search
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: t.surface,
                border: Border(bottom: BorderSide(color: t.border)),
              ),
              child: Row(
                children: [
                  for (final scope in const [
                    (true, 'Older (7d+)'),
                    (false, 'All Dates'),
                  ])
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          key: ValueKey(
                            scope.$1
                                ? 'history-scope-older'
                                : 'history-scope-all',
                          ),
                          borderRadius: BorderRadius.circular(6),
                          hoverColor: t.hoverFill,
                          onTap: () {
                            if (_showOlderOnly == scope.$1) return;
                            setState(() {
                              _showOlderOnly = scope.$1;
                            });
                            _loadNextPage(reset: true);
                          },
                          child: DecoratedBox(
                            decoration: t.controlDecoration(
                              active: _showOlderOnly == scope.$1,
                              exclusive: false,
                              radius: 6,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 5,
                              ),
                              child: Text(
                                scope.$2,
                                style: TextStyle(
                                  color: t.controlForeground(
                                    active: _showOlderOnly == scope.$1,
                                    exclusive: false,
                                  ),
                                  fontSize: 11.5,
                                  fontWeight: _showOlderOnly == scope.$1
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  Container(
                    width: 1,
                    height: 18,
                    margin: const EdgeInsets.symmetric(horizontal: 8),
                    color: t.border,
                  ),
                  for (final entry in const [
                    (GalleryMediaFilter.all, 'All'),
                    (GalleryMediaFilter.images, 'Images'),
                    (GalleryMediaFilter.videos, 'Videos'),
                  ])
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          key: ValueKey(
                            'history-dialog-filter-${entry.$1.name}',
                          ),
                          borderRadius: BorderRadius.circular(5),
                          hoverColor: t.hoverFill,
                          onTap: () => setState(() => _mediaFilter = entry.$1),
                          child: DecoratedBox(
                            decoration: t.controlDecoration(
                              active: _mediaFilter == entry.$1,
                              exclusive: false,
                              radius: 5,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 9,
                                vertical: 5,
                              ),
                              child: Text(
                                entry.$2,
                                style: TextStyle(
                                  color: t.controlForeground(
                                    active: _mediaFilter == entry.$1,
                                    exclusive: false,
                                  ),
                                  fontSize: 11.5,
                                  fontWeight: _mediaFilter == entry.$1
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  const Spacer(),
                  SizedBox(
                    width: 220,
                    height: 30,
                    child: TextField(
                      key: const ValueKey('history-dialog-search'),
                      controller: _searchController,
                      onChanged: (value) =>
                          setState(() => _searchQuery = value),
                      style: TextStyle(color: t.ink, fontSize: 12),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: 'Filter by title or date...',
                        hintStyle: TextStyle(color: t.inkMuted, fontSize: 11.5),
                        prefixIcon: Icon(
                          Icons.search_rounded,
                          size: 15,
                          color: t.inkMuted,
                        ),
                        suffixIcon: _searchQuery.isNotEmpty
                            ? IconButton(
                                icon: Icon(
                                  Icons.clear_rounded,
                                  size: 14,
                                  color: t.inkMuted,
                                ),
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() => _searchQuery = '');
                                },
                                padding: EdgeInsets.zero,
                              )
                            : null,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        filled: true,
                        fillColor: t.surfaceRaised,
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(6),
                          borderSide: BorderSide(color: t.border),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(6),
                          borderSide: BorderSide(color: t.borderStrong),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Body
            Expanded(
              child: _isLoading && _items.isEmpty
                  ? Center(
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: t.ink,
                        ),
                      ),
                    )
                  : groups.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.photo_library_outlined,
                            size: 28,
                            color: t.inkMuted,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _showOlderOnly && _items.isEmpty
                                ? 'No captures older than 7 days.'
                                : 'No matching captures found.',
                            style: TextStyle(color: t.inkMuted, fontSize: 13),
                          ),
                          if (_showOlderOnly && _items.isEmpty) ...[
                            const SizedBox(height: 10),
                            OutlinedButton(
                              onPressed: () {
                                setState(() => _showOlderOnly = false);
                                _loadNextPage(reset: true);
                              },
                              child: Text(
                                'Show All Dates',
                                style: TextStyle(color: t.ink, fontSize: 12),
                              ),
                            ),
                          ],
                        ],
                      ),
                    )
                  : CustomScrollView(
                      controller: _scrollController,
                      slivers: [
                        for (final group in groups) ...[
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                              child: Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  key: ValueKey(
                                    'history-dialog-group-${group.key}',
                                  ),
                                  borderRadius: BorderRadius.circular(6),
                                  hoverColor: t.hoverFill,
                                  onTap: () {
                                    setState(() {
                                      if (_collapsedDayKeys.contains(
                                        group.key,
                                      )) {
                                        _collapsedDayKeys.remove(group.key);
                                      } else {
                                        _collapsedDayKeys.add(group.key);
                                      }
                                    });
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 5,
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          _collapsedDayKeys.contains(group.key)
                                              ? Icons.chevron_right_rounded
                                              : Icons.expand_more_rounded,
                                          size: 16,
                                          color: t.inkMuted,
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          group.longLabel,
                                          style: TextStyle(
                                            color: t.ink,
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        DecoratedBox(
                                          decoration: BoxDecoration(
                                            color: t.selectedFill,
                                            borderRadius: BorderRadius.circular(
                                              10,
                                            ),
                                          ),
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 7,
                                              vertical: 1.5,
                                            ),
                                            child: Text(
                                              '${group.items.length}',
                                              style: TextStyle(
                                                color: t.ink,
                                                fontSize: 10.5,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          if (!_collapsedDayKeys.contains(group.key))
                            SliverPadding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              sliver: SliverGrid(
                                delegate: SliverChildBuilderDelegate((
                                  context,
                                  index,
                                ) {
                                  final item = group.items[index];
                                  return _buildCaptureCard(t, item);
                                }, childCount: group.items.length),
                                gridDelegate:
                                    const SliverGridDelegateWithMaxCrossAxisExtent(
                                      maxCrossAxisExtent: 190,
                                      mainAxisSpacing: 10,
                                      crossAxisSpacing: 10,
                                      childAspectRatio: 1.28,
                                    ),
                              ),
                            ),
                        ],
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            child: Center(
                              child: _isLoading
                                  ? SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: t.ink,
                                      ),
                                    )
                                  : _hasMore
                                  ? OutlinedButton(
                                      key: const ValueKey(
                                        'history-dialog-load-more',
                                      ),
                                      onPressed: () => _loadNextPage(),
                                      child: Text(
                                        'Load more',
                                        style: TextStyle(
                                          color: t.ink,
                                          fontSize: 12,
                                        ),
                                      ),
                                    )
                                  : Text(
                                      'End of history',
                                      style: TextStyle(
                                        color: t.inkMuted,
                                        fontSize: 11,
                                      ),
                                    ),
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCaptureCard(SnipTheme t, CaptureItem item) {
    final isSelected = widget.activeItem?.id == item.id;
    final displayPath =
        (item.isVideo &&
            item.thumbnailPath != null &&
            item.thumbnailPath!.isNotEmpty)
        ? item.thumbnailPath!
        : item.filePath;
    final fileExists = !item.isVideo
        ? _cachedFileExists(displayPath)
        : _cachedFileExists(item.thumbnailPath);

    return Container(
      decoration: BoxDecoration(
        color: isSelected ? t.selectedFill : t.surfaceRaised,
        borderRadius: BorderRadius.circular(8),
        border: isSelected
            ? Border.all(color: t.borderStrong, width: 2.0)
            : Border.all(color: t.border, width: t.hairline),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey('history-dialog-card-${item.id}'),
          borderRadius: BorderRadius.circular(8),
          hoverColor: t.hoverFill,
          onTap: () {
            widget.onSelectItem(item);
            Navigator.of(context).pop();
          },
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(5),
                          child: ColoredBox(
                            color: t.canvas,
                            child: fileExists
                                ? Image.file(
                                    File(displayPath),
                                    key: ValueKey(
                                      isSelected
                                          ? 'dlg:$displayPath#${widget.imageRevision}'
                                          : 'dlg:$displayPath',
                                    ),
                                    fit: BoxFit.cover,
                                    cacheWidth: kGalleryThumbnailCacheWidth,
                                    gaplessPlayback: true,
                                    errorBuilder: (ctx, err, stack) => Center(
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
                                      color: t.inkMuted,
                                      size: 20,
                                    ),
                                  ),
                          ),
                        ),
                      ),
                      if (item.isVideo) ...[
                        Center(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: t.ink,
                              shape: BoxShape.circle,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(3),
                              child: Icon(
                                Icons.play_arrow_rounded,
                                size: 14,
                                color: t.onActive,
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          bottom: 3,
                          left: 3,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: t.ink,
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 1,
                              ),
                              child: Text(
                                _formatDurationBadge(item.durationMs),
                                style: TextStyle(
                                  color: t.onActive,
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                      if (isSelected)
                        Positioned(
                          top: 4,
                          left: 4,
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                              color: t.ink,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.check_rounded,
                              size: 11,
                              color: t.onActive,
                            ),
                          ),
                        ),
                      Positioned(
                        bottom: 3,
                        right: 3,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: t.ink,
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 1,
                            ),
                            child: Text(
                              p.extension(item.filePath).replaceAll('.', ''),
                              style: TextStyle(
                                color: t.onActive,
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 5),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: t.ink,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            _formatTime(item.createdAt),
                            style: TextStyle(color: t.inkMuted, fontSize: 9.5),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      key: ValueKey('history-dialog-reveal-${item.id}'),
                      icon: const Icon(Icons.folder_open_rounded, size: 14),
                      color: t.inkMuted,
                      hoverColor: t.hoverFill,
                      tooltip: 'Reveal in Finder / Explorer',
                      onPressed: () {
                        if (widget.onRevealItemInFolder != null) {
                          widget.onRevealItemInFolder!(item);
                        } else {
                          StorageService.revealFileInFolder(item.filePath);
                        }
                      },
                      padding: EdgeInsets.zero,
                      style: IconButton.styleFrom(
                        minimumSize: const Size(20, 20),
                        maximumSize: const Size(22, 22),
                        padding: EdgeInsets.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      constraints: const BoxConstraints(
                        minWidth: 20,
                        minHeight: 20,
                      ),
                    ),
                    IconButton(
                      key: ValueKey('history-dialog-delete-${item.id}'),
                      icon: const Icon(Icons.delete_outline_rounded, size: 14),
                      color: t.controlForeground(
                        active: false,
                        tone: SnipControlTone.danger,
                      ),
                      hoverColor: t.danger.withValues(alpha: 0.15),
                      tooltip: 'Delete Capture',
                      onPressed: () => _handleDelete(item),
                      padding: EdgeInsets.zero,
                      style: IconButton.styleFrom(
                        minimumSize: const Size(20, 20),
                        maximumSize: const Size(22, 22),
                        padding: EdgeInsets.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      constraints: const BoxConstraints(
                        minWidth: 20,
                        minHeight: 20,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
