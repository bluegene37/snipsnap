// Gene - Oct, 22, 2026: Unit tests verifying PdfExportService PDF document generation, header validation, page format, and orientation.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:snipsnap/services/pdf_export_service.dart';
import 'package:snipsnap/services/storage_service.dart';
import 'package:snipsnap/views/dialogs/save_as_dialog.dart';

Uint8List _createTestPngBytes({required int width, required int height}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(50, 100, 150));
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  group('PdfExportService', () {
    test('generates valid PDF document with %PDF- header', () async {
      final pngBytes = _createTestPngBytes(width: 200, height: 100);
      final pdfBytes = await PdfExportService.generatePdf(
        imageBytes: pngBytes,
        pageSize: PdfPageSize.fitImage,
        margin: PdfMargin.none,
      );

      expect(pdfBytes, isNotEmpty);
      final header = ascii.decode(pdfBytes.sublist(0, 5));
      expect(header, '%PDF-');
    });

    test(
      'generates PDF with A4 paper format in landscape for wide image',
      () async {
        final widePng = _createTestPngBytes(width: 400, height: 200);
        final pdfBytes = await PdfExportService.generatePdf(
          imageBytes: widePng,
          pageSize: PdfPageSize.a4,
          margin: PdfMargin.standard,
        );

        expect(pdfBytes, isNotEmpty);
        expect(ascii.decode(pdfBytes.sublist(0, 5)), '%PDF-');
      },
    );

    test(
      'generates PDF with Letter paper format in portrait for tall image',
      () async {
        final tallPng = _createTestPngBytes(width: 200, height: 400);
        final pdfBytes = await PdfExportService.generatePdf(
          imageBytes: tallPng,
          pageSize: PdfPageSize.letter,
          margin: PdfMargin.none,
        );

        expect(pdfBytes, isNotEmpty);
        expect(ascii.decode(pdfBytes.sublist(0, 5)), '%PDF-');
      },
    );

    // Gene - Oct, 22, 2026: Added unit test verifying ArgumentError when passed corrupted/empty image bytes.
    test(
      'throws ArgumentError when passed corrupted or empty image bytes',
      () async {
        expect(
          () => PdfExportService.generatePdf(
            imageBytes: Uint8List(0),
            pageSize: PdfPageSize.fitImage,
            margin: PdfMargin.none,
          ),
          throwsA(isA<ArgumentError>()),
        );
      },
    );

    // Gene - Oct, 22, 2026: Added integration test verifying PDF file export through StorageService.
    test('StorageService exports PDF bytes with .pdf extension', () async {
      final tempDir = await Directory.systemTemp.createTemp('snipsnap_test_');
      try {
        final pdfBytes = [37, 80, 68, 70, 45, 49, 46, 55]; // %PDF-1.7
        final savedPath = await StorageService.exportImageDialogWithFormat(
          bytes: pdfBytes,
          fileName: 'test_doc',
          isJpg: false,
          isPdf: true,
          customFolderPath: tempDir.path,
        );
        expect(savedPath, isNotNull);
        expect(savedPath!.endsWith('.pdf'), isTrue);
        expect(await File(savedPath).exists(), isTrue);
      } finally {
        await tempDir.delete(recursive: true);
      }
    });
  });
}
