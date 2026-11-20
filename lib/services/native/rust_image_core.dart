// Gene - Nov, 20, 2026: Zero-package dart:ffi bridge to native Rust snipsnap_core pixel manipulation routines.
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

typedef _MallocNative = ffi.Pointer<ffi.Void> Function(ffi.Size size);
typedef _MallocDart = ffi.Pointer<ffi.Void> Function(int size);
typedef _FreeNative = ffi.Void Function(ffi.Pointer<ffi.Void> ptr);
typedef _FreeDart = void Function(ffi.Pointer<ffi.Void> ptr);

typedef _FloodFillNative =
    ffi.Bool Function(
      ffi.Pointer<ffi.Uint8> rgba,
      ffi.Int32 width,
      ffi.Int32 height,
      ffi.Int32 startX,
      ffi.Int32 startY,
      ffi.Uint32 fillRgba,
      ffi.Float tolerancePercent,
      ffi.Float opacity,
      ffi.Bool isGlobal,
    );
typedef _FloodFillDart =
    bool Function(
      ffi.Pointer<ffi.Uint8> rgba,
      int width,
      int height,
      int startX,
      int startY,
      int fillRgba,
      double tolerancePercent,
      double opacity,
      bool isGlobal,
    );

typedef _CropNative =
    ffi.Bool Function(
      ffi.Pointer<ffi.Uint8> src,
      ffi.Int32 srcW,
      ffi.Int32 srcH,
      ffi.Int32 cropX,
      ffi.Int32 cropY,
      ffi.Int32 cropW,
      ffi.Int32 cropH,
      ffi.Pointer<ffi.Uint8> dst,
    );
typedef _CropDart =
    bool Function(
      ffi.Pointer<ffi.Uint8> src,
      int srcW,
      int srcH,
      int cropX,
      int cropY,
      int cropW,
      int cropH,
      ffi.Pointer<ffi.Uint8> dst,
    );

typedef _RectOpNative =
    ffi.Bool Function(
      ffi.Pointer<ffi.Uint8> rgba,
      ffi.Int32 width,
      ffi.Int32 height,
      ffi.Int32 rectX,
      ffi.Int32 rectY,
      ffi.Int32 rectW,
      ffi.Int32 rectH,
    );
typedef _RectOpDart =
    bool Function(
      ffi.Pointer<ffi.Uint8> rgba,
      int width,
      int height,
      int rectX,
      int rectY,
      int rectW,
      int rectH,
    );

typedef _RectParamOpNative =
    ffi.Bool Function(
      ffi.Pointer<ffi.Uint8> rgba,
      ffi.Int32 width,
      ffi.Int32 height,
      ffi.Int32 rectX,
      ffi.Int32 rectY,
      ffi.Int32 rectW,
      ffi.Int32 rectH,
      ffi.Int32 param,
    );
typedef _RectParamOpDart =
    bool Function(
      ffi.Pointer<ffi.Uint8> rgba,
      int width,
      int height,
      int rectX,
      int rectY,
      int rectW,
      int rectH,
      int param,
    );

typedef _CompositeNative =
    ffi.Bool Function(
      ffi.Pointer<ffi.Uint8> dst,
      ffi.Int32 dstW,
      ffi.Int32 dstH,
      ffi.Pointer<ffi.Uint8> src,
      ffi.Int32 srcW,
      ffi.Int32 srcH,
      ffi.Int32 dstX,
      ffi.Int32 dstY,
    );
typedef _CompositeDart =
    bool Function(
      ffi.Pointer<ffi.Uint8> dst,
      int dstW,
      int dstH,
      ffi.Pointer<ffi.Uint8> src,
      int srcW,
      int srcH,
      int dstX,
      int dstY,
    );

typedef _ResizeNative =
    ffi.Bool Function(
      ffi.Pointer<ffi.Uint8> src,
      ffi.Int32 srcW,
      ffi.Int32 srcH,
      ffi.Pointer<ffi.Uint8> dst,
      ffi.Int32 dstW,
      ffi.Int32 dstH,
    );
