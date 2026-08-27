import 'dart:io';
import 'dart:math' as math;
import 'package:image/image.dart' as img;

void main() {
  final file = File('assets/images/app_logo_v1.png');
  if (!file.existsSync()) {
    stderr.writeln('assets/images/app_logo_v1.png not found!');
    exit(1);
  }

  final source = img.decodePng(file.readAsBytesSync());
  if (source == null) {
    stderr.writeln('Could not decode app_logo_v1.png');
    exit(1);
  }

  stdout.writeln('Original size: ${source.width} x ${source.height}');

  // The intertwined SS emblem is centered in the image.
  final cx = source.width ~/ 2;
  final cy = source.height ~/ 2;

  // Let's crop a square region centered at (cx, cy) using the height as bounding reference
  // In 1408x768, a square of 720x720 (or 680x680) centered around (cx, cy) gives a clean frame
  // with proportional breathing room around the SS emblem without touching the watermark at the corner.
  final cropSize = (source.height * 0.88).round(); // ~675px
  final cropLeft = (cx - cropSize ~/ 2).clamp(0, source.width - cropSize);
  final cropTop = (cy - cropSize ~/ 2).clamp(0, source.height - cropSize);

  stdout.writeln(
    'Crop rect: left=$cropLeft, top=$cropTop, size=${cropSize}x$cropSize',
  );

  final cropped = img.copyCrop(
    source,
    x: cropLeft,
    y: cropTop,
    width: cropSize,
    height: cropSize,
  );

  // Resize to standard 1024x1024 logo
  const outSize = 1024;
  final colorLogo = img.copyResize(
    cropped,
    width: outSize,
    height: outSize,
    interpolation: img.Interpolation.cubic,
  );

  File('assets/images/app_logo.png').writeAsBytesSync(img.encodePng(colorLogo));
  File(
    'assets/images/app_logo_square.png',
  ).writeAsBytesSync(img.encodePng(colorLogo));
  stdout.writeln(
    'Saved assets/images/app_logo.png and app_logo_square.png (1024x1024 color)',
  );

  // Create Black & White / Skeleton Monochrome versions:
  final monoLogo = img.Image(width: outSize, height: outSize, numChannels: 4);
  final skeletonDark = img.Image(
    width: outSize,
    height: outSize,
    numChannels: 4,
  );
  final skeletonLight = img.Image(
    width: outSize,
    height: outSize,
    numChannels: 4,
  );

  final darkBg = img.ColorRgba8(0x14, 0x14, 0x14, 255);
  final lightBg = img.ColorRgba8(0xF2, 0xF2, 0xF0, 255);

  img.fill(skeletonDark, color: darkBg);
  img.fill(skeletonLight, color: lightBg);

  for (int y = 0; y < outSize; y++) {
    for (int x = 0; x < outSize; x++) {
      final p = colorLogo.getPixel(x, y);
      // Relative luminance
      final lum = (0.299 * p.r + 0.587 * p.g + 0.114 * p.b) / 255.0;

      // Enhance contrast on the mark
      final norm = ((lum - 0.08) / 0.72).clamp(0.0, 1.0);
      final curved = math.pow(norm, 1.3).toDouble();

      final monoVal = (curved * 255).round().clamp(0, 255);
      monoLogo.setPixel(x, y, img.ColorRgba8(monoVal, monoVal, monoVal, 255));

      // Skeleton Dark (silver-white stroke on dark canvas)
      final darkVal = (20 + curved * 235).round().clamp(0, 255);
      skeletonDark.setPixel(
        x,
        y,
        img.ColorRgba8(darkVal, darkVal, darkVal, 255),
      );

      // Skeleton Light (deep ink stroke on light canvas)
      final lightVal = (242 - curved * 222).round().clamp(0, 255);
      skeletonLight.setPixel(
        x,
        y,
        img.ColorRgba8(lightVal, lightVal, lightVal, 255),
      );
    }
  }

  File(
    'assets/images/app_logo_mono.png',
  ).writeAsBytesSync(img.encodePng(monoLogo));
  File(
    'assets/images/app_logo_skeleton_dark.png',
  ).writeAsBytesSync(img.encodePng(skeletonDark));
  File(
    'assets/images/app_logo_skeleton_light.png',
  ).writeAsBytesSync(img.encodePng(skeletonLight));

  stdout.writeln('Saved assets/images/app_logo_mono.png');
  stdout.writeln('Saved assets/images/app_logo_skeleton_dark.png');
  stdout.writeln('Saved assets/images/app_logo_skeleton_light.png');
}
