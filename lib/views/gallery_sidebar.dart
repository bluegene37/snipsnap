import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../models/capture_item.dart';
import '../services/storage_service.dart';
import '../utils/snip_theme.dart';

class GallerySidebar extends StatelessWidget {
  final List<CaptureItem> items;
  final CaptureItem? activeItem;
  final ValueChanged<CaptureItem> onSelectItem;
  final ValueChanged<CaptureItem> onDeleteItem;
  final VoidCallback onClose;
  final VoidCallback? onOpenLibraryLocation;
  final ValueChanged<CaptureItem>? onRevealItemInFolder;

  final double zoomScale;
  final ValueChanged<double>? onZoomScaleChanged;

  const GallerySidebar({
    super.key,
    required this.items,
    required this.activeItem,
    required this.onSelectItem,
    required this.onDeleteItem,
    required this.onClose,
    this.onOpenLibraryLocation,
    this.onRevealItemInFolder,
    this.zoomScale = 1.0,
    this.onZoomScaleChanged,
  });

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

    return Container(
      height: 145,
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(
          top: BorderSide(color: t.border),
        ),
      ),
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
                Icon(Icons.photo_library_rounded, color: t.ink, size: 15),
                const SizedBox(width: 6),
                Text(
                  'Screenshots',
                  style: TextStyle(color: t.ink, fontSize: 12, fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 10),

                // Open Screenshots Library Folder Button
                Tooltip(
                  message: 'Open Screenshots Library Folder in Finder/Explorer',
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(6),
                      hoverColor: t.hoverFill,
                      onTap: () {
                        if (onOpenLibraryLocation != null) {
                          onOpenLibraryLocation!();
                        } else {
                          StorageService.openLibraryFolder();
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: t.surfaceRaised,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: t.border),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.folder_open_rounded, size: 13, color: t.ink),
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

                const Spacer(),

                // Middle: Zoom Slider Controls in the Sub-Header Bar of Screenshot History Tray
                if (onZoomScaleChanged != null) ...[
                  IconButton(
                    icon: const Icon(Icons.remove_rounded, size: 14),
                    // inkFaint, not inkMuted, for the *disabled* edge — the
                    // token doc reserves inkFaint for dividers and disabled
                    // text, and header_bar.dart's identical zoom stepper
                    // already uses it. inkMuted is the secondary-but-enabled
                    // tone and stays that way at the reset button below.
                    color: zoomScale > 0.2 ? t.ink : t.inkFaint,
                    tooltip: 'Zoom Out',
                    onPressed: zoomScale > 0.2
                        ? () => onZoomScaleChanged!((zoomScale - 0.25).clamp(0.2, 4.0))
                        : null,
                    constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                    padding: EdgeInsets.zero,
                  ),
                  SizedBox(
                    width: 240,
                    child: SliderTheme(
                      data: sliderThemeData,
                      child: Slider(
                        value: zoomScale.clamp(0.2, 4.0),
                        min: 0.2,
                        max: 4.0,
                        onChanged: onZoomScaleChanged,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_rounded, size: 14),
                    color: zoomScale < 4.0 ? t.ink : t.inkFaint,
                    tooltip: 'Zoom In',
                    onPressed: zoomScale < 4.0
                        ? () => onZoomScaleChanged!((zoomScale + 0.25).clamp(0.2, 4.0))
                        : null,
                    constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                    padding: EdgeInsets.zero,
                  ),
                  const SizedBox(width: 4),
                  Tooltip(
                    message: 'Reset Zoom to 100%',
                    child: InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: () => onZoomScaleChanged!(1.0),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        // A non-exclusive "selected" readout, not the app's
                        // one exclusive-active control — controlDecoration's
                        // non-exclusive shape (selectedFill highlight, not
                        // an activeFill knockout plate).
                        decoration: t.controlDecoration(
                          active: zoomScale == 1.0,
                          exclusive: false,
                          radius: 6,
                        ),
                        child: Text(
                          '${(zoomScale * 100).round()}%',
                          style: TextStyle(
                            color: t.controlForeground(active: zoomScale == 1.0, exclusive: false),
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
                    icon: const Icon(Icons.center_focus_strong_rounded, size: 14),
                    // Deliberately inkMuted, unlike the two steppers above:
                    // this button is never disabled (onPressed is
                    // unconditional). The dimmer tone says "you are not at
                    // 100%", an enabled secondary state — inkFaint would both
                    // lie about interactivity and drop to 2.72:1 in light.
                    color: zoomScale == 1.0 ? t.ink : t.inkMuted,
                    tooltip: 'Reset Zoom (100%)',
                    onPressed: () => onZoomScaleChanged!(1.0),
                    constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                    padding: EdgeInsets.zero,
                  ),
                ],

                const Spacer(),

                // Right: Resolution & Close Button
                if (activeItem != null && activeItem!.width > 0 && activeItem!.height > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: t.surfaceRaised,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: t.border),
                    ),
                    child: Text(
                      '${activeItem!.width} x ${activeItem!.height}',
                      style: TextStyle(color: t.inkMuted, fontSize: 11, fontFamily: 'monospace'),
                    ),
                  ),
                const SizedBox(width: 8),

                // Right: Controls & Hide Button

                IconButton(
                  // Was a fixed Colors.white54 regardless of mode — already
                  // a pre-existing legibility bug in light mode (white54 on
                  // a near-white sub-header bar is nearly invisible).
                  icon: Icon(Icons.close_rounded, color: t.inkMuted, size: 16),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                  tooltip: 'Hide Screenshots Tray',
                  onPressed: onClose,
                ),
              ],
            ),
          ),