typedef _ResizeDart =
    bool Function(
      ffi.Pointer<ffi.Uint8> src,
      int srcW,
      int srcH,
      ffi.Pointer<ffi.Uint8> dst,
      int dstW,
      int dstH,
    );

class _RustBindings {
  final ffi.DynamicLibrary library;
  final _MallocDart malloc;
  final _FreeDart free;
  final _FloodFillDart floodFillRgba;
  final _CropDart cropRgba;
  final _RectOpDart eraseRectRgba;
  final _CompositeDart compositeRgba;
  final _ResizeDart resizeRgba;
  final _RectParamOpDart pixelateRegionRgba;
  final _RectParamOpDart boxBlurRegionRgba;

  _RustBindings._({
    required this.library,
    required this.malloc,
    required this.free,
    required this.floodFillRgba,
    required this.cropRgba,
    required this.eraseRectRgba,
    required this.compositeRgba,
    required this.resizeRgba,
    required this.pixelateRegionRgba,
    required this.boxBlurRegionRgba,
  });

  static _RustBindings? tryLoad() {
    final lib = _openSnipsnapLibrary();
    if (lib == null) return null;

    final libc = _openCAllocatorLibrary(lib);
    if (libc == null) return null;

    try {
      final malloc = libc.lookupFunction<_MallocNative, _MallocDart>('malloc');
      final free = libc.lookupFunction<_FreeNative, _FreeDart>('free');
      final floodFill = lib.lookupFunction<_FloodFillNative, _FloodFillDart>(
        'snipsnap_flood_fill_rgba',
      );
      final crop = lib.lookupFunction<_CropNative, _CropDart>(
        'snipsnap_crop_rgba',
      );
      final erase = lib.lookupFunction<_RectOpNative, _RectOpDart>(
        'snipsnap_erase_rect_rgba',
      );
      final composite = lib.lookupFunction<_CompositeNative, _CompositeDart>(
        'snipsnap_composite_rgba',
      );
      final resize = lib.lookupFunction<_ResizeNative, _ResizeDart>(
        'snipsnap_resize_rgba',
      );
      final pixelate = lib.lookupFunction<_RectParamOpNative, _RectParamOpDart>(
        'snipsnap_pixelate_region_rgba',
      );
      final blur = lib.lookupFunction<_RectParamOpNative, _RectParamOpDart>(
        'snipsnap_box_blur_region_rgba',
      );

      return _RustBindings._(
        library: lib,
        malloc: malloc,
        free: free,
        floodFillRgba: floodFill,
        cropRgba: crop,
        eraseRectRgba: erase,
        compositeRgba: composite,
        resizeRgba: resize,
        pixelateRegionRgba: pixelate,
        boxBlurRegionRgba: blur,
      );
    } catch (_) {
      return null;
    }
  }

  static ffi.DynamicLibrary? _openSnipsnapLibrary() {
    try {
      final proc = ffi.DynamicLibrary.process();
      if (proc.providesSymbol('snipsnap_flood_fill_rgba') &&
          proc.providesSymbol('snipsnap_crop_rgba') &&
          proc.providesSymbol('snipsnap_box_blur_region_rgba')) {
        return proc;
      }
    } catch (_) {}

    final candidates = <String>[
      if (Platform.isMacOS) ...[
        'libsnipsnap_core.dylib',
        'native/snipsnap_core/target/release/libsnipsnap_core.dylib',
        'native/snipsnap_core/target/debug/libsnipsnap_core.dylib',
      ] else if (Platform.isWindows) ...[
        'snipsnap_core.dll',
        'native/snipsnap_core/target/x86_64-pc-windows-msvc/release/snipsnap_core.dll',
        'native/snipsnap_core/target/release/snipsnap_core.dll',
      ] else if (Platform.isLinux) ...[
        'libsnipsnap_core.so',
        'native/snipsnap_core/target/release/libsnipsnap_core.so',
      ],
    ];

    for (final path in candidates) {
      try {
        final dylib = ffi.DynamicLibrary.open(path);
        if (dylib.providesSymbol('snipsnap_flood_fill_rgba') &&
            dylib.providesSymbol('snipsnap_crop_rgba')) {
          return dylib;
        }
      } catch (_) {}
    }
    return null;
  }

