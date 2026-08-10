import 'annotation.dart';

class CaptureItem {
  final String id;
  final String filePath;
  final String title;
  final DateTime createdAt;
  final int width;
  final int height;
  final List<Annotation> annotations;

  CaptureItem({
    required this.id,
    required this.filePath,
    required this.title,
    required this.createdAt,
    this.width = 0,
    this.height = 0,
    this.annotations = const [],
  });

  CaptureItem copyWith({
    String? id,
    String? filePath,
    String? title,
    DateTime? createdAt,
    int? width,
    int? height,
    List<Annotation>? annotations,
  }) {
    return CaptureItem(
      id: id ?? this.id,
      filePath: filePath ?? this.filePath,
      title: title ?? this.title,
      createdAt: createdAt ?? this.createdAt,
      width: width ?? this.width,
      height: height ?? this.height,
      annotations: annotations ?? this.annotations,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'filePath': filePath,
      'title': title,
      'createdAt': createdAt.toIso8601String(),
      'width': width,
      'height': height,
    };
  }

  factory CaptureItem.fromJson(Map<String, dynamic> json) {
    return CaptureItem(
      id: json['id'] as String,
      filePath: json['filePath'] as String,
      title: json['title'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      width: json['width'] as int? ?? 0,
      height: json['height'] as int? ?? 0,
    );
  }
}
