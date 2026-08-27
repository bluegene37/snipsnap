import 'dart:io';
import 'package:image/image.dart' as img;

void main() {
  final inputPath =
      '/Users/bluegene37/.gemini/antigravity/brain/b5bdca92-ec10-49dc-b1fe-2060e426c79d/snipsnap_skeleton_logo_1787388521610.jpg';
  final inputFile = File(inputPath);
  if (!inputFile.existsSync()) {
    stderr.writeln('Source image not found at $inputPath');
    exit(1);
  }

  final image = img.decodeImage(inputFile.readAsBytesSync());
  if (image == null) {
    stderr.writeln('Failed to decode image');
    exit(1);
  }

  stdout.writeln('Decoded image size: ${image.width}x${image.height}');

  // Resize to standard 1024x1024
  final resized = img.copyResize(
    image,
    width: 1024,
    height: 1024,
    interpolation: img.Interpolation.cubic,
  );

  // Save as main app_logo.png and app_logo_skeleton_dark.png
  final pngBytes = img.encodePng(resized);
  File('assets/images/app_logo.png').writeAsBytesSync(pngBytes);
  File('assets/images/app_logo_skeleton_dark.png').writeAsBytesSync(pngBytes);
  File('assets/images/app_logo_skeleton.png').writeAsBytesSync(pngBytes);

  // Create inverted / light-mode skeleton version (deep black ink strokes on light paper)
  final lightImg = img.Image(width: 1024, height: 1024, numChannels: 4);
  img.fill(lightImg, color: img.ColorRgba8(0xF2, 0xF2, 0xF0, 255));

  for (int y = 0; y < 1024; y++) {
    for (int x = 0; x < 1024; x++) {
      final p = resized.getPixel(x, y);
      final lum = (0.299 * p.r + 0.587 * p.g + 0.114 * p.b) / 255.0;
      // Invert luminance so white lines become dark ink (0x141414) on light background (0xF2F2F0)
      final val = (242 - lum * 222).round().clamp(0, 255);
      lightImg.setPixel(x, y, img.ColorRgba8(val, val, val, 255));
    }
  }

  File(
    'assets/images/app_logo_skeleton_light.png',
  ).writeAsBytesSync(img.encodePng(lightImg));

  stdout.writeln('Successfully generated and saved:');
  stdout.writeln('- assets/images/app_logo.png');
  stdout.writeln('- assets/images/app_logo_skeleton.png');
  stdout.writeln('- assets/images/app_logo_skeleton_dark.png');
  stdout.writeln('- assets/images/app_logo_skeleton_light.png');
}
