// Generates the SnipSnap logo assets from geometry, so the logo is
// reproducible from source rather than living only as an opaque PNG.
//
//   dart run tool/generate_logo.dart
//
// Outputs:
//   assets/images/app_logo.png   full-bleed 1024x1024 tile (in-app brand mark)
//   build/logo/macos_icon.png    1024x1024 with Big Sur-style transparent
//                                margin, source for the macOS .appiconset
//
// Design: the mark uses only the app's two paper tones (see snip_theme.dart)
// — ink 0xFF141414 as the tile, paper 0xFFF2F2F0 as the mark — because the
// whole UI is a strict two-tone inversion system and the logo follows it.
// The two S's are square-wave letterforms (crop-bracket corners, no font),
// and a single diagonal "snip" cut displaces the upper half: snip, snap.
import 'dart:io';
import 'dart:math';

import 'package:image/image.dart' as img;

// All geometry is authored in a 1024-unit space, rendered at [_ss]x
// supersampling, then averaged down for anti-aliased edges.
const _ss = 4;
const _size = 1024;

final _ink = img.ColorRgba8(0x14, 0x14, 0x14, 255);
final _paper = img.ColorRgba8(0xF2, 0xF2, 0xF0, 255);

// Geometric S: the spine is two tangent circular arcs (240 degrees each),
// stroked by offsetting the sampled spine along its normals. The flat
// terminal caps this produces are deliberate — chopped ends, like a cut.
const _spineR = 95.0; // spine arc radius
const _halfStroke = 42.0;
const _upperCy = 417.0; // 512 - _spineR
const _lowerCy = 607.0; // 512 + _spineR

List<List<double>> _sOutline(double cx) {
  const n = 120;
  final spine = <List<double>>[];
  // Upper bowl: from the top-right terminal, over the top, down to the
  // waist at (cx, 512).
  for (var i = 0; i <= n; i++) {
    final th = (-30 - 240 * i / n) * pi / 180;
    spine.add([cx + _spineR * cos(th), _upperCy + _spineR * sin(th)]);
  }
  // Lower bowl: from the waist, around the bottom, to the lower-left
  // terminal (starts at i = 1: i = 0 would duplicate the waist point).
  for (var i = 1; i <= n; i++) {
    final th = (-90 + 240 * i / n) * pi / 180;
    spine.add([cx + _spineR * cos(th), _lowerCy + _spineR * sin(th)]);
  }
  final left = <List<double>>[];
  final right = <List<double>>[];
  for (var i = 0; i < spine.length; i++) {
    final a = spine[max(i - 1, 0)];
    final b = spine[min(i + 1, spine.length - 1)];
    var tx = b[0] - a[0];
    var ty = b[1] - a[1];
    final len = sqrt(tx * tx + ty * ty);
    tx /= len;
    ty /= len;
    left.add([spine[i][0] - ty * _halfStroke, spine[i][1] + tx * _halfStroke]);
    right.add([spine[i][0] + ty * _halfStroke, spine[i][1] - tx * _halfStroke]);
  }
  return [...left, ...right.reversed];
}

// The snip: a line through (160, 650) and (864, 374) in tile space.
const _cutAx = 160.0, _cutAy = 650.0;
const _cutSlope = (374.0 - 650.0) / (864.0 - 160.0);
// Displacement of the piece above the cut, roughly perpendicular to it.
const _snapDx = -9.0, _snapDy = -24.0;

double _cutSide(double x, double y) => y - (_cutAy + _cutSlope * (x - _cutAx));

/// Sutherland–Hodgman clip of [poly] against the cut line, keeping the side
/// where `_cutSide` is negative ([above] = true) or positive.
List<List<double>> _clip(List<List<double>> poly, {required bool above}) {
  final out = <List<double>>[];
  for (var i = 0; i < poly.length; i++) {
    final p1 = poly[i];
    final p2 = poly[(i + 1) % poly.length];
    var s1 = _cutSide(p1[0], p1[1]);
    var s2 = _cutSide(p2[0], p2[1]);
    if (!above) {
      s1 = -s1;
      s2 = -s2;
    }
    if (s1 <= 0) out.add(p1);
    if ((s1 < 0) != (s2 < 0)) {
      final t = s1 / (s1 - s2);
      out.add([p1[0] + t * (p2[0] - p1[0]), p1[1] + t * (p2[1] - p1[1])]);
    }
  }
  return out;
}

void _fill(img.Image canvas, List<List<double>> poly) {
  if (poly.length < 3) return;
  img.fillPolygon(
    canvas,
    vertices: [for (final p in poly) img.Point(p[0] * _ss, p[1] * _ss)],
    color: _paper,
  );
}

void main() {
  final big = img.Image(
      width: _size * _ss, height: _size * _ss, numChannels: 4);
  img.fillRect(big,
      x1: 0,
      y1: 0,
      x2: _size * _ss - 1,
      y2: _size * _ss - 1,
      radius: 232 * _ss,
      color: _ink);

  // Two letters, centered as a pair around x = 512.
  for (final cx in const [343.0, 681.0]) {
    final letter = _sOutline(cx);
    _fill(big, _clip(letter, above: false));
    final upper = _clip(letter, above: true);
    _fill(big, [
      for (final p in upper) [p[0] + _snapDx, p[1] + _snapDy]
    ]);
  }

  final tile = img.copyResize(big,
      width: _size, height: _size, interpolation: img.Interpolation.average);
  File('assets/images/app_logo.png')
      .writeAsBytesSync(img.encodePng(tile));

  // macOS: Apple's Big Sur template is an 824px rounded rect centered in a
  // transparent 1024px canvas.
  final margined = img.Image(width: _size, height: _size, numChannels: 4);
  img.compositeImage(margined, img.copyResize(big, width: 824, height: 824),
      dstX: 100, dstY: 100);
  Directory('build/logo').createSync(recursive: true);
  File('build/logo/macos_icon.png')
      .writeAsBytesSync(img.encodePng(margined));

  stdout.writeln('wrote assets/images/app_logo.png and build/logo/macos_icon.png');
}
