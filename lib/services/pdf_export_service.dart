// Gene - Oct, 22, 2026: Implemented PdfExportService to export screenshot images as single-page PDF documents.
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../views/dialogs/save_as_dialog.dart';

/// Top-level isolate computation for PDF generation to keep the UI smooth.
Future<Uint8List> _buildPdfDocument(
  ({Uint8List imageBytes, PdfPageSize pageSize, PdfMargin margin}) req,
) async {
  final decoded = img.decodeImage(req.imageBytes);
  if (decoded == null) {
    throw ArgumentError(
      'Invalid or corrupted image bytes passed to PdfExportService',
    );
  }

  final pdf = pw.Document();
  final pdfImage = pw.MemoryImage(req.imageBytes);
  final isWide = decoded.width > decoded.height;

  final PdfPageFormat format;
  final double marginPoints = req.margin == PdfMargin.standard ? 36.0 : 0.0;

  switch (req.pageSize) {
    case PdfPageSize.fitImage:
      format = PdfPageFormat(
        decoded.width.toDouble(),
        decoded.height.toDouble(),
        marginAll: 0,
      );
    case PdfPageSize.a4:
      final base = PdfPageFormat.a4;
      format = (isWide ? base.landscape : base).copyWith(
        marginTop: marginPoints,
        marginBottom: marginPoints,
        marginLeft: marginPoints,
        marginRight: marginPoints,
      );
    case PdfPageSize.letter:
      final base = PdfPageFormat.letter;
      format = (isWide ? base.landscape : base).copyWith(
        marginTop: marginPoints,
        marginBottom: marginPoints,
        marginLeft: marginPoints,
        marginRight: marginPoints,
      );
  }

  pdf.addPage(
    pw.Page(
      pageFormat: format,
      build: (pw.Context context) {
        if (req.pageSize == PdfPageSize.fitImage) {
          return pw.FullPage(
            ignoreMargins: true,
            child: pw.Image(pdfImage, fit: pw.BoxFit.fill),
          );
        }
        return pw.Center(child: pw.Image(pdfImage, fit: pw.BoxFit.contain));
      },
    ),
  );

  return pdf.save();
}

/// Service that compiles screenshot image bytes into PDF documents.
class PdfExportService {
  const PdfExportService._();

  /// Compiles [imageBytes] into a PDF document byte array using the specified
  /// [pageSize] and [margin] options. Runs in a worker isolate.
  static Future<Uint8List> generatePdf({
    required Uint8List imageBytes,
    PdfPageSize pageSize = PdfPageSize.fitImage,
    PdfMargin margin = PdfMargin.none,
  }) async {
    return compute(_buildPdfDocument, (
      imageBytes: imageBytes,
      pageSize: pageSize,
      margin: margin,
    ));
  }
}
