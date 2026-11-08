// Gene - Nov, 08, 2026: Created VideoCapturePlayerView for in-app video playback, timeline scrubbing, frame extraction as editable screenshot, and start/end clip trimming.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../models/capture_item.dart';
import '../services/capture_service.dart';
import '../utils/snip_theme.dart';

class VideoCapturePlayerView extends StatefulWidget {
  final CaptureItem capture;
  final CaptureService captureService;
  final Future<void> Function(int timestampMs) onGrabFrameAsScreenshot;
  final Future<void> Function(int startMs, int endMs) onTrimVideo;
  final VoidCallback onCopyVideo;
  final VoidCallback onSaveVideoAs;
  final VoidCallback onRevealInFolder;

  const VideoCapturePlayerView({
    super.key,
    required this.capture,
    required this.captureService,
    required this.onGrabFrameAsScreenshot,
    required this.onTrimVideo,
    required this.onCopyVideo,
    required this.onSaveVideoAs,
    required this.onRevealInFolder,
  });

  @override
  State<VideoCapturePlayerView> createState() => _VideoCapturePlayerViewState();
}

class _VideoCapturePlayerViewState extends State<VideoCapturePlayerView> {
  bool _isPlaying = false;
  int _currentMs = 0;
  double _playbackSpeed = 1.0;
  bool _showTrimControls = false;
  late double _trimStartMs;
  late double _trimEndMs;
  bool _isTrimming = false;
  bool _isGrabbingFrame = false;

  String? _previewFramePath;
  bool _extractingPreview = false;
  Timer? _playTimer;

  int get _totalDurationMs =>
      (widget.capture.durationMs > 0 ? widget.capture.durationMs : 5000)
          .clamp(500, 36000000);

  @override
  void initState() {
    super.initState();
    _resetForCapture();
  }

