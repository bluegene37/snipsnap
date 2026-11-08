import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../models/capture_item.dart';
import '../services/storage_service.dart';
import '../utils/image_eviction.dart';
import '../utils/snip_theme.dart';

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

  /// Bumped whenever the active capture's file is rewritten in place (crop,
  /// flatten, flood fill, undo/redo). Keys the active item's thumbnail so it
  /// re-decodes — the other thumbnails keep their cached bitmaps untouched.
  final int imageRevision;

  // Gene - Oct, 27, 2026: Added isOpen and onToggleCollapse to support keeping the header bar visible when collapsed.
  final bool isOpen;
  final VoidCallback? onToggleCollapse;

  // Gene - Oct, 27, 2026: Updated constructor to accept isOpen and onToggleCollapse.
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
  //   this.zoomScale = 1.0,
  //   this.onZoomScaleChanged,
  //   this.imageRevision = 0,
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
    this.imageRevision = 0,
    this.isOpen = true,
    this.onToggleCollapse,
  });

  @override
  State<GallerySidebar> createState() => _GallerySidebarState();
}

class _GallerySidebarState extends State<GallerySidebar> {
  GalleryMediaFilter _filter = GalleryMediaFilter.all;
  String? _editingItemId;
  final TextEditingController _renameController = TextEditingController();

  @override
  void dispose() {
    _renameController.dispose();
    super.dispose();
  }