  static ffi.DynamicLibrary? _openCAllocatorLibrary(ffi.DynamicLibrary core) {
    if (core.providesSymbol('malloc') && core.providesSymbol('free')) {
      return core;
    }
    try {
      final proc = ffi.DynamicLibrary.process();
      if (proc.providesSymbol('malloc') && proc.providesSymbol('free')) {
        return proc;
      }
    } catch (_) {}

    final allocatorNames = Platform.isWindows
        ? const ['ucrtbase.dll', 'msvcrt.dll']
        : Platform.isMacOS
        ? const ['libSystem.B.dylib']
        : const ['libc.so.6'];

    for (final name in allocatorNames) {
      try {
        final lib = ffi.DynamicLibrary.open(name);
        if (lib.providesSymbol('malloc') && lib.providesSymbol('free')) {
          return lib;
        }
      } catch (_) {}
    }
    return null;
  }
}

class RustImageCore {
  RustImageCore._();

  static final _RustBindings? _bindings = _RustBindings.tryLoad();

  static bool get isAvailable => _bindings != null;

  static ffi.Pointer<ffi.Uint8> _allocAndCopy(
    _RustBindings b,
    Uint8List source,
    int byteCount,
  ) {
    final raw = b.malloc(byteCount);
    if (raw.address == 0) {
      throw StateError('Failed to allocate $byteCount native bytes');
    }
    final typed = raw.cast<ffi.Uint8>();
    typed.asTypedList(byteCount).setRange(0, byteCount, source);
    return typed;
  }

  static bool floodFillRgba({
    required Uint8List rgba,
    required int width,
    required int height,
    required int startX,
    required int startY,
    required int fillRgbaPacked,
    double tolerancePercent = 15.0,
    double opacity = 1.0,
    bool isGlobal = false,
  }) {
    final b = _bindings;
    if (b == null) return false;
    final len = width * height * 4;
    if (len <= 0 || rgba.length < len) return false;

    final ptr = _allocAndCopy(b, rgba, len);
    try {
      final changed = b.floodFillRgba(
        ptr,
        width,
        height,
        startX,
        startY,
        fillRgbaPacked,
        tolerancePercent,
        opacity,
        isGlobal,
      );
      if (changed) {
        rgba.setRange(0, len, ptr.asTypedList(len));
      }
      return changed;
    } finally {
      b.free(ptr.cast<ffi.Void>());
    }
  }

  static Uint8List? cropRgba({
    required Uint8List src,
    required int srcWidth,
    required int srcHeight,
    required int cropX,
    required int cropY,
    required int cropWidth,
    required int cropHeight,
  }) {
    final b = _bindings;
    if (b == null) return null;
    final srcLen = srcWidth * srcHeight * 4;
    final dstLen = cropWidth * cropHeight * 4;
    if (srcLen <= 0 || dstLen <= 0 || src.length < srcLen) return null;

    final srcPtr = _allocAndCopy(b, src, srcLen);
    final dstVoid = b.malloc(dstLen);
    if (dstVoid.address == 0) {
      b.free(srcPtr.cast<ffi.Void>());
      return null;
    }
    final dstPtr = dstVoid.cast<ffi.Uint8>();
    try {
      final ok = b.cropRgba(
        srcPtr,
        srcWidth,
        srcHeight,
        cropX,
        cropY,
        cropWidth,
        cropHeight,
        dstPtr,
      );
      if (!ok) return null;
      return Uint8List.fromList(dstPtr.asTypedList(dstLen));
    } finally {
      b.free(srcPtr.cast<ffi.Void>());
      b.free(dstVoid);
    }
  }

  static bool eraseRectRgba({
    required Uint8List rgba,
    required int width,
    required int height,
    required int rectX,
    required int rectY,
    required int rectW,
    required int rectH,
  }) {
    final b = _bindings;
    if (b == null) return false;
    final len = width * height * 4;
    if (len <= 0 || rgba.length < len) return false;

    final ptr = _allocAndCopy(b, rgba, len);
    try {
      final ok = b.eraseRectRgba(
        ptr,
        width,
        height,
        rectX,
        rectY,
        rectW,
        rectH,
      );
      if (ok) {
        rgba.setRange(0, len, ptr.asTypedList(len));
      }
      return ok;
    } finally {
      b.free(ptr.cast<ffi.Void>());
    }
  }

