import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../../utils/constants.dart';

enum SaveFormat { png, jpg }

class SaveOptions {
  final String fileName;
  final SaveFormat format;
  final int quality;
  final String? customFolderPath;
  final double framingPadding;
  final double cornerRadius;
  final double shadowBlur;
  final int? gradientIndex;

  SaveOptions({
    required this.fileName,
    required this.format,
    this.quality = 90,
    this.customFolderPath,
    this.framingPadding = 0.0,
    this.cornerRadius = 0.0,
    this.shadowBlur = 0.0,
    this.gradientIndex,
  });
}

class SaveAsDialog extends StatefulWidget {
  final String initialName;
  final bool isDarkMode;
  final ValueChanged<SaveOptions> onConfirm;

  const SaveAsDialog({
    super.key,
    required this.initialName,
    this.isDarkMode = true,
    required this.onConfirm,
  });

  @override
  State<SaveAsDialog> createState() => _SaveAsDialogState();
}

class _SaveAsDialogState extends State<SaveAsDialog> {
  late TextEditingController _nameController;
  SaveFormat _selectedFormat = SaveFormat.png;
  double _jpgQuality = 90;
  String _selectedLocationKey = 'downloads';
  String? _customFolderPath;
  String _customFolderDisplay = '';
  final double _framingPadding = 0.0;
  final double _cornerRadius = 0.0;
  final bool _enableShadow = false;
  final int _selectedGradientIndex = 0;

