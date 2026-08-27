import 'dart:io';
import 'package:image/image.dart' as img;

void main() {
  final brainDir =
      '/Users/bluegene37/.gemini/antigravity/brain/b5bdca92-ec10-49dc-b1fe-2060e426c79d';

  final options = <String, String>{
    'logo_option_1_viewfinder_ss':
        '$brainDir/snipsnap_skeleton_icon_1787388570981.jpg',
    'logo_option_2_blueprint_ss':
        '$brainDir/snipsnap_skeleton_duo_1787388546212.jpg',
    'logo_option_3_monogram_s':
        '$brainDir/snipsnap_skeleton_logo_1787388521610.jpg',
  };

  for (final entry in options.entries) {
    final file = File(entry.value);
    if (!file.existsSync()) {
      stderr.writeln('Warning: ${entry.value} does not exist');
      continue;
    }

    final decoded = img.decodeImage(file.readAsBytesSync());
    if (decoded == null) continue;

    final resized = img.copyResize(
      decoded,
      width: 1024,
      height: 1024,
      interpolation: img.Interpolation.cubic,
    );

    // Save dark PNG
    final darkPath = 'assets/images/${entry.key}_dark.png';
    final standardPath = 'assets/images/${entry.key}.png';
    final pngBytes = img.encodePng(resized);
    File(darkPath).writeAsBytesSync(pngBytes);
    File(standardPath).writeAsBytesSync(pngBytes);

    // Generate light inverted PNG
    final lightImg = img.Image(width: 1024, height: 1024, numChannels: 4);
    img.fill(lightImg, color: img.ColorRgba8(0xF2, 0xF2, 0xF0, 255));

    for (int y = 0; y < 1024; y++) {
      for (int x = 0; x < 1024; x++) {
        final p = resized.getPixel(x, y);
        final lum = (0.299 * p.r + 0.587 * p.g + 0.114 * p.b) / 255.0;
        final val = (242 - lum * 222).round().clamp(0, 255);
        lightImg.setPixel(x, y, img.ColorRgba8(val, val, val, 255));
      }
    }
    final lightPath = 'assets/images/${entry.key}_light.png';
    File(lightPath).writeAsBytesSync(img.encodePng(lightImg));

    stdout.writeln('Saved $standardPath and $lightPath');
  }

  stdout.writeln('All logo options saved successfully.');
}
