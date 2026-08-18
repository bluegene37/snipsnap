import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/services/ocr/ocr_engine.dart';

void main() {
  test('parses a channel payload into lines and words', () {
    final result = OcrResult.fromChannelMap(const {
      'width': 800,
      'height': 600,
      'lines': [
        {
          'text': 'Hello world',
          'x': 10.0,
          'y': 20.0,
          'w': 100.0,
          'h': 18.0,
          'confidence': 0.94,
          'words': [
            {'text': 'Hello', 'x': 10.0, 'y': 20.0, 'w': 44.0, 'h': 18.0, 'confidence': 0.96},
            {'text': 'world', 'x': 58.0, 'y': 20.0, 'w': 52.0, 'h': 18.0, 'confidence': 0.92},
          ],
        },
      ],
    });

    expect(result.imageSize, const Size(800, 600));
    expect(result.lines, hasLength(1));
    expect(result.lines.single.boundsPx, const Rect.fromLTWH(10, 20, 100, 18));
    expect(result.lines.single.words, hasLength(2));
    expect(result.lines.single.words.first.text, 'Hello');
    expect(result.plainText, 'Hello world');
  });

  test('joins multiple lines with newlines', () {
    final result = OcrResult.fromChannelMap(const {
      'width': 10,
      'height': 10,
      'lines': [
        {'text': 'one', 'x': 0.0, 'y': 0.0, 'w': 1.0, 'h': 1.0, 'confidence': 1.0, 'words': []},
        {'text': 'two', 'x': 0.0, 'y': 2.0, 'w': 1.0, 'h': 1.0, 'confidence': 1.0, 'words': []},
      ],
    });
    expect(result.plainText, 'one\ntwo');
  });

  test('tolerates a payload with no lines', () {
    final result = OcrResult.fromChannelMap(const {'width': 5, 'height': 5, 'lines': []});
    expect(result.lines, isEmpty);
    expect(result.plainText, isEmpty);
    expect(result.isEmpty, isTrue);
  });
}
