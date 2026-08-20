import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../../utils/constants.dart';
import '../../utils/snip_theme.dart';

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
  double _framingPadding = 0.0;
  double _cornerRadius = 0.0;
  bool _enableShadow = false;
  int _selectedGradientIndex = 0;
  bool _isFramingExpanded = false;

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
    final t = SnipTheme.of(context);

    return AlertDialog(
      backgroundColor: t.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      contentPadding: EdgeInsets.zero,
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header Title
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
                child: Row(
                  children: [
                    Icon(Icons.download_rounded, color: t.ink, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      'Save Screenshot As',
                      style: TextStyle(color: t.ink, fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: t.border),

              // Form Inputs Section: Save As & Where
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 1. Save As Filename Field
                    _buildFormRow(
                      label: 'Save As:',
                      textColor: t.inkMuted,
                      child: TextField(
                        controller: _nameController,
                        style: TextStyle(color: t.ink, fontSize: 13),
                        decoration: InputDecoration(
                          isDense: true,
                          filled: true,
                          fillColor: t.surfaceRaised,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(6),
                            borderSide: BorderSide(color: t.border),
                          ),
                          // Focus is signalled by weight (a thicker hairline)
                          // and the emphasis token, not a colour swap.
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(6),
                            borderSide: BorderSide(color: t.borderStrong, width: 1.5),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // 2. Where Location Selector
                    _buildFormRow(
                      label: 'Where:',
                      textColor: t.inkMuted,
                      child: Row(
                        children: [
                          Expanded(
                            child: Container(
                              height: 34,
                              padding: const EdgeInsets.symmetric(horizontal: 10),
                              decoration: BoxDecoration(
                                color: t.surfaceRaised,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: t.border),
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<String>(
                                  value: _selectedLocationKey,
                                  isExpanded: true,
                                  icon: Icon(Icons.unfold_more_rounded, size: 16, color: t.inkMuted),
                                  dropdownColor: t.surfaceRaised,
                                  style: TextStyle(color: t.ink, fontSize: 13),
                                  items: [
                                    DropdownMenuItem(
                                      value: 'downloads',
                                      child: Row(
                                        children: [
                                          // Was a fixed Finder/Explorer-style
                                          // folder-kind hue (gold/green/blue)
                                          // regardless of theme — a review
                                          // round computed real contrast
                                          // against light mode's
                                          // t.surfaceRaised (0xFFFFFFFF) and
                                          // found two of three fail the 3:1
                                          // bar this same task enforces
                                          // everywhere else: gold #FFC107
                                          // 1.63:1, green #4CAF50 2.78:1, blue
                                          // #2196F3 3.12:1 (barely). Dark mode
                                          // was fine (10.2/6.0/5.3:1), which
                                          // is why an eyeball check missed
                                          // it. Tokenised to t.ink instead —
                                          // these are decorative folder-kind
                                          // hints, not user annotation data,
                                          // so there's no reason to keep a
                                          // fixed hue here at all. t.ink on
                                          // t.surfaceRaised is 18.4:1 light /
                                          // 16.1:1 dark (see
                                          // `SnipTheme.of` "ink on surface"
                                          // in snip_theme_test.dart for the
                                          // same pairing computed generally;
                                          // save_as_dialog_test.dart pins
                                          // these three specific icons).
                                          Icon(Icons.folder_rounded, size: 16, color: t.ink),
                                          const SizedBox(width: 8),
                                          Text('Downloads', style: TextStyle(color: t.ink)),
                                        ],
                                      ),
                                    ),
                                    DropdownMenuItem(
                                      value: 'desktop',
                                      child: Row(
                                        children: [
                                          Icon(Icons.desktop_windows_rounded, size: 16, color: t.ink),
                                          const SizedBox(width: 8),
                                          Text('Desktop', style: TextStyle(color: t.ink)),
                                        ],
                                      ),
                                    ),
                                    DropdownMenuItem(
                                      value: 'documents',
                                      child: Row(
                                        children: [
                                          Icon(Icons.description_rounded, size: 16, color: t.ink),
                                          const SizedBox(width: 8),
                                          Text('Documents', style: TextStyle(color: t.ink)),
                                        ],
                                      ),
                                    ),
                                    if (_customFolderPath != null)
                                      DropdownMenuItem(
                                        value: 'custom',
                                        child: Row(
                                          children: [
                                            Icon(Icons.folder_special_rounded, size: 16, color: t.ink),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Text(
                                                _customFolderDisplay,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(color: t.ink),
                                              ),
                                            ),
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
                              backgroundColor: t.surfaceRaised,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(6),
                                side: BorderSide(color: t.border),
                              ),
                              padding: const EdgeInsets.all(8),
                              minimumSize: const Size(34, 34),
                            ),
                            icon: Icon(Icons.folder_open_rounded, size: 16, color: t.ink),
                            tooltip: 'Choose Custom Folder...',
                            onPressed: _pickCustomFolder,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: t.border),

              // Format Selection Tiles (PNG vs JPEG)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Image Format:', style: TextStyle(color: t.inkMuted, fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: _FormatTile(
                            label: 'PNG (.png)',
                            subtitle: 'Lossless quality',
                            isSelected: _selectedFormat == SaveFormat.png,
                            onTap: () => setState(() => _selectedFormat = SaveFormat.png),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _FormatTile(
                            label: 'JPEG (.jpg)',
                            subtitle: 'Smaller file size',
                            isSelected: _selectedFormat == SaveFormat.jpg,
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
                          Text('JPEG Quality:', style: TextStyle(color: t.inkMuted, fontSize: 13, fontWeight: FontWeight.w600)),
                          Text('${_jpgQuality.round()}%', style: TextStyle(color: t.ink, fontWeight: FontWeight.bold, fontSize: 13)),
                        ],
                      ),
                      Slider(
                        value: _jpgQuality,
                        min: 30,
                        max: 100,
                        divisions: 14,
                        activeColor: t.ink,
                        inactiveColor: t.border,
                        onChanged: (val) => setState(() => _jpgQuality = val),
                      ),
                    ],
                  ],
                ),
              ),
              Divider(height: 1, color: t.border),

              // Social Framing / Canvas Padding Options
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    InkWell(
                      onTap: () => setState(() => _isFramingExpanded = !_isFramingExpanded),
                      child: Row(
                        children: [
                          Icon(Icons.palette_rounded, size: 16, color: t.ink),
                          const SizedBox(width: 8),
                          Text(
                            'Social Framing & Padding',
                            style: TextStyle(color: t.ink, fontSize: 13, fontWeight: FontWeight.bold),
                          ),
                          const Spacer(),
                          Text(
                            _framingPadding > 0 ? '${_framingPadding.toInt()}px framed' : 'None',
                            style: TextStyle(color: t.inkMuted, fontSize: 11),
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            _isFramingExpanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                            size: 18,
                            color: t.inkMuted,
                          ),
                        ],
                      ),
                    ),
                    if (_isFramingExpanded) ...[
                      const SizedBox(height: 14),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Padding:', style: TextStyle(color: t.inkMuted, fontSize: 12)),
                          Wrap(
                            spacing: 6,
                            children: [0.0, 32.0, 64.0].map((pVal) {
                              final isSelected = _framingPadding == pVal;
                              // A genuine "exactly one of N" radio group —
                              // ChoiceChip can't take a BoxDecoration, so the
                              // exclusive-active tokens are wired field by
                              // field instead, same technique Task 4 used
                              // for FilterChip-based radio groups.
                              return ChoiceChip(
                                label: Text(
                                  pVal == 0 ? 'None' : '${pVal.toInt()}px',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: t.controlForeground(active: isSelected, exclusive: true),
                                  ),
                                ),
                                selected: isSelected,
                                selectedColor: t.activeFill,
                                backgroundColor: Colors.transparent,
                                side: BorderSide(color: isSelected ? t.activeFill : t.border),
                                showCheckmark: false,
                                onSelected: (sel) {
                                  if (sel) {
                                    setState(() {
                                      _framingPadding = pVal;
                                      if (pVal > 0 && _cornerRadius == 0) _cornerRadius = 16.0;
                                      if (pVal > 0) _enableShadow = true;
                                    });
                                  }
                                },
                              );
                            }).toList(),
                          ),
                        ],
                      ),
                      if (_framingPadding > 0) ...[
                        const SizedBox(height: 10),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('Corner Radius:', style: TextStyle(color: t.inkMuted, fontSize: 12)),
                            Wrap(
                              spacing: 6,
                              children: [0.0, 12.0, 24.0].map((rVal) {
                                final isSelected = _cornerRadius == rVal;
                                return ChoiceChip(
                                  label: Text(
                                    rVal == 0 ? 'Sharp' : '${rVal.toInt()}px',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: t.controlForeground(active: isSelected, exclusive: true),
                                    ),
                                  ),
                                  selected: isSelected,
                                  selectedColor: t.activeFill,
                                  backgroundColor: Colors.transparent,
                                  side: BorderSide(color: isSelected ? t.activeFill : t.border),
                                  showCheckmark: false,
                                  onSelected: (sel) {
                                    if (sel) setState(() => _cornerRadius = rVal);
                                  },
                                );
                              }).toList(),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('Drop Shadow:', style: TextStyle(color: t.inkMuted, fontSize: 12)),
                            Switch(
                              value: _enableShadow,
                              activeTrackColor: t.activeFill,
                              onChanged: (v) => setState(() => _enableShadow = v),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text('Background Gradient:', style: TextStyle(color: t.inkMuted, fontSize: 12)),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: List.generate(AppColors.framingGradients.length, (idx) {
                            final isSel = _selectedGradientIndex == idx;
                            // The gradient preview itself keeps its real,
                            // unconverted colour — same rule as the
                            // annotation swatches. Only the chrome around it
                            // (the selected ring, the check glyph) is
                            // monochrome, and since a gradient has more than
                            // one stop, a single-colour ringOn isn't enough:
                            // a ring picked against just one endpoint can
                            // still vanish against the other, so this uses
                            // ringOnGradient, which is guaranteed safe
                            // against every stop.
                            final stops = (AppColors.framingGradients[idx] as LinearGradient).colors;
                            final ring = t.ringOnGradient(stops);
                            return GestureDetector(
                              onTap: () => setState(() => _selectedGradientIndex = idx),
                              child: Container(
                                width: 34,
                                height: 34,
                                decoration: BoxDecoration(
                                  gradient: AppColors.framingGradients[idx],
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: isSel ? ring : Colors.transparent,
                                    width: 2.5,
                                  ),
                                  // Elevation shadow on the selected tile —
                                  // decorative, mode-invariant, matching the
                                  // other incidental drop shadows in this
                                  // file's dialogs.
                                  boxShadow: isSel ? const [BoxShadow(color: Colors.black45, blurRadius: 4)] : null,
                                ),
                                child: isSel ? Icon(Icons.check_rounded, size: 16, color: ring) : null,
                              ),
                            );
                          }),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
              Divider(height: 1, color: t.border),

              // Bottom Actions: Cancel & Save
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: t.ink,
                        side: BorderSide(color: t.border),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel', style: TextStyle(fontSize: 13)),
                    ),
                    const SizedBox(width: 10),
                    // The dialog's one CTA — emphasis is a border/text-only
                    // token, never a fill (Task 3's corrected precedent).
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: t.surfaceRaised,
                        foregroundColor: t.emphasis,
                        side: BorderSide(color: t.emphasis, width: 1.2),
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        elevation: 0,
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

/// One PNG/JPEG format tile — a genuine "exactly one of two" radio choice,
/// so it routes through [SnipTheme.controlDecoration]/[controlForeground]'s
/// exclusive-active shape (the full ink/onActive knockout plate) rather than
/// a tinted accent background, matching Task 4's Shape Chooser Grid
/// precedent for the same "radio group" shape.
class _FormatTile extends StatelessWidget {
  final String label;
  final String subtitle;
  final bool isSelected;
  final VoidCallback onTap;

  const _FormatTile({
    required this.label,
    required this.subtitle,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = SnipTheme.of(context);
    final decoration = t.controlDecoration(active: isSelected, exclusive: true, radius: 10);
    final titleColor = t.controlForeground(active: isSelected, exclusive: true);
    // dim only changes the resting (unselected) answer to inkMuted — a
    // knocked-out active tile stays onActive regardless, since that's the
    // colour guaranteed legible against the activeFill plate.
    final subColor = t.controlForeground(active: isSelected, exclusive: true, dim: true);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: decoration,
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