  List<CaptureItem> get _filteredItems {
    return switch (_filter) {
      GalleryMediaFilter.all => widget.items,
      GalleryMediaFilter.images =>
        widget.items.where((i) => !i.isVideo).toList(),
      GalleryMediaFilter.videos =>
        widget.items.where((i) => i.isVideo).toList(),
    };
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

  void _commitInlineRename(CaptureItem item) {
    final trimmed = _renameController.text.trim();
    setState(() {
      _editingItemId = null;
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
                          onTap: () => setState(() => _filter = entry.$1),
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
                      onPressed: widget.zoomScale > 0.2
                          ? () => widget.onZoomScaleChanged!(
                              (widget.zoomScale - 0.25).clamp(0.2, 4.0),
                            )
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
                        child: Slider(
                          value: widget.zoomScale.clamp(0.2, 4.0),
                          min: 0.2,
                          max: 4.0,
                          onChanged: widget.onZoomScaleChanged,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.add_rounded, size: 14),
                      color: widget.zoomScale < 4.0 ? t.ink : t.inkFaint,
                      tooltip: 'Zoom In',
                      onPressed: widget.zoomScale < 4.0
                          ? () => widget.onZoomScaleChanged!(
                              (widget.zoomScale + 0.25).clamp(0.2, 4.0),
                            )
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
            // Old implementation:
            // Expanded(
            //   child: items.isEmpty
            if (widget.isOpen)
              Expanded(
                child: filtered.isEmpty
                    ? Center(
                        child: Text(
                          widget.items.isEmpty
                              ? 'No captures yet. Click "Snip" to start!'
                              : 'No matching items in this filter.',
                          textAlign: TextAlign.center,
                          // Was a fixed Colors.white38 regardless of mode — same
                          // pre-existing light-mode legibility bug as the close
                          // button above (white38 on near-white is unreadable).
                          style: TextStyle(color: t.inkMuted, fontSize: 13),
                        ),
                      )
                    : ListView.builder(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        itemCount: filtered.length,
                        itemBuilder: (context, index) {
                          final item = filtered[index];
                          final isSelected = widget.activeItem?.id == item.id;
                          final displayPath =
                              (item.isVideo &&
                                  item.thumbnailPath != null &&
                                  item.thumbnailPath!.isNotEmpty)
                              ? item.thumbnailPath!
                              : item.filePath;
                          final fileExists =
                              !item.isVideo
                              ? File(displayPath).existsSync()
                              : (item.thumbnailPath != null &&
                                    File(item.thumbnailPath!).existsSync());

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
                              ? Border.all(color: t.borderStrong, width: 2.0)
                              : Border.all(color: t.border, width: t.hairline);

                          return Container(
                            width: 150,
                            margin: const EdgeInsets.only(right: 8),
                            decoration: BoxDecoration(
                              color: cardBg,
                              borderRadius: BorderRadius.circular(6),
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
                                borderRadius: BorderRadius.circular(6),
                                hoverColor: t.hoverFill,
                                onTap: () => widget.onSelectItem(item),
                                child: Padding(
                                  padding: const EdgeInsets.all(5),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      // Thumbnail Image + Extension Pill Badge
                                      Expanded(
                                        child: Stack(
                                          children: [
                                            Positioned.fill(
                                              child: ClipRRect(
                                                borderRadius:
                                                    BorderRadius.circular(4),
                                                child: ColoredBox(
                                                  color: t.canvas,
                                                  child: fileExists
                                                      ? Image.file(
                                                          File(displayPath),
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
                                                          fit: BoxFit.cover,
                                                          // Thumbnails are ~170px
                                                          // wide; decoding the full
                                                          // Retina capture for each
                                                          // one wastes memory and
                                                          // makes cache misses
                                                          // visibly janky.
                                                          cacheWidth:
                                                              kGalleryThumbnailCacheWidth,
                                                          gaplessPlayback: true,
                                                          errorBuilder:
                                                              (
                                                                ctx,
                                                                err,
                                                                stack,
                                                              ) => Center(
                                                                child: Icon(
                                                                  Icons
                                                                      .broken_image_rounded,
                                                                  color: t
                                                                      .inkMuted,
                                                                  size: 20,
                                                                ),
                                                              ),
                                                        )
                                                      : Center(
                                                          child: Icon(
                                                            item.isVideo
                                                                ? Icons
                                                                      .videocam_rounded
                                                                : Icons
                                                                      .image_not_supported_rounded,
                                                            color: t.inkMuted,
                                                            size: 20,
                                                          ),
                                                        ),
                                                ),
                                              ),
                                            ),
                                            // Gene - Nov, 08, 2026: Center play icon and bottom-left duration badge for video items.
                                            if (item.isVideo) ...[
                                              Center(
                                                child: DecoratedBox(
                                                  decoration: BoxDecoration(
                                                    color: t.ink,
                                                    shape: BoxShape.circle,
                                                  ),
                                                  child: Padding(
                                                    padding:
                                                        const EdgeInsets.all(3),
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
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          3,
                                                        ),
                                                  ),
                                                  child: Padding(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          horizontal: 4,
                                                          vertical: 1,
                                                        ),
                                                    child: Text(
                                                      _formatDurationBadge(
                                                        item.durationMs,
                                                      ),
                                                      style: TextStyle(
                                                        color: t.onActive,
                                                        fontSize: 9,
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
                                                  padding: const EdgeInsets.all(
                                                    2,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    color: t.ink,
                                                    shape: BoxShape.circle,
                                                    boxShadow: [
                                                      BoxShadow(
                                                        color: Colors.black
                                                            .withValues(
                                                              alpha: 0.25,
                                                            ),
                                                        blurRadius: 3,
                                                        offset: const Offset(
                                                          0,
                                                          1,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                  child: Icon(
                                                    Icons.check_rounded,
                                                    size: 11,
                                                    color: t.onActive,
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
                                                      horizontal: 4,
                                                      vertical: 1,
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
                                                      BorderRadius.circular(3),
                                                ),
                                                child: Text(
                                                  p
                                                      .extension(item.filePath)
                                                      .replaceAll('.', ''),
                                                  style: TextStyle(
                                                    color: t.onActive,
                                                    fontSize: 9,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      // Title and delete button
                                      Row(
                                        children: [
                                          Expanded(
                                            child: _editingItemId == item.id
                                                ? SizedBox(
                                                    height: 22,
                                                    child: TextField(
                                                      controller:
                                                          _renameController,
                                                      autofocus: true,
                                                      style: TextStyle(
                                                        color: t.ink,
                                                        fontSize: 10,
                                                        fontWeight:
                                                            FontWeight.w600,
                                                      ),
                                                      decoration:
                                                          InputDecoration(
                                                            isDense: true,
                                                            contentPadding:
                                                                const EdgeInsets.symmetric(
                                                                  horizontal: 4,
                                                                  vertical: 2,
                                                                ),
                                                            border:
                                                                OutlineInputBorder(
                                                                  borderSide:
                                                                      BorderSide(
                                                                        color:
                                                                            t.borderStrong,
                                                                      ),
                                                                ),
                                                          ),
                                                      onSubmitted: (_) =>
                                                          _commitInlineRename(
                                                            item,
                                                          ),
                                                      onTapOutside: (_) =>
                                                          _commitInlineRename(
                                                            item,
                                                          ),
                                                    ),
                                                  )
                                                : GestureDetector(
                                                    onSecondaryTap:
                                                        widget.onRenameItem !=
                                                            null
                                                        ? () =>
                                                              _startInlineRename(
                                                                item,
                                                              )
                                                        : null,
                                                    child: Column(
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .start,
                                                      children: [
                                                        Text(
                                                          item.title,
                                                          maxLines: 1,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                          style: TextStyle(
                                                            color: t.ink,
                                                            fontSize: 10,
                                                            fontWeight:
                                                                FontWeight.w600,
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
                                          if (widget.onRenameItem != null &&
                                              _editingItemId != item.id)
                                            IconButton(
                                              key: ValueKey(
                                                'rename-item-${item.id}',
                                              ),
                                              icon: const Icon(
                                                Icons.edit_outlined,
                                                size: 13,
                                              ),
                                              color: t.inkMuted,
                                              hoverColor: t.hoverFill,
                                              tooltip: 'Rename capture',
                                              onPressed: () =>
                                                  _startInlineRename(item),
                                              padding: EdgeInsets.zero,
                                              // Gene - Nov, 8, 2026: Added M3 shrinkWrap style so gallery card action buttons do not overflow the 138x84 card under useMaterial3: true
                                              style: IconButton.styleFrom(
                                                minimumSize: const Size(18, 18),
                                                maximumSize: const Size(20, 20),
                                                padding: EdgeInsets.zero,
                                                tapTargetSize:
                                                    MaterialTapTargetSize
                                                        .shrinkWrap,
                                              ),
                                              constraints: const BoxConstraints(
                                                minWidth: 18,
                                                minHeight: 18,
                                              ),
                                            ),
                                          IconButton(
                                            icon: const Icon(
                                              Icons.folder_open_rounded,
                                              size: 14,
                                            ),
                                            color: t.inkMuted,
                                            hoverColor: t.hoverFill,
                                            tooltip:
                                                'Reveal in Finder / Explorer',
                                            onPressed: () {
                                              if (widget.onRevealItemInFolder !=
                                                  null) {
                                                widget.onRevealItemInFolder!(
                                                  item,
                                                );
                                              } else {
                                                StorageService.revealFileInFolder(
                                                  item.filePath,
                                                );
                                              }
                                            },
                                            padding: EdgeInsets.zero,
                                            style: IconButton.styleFrom(
                                              minimumSize: const Size(18, 18),
                                              maximumSize: const Size(20, 20),
                                              padding: EdgeInsets.zero,
                                              tapTargetSize:
                                                  MaterialTapTargetSize
                                                      .shrinkWrap,
                                            ),
                                            constraints: const BoxConstraints(
                                              minWidth: 20,
                                              minHeight: 20,
                                            ),
                                          ),
                                          IconButton(
                                            icon: const Icon(
                                              Icons.delete_outline_rounded,
                                              size: 14,
                                            ),
                                            // The one sanctioned chromatic
                                            // exception — never an inline red.
                                            color: t.controlForeground(
                                              active: false,
                                              tone: SnipControlTone.danger,
                                            ),
                                            hoverColor: t.danger.withValues(
                                              alpha: 0.15,
                                            ),
                                            tooltip: 'Delete Capture',
                                            onPressed: () =>
                                                widget.onDeleteItem(item),
                                            padding: EdgeInsets.zero,
                                            style: IconButton.styleFrom(
                                              minimumSize: const Size(18, 18),
                                              maximumSize: const Size(20, 20),
                                              padding: EdgeInsets.zero,
                                              tapTargetSize:
                                                  MaterialTapTargetSize
                                                      .shrinkWrap,
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
                        },
                      ),
              ),
          ],
        ),
      ),
    );
  }
}