          // Horizontal Captures List
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Text(
                      'No captures yet. Click "Snip" to start!',
                      textAlign: TextAlign.center,
                      // Was a fixed Colors.white38 regardless of mode — same
                      // pre-existing light-mode legibility bug as the close
                      // button above (white38 on near-white is unreadable).
                      style: TextStyle(color: t.inkMuted, fontSize: 13),
                    ),
                  )
                : ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final item = items[index];
                      final isSelected = activeItem?.id == item.id;
                      final fileExists = File(item.filePath).existsSync();

                      // The selected capture is a non-exclusive highlight
                      // (selectedFill, ink foreground) — not the exclusive
                      // ink/onActive knockout plate, which stays reserved
                      // for the tool sidebar's single active tool. Rows are
                      // borderless: no separate hairline strengthens on
                      // selection or hover, only the fill changes (hover is
                      // wired below via InkWell's own hoverColor, painted
                      // into the transparent Material that sits between this
                      // Container and that InkWell — see the note there).
                      final cardBg = isSelected ? t.selectedFill : t.surfaceRaised;

                      return Container(
                        width: 150,
                        margin: const EdgeInsets.only(right: 8),
                        decoration: BoxDecoration(
                          color: cardBg,
                          borderRadius: BorderRadius.circular(6),
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
                            onTap: () => onSelectItem(item),
                            child: Padding(
                              padding: const EdgeInsets.all(5),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // Thumbnail Image + Extension Pill Badge
                                  Expanded(
                                    child: Stack(
                                      children: [
                                        Positioned.fill(
                                          child: ClipRRect(
                                            borderRadius: BorderRadius.circular(4),
                                            child: Container(
                                              color: t.canvas,
                                              child: fileExists
                                                  ? Image.file(
                                                      File(item.filePath),
                                                      fit: BoxFit.cover,
                                                      errorBuilder: (ctx, err, stack) => Center(
                                                        child: Icon(Icons.broken_image_rounded,
                                                            color: t.inkMuted, size: 20),
                                                      ),
                                                    )
                                                  : Center(
                                                      child: Icon(Icons.image_not_supported_rounded,
                                                          color: t.inkMuted, size: 20),
                                                    ),
                                            ),
                                          ),
                                        ),
                                        // Snagit-style Extension Badge in bottom right
                                        Positioned(
                                          bottom: 3,
                                          right: 3,
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
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
                                              borderRadius: BorderRadius.circular(3),
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
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  // Title and delete button
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
                                                fontSize: 10,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            Text(
                                              _formatTime(item.createdAt),
                                              style: TextStyle(
                                                color: t.inkMuted,
                                                fontSize: 9,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                       IconButton(
                                         icon: const Icon(Icons.folder_open_rounded, size: 14),
                                         color: t.inkMuted,
                                         hoverColor: t.hoverFill,
                                         tooltip: 'Reveal in Finder / Explorer',
                                         onPressed: () {
                                           if (onRevealItemInFolder != null) {
                                             onRevealItemInFolder!(item);
                                           } else {
                                             StorageService.revealFileInFolder(item.filePath);
                                           }
                                         },
                                         padding: EdgeInsets.zero,
                                         constraints:
                                             const BoxConstraints(minWidth: 20, minHeight: 20),
                                       ),
                                       IconButton(
                                         icon: const Icon(Icons.delete_outline_rounded, size: 14),
                                         // The one sanctioned chromatic
                                         // exception — never an inline red.
                                         color: t.controlForeground(
                                           active: false,
                                           tone: SnipControlTone.danger,
                                         ),
                                         hoverColor: t.danger.withValues(alpha: 0.15),
                                         tooltip: 'Delete Capture',
                                         onPressed: () => onDeleteItem(item),
                                         padding: EdgeInsets.zero,
                                         constraints:
                                             const BoxConstraints(minWidth: 20, minHeight: 20),
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
    );
  }
}