  @override
  void initState() {
    super.initState();
    String clean = widget.initialName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '-').replaceAll(' ', '_');
    if (clean.toLowerCase().endsWith('.png')) {
      clean = clean.substring(0, clean.length - 4);
    } else if (clean.toLowerCase().endsWith('.jpg') || clean.toLowerCase().endsWith('.jpeg')) {
      clean = clean.substring(0, clean.length - 4);
    }
    _nameController = TextEditingController(text: clean);
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _pickCustomFolder() async {
    try {
      final selectedDir = await FilePicker.getDirectoryPath(
        dialogTitle: 'Select Target Save Folder',
      );
      if (selectedDir != null && selectedDir.isNotEmpty) {
        setState(() {
          _selectedLocationKey = 'custom';
          _customFolderPath = selectedDir;
          _customFolderDisplay = p.basename(selectedDir);
        });
      }
    } catch (e) {
      debugPrint('SnipSnap pick custom folder error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final bgColor = widget.isDarkMode ? AppColors.darkSurface : AppColors.lightSurface;
    final textColor = widget.isDarkMode ? Colors.white : Colors.black87;
    final subColor = widget.isDarkMode ? Colors.white70 : Colors.black54;
    final fieldBg = widget.isDarkMode ? AppColors.darkSurfaceVariant : AppColors.lightSurfaceVariant;
    final borderColor = widget.isDarkMode ? Colors.white12 : Colors.black12;

    return AlertDialog(
      backgroundColor: bgColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      contentPadding: EdgeInsets.zero,
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header Title
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
              child: Row(
                children: [
                  const Icon(Icons.download_rounded, color: AppColors.accent, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    'Save Screenshot As',
                    style: TextStyle(color: textColor, fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: borderColor),

            // Form Inputs Section: Save As & Where
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 1. Save As Filename Field
                  _buildFormRow(
                    label: 'Save As:',
                    textColor: subColor,
                    child: TextField(
                      controller: _nameController,
                      style: TextStyle(color: textColor, fontSize: 13),
                      decoration: InputDecoration(
                        isDense: true,
                        filled: true,
                        fillColor: fieldBg,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(6),
                          borderSide: BorderSide(color: borderColor),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(6),
                          borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // 2. Where Location Selector
                  _buildFormRow(
                    label: 'Where:',
                    textColor: subColor,
                    child: Row(
                      children: [
                        Expanded(
                          child: Container(
                            height: 34,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            decoration: BoxDecoration(
                              color: fieldBg,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: borderColor),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                value: _selectedLocationKey,
                                isExpanded: true,
                                icon: Icon(Icons.unfold_more_rounded, size: 16, color: subColor),
                                dropdownColor: fieldBg,
                                style: TextStyle(color: textColor, fontSize: 13),
                                items: [
                                  DropdownMenuItem(
                                    value: 'downloads',
                                    child: Row(
                                      children: const [
                                        Icon(Icons.folder_rounded, size: 16, color: Color(0xFFFFC107)),
                                        SizedBox(width: 8),
                                        Text('Downloads'),
                                      ],
                                    ),
                                  ),
                                  DropdownMenuItem(
                                    value: 'desktop',
                                    child: Row(
                                      children: const [
                                        Icon(Icons.desktop_windows_rounded, size: 16, color: Color(0xFF4CAF50)),
                                        SizedBox(width: 8),
                                        Text('Desktop'),
                                      ],
                                    ),
                                  ),
                                  DropdownMenuItem(
                                    value: 'documents',
                                    child: Row(
                                      children: const [
                                        Icon(Icons.description_rounded, size: 16, color: Color(0xFF2196F3)),
                                        SizedBox(width: 8),
                                        Text('Documents'),
                                      ],
                                    ),
                                  ),
                                  if (_customFolderPath != null)
                                    DropdownMenuItem(
                                      value: 'custom',
                                      child: Row(
                                        children: [
                                          const Icon(Icons.folder_special_rounded, size: 16, color: AppColors.accent),
                                          const SizedBox(width: 8),
                                          Expanded(child: Text(_customFolderDisplay, overflow: TextOverflow.ellipsis)),
                                        ],
                                      ),
                                    ),
                                ],
                                onChanged: (val) {
                                  if (val != null) {
                                    setState(() => _selectedLocationKey = val);
                                  }
                                },
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        IconButton(
                          style: IconButton.styleFrom(
                            backgroundColor: fieldBg,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(6),
                              side: BorderSide(color: borderColor),
                            ),
                            padding: const EdgeInsets.all(8),
                            minimumSize: const Size(34, 34),
                          ),
                          icon: Icon(Icons.folder_open_rounded, size: 16, color: textColor),
                          tooltip: 'Choose Custom Folder...',
                          onPressed: _pickCustomFolder,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: borderColor),

            // Format Selection Tiles (PNG vs JPEG)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Image Format:', style: TextStyle(color: subColor, fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _FormatTile(
                          label: 'PNG (.png)',
                          subtitle: 'Lossless quality',
                          isSelected: _selectedFormat == SaveFormat.png,
                          isDarkMode: widget.isDarkMode,
                          onTap: () => setState(() => _selectedFormat = SaveFormat.png),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _FormatTile(
                          label: 'JPEG (.jpg)',
                          subtitle: 'Smaller file size',
                          isSelected: _selectedFormat == SaveFormat.jpg,
                          isDarkMode: widget.isDarkMode,
                          onTap: () => setState(() => _selectedFormat = SaveFormat.jpg),
                        ),
                      ),
                    ],
                  ),

                  // Quality slider for JPEG format
                  if (_selectedFormat == SaveFormat.jpg) ...[
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('JPEG Quality:', style: TextStyle(color: subColor, fontSize: 13, fontWeight: FontWeight.w600)),
                        Text('${_jpgQuality.round()}%', style: const TextStyle(color: AppColors.accent, fontWeight: FontWeight.bold, fontSize: 13)),
                      ],
                    ),
                    Slider(
                      value: _jpgQuality,
                      min: 30,
                      max: 100,
                      divisions: 14,
                      activeColor: AppColors.accent,
                      onChanged: (val) => setState(() => _jpgQuality = val),
                    ),
                  ],
                ],
              ),
            ),
            Divider(height: 1, color: borderColor),

            // Bottom Actions: Cancel & Save
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: textColor,
                      side: BorderSide(color: borderColor),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel', style: TextStyle(fontSize: 13)),
                  ),
                  const SizedBox(width: 10),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      elevation: 2,
                    ),
                    onPressed: () {
                      final rawName = _nameController.text.trim();
                      final name = rawName.isEmpty ? 'screenshot' : rawName;
                      Navigator.pop(context);
                      widget.onConfirm(SaveOptions(
                        fileName: name,
                        format: _selectedFormat,
                        quality: _jpgQuality.round(),
                        customFolderPath: _selectedLocationKey == 'custom'
                            ? _customFolderPath
                            : _selectedLocationKey,
                        framingPadding: _framingPadding,
                        cornerRadius: _cornerRadius,
                        shadowBlur: _enableShadow ? 24.0 : 0.0,
                        gradientIndex: _framingPadding > 0 ? _selectedGradientIndex : null,
                      ));
                    },
                    child: const Text('Save', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFormRow({
    required String label,
    required Color textColor,
    required Widget child,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 70,
          child: Text(
            label,
            style: TextStyle(color: textColor, fontSize: 13, fontWeight: FontWeight.w500),
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}

class _FormatTile extends StatelessWidget {
  final String label;
  final String subtitle;
  final bool isSelected;
  final bool isDarkMode;
  final VoidCallback onTap;

  const _FormatTile({
    required this.label,
    required this.subtitle,
    required this.isSelected,
    required this.isDarkMode,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tileBg = isSelected
        ? AppColors.accent.withValues(alpha: 0.15)
        : (isDarkMode ? AppColors.darkSurfaceVariant : AppColors.lightSurfaceVariant);
    final borderColor = isSelected ? AppColors.accent : (isDarkMode ? Colors.white10 : Colors.black12);
    final titleColor = isSelected ? AppColors.accent : (isDarkMode ? Colors.white : Colors.black87);
    final subColor = isDarkMode ? Colors.white54 : Colors.black54;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: tileBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: borderColor, width: isSelected ? 1.5 : 1.0),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(color: titleColor, fontSize: 13, fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              Text(subtitle, style: TextStyle(color: subColor, fontSize: 11)),
            ],
          ),
        ),
      ),
    );
  }
}