  @override
  void didUpdateWidget(covariant VideoCapturePlayerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.capture.id != widget.capture.id ||
        oldWidget.capture.filePath != widget.capture.filePath ||
        oldWidget.capture.durationMs != widget.capture.durationMs) {
      _stopPlayback();
      _resetForCapture();
    }
  }

  void _resetForCapture() {
    _currentMs = 0;
    _trimStartMs = 0;
    _trimEndMs = _totalDurationMs.toDouble();
    _previewFramePath = widget.capture.thumbnailPath;
  }

  @override
  void dispose() {
    _playTimer?.cancel();
    super.dispose();
  }

  void _togglePlay() {
    if (_isPlaying) {
      _stopPlayback();
    } else {
      _startPlayback();
    }
  }

  void _startPlayback() {
    if (_currentMs >= _trimEndMs.round()) {
      _currentMs = _trimStartMs.round();
    }
    setState(() => _isPlaying = true);
    const tickMs = 150;
    _playTimer?.cancel();
    _playTimer = Timer.periodic(const Duration(milliseconds: tickMs), (_) {
      if (!mounted || !_isPlaying) return;
      final step = (tickMs * _playbackSpeed).round();
      final nextMs = _currentMs + step;
      if (nextMs >= _trimEndMs.round()) {
        setState(() {
          _currentMs = _trimEndMs.round();
          _isPlaying = false;
        });
        _playTimer?.cancel();
        _requestPreviewFrame(_currentMs);
        return;
      }
      setState(() {
        _currentMs = nextMs;
      });
      _requestPreviewFrame(_currentMs);
    });
  }

  void _stopPlayback() {
    _playTimer?.cancel();
    _playTimer = null;
    if (mounted && _isPlaying) {
      setState(() => _isPlaying = false);
    }
  }

  Future<void> _requestPreviewFrame(int timestampMs) async {
    if (_extractingPreview) return;
    _extractingPreview = true;
    try {
      final tempDir = Directory.systemTemp;
      final outPath =
          '${tempDir.path}/snipsnap_vframe_${widget.capture.id}.png';
      final extracted = await widget.captureService.extractVideoFrame(
        videoPath: widget.capture.filePath,
        timestampMs: timestampMs,
        targetPath: outPath,
      );
      if (mounted && extracted != null) {
        await FileImage(File(extracted)).evict();
        setState(() {
          _previewFramePath = extracted;
        });
      }
    } finally {
      _extractingPreview = false;
    }
  }

  String _formatDuration(int ms) {
    final totalSecs = (ms / 1000).floor().clamp(0, 359999);
    final mins = (totalSecs ~/ 60).toString().padLeft(2, '0');
    final secs = (totalSecs % 60).toString().padLeft(2, '0');
    final tenths = ((ms % 1000) ~/ 100).clamp(0, 9);
    return '$mins:$secs.$tenths';
  }

  Future<void> _handleGrabFrame() async {
    if (_isGrabbingFrame) return;
    _stopPlayback();
    setState(() => _isGrabbingFrame = true);
    try {
      await widget.onGrabFrameAsScreenshot(_currentMs);
    } finally {
      if (mounted) setState(() => _isGrabbingFrame = false);
    }
  }

  Future<void> _handleApplyTrim() async {
    if (_isTrimming) return;
    _stopPlayback();
    final start = _trimStartMs.round();
    final end = _trimEndMs.round();
    if (end - start < 200) return;
    setState(() => _isTrimming = true);
    try {
      await widget.onTrimVideo(start, end);
      if (mounted) {
        setState(() => _showTrimControls = false);
      }
    } finally {
      if (mounted) setState(() => _isTrimming = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = SnipTheme.of(context);
    final hasPreview =
        _previewFramePath != null && File(_previewFramePath!).existsSync();

    return ColoredBox(
      color: t.canvas,
      child: Column(
        children: [
          // Top Video Info & Quick Actions Bar
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: t.surface,
              border: Border(
                bottom: BorderSide(color: t.border, width: t.hairline),
              ),
            ),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              alignment: WrapAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: t.controlDecoration(
                        active: true,
                        exclusive: false,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.videocam_rounded, size: 15, color: t.ink),
                          const SizedBox(width: 6),
                          Text(
                            'MP4 VIDEO • ${widget.capture.width}×${widget.capture.height}',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: t.ink,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 260),
                      child: Text(
                        widget.capture.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: t.ink,
                        ),
                      ),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    _ActionButton(
                      key: const ValueKey('video-grab-frame-btn'),
                      icon: Icons.add_a_photo_outlined,
                      label: _isGrabbingFrame
                          ? 'Grabbing…'
                          : 'Grab Frame as Screenshot',
                      primary: true,
                      onTap: _isGrabbingFrame ? null : _handleGrabFrame,
                    ),
                    _ActionButton(
                      key: const ValueKey('video-toggle-trim-btn'),
                      icon: Icons.content_cut_rounded,
                      label: 'Trim',
                      active: _showTrimControls,
                      onTap: () =>
                          setState(() => _showTrimControls = !_showTrimControls),
                    ),
                    _ActionButton(
                      key: const ValueKey('video-copy-btn'),
                      icon: Icons.copy_rounded,
                      label: 'Copy MP4',
                      onTap: widget.onCopyVideo,
                    ),
                    _ActionButton(
                      key: const ValueKey('video-save-as-btn'),
                      icon: Icons.download_rounded,
                      label: 'Save MP4 As…',
                      onTap: widget.onSaveVideoAs,
                    ),
                    _ActionButton(
                      key: const ValueKey('video-reveal-btn'),
                      icon: Icons.folder_open_rounded,
                      label: 'Folder',
                      onTap: widget.onRevealInFolder,
                    ),
                  ],
                ),
              ],
            ),
          ),

          // Video Frame Viewport
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: GestureDetector(
                  onTap: _togglePlay,
                  child: Container(
                    decoration: BoxDecoration(
                      color: t.surface,
                      borderRadius: BorderRadius.circular(t.radius),
                      border: Border.all(color: t.border, width: t.hairline),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        if (hasPreview)
                          Image.file(
                            File(_previewFramePath!),
                            fit: BoxFit.contain,
                            gaplessPlayback: true,
                          )
                        else
                          SizedBox(
                            width: 560,
                            height: 340,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.movie_creation_outlined,
                                  size: 56,
                                  color: t.inkMuted,
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  widget.capture.title,
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    color: t.ink,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${widget.capture.width}×${widget.capture.height} • ${_formatDuration(_totalDurationMs)}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: t.inkMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        if (!_isPlaying)
                          Container(
                            width: 60,
                            height: 60,
                            decoration: BoxDecoration(
                              color: t.activeFill,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: t.onActive,
                                width: t.activeBorderWidth,
                              ),
                            ),
                            child: Icon(
                              Icons.play_arrow_rounded,
                              size: 34,
                              color: t.onActive,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Optional Trim Range Bar
          if (_showTrimControls)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                color: t.surfaceRaised,
                border: Border(
                  top: BorderSide(color: t.border, width: t.hairline),
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.content_cut_rounded, size: 16, color: t.ink),
                  const SizedBox(width: 8),
                  Text(
                    'Trim Range: ${_formatDuration(_trimStartMs.round())} – ${_formatDuration(_trimEndMs.round())}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: t.ink,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: RangeSlider(
                      values: RangeValues(
                        _trimStartMs.clamp(0, _totalDurationMs.toDouble()),
                        _trimEndMs.clamp(0, _totalDurationMs.toDouble()),
                      ),
                      min: 0,
                      max: _totalDurationMs.toDouble(),
                      activeColor: t.ink,
                      inactiveColor: t.border,
                      onChanged: (values) {
                        if (values.end - values.start < 200) return;
                        setState(() {
                          _trimStartMs = values.start;
                          _trimEndMs = values.end;
                          _currentMs = _currentMs.clamp(
                            _trimStartMs.round(),
                            _trimEndMs.round(),
                          );
                        });
                        _requestPreviewFrame(_currentMs);
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  _ActionButton(
                    key: const ValueKey('video-apply-trim-btn'),
                    icon: Icons.check_rounded,
                    label: _isTrimming ? 'Trimming…' : 'Save Trimmed Clip',
                    primary: true,
                    onTap: _isTrimming ? null : _handleApplyTrim,
                  ),
                ],
              ),
            ),

          // Bottom Transport & Scrubbing Controls
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(
              color: t.surface,
              border: Border(
                top: BorderSide(color: t.border, width: t.hairline),
              ),
            ),
            child: Row(
              children: [
                IconButton(
                  key: const ValueKey('video-play-pause-btn'),
                  onPressed: _togglePlay,
                  tooltip: _isPlaying ? 'Pause' : 'Play',
                  icon: Icon(
                    _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    color: t.ink,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  _formatDuration(_currentMs),
                  style: TextStyle(
                    fontSize: 12,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    fontWeight: FontWeight.w600,
                    color: t.ink,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Slider(
                    key: const ValueKey('video-scrub-slider'),
                    value: _currentMs
                        .toDouble()
                        .clamp(0, _totalDurationMs.toDouble()),
                    min: 0,
                    max: _totalDurationMs.toDouble(),
                    activeColor: t.ink,
                    inactiveColor: t.border,
                    onChanged: (value) {
                      _stopPlayback();
                      final ms = value.round();
                      setState(() => _currentMs = ms);
                      _requestPreviewFrame(ms);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _formatDuration(_totalDurationMs),
                  style: TextStyle(
                    fontSize: 12,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: t.inkMuted,
                  ),
                ),
                const SizedBox(width: 14),
                // Speed selector
                for (final speed in const [0.5, 1.0, 1.5, 2.0]) ...[
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(t.radius),
                      onTap: () => setState(() => _playbackSpeed = speed),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 4,
                        ),
                        decoration: t.controlDecoration(
                          active: _playbackSpeed == speed,
                          exclusive: true,
                        ),
                        child: Text(
                          '${speed}x',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: t.controlForeground(
                              active: _playbackSpeed == speed,
                              exclusive: true,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool primary;
  final bool active;
  final VoidCallback? onTap;

  const _ActionButton({
    super.key,
    required this.icon,
    required this.label,
    this.primary = false,
    this.active = false,
    this.onTap,
  });

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = SnipTheme.of(context);
    final isActive = widget.primary || widget.active;
    final enabled = widget.onTap != null;
    final fg = t.controlForeground(
      active: isActive,
      exclusive: widget.primary,
      enabled: enabled,
    );

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: t.controlDecoration(
            active: isActive,
            exclusive: widget.primary,
            hover: _hover,
            enabled: enabled,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, size: 14, color: fg),
              const SizedBox(width: 6),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
