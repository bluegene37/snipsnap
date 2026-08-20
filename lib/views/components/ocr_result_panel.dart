import 'package:flutter/material.dart';

import '../../services/clipboard_service.dart';
import '../../services/ocr/ocr_engine.dart';
import '../../utils/snip_theme.dart';

/// Shows extracted text with copy and insert actions.
///
/// Four distinct states, and telling them apart is the whole point of the
/// widget: still running, the engine is not available on this host, the engine
/// ran and found nothing, and the engine ran and found text. The middle two
/// both arrive as an empty [OcrResult] from `OcrService` — only the caller's
/// `availability()` probe separates them, which is why
/// [unavailableReason] is a parameter and not something inferred here.
class OcrResultPanel extends StatelessWidget {
  final OcrResult result;
  final bool isLoading;

  /// Non-null when the platform has no usable OCR engine. Takes precedence
  /// over [result] — an empty result caused by an absent engine must not be
  /// reported as "no text found".
  final String? unavailableReason;
  final VoidCallback onClose;
  final ValueChanged<String> onInsertAsText;
  final bool isDarkMode;

  const OcrResultPanel({
    super.key,
    required this.result,
    required this.onClose,
    required this.onInsertAsText,
    required this.isDarkMode,
    this.isLoading = false,
    this.unavailableReason,
  });

  bool get _hasText => !isLoading && unavailableReason == null && !result.isEmpty;

  @override
  Widget build(BuildContext context) {
    final t = SnipTheme.of(context);

    return Material(
      color: Colors.transparent,
      child: Container(
        width: 320,
        constraints: const BoxConstraints(maxHeight: 420),
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: t.border),
          // Decorative elevation shadow under this floating panel, sitting
          // on whatever the panel is anchored over — mode-invariant like
          // the app's other incidental drop shadows (e.g. the shortcut
          // dialog's kbd badges).
          boxShadow: const [
            BoxShadow(color: Colors.black26, blurRadius: 16, offset: Offset(0, 4)),
          ],
        ),
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Text(
                  'Extracted text',
                  style: TextStyle(color: t.ink, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close_rounded, size: 18),
                  color: t.inkMuted,
                  onPressed: onClose,
                  tooltip: 'Close',
                ),
              ],
            ),
            const SizedBox(height: 8),
            Flexible(child: _buildBody(t)),
            if (_hasText) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  TextButton.icon(
                    style: TextButton.styleFrom(foregroundColor: t.ink),
                    icon: const Icon(Icons.copy_rounded, size: 16),
                    label: const Text('Copy'),
                    onPressed: () => ClipboardService.copyText(result.plainText),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    style: TextButton.styleFrom(foregroundColor: t.ink),
                    icon: const Icon(Icons.text_fields_rounded, size: 16),
                    label: const Text('Insert'),
                    onPressed: () => onInsertAsText(result.plainText),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildBody(SnipTheme t) {
    if (isLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (unavailableReason != null) {
      return Text(
        unavailableReason!,
        style: TextStyle(color: t.inkMuted, fontSize: 13),
      );
    }
    if (result.isEmpty) {
      return Text(
        'No text found in this area.',
        style: TextStyle(color: t.inkMuted, fontSize: 13),
      );
    }
    return SingleChildScrollView(
      child: SelectableText(
        result.plainText,
        style: TextStyle(color: t.ink, fontSize: 13, height: 1.5),
      ),
    );
  }
}