  static bool compositeRgba({
    required Uint8List dst,
    required int dstWidth,
    required int dstHeight,
    required Uint8List src,
    required int srcWidth,
    required int srcHeight,
    required int dstX,
    required int dstY,
  }) {
    final b = _bindings;
    if (b == null) return false;
    final dstLen = dstWidth * dstHeight * 4;
    final srcLen = srcWidth * srcHeight * 4;
    if (dstLen <= 0 ||
        srcLen <= 0 ||
        dst.length < dstLen ||
        src.length < srcLen) {
      return false;
    }

    final dstPtr = _allocAndCopy(b, dst, dstLen);
    final srcPtr = _allocAndCopy(b, src, srcLen);
    try {
      final ok = b.compositeRgba(
        dstPtr,
        dstWidth,
        dstHeight,
        srcPtr,
        srcWidth,
        srcHeight,
        dstX,
        dstY,
      );
      if (ok) {
        dst.setRange(0, dstLen, dstPtr.asTypedList(dstLen));
      }
      return ok;
    } finally {
      b.free(dstPtr.cast<ffi.Void>());
      b.free(srcPtr.cast<ffi.Void>());
    }
  }

  static Uint8List? resizeRgba({
    required Uint8List src,
    required int srcWidth,
    required int srcHeight,
    required int dstWidth,
    required int dstHeight,
  }) {
    final b = _bindings;
    if (b == null) return null;
    final srcLen = srcWidth * srcHeight * 4;
    final dstLen = dstWidth * dstHeight * 4;
    if (srcLen <= 0 || dstLen <= 0 || src.length < srcLen) return null;

    final srcPtr = _allocAndCopy(b, src, srcLen);
    final dstVoid = b.malloc(dstLen);
    if (dstVoid.address == 0) {
      b.free(srcPtr.cast<ffi.Void>());
      return null;
    }
    final dstPtr = dstVoid.cast<ffi.Uint8>();
    try {
      final ok = b.resizeRgba(
        srcPtr,
        srcWidth,
        srcHeight,
        dstPtr,
        dstWidth,
        dstHeight,
      );
      if (!ok) return null;
      return Uint8List.fromList(dstPtr.asTypedList(dstLen));
    } finally {
      b.free(srcPtr.cast<ffi.Void>());
      b.free(dstVoid);
    }
  }

  static bool pixelateRegionRgba({
    required Uint8List rgba,
    required int width,
    required int height,
    required int rectX,
    required int rectY,
    required int rectW,
    required int rectH,
    required int blockSize,
  }) {
    final b = _bindings;
    if (b == null) return false;
    final len = width * height * 4;
    if (len <= 0 || rgba.length < len) return false;

    final ptr = _allocAndCopy(b, rgba, len);
    try {
      final ok = b.pixelateRegionRgba(
        ptr,
        width,
        height,
        rectX,
        rectY,
        rectW,
        rectH,
        blockSize,
      );
      if (ok) {
        rgba.setRange(0, len, ptr.asTypedList(len));
      }
      return ok;
    } finally {
      b.free(ptr.cast<ffi.Void>());
    }
  }

  static bool boxBlurRegionRgba({
    required Uint8List rgba,
    required int width,
    required int height,
    required int rectX,
    required int rectY,
    required int rectW,
    required int rectH,
    required int radius,
  }) {
    final b = _bindings;
    if (b == null) return false;
    final len = width * height * 4;
    if (len <= 0 || rgba.length < len) return false;

    final ptr = _allocAndCopy(b, rgba, len);
    try {
      final ok = b.boxBlurRegionRgba(
        ptr,
        width,
        height,
        rectX,
        rectY,
        rectW,
        rectH,
        radius,
      );
      if (ok) {
        rgba.setRange(0, len, ptr.asTypedList(len));
      }
      return ok;
    } finally {
      b.free(ptr.cast<ffi.Void>());
    }
  }
}
