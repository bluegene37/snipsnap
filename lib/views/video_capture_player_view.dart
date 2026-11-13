// Gene - Nov, 08, 2026: Created VideoCapturePlayerView for in-app video playback, timeline scrubbing, frame extraction as editable screenshot, and start/end clip trimming.
// Gene - Nov, 13, 2026: Upgraded to 60fps native FlutterTexture playback with audio controls, keyboard shortcuts, Snagit Cut/Trim + Undo/Restore + Save Copy, and animated GIF export bar.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/capture_item.dart';
import '../services/capture_service.dart';
import '../utils/snip_theme.dart';

class VideoCapturePlayerView extends StatefulWidget {
  final CaptureItem capture;
  final CaptureService captureService;
  final Future<void> Function(int timestampMs) onGrabFrameAsScreenshot;
  final Future<void> Function(int startMs, int endMs) onTrimVideo;
  // Gene - Nov, 13, 2026: Added optional callbacks for Snagit Cut Selection, Save Copy, Undo/Restore Original, and Animated GIF export.
  final Future<void> Function(int cutStartMs, int cutEndMs)? onCutVideo;
  final Future<void> Function(int startMs, int endMs)? onSaveTrimmedCopy;
  final Future<void> Function()? onRestoreOriginal;
  final bool canRestoreOriginal;
  final Future<void> Function({
    required int startMs,
    required int endMs,
    required int fps,
    required int maxWidth,
    required bool copyToClipboard,
  })? onExportGif;
  final VoidCallback onCopyVideo;
  final VoidCallback onSaveVideoAs;
  final VoidCallback onRevealInFolder;

