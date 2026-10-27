import 'annotation.dart';

// Gene - Oct, 27, 2026: Added CaptureMediaType enum to support still image and video screen recordings.
enum CaptureMediaType {
  image,
  video;

  static CaptureMediaType fromString(String? value) {
    if (value == 'video') return CaptureMediaType.video;
    return CaptureMediaType.image;
  }
}

class CaptureItem {
  final String id;
  final String filePath;
  final String title;
  final DateTime createdAt;
  final int width;
  final int height;
  final List<Annotation> annotations;

  /// True when this capture's annotations were loaded from pre-v4 rows and
  /// still hold viewport coordinates. Cleared once converted.
  final bool annotationsNeedConversion;

  // Gene - Oct, 27, 2026: Added video recording fields for Phase 1 of screen recording.
  final CaptureMediaType mediaType;
  final int durationMs;
  final bool hasAudio;
  final String? thumbnailPath;

  bool get isVideo => mediaType == CaptureMediaType.video;
  bool get isImage => mediaType == CaptureMediaType.image;

  // Gene - Oct, 27, 2026: Updated constructor to accept mediaType, durationMs, hasAudio, and thumbnailPath.
  // Old constructor:
  // CaptureItem({
  //   required this.id,
  //   required this.filePath,
  //   required this.title,
  //   required this.createdAt,
  //   this.width = 0,
  //   this.height = 0,
  //   this.annotations = const [],
  //   this.annotationsNeedConversion = false,
  // });
  CaptureItem({
    required this.id,
    required this.filePath,
    required this.title,
    required this.createdAt,
    this.width = 0,
    this.height = 0,
    this.annotations = const [],
    this.annotationsNeedConversion = false,
    this.mediaType = CaptureMediaType.image,
    this.durationMs = 0,
    this.hasAudio = false,
    this.thumbnailPath,
  });

  /// True when both dimensions were recorded. Captures created before
  /// dimensions were persisted report false and must be decoded to recover.
  bool get hasDimensions => width > 0 && height > 0;

  // Gene - Oct, 27, 2026: Updated copyWith to support video recording properties.
  // Old implementation:
  // CaptureItem copyWith({
  //   String? id,
  //   String? filePath,
  //   String? title,
  //   DateTime? createdAt,
  //   int? width,
  //   int? height,
  //   List<Annotation>? annotations,
  //   bool? annotationsNeedConversion,
  // }) {
  //   return CaptureItem(
  //     id: id ?? this.id,
  //     filePath: filePath ?? this.filePath,
  //     title: title ?? this.title,
  //     createdAt: createdAt ?? this.createdAt,
  //     width: width ?? this.width,
  //     height: height ?? this.height,
  //     annotations: annotations ?? this.annotations,
  //     annotationsNeedConversion:
  //         annotationsNeedConversion ?? this.annotationsNeedConversion,
  //   );
  // }
  CaptureItem copyWith({
    String? id,
    String? filePath,
    String? title,
    DateTime? createdAt,
    int? width,
    int? height,
    List<Annotation>? annotations,
    bool? annotationsNeedConversion,
    CaptureMediaType? mediaType,
    int? durationMs,
    bool? hasAudio,
    String? thumbnailPath,
  }) {
    return CaptureItem(
      id: id ?? this.id,
      filePath: filePath ?? this.filePath,
      title: title ?? this.title,
      createdAt: createdAt ?? this.createdAt,
      width: width ?? this.width,
      height: height ?? this.height,
      annotations: annotations ?? this.annotations,
      annotationsNeedConversion:
          annotationsNeedConversion ?? this.annotationsNeedConversion,
      mediaType: mediaType ?? this.mediaType,
      durationMs: durationMs ?? this.durationMs,
      hasAudio: hasAudio ?? this.hasAudio,
      thumbnailPath: thumbnailPath ?? this.thumbnailPath,
    );
  }

  // Gene - Oct, 27, 2026: Updated toJson to serialize mediaType, durationMs, hasAudio, and thumbnailPath.
  // Old implementation:
  // Map<String, dynamic> toJson() {
  //   return {
  //     'id': id,
  //     'filePath': filePath,
  //     'title': title,
  //     'createdAt': createdAt.toIso8601String(),
  //     'width': width,
  //     'height': height,
  //   };
  // }
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'filePath': filePath,
      'title': title,
      'createdAt': createdAt.toIso8601String(),
      'width': width,
      'height': height,
      'mediaType': mediaType.name,
      'durationMs': durationMs,
      'hasAudio': hasAudio,
      if (thumbnailPath != null) 'thumbnailPath': thumbnailPath,
    };
  }

  // Gene - Oct, 27, 2026: Updated fromJson to deserialize video recording properties.
  // Old implementation:
  // factory CaptureItem.fromJson(Map<String, dynamic> json) {
  //   return CaptureItem(
  //     id: json['id'] as String,
  //     filePath: json['filePath'] as String,
  //     title: json['title'] as String,
  //     createdAt: DateTime.parse(json['createdAt'] as String),
  //     width: json['width'] as int? ?? 0,
  //     height: json['height'] as int? ?? 0,
  //   );
  // }
  factory CaptureItem.fromJson(Map<String, dynamic> json) {
    return CaptureItem(
      id: json['id'] as String,
      filePath: json['filePath'] as String,
      title: json['title'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      width: json['width'] as int? ?? 0,
      height: json['height'] as int? ?? 0,
      mediaType: CaptureMediaType.fromString(json['mediaType'] as String?),
      durationMs: json['durationMs'] as int? ?? 0,
      hasAudio: json['hasAudio'] as bool? ?? false,
      thumbnailPath: json['thumbnailPath'] as String?,
    );
  }
}
