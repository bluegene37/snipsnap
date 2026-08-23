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
        {'text': 'one', 'x': 0.0, 'y': 0.0, 'w': 1.0, 'h': 1.0, 'confidence': 1.0, 'words': <dynamic>[]},
        {'text': 'two', 'x': 0.0, 'y': 2.0, 'w': 1.0, 'h': 1.0, 'confidence': 1.0, 'words': <dynamic>[]},
      ],
    });
    expect(result.plainText, 'one\ntwo');
  });

  test('tolerates a payload with no lines', () {
    final result = OcrResult.fromChannelMap(const {'width': 5, 'height': 5, 'lines': <dynamic>[]});
    expect(result.lines, isEmpty);
    expect(result.plainText, isEmpty);
    expect(result.isEmpty, isTrue);
  });

  test('tolerates a line with missing rect coordinates', () {
    final result = OcrResult.fromChannelMap(const {
      'width': 100,
      'height': 100,
      'lines': [
        {'text': 'no coords', 'confidence': 0.9, 'words': <dynamic>[]},
      ],
    });
    expect(result.lines, hasLength(1));
    expect(result.lines.single.text, 'no coords');
    expect(result.lines.single.boundsPx, const Rect.fromLTWH(0, 0, 0, 0));
  });

  test('tolerates non-Map entries in lines array', () {
    final result = OcrResult.fromChannelMap(const {
      'width': 100,
      'height': 100,
      'lines': [
        {'text': 'valid', 'x': 10.0, 'y': 20.0, 'w': 30.0, 'h': 15.0, 'confidence': 0.95, 'words': <dynamic>[]},
        'invalid string entry',
        null,
        {
          'text': 'another valid',
          'x': 50.0,
          'y': 70.0,
          'w': 40.0,
          'h': 15.0,
          'confidence': 0.92,
          'words': <dynamic>[],
        },
      ],
    });
    expect(result.lines, hasLength(2));
    expect(result.lines.first.text, 'valid');
    expect(result.lines.last.text, 'another valid');
  });

  test('tolerates wrong-typed lines value', () {
    final result = OcrResult.fromChannelMap(const {
      'width': 100,
      'height': 100,
      'lines': 'should be a list',
    });
    expect(result.lines, isEmpty);
    expect(result.imageSize, const Size(100, 100));
  });

  test('tolerates non-Map entries in words array', () {
    final result = OcrResult.fromChannelMap(const {
      'width': 100,
      'height': 100,
      'lines': [
        {
          'text': 'mixed words',
          'x': 10.0,
          'y': 20.0,
          'w': 100.0,
          'h': 15.0,
          'confidence': 0.9,
          'words': [
            {'text': 'valid', 'x': 10.0, 'y': 20.0, 'w': 30.0, 'h': 15.0, 'confidence': 0.95},
            'invalid',
            null,
            {'text': 'also valid', 'x': 45.0, 'y': 20.0, 'w': 55.0, 'h': 15.0, 'confidence': 0.93},
          ],
        },
      ],
    });
    expect(result.lines, hasLength(1));
    expect(result.lines.single.words, hasLength(2));
    expect(result.lines.single.words.first.text, 'valid');
    expect(result.lines.single.words.last.text, 'also valid');
  });

  test('tolerates wrong-typed width and height', () {
    final result = OcrResult.fromChannelMap(const {
      'width': 'not a number',
      'height': 'also not a number',
      'lines': <dynamic>[],
    });
    expect(result.imageSize, const Size(0, 0));
  });

  test('tolerates non-numeric coordinate values', () {
    final result = OcrResult.fromChannelMap(const {
      'width': 100,
      'height': 100,
      'lines': [
        {
          'text': 'bad coords',
          'x': '12',
          'y': 'abc',
          'w': true,
          'h': 15.0,
          'confidence': 0.9,
          'words': <dynamic>[],
        },
      ],
    });
    expect(result.lines, hasLength(1));
    expect(result.lines.single.text, 'bad coords');
    expect(result.lines.single.boundsPx, const Rect.fromLTWH(0, 0, 0, 15));
  });

  test('tolerates non-String text field', () {
    final result = OcrResult.fromChannelMap(const {
      'width': 100,
      'height': 100,
      'lines': [
        {
          'text': 5,
          'x': 10.0,
          'y': 20.0,
          'w': 30.0,
          'h': 15.0,
          'confidence': 0.9,
          'words': [
            {'text': 123, 'x': 10.0, 'y': 20.0, 'w': 20.0, 'h': 15.0, 'confidence': 0.95},
          ],
        },
      ],
    });
    expect(result.lines, hasLength(1));
    expect(result.lines.single.text, '');
    expect(result.lines.single.words, hasLength(1));
    expect(result.lines.single.words.first.text, '');
  });

  test('tolerates non-numeric confidence field', () {
    final result = OcrResult.fromChannelMap(const {
      'width': 100,
      'height': 100,
      'lines': [
        {
          'text': 'bad confidence',
          'x': 10.0,
          'y': 20.0,
          'w': 30.0,
          'h': 15.0,
          'confidence': 'high',
          'words': [
            {
              'text': 'word',
              'x': 10.0,
              'y': 20.0,
              'w': 20.0,
              'h': 15.0,
              'confidence': true,
            },
          ],
        },
      ],
    });
    expect(result.lines, hasLength(1));
    expect(result.lines.single.confidence, 0.0);
    expect(result.lines.single.words, hasLength(1));
    expect(result.lines.single.words.first.confidence, 0.0);
  });
}
