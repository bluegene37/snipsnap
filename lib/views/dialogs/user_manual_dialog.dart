import 'package:flutter/material.dart';
import '../../models/manual_topic.dart';
import '../../utils/snip_theme.dart';
import 'user_manual_data.dart';

/// A full-featured in-app User Manual and Knowledge Base dialog with real-time
/// search filtering, categorized master-detail navigation, and rich step-by-step
/// instructions.
class UserManualDialog extends StatefulWidget {
  final String? initialTopicId;
  final VoidCallback? onOpenShortcuts;

  const UserManualDialog({
    super.key,
    this.initialTopicId,
    this.onOpenShortcuts,
  });

  static Future<void> show(
    BuildContext context, {
    String? initialTopicId,
    VoidCallback? onOpenShortcuts,
  }) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => UserManualDialog(
        initialTopicId: initialTopicId,
        onOpenShortcuts: onOpenShortcuts,
      ),
    );
  }

  @override
  State<UserManualDialog> createState() => _UserManualDialogState();
}

class _UserManualDialogState extends State<UserManualDialog> {
  final TextEditingController _searchController = TextEditingController();
  late String _selectedTopicId;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    final topics = UserManualData.topics;
    if (widget.initialTopicId != null &&
        topics.any((t) => t.id == widget.initialTopicId)) {
      _selectedTopicId = widget.initialTopicId!;
    } else {
      _selectedTopicId = topics.isNotEmpty ? topics.first.id : '';
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<ManualTopic> get _filteredTopics {
    if (_searchQuery.trim().isEmpty) {
      return UserManualData.topics;
    }
    return UserManualData.topics
        .where((t) => t.matches(_searchQuery))
        .toList();
  }

  ManualTopic? get _activeTopic {
    final filtered = _filteredTopics;
    if (filtered.isEmpty) return null;
    return filtered.firstWhere(
      (t) => t.id == _selectedTopicId,
      orElse: () => filtered.first,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = SnipTheme.of(context);
    final activeTopic = _activeTopic;
    final filteredTopics = _filteredTopics;

    return Dialog(
      backgroundColor: t.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: t.border),
      ),
      child: Container(
        width: 860,
        height: 640,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children: [
            // Top Window Title Bar
            _buildDialogHeader(t),

            // Master-Detail Body Area
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Left Master Sidebar
                  _buildSidebar(t, filteredTopics),

                  // Vertical Divider
                  VerticalDivider(
                    width: 1,
                    thickness: 1,
                    color: t.border,
                  ),

                  // Right Detail Content Area
                  Expanded(
                    child: activeTopic != null
                        ? _buildContentPane(t, activeTopic)
                        : _buildEmptySearchState(t),
                  ),
                ],
              ),
            ),

            // Bottom Action Bar
            _buildDialogFooter(t),
          ],
        ),
      ),
    );
  }

  Widget _buildDialogHeader(SnipTheme t) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: t.surfaceRaised,
        border: Border(bottom: BorderSide(color: t.border)),
      ),
      child: Row(
        children: [
          Icon(Icons.menu_book_rounded, size: 20, color: t.emphasis),
          const SizedBox(width: 10),
          Text(
            'SnipSnap User Manual & Knowledge Base',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: t.ink,
              letterSpacing: 0.2,
            ),
          ),
          const Spacer(),
          IconButton(
            icon: Icon(Icons.close_rounded, size: 18, color: t.inkMuted),
            tooltip: 'Close (ESC)',
            splashRadius: 18,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _buildSidebar(SnipTheme t, List<ManualTopic> topics) {
    return Container(
      width: 260,
      color: t.surface,
      child: Column(
        children: [
          // Search Box
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchController,
              onChanged: (val) {
                setState(() {
                  _searchQuery = val;
                  // Keep the sidebar highlight and the content pane on the
                  // same topic. The sidebar marks a row selected by
                  // `_selectedTopicId`, but the pane renders `_activeTopic`,
                  // which falls back to the first match — so filtering the
                  // selection out of the results left a topic on screen with
                  // no row highlighted, and clearing the search then threw
                  // away whatever the reader had landed on. Promoting the
                  // fallback to the real selection keeps the two in step.
                  final matches = _filteredTopics;
                  if (matches.isNotEmpty &&
                      !matches.any((t) => t.id == _selectedTopicId)) {
                    _selectedTopicId = matches.first.id;
                  }
                });
              },
              style: TextStyle(fontSize: 13, color: t.ink),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Search guides & shortcuts...',
                hintStyle: TextStyle(fontSize: 12, color: t.inkMuted),
                prefixIcon: Icon(Icons.search_rounded, size: 16, color: t.inkMuted),
                prefixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: Icon(Icons.clear_rounded, size: 14, color: t.inkMuted),
                        splashRadius: 14,
                        onPressed: () {
                          _searchController.clear();
                          setState(() {
                            _searchQuery = '';
                          });
                        },
                      )
                    : null,
                suffixIconConstraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                filled: true,
                fillColor: t.surfaceRaised,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: t.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: t.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: t.borderStrong, width: 1.2),
                ),
              ),
            ),
          ),

          // Categories List
          Expanded(
            child: topics.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'No matching topics',
                        style: TextStyle(color: t.inkMuted, fontSize: 12),
                      ),
                    ),
                  )
                : SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    child: Column(
                      children: topics.map((topic) {
                        final isSelected = topic.id == _selectedTopicId;

                        return Padding(
                          key: ValueKey('topic_${topic.id}'),
                          padding: const EdgeInsets.only(bottom: 4),
                          child: InkWell(
                            onTap: () {
                              setState(() {
                                _selectedTopicId = topic.id;
                              });
                            },
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(
                              color: isSelected ? t.selectedFill : Colors.transparent,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: isSelected ? t.borderStrong : Colors.transparent,
                                width: 1,
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  topic.icon,
                                  size: 16,
                                  color: isSelected ? t.ink : t.inkMuted,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    topic.title,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                      color: isSelected ? t.ink : t.inkMuted,
                                    ),
                                  ),
                                ),
                                if (topic.badge != null) ...[
                                  const SizedBox(width: 4),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: isSelected ? t.activeFill : t.surfaceRaised,
                                      borderRadius: BorderRadius.circular(4),
                                      border: Border.all(
                                        color: isSelected ? t.activeFill : t.border,
                                        width: 0.8,
                                      ),
                                    ),
                                    child: Text(
                                      topic.badge!,
                                      style: TextStyle(
                                        fontSize: 9,
                                        fontWeight: FontWeight.w600,
                                        color: isSelected ? t.onActive : t.inkMuted,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildContentPane(SnipTheme t, ManualTopic topic) {
    return ColoredBox(
      key: const ValueKey('manual_content_pane'),
      color: t.surfaceRaised.withAlpha(80),
      child: ListView(
        key: ValueKey('content_list_${topic.id}'),
        padding: const EdgeInsets.all(24),
        children: [
          // Topic Header
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: t.surfaceRaised,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: t.border),
                ),
                child: Icon(topic.icon, size: 24, color: t.ink),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      topic.title,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: t.ink,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      topic.subtitle,
                      style: TextStyle(
                        fontSize: 13,
                        color: t.inkMuted,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 20),
          Divider(color: t.border, height: 1),
          const SizedBox(height: 20),

          // Sections
          ...topic.sections.map((section) => _buildSectionCard(t, section)),
        ],
      ),
    );
  }

  Widget _buildSectionCard(SnipTheme t, ManualSection section) {
    return Container(
      margin: const EdgeInsets.only(bottom: 18),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Section Title & Tags / Shortcuts
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  section.title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: t.ink,
                  ),
                ),
              ),
              if (section.shortcuts.isNotEmpty)
                Wrap(
                  spacing: 4,
                  children: section.shortcuts
                      .map((sc) => _buildShortcutBadge(t, sc))
                      .toList(),
                ),
            ],
          ),

          const SizedBox(height: 8),

          // Description
          SelectableText(
            section.description,
            style: TextStyle(
              fontSize: 13,
              color: t.ink,
              height: 1.45,
            ),
          ),

          // Steps list
          if (section.steps.isNotEmpty) ...[
            const SizedBox(height: 12),
            ...section.steps.asMap().entries.map((entry) {
              final idx = entry.key + 1;
              final stepText = entry.value;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 20,
                      height: 20,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: t.surfaceRaised,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: t.borderStrong, width: 0.8),
                      ),
                      child: Text(
                        '$idx',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: t.ink,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: SelectableText(
                        stepText,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: t.ink,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],

          // Tip Callout Banner
          if (section.tip != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: t.surfaceRaised,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: t.border),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.lightbulb_outline_rounded, size: 16, color: t.emphasis),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SelectableText(
                      section.tip!,
                      style: TextStyle(
                        fontSize: 12,
                        color: t.ink,
                        fontStyle: FontStyle.italic,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          // Feature Tags
          if (section.tags.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              children: section.tags.map((tag) {
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: t.surfaceRaised,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: t.border, width: 0.8),
                  ),
                  child: Text(
                    tag,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                      color: t.inkMuted,
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildShortcutBadge(SnipTheme t, String shortcutText) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: t.surfaceRaised,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: t.borderStrong, width: 0.9),
      ),
      child: Text(
        shortcutText,
        style: TextStyle(
          fontSize: 10.5,
          fontFamily: 'monospace',
          fontWeight: FontWeight.bold,
          color: t.ink,
        ),
      ),
    );
  }

  Widget _buildEmptySearchState(SnipTheme t) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_off_rounded, size: 48, color: t.inkMuted),
          const SizedBox(height: 12),
          Text(
            'No matching guides found',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: t.ink,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Try searching for tools, shortcuts, OCR, or capture modes.',
            style: TextStyle(fontSize: 13, color: t.inkMuted),
          ),
        ],
      ),
    );
  }

  Widget _buildDialogFooter(SnipTheme t) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        color: t.surfaceRaised,
        border: Border(top: BorderSide(color: t.border)),
      ),
      child: Row(
        children: [
          if (widget.onOpenShortcuts != null) ...[
            OutlinedButton.icon(
              icon: Icon(Icons.keyboard_rounded, size: 15, color: t.ink),
              label: Text(
                'Keyboard Shortcuts…',
                style: TextStyle(fontSize: 12, color: t.ink),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: t.border),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              onPressed: () {
                Navigator.of(context).pop();
                widget.onOpenShortcuts!();
              },
            ),
          ],
          const Spacer(),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: t.surfaceRaised,
              foregroundColor: t.emphasis,
              side: BorderSide(color: t.emphasis, width: 1.2),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
              ),
              elevation: 0,
            ),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text(
              'Close',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