  const VideoCapturePlayerView({
    super.key,
    required this.capture,
    required this.captureService,
    required this.onGrabFrameAsScreenshot,
    required this.onTrimVideo,
    this.onCutVideo,
    this.onSaveTrimmedCopy,
    this.onRestoreOriginal,
    this.canRestoreOriginal = false,
    this.onExportGif,
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
  double _volume = 1.0;
  bool _isMuted = false;
  bool _showTrimControls = false;
  bool _showGifControls = false;
  int _gifFps = 15;
  int _gifMaxWidth = 720;
  bool _gifSelectionOnly = false;
  bool _isExportingGif = false;
  late double _trimStartMs;
  late double _trimEndMs;
  bool _isTrimming = false;
  bool _isCutting = false;
  bool _isSavingCopy = false;
  bool _isGrabbingFrame = false;

  int? _textureId;
  int _nativeDurationMs = 0;
  int _nativeWidth = 0;
  int _nativeHeight = 0;
  bool _nativeHasAudio = false;
  int _playerInitToken = 0;

  String? _previewFramePath;
  bool _extractingPreview = false;
  Timer? _playTimer;
  final FocusNode _focusNode = FocusNode();

  int get _totalDurationMs {
    final candidate = _nativeDurationMs > 0
        ? _nativeDurationMs
        : (widget.capture.durationMs > 0 ? widget.capture.durationMs : 5000);
    return candidate.clamp(500, 36000000);
  }

  @override
  void initState() {
    super.initState();
    _resetForCapture();
    unawaited(_initNativePlayer());
  }

  @override
  void didUpdateWidget(covariant VideoCapturePlayerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.capture.id != widget.capture.id ||
        oldWidget.capture.filePath != widget.capture.filePath ||
        oldWidget.capture.durationMs != widget.capture.durationMs) {
      _stopPlayback();
      _disposeNativePlayer();
      _resetForCapture();
      unawaited(_initNativePlayer());
    }
  }

  void _resetForCapture() {
    _currentMs = 0;
    _nativeDurationMs = 0;
    _nativeWidth = 0;
    _nativeHeight = 0;
    _nativeHasAudio = widget.capture.hasAudio;
    _trimStartMs = 0;
    _trimEndMs = _totalDurationMs.toDouble();
    _previewFramePath = widget.capture.thumbnailPath;
  }

  Future<void> _initNativePlayer() async {
    final token = ++_playerInitToken;
    final info = await widget.captureService.createVideoPlayer(
      widget.capture.filePath,
    );
    if (!mounted || token != _playerInitToken) {
      if (info != null) {
        unawaited(widget.captureService.disposeVideoPlayer(info.textureId));
      }
      return;
    }
    if (info == null) return;
    widget.captureService.registerVideoPlayerListener(
      info.textureId,
      VideoPlayerListener(
        onProgress: (posMs, isPlaying) {
          if (!mounted || _textureId != info.textureId) return;
          setState(() {
            _currentMs = posMs.clamp(0, _totalDurationMs);
            _isPlaying = isPlaying;
          });
        },
        onCompleted: () {
          if (!mounted || _textureId != info.textureId) return;
          setState(() {
            _isPlaying = false;
            _currentMs = _totalDurationMs;
          });
        },
      ),
    );
    setState(() {
      _textureId = info.textureId;
      if (info.durationMs > 0) {
        _nativeDurationMs = info.durationMs;
        if (_trimEndMs <= 0 ||
            (_trimEndMs - widget.capture.durationMs).abs() < 250 ||
            _trimEndMs > info.durationMs) {
          _trimEndMs = _totalDurationMs.toDouble();
        }
      }
      if (info.width > 0) _nativeWidth = info.width;
      if (info.height > 0) _nativeHeight = info.height;
      _nativeHasAudio = info.hasAudio || widget.capture.hasAudio;
    });
  }

  void _disposeNativePlayer() {
    _playerInitToken++;
    final tid = _textureId;
    _textureId = null;
    if (tid != null) {
      unawaited(widget.captureService.disposeVideoPlayer(tid));
    }
  }

  @override
  void dispose() {
    _playTimer?.cancel();
    _disposeNativePlayer();
    _focusNode.dispose();
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
    if (_textureId != null) {
      final startTarget = _currentMs >= _trimEndMs.round() - 50
          ? _trimStartMs.round()
          : _currentMs;
      if (startTarget != _currentMs) {
        unawaited(widget.captureService.seekVideo(_textureId!, startTarget));
      }
      unawaited(widget.captureService.setVideoSpeed(_textureId!, _playbackSpeed));
      unawaited(widget.captureService.setVideoMuted(_textureId!, _isMuted));
      unawaited(widget.captureService.setVideoVolume(_textureId!, _volume));
      unawaited(widget.captureService.playVideo(_textureId!));
      setState(() {
        _currentMs = startTarget;
        _isPlaying = true;
      });
      return;
    }

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
    if (_textureId != null && _isPlaying) {
      unawaited(widget.captureService.pauseVideo(_textureId!));
    }
    if (mounted && _isPlaying) {
      setState(() => _isPlaying = false);
    }
  }

  void _seekTo(int targetMs) {
    final clamped = targetMs.clamp(0, _totalDurationMs);
    setState(() => _currentMs = clamped);
    if (_textureId != null) {
      unawaited(widget.captureService.seekVideo(_textureId!, clamped));
    } else {
      _requestPreviewFrame(clamped);
    }
  }

  Future<void> _requestPreviewFrame(int timestampMs) async {
    if (_textureId != null) {
      await widget.captureService.seekVideo(_textureId!, timestampMs);
      return;
    }
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

  Future<void> _handleCutSelection() async {
    if (_isCutting || widget.onCutVideo == null) return;
    _stopPlayback();
    final start = _trimStartMs.round();
    final end = _trimEndMs.round();
    if (end - start < 200) return;
    setState(() => _isCutting = true);
    try {
      await widget.onCutVideo!(start, end);
      if (mounted) {
        setState(() => _showTrimControls = false);
      }
    } finally {
      if (mounted) setState(() => _isCutting = false);
    }
  }

  Future<void> _handleSaveTrimmedCopy() async {
    if (_isSavingCopy || widget.onSaveTrimmedCopy == null) return;
    _stopPlayback();
    final start = _trimStartMs.round();
    final end = _trimEndMs.round();
    if (end - start < 200) return;
    setState(() => _isSavingCopy = true);
    try {
      await widget.onSaveTrimmedCopy!(start, end);
    } finally {
      if (mounted) setState(() => _isSavingCopy = false);
    }
  }

  Future<void> _handleExportGif({required bool copyToClipboard}) async {
    if (_isExportingGif || widget.onExportGif == null) return;
    _stopPlayback();
    final start = _gifSelectionOnly ? _trimStartMs.round() : 0;
    final end = _gifSelectionOnly ? _trimEndMs.round() : _totalDurationMs;
    if (end - start < 200) return;
    setState(() => _isExportingGif = true);
    try {
      await widget.onExportGif!(
        startMs: start,
        endMs: end,
        fps: _gifFps,
        maxWidth: _gifMaxWidth,
        copyToClipboard: copyToClipboard,
      );
    } finally {
      if (mounted) setState(() => _isExportingGif = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = SnipTheme.of(context);
    final hasPreview =
        _previewFramePath != null && File(_previewFramePath!).existsSync();
    final displayW = _nativeWidth > 0 ? _nativeWidth : widget.capture.width;
    final displayH = _nativeHeight > 0 ? _nativeHeight : widget.capture.height;
    final aspect = (displayW > 0 && displayH > 0)
        ? displayW / displayH
        : 16 / 9;

    return Focus(
      focusNode: _focusNode,
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent) {
          if (event.logicalKey == LogicalKeyboardKey.space) {
            _togglePlay();
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
            _stopPlayback();
            _seekTo(_currentMs - 33);
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            _stopPlayback();
            _seekTo(_currentMs + 33);
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: ColoredBox(
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
                              'MP4 VIDEO • $displayW×$displayH',
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
                        onTap: () => setState(() {
                          _showTrimControls = !_showTrimControls;
                          if (_showTrimControls) _showGifControls = false;
                        }),
                      ),
                      if (widget.canRestoreOriginal &&
                          widget.onRestoreOriginal != null)
                        _ActionButton(
                          key: const ValueKey('video-restore-original-btn'),
                          icon: Icons.undo_rounded,
                          label: 'Undo Edit',
                          onTap: () => unawaited(widget.onRestoreOriginal!()),
                        ),
                      if (widget.onExportGif != null)
                        _ActionButton(
                          key: const ValueKey('video-toggle-gif-btn'),
                          icon: Icons.gif_box_outlined,
                          label: 'Export GIF',
                          active: _showGifControls,
                          onTap: () => setState(() {
                            _showGifControls = !_showGifControls;
                            if (_showGifControls) _showTrimControls = false;
                          }),
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
                    onTap: () {
                      _focusNode.requestFocus();
                      _togglePlay();
                    },
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
                          if (_textureId != null)
                            AspectRatio(
                              aspectRatio: aspect,
                              child: Texture(textureId: _textureId!),
                            )
                          else if (hasPreview)
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
                                    '$displayW×$displayH • ${_formatDuration(_totalDurationMs)}',
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

            // Optional Trim & Cut Range Bar (Snagit in-place Cut + Trim + Save Copy)
            if (_showTrimControls)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: t.surfaceRaised,
                  border: Border(
                    top: BorderSide(color: t.border, width: t.hairline),
                  ),
                ),
                child: Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.content_cut_rounded, size: 16, color: t.ink),
                        const SizedBox(width: 8),
                        Text(
                          'Selection: ${_formatDuration(_trimStartMs.round())} – ${_formatDuration(_trimEndMs.round())}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: t.ink,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(
                      width: 320,
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
                          _stopPlayback();
                          setState(() {
                            _trimStartMs = values.start;
                            _trimEndMs = values.end;
                            _currentMs = _currentMs.clamp(
                              _trimStartMs.round(),
                              _trimEndMs.round(),
                            );
                          });
                          unawaited(_requestPreviewFrame(_currentMs));
                        },
                      ),
                    ),
                    if (widget.onCutVideo != null)
                      _ActionButton(
                        key: const ValueKey('video-cut-selection-btn'),
                        icon: Icons.auto_fix_off_rounded,
                        label: _isCutting ? 'Cutting…' : 'Cut Selection',
                        onTap: _isCutting ? null : _handleCutSelection,
                      ),
                    _ActionButton(
                      key: const ValueKey('video-apply-trim-btn'),
                      icon: Icons.check_rounded,
                      label: _isTrimming ? 'Trimming…' : 'Save Trimmed Clip',
                      primary: true,
                      onTap: _isTrimming ? null : _handleApplyTrim,
                    ),
                    if (widget.onSaveTrimmedCopy != null)
                      _ActionButton(
                        key: const ValueKey('video-save-copy-btn'),
                        icon: Icons.library_add_outlined,
                        label: _isSavingCopy ? 'Saving…' : 'Save Copy',
                        onTap: _isSavingCopy ? null : _handleSaveTrimmedCopy,
                      ),
                  ],
                ),
              ),

            // Optional Animated GIF Export Bar
            if (_showGifControls && widget.onExportGif != null)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: t.surfaceRaised,
                  border: Border(
                    top: BorderSide(color: t.border, width: t.hairline),
                  ),
                ),
                child: Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.gif_box_outlined, size: 16, color: t.ink),
                        const SizedBox(width: 6),
                        Text(
                          'Animated GIF:',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: t.ink,
                          ),
                        ),
                      ],
                    ),
                    for (final fpsOpt in const [10, 15, 20])
                      _SmallChoiceChip(
                        label: '$fpsOpt FPS',
                        selected: _gifFps == fpsOpt,
                        onTap: () => setState(() => _gifFps = fpsOpt),
                      ),
                    for (final resOpt in const [
                      (label: 'Original', width: 0),
                      (label: '720p', width: 720),
                      (label: '480p', width: 480),
                    ])
                      _SmallChoiceChip(
                        label: resOpt.label,
                        selected: _gifMaxWidth == resOpt.width,
                        onTap: () =>
                            setState(() => _gifMaxWidth = resOpt.width),
                      ),
                    _SmallChoiceChip(
                      label: _gifSelectionOnly ? 'Selected Range' : 'Full Video',
                      selected: _gifSelectionOnly,
                      onTap: () => setState(
                        () => _gifSelectionOnly = !_gifSelectionOnly,
                      ),
                    ),
                    _ActionButton(
                      key: const ValueKey('video-export-gif-copy-btn'),
                      icon: Icons.copy_rounded,
                      label: _isExportingGif ? 'Exporting…' : 'Copy GIF',
                      onTap: _isExportingGif
                          ? null
                          : () => _handleExportGif(copyToClipboard: true),
                    ),
                    _ActionButton(
                      key: const ValueKey('video-export-gif-save-btn'),
                      icon: Icons.download_rounded,
                      label: _isExportingGif ? 'Exporting…' : 'Save GIF As…',
                      primary: true,
                      onTap: _isExportingGif
                          ? null
                          : () => _handleExportGif(copyToClipboard: false),
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
                    key: const ValueKey('video-step-back-btn'),
                    onPressed: () {
                      _stopPlayback();
                      _seekTo(_currentMs - 33);
                    },
                    tooltip: 'Previous Frame (←)',
                    icon: Icon(
                      Icons.skip_previous_rounded,
                      size: 18,
                      color: t.ink,
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('video-play-pause-btn'),
                    onPressed: _togglePlay,
                    tooltip: _isPlaying ? 'Pause (Space)' : 'Play (Space)',
                    icon: Icon(
                      _isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      color: t.ink,
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('video-step-forward-btn'),
                    onPressed: () {
                      _stopPlayback();
                      _seekTo(_currentMs + 33);
                    },
                    tooltip: 'Next Frame (→)',
                    icon: Icon(
                      Icons.skip_next_rounded,
                      size: 18,
                      color: t.ink,
                    ),
                  ),
                  const SizedBox(width: 4),
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
                        _seekTo(value.round());
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
                  if (_nativeHasAudio) ...[
                    const SizedBox(width: 10),
                    IconButton(
                      key: const ValueKey('video-mute-btn'),
                      onPressed: () {
                        setState(() => _isMuted = !_isMuted);
                        if (_textureId != null) {
                          unawaited(
                            widget.captureService.setVideoMuted(
                              _textureId!,
                              _isMuted,
                            ),
                          );
                        }
                      },
                      tooltip: _isMuted ? 'Unmute Audio' : 'Mute Audio',
                      icon: Icon(
                        _isMuted || _volume == 0
                            ? Icons.volume_off_rounded
                            : Icons.volume_up_rounded,
                        size: 18,
                        color: t.ink,
                      ),
                    ),
                    SizedBox(
                      width: 72,
                      child: Slider(
                        key: const ValueKey('video-volume-slider'),
                        value: _isMuted ? 0.0 : _volume,
                        min: 0.0,
                        max: 1.0,
                        activeColor: t.ink,
                        inactiveColor: t.border,
                        onChanged: (v) {
                          setState(() {
                            _volume = v;
                            _isMuted = v == 0;
                          });
                          if (_textureId != null) {
                            unawaited(
                              widget.captureService.setVideoMuted(
                                _textureId!,
                                _isMuted,
                              ),
                            );
                            unawaited(
                              widget.captureService.setVideoVolume(
                                _textureId!,
                                v,
                              ),
                            );
                          }
                        },
                      ),
                    ),
                  ],
                  const SizedBox(width: 10),
                  // Speed selector
                  for (final speed in const [0.5, 1.0, 1.5, 2.0]) ...[
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(t.radius),
                        onTap: () {
                          setState(() => _playbackSpeed = speed);
                          if (_textureId != null) {
                            unawaited(
                              widget.captureService.setVideoSpeed(
                                _textureId!,
                                speed,
                              ),
                            );
                          }
                        },
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
      ),
    );
  }
}

class _SmallChoiceChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _SmallChoiceChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = SnipTheme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(t.radius),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: t.controlDecoration(active: selected, exclusive: true),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: t.controlForeground(active: selected, exclusive: true),
          ),
        ),
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
