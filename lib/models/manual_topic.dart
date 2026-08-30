import 'package:flutter/material.dart';

/// A distinct section or sub-feature within a [ManualTopic].
class ManualSection {
  final String title;
  final String description;
  final List<String> steps;
  final String? tip;
  final List<String> shortcuts;
  final List<String> tags;

  const ManualSection({
    required this.title,
    required this.description,
    this.steps = const [],
    this.tip,
    this.shortcuts = const [],
    this.tags = const [],
  });
}

/// A top-level documentation category / topic in the SnipSnap User Manual.
class ManualTopic {
  final String id;
  final String title;
  final String subtitle;
  final IconData icon;
  final String? badge;
  final List<String> keywords;
  final List<ManualSection> sections;

  const ManualTopic({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    this.badge,
    this.keywords = const [],
    required this.sections,
  });

  /// Evaluates whether this topic or any of its sections matches a query string.
  bool matches(String query) {
    if (query.trim().isEmpty) return true;
    final q = query.toLowerCase().trim();

    if (title.toLowerCase().contains(q)) return true;
    if (subtitle.toLowerCase().contains(q)) return true;
    if (badge != null && badge!.toLowerCase().contains(q)) return true;
    if (keywords.any((k) => k.toLowerCase().contains(q))) return true;

    for (final section in sections) {
      if (section.title.toLowerCase().contains(q)) return true;
      if (section.description.toLowerCase().contains(q)) return true;
      if (section.tip != null && section.tip!.toLowerCase().contains(q)) {
        return true;
      }
      if (section.steps.any((s) => s.toLowerCase().contains(q))) return true;
      if (section.shortcuts.any((sc) => sc.toLowerCase().contains(q))) {
        return true;
      }
      if (section.tags.any((t) => t.toLowerCase().contains(q))) return true;
    }

    return false;
  }
}
