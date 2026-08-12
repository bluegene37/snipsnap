import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../models/capture_item.dart';
import '../utils/constants.dart';

class GallerySidebar extends StatelessWidget {
  final List<CaptureItem> items;
  final CaptureItem? activeItem;
  final ValueChanged<CaptureItem> onSelectItem;
  final ValueChanged<CaptureItem> onDeleteItem;
  final VoidCallback onClose;
  final bool isDarkMode;

  final double zoomScale;
  final ValueChanged<double>? onZoomScaleChanged;

  const GallerySidebar({
    super.key,
    required this.items,
    required this.activeItem,
    required this.onSelectItem,
    required this.onDeleteItem,
    required this.onClose,
    this.isDarkMode = true,
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
    final sidebarBg = isDarkMode ? AppColors.sidebarBg : AppColors.sidebarBgLight;
    final headerBg = isDarkMode ? AppColors.darkSurface : AppColors.lightSurface;
    final textColor = isDarkMode ? Colors.white : Colors.black87;
    final subTextColor = isDarkMode ? Colors.white54 : Colors.black54;
    final borderColor = isDarkMode ? Colors.white10 : Colors.black12;

    return Container(
      height: 145,
      decoration: BoxDecoration(
        color: sidebarBg,
        border: Border(
          top: BorderSide(color: borderColor),
        ),
      ),
      child: Column(
        children: [
          // Snagit-style Tray Sub-Header Bar
          Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: headerBg,
              border: Border(bottom: BorderSide(color: borderColor)),
            ),
            child: Row(
              children: [
                // Screenshots Gallery Header
                const Icon(Icons.photo_library_rounded, color: AppColors.accent, size: 15),
                const SizedBox(width: 6),
                Text(
                  'Screenshots',
                  style: TextStyle(color: textColor, fontSize: 12, fontWeight: FontWeight.bold),
                ),

                const Spacer(),

                // Middle: Zoom Slider Controls in the Sub-Header Bar of Screenshot History Tray
                if (onZoomScaleChanged != null) ...[
                  IconButton(
                    icon: const Icon(Icons.remove_rounded, size: 14),
                    color: zoomScale > 0.2 ? textColor : subTextColor,
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
                      data: SliderThemeData(
                        activeTrackColor: AppColors.accent,
                        inactiveTrackColor: isDarkMode ? Colors.white24 : Colors.black12,
                        thumbColor: AppColors.accent,
                        trackHeight: 3,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                      ),
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
                    color: zoomScale < 4.0 ? textColor : subTextColor,
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
                        decoration: BoxDecoration(
                          color: zoomScale == 1.0
                              ? AppColors.accent.withValues(alpha: 0.2)
                              : (isDarkMode ? Colors.white10 : Colors.black12),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: zoomScale == 1.0 ? AppColors.accent : borderColor,
                          ),
                        ),
                        child: Text(
                          '${(zoomScale * 100).round()}%',
                          style: TextStyle(
                            color: zoomScale == 1.0 ? AppColors.accent : textColor,
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
                    color: zoomScale == 1.0 ? AppColors.accent : subTextColor,
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
                      color: Colors.black26,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '${activeItem!.width} x ${activeItem!.height}',
                      style: const TextStyle(color: Colors.white54, fontSize: 11, fontFamily: 'monospace'),
                    ),
                  ),
                const SizedBox(width: 8),

                // Right: Controls & Hide Button

                IconButton(
                  icon: const Icon(Icons.close_rounded, color: Colors.white54, size: 16),
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
                ? const Center(
                    child: Text(
                      'No captures yet. Click "Snip" to start!',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white38, fontSize: 13),
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

                      final cardBg = isSelected
                          ? (isDarkMode ? AppColors.darkSurfaceVariant : AppColors.lightSurfaceVariant)
                          : (isDarkMode ? AppColors.darkSurface.withValues(alpha: 0.5) : AppColors.lightSurface);
                      final cardBorder = isSelected
                          ? AppColors.accent
                          : (isDarkMode ? Colors.white.withValues(alpha: 0.08) : Colors.black.withValues(alpha: 0.08));

                      return Container(
                        width: 150,
                        margin: const EdgeInsets.only(right: 8),
                        decoration: BoxDecoration(
                          color: cardBg,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: cardBorder,
                            width: isSelected ? 2.0 : 1,
                          ),
                        ),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(6),
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
                                            color: isDarkMode ? Colors.black26 : Colors.black12,
                                            child: fileExists
                                                ? Image.file(
                                                    File(item.filePath),
                                                    fit: BoxFit.cover,
                                                    errorBuilder: (ctx, err, stack) => Center(
                                                      child: Icon(Icons.broken_image_rounded,
                                                          color: subTextColor, size: 20),
                                                    ),
                                                  )
                                                : Center(
                                                    child: Icon(Icons.image_not_supported_rounded,
                                                        color: subTextColor, size: 20),
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
                                            color: Colors.black.withValues(alpha: 0.75),
                                            borderRadius: BorderRadius.circular(3),
                                          ),
                                          child: Text(
                                            p.extension(item.filePath).replaceAll('.', ''),
                                            style: const TextStyle(
                                              color: Colors.white,
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
                                              color: textColor,
                                              fontSize: 10,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          Text(
                                            _formatTime(item.createdAt),
                                            style: TextStyle(
                                              color: subTextColor,
                                              fontSize: 9,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.delete_outline_rounded, size: 14),
                                      color: subTextColor,
                                      hoverColor: Colors.redAccent.withValues(alpha: 0.2),
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
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
