import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/models/capture_item.dart';

void main() {
  test('hasDimensions is false when width or height is zero', () {
    final item = CaptureItem(
      id: 'a',
      filePath: '/tmp/a.png',
      title: 'A',
      createdAt: DateTime(2026, 1, 1),
    );
    expect(item.hasDimensions, isFalse);

    expect(item.copyWith(width: 100).hasDimensions, isFalse);
    expect(item.copyWith(width: 100, height: 50).hasDimensions, isTrue);
  });
}
