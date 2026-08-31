import 'package:flutter/foundation.dart';

import 'update_info.dart';
import 'update_service.dart';

/// UI-facing state for the update checker: whether a newer release is
/// available, whether a check or download is in flight, and the actions the
/// update dialog exposes (install, skip, later).
///
/// A plain [ChangeNotifier], matching this app's setState-style state
/// handling — `_MainScreenState` owns one instance and the update widgets
/// listen to it directly.
class UpdateController extends ChangeNotifier {
  UpdateController({UpdateService? service})
    : _service = service ?? UpdateService();

  final UpdateService _service;

  UpdateInfo? _availableUpdate;
  UpdateCheckResult? _lastResult;
  bool _isChecking = false;
  bool _isDownloading = false;
  double _downloadProgress = 0;
  Object? _installError;

  UpdateInfo? get availableUpdate => _availableUpdate;
  UpdateCheckResult? get lastResult => _lastResult;
  bool get isChecking => _isChecking;
  bool get isDownloading => _isDownloading;
  double get downloadProgress => _downloadProgress;
  Object? get installError => _installError;
  UpdatePlatform get platform => _service.platform;
  String get currentVersion => _service.currentVersion.toString();

  /// Startup check: throttled, respects skipped versions, and never surfaces
  /// errors to the UI — failures only reach the debug log.
  Future<void> checkSilently() => _check(force: false, ignoreSkipped: false);

  /// User-triggered check: always hits the network and resurfaces versions
  /// the user previously skipped. [lastResult] carries upToDate/failed so
  /// the caller can show feedback.
  Future<void> checkManually() => _check(force: true, ignoreSkipped: true);

  Future<void> _check({
    required bool force,
    required bool ignoreSkipped,
  }) async {
    _isChecking = true;
    notifyListeners();
    try {
      final result = await _service.checkForUpdate(
        force: force,
        ignoreSkipped: ignoreSkipped,
      );
      _lastResult = result;
      _availableUpdate = result.status == UpdateStatus.available
          ? result.info
          : null;
    } finally {
      _isChecking = false;
      notifyListeners();
    }
  }

  /// "Skip this version": persisted; automatic checks stay quiet about it.
  Future<void> skipAvailableVersion() async {
    final update = _availableUpdate;
    if (update == null) return;
    await _service.skipVersion(update.version);
    _availableUpdate = null;
    notifyListeners();
  }

  /// "Later": hides the prompt for this session without persisting anything.
  void dismiss() {
    _availableUpdate = null;
    notifyListeners();
  }

  /// Whether [applyUpdate] installs directly — download plus silent swap and
  /// relaunch — rather than opening the release page in the browser. True on
  /// Windows and macOS when the release carries an asset for the platform;
  /// Linux always falls back to the browser (no single install format to
  /// script against).
  bool get canInstallDirectly {
    if (_availableUpdate?.asset == null) return false;
    return platform == UpdatePlatform.windows ||
        platform == UpdatePlatform.macos;
  }

  /// [canInstallDirectly]: download and hand off to the platform's detached
  /// install script (the app exits and relaunches updated). Otherwise: open
  /// the release page in the browser.
  Future<void> applyUpdate() async {
    final update = _availableUpdate;
    if (update == null) return;
    _installError = null;

    if (canInstallDirectly) {
      _isDownloading = true;
      _downloadProgress = 0;
      notifyListeners();
      void onProgress(int received, int total) {
        _downloadProgress = total > 0 ? received / total : 0;
        notifyListeners();
      }

      try {
        if (platform == UpdatePlatform.windows) {
          await _service.downloadAndInstallWindows(
            update,
            onProgress: onProgress,
          );
        } else {
          await _service.downloadAndInstallMacos(
            update,
            onProgress: onProgress,
          );
        }
      } catch (e) {
        _installError = e;
      } finally {
        _isDownloading = false;
        notifyListeners();
      }
    } else {
      await openReleasePage();
    }
  }

  /// Opens the release page in the browser — the fallback path, and the
  /// escape hatch the dialog offers after a failed direct install. Failures
  /// land in [installError] like everything else instead of escaping as an
  /// unhandled async error from a button press.
  Future<void> openReleasePage() async {
    final update = _availableUpdate;
    if (update == null) return;
    try {
      await _service.openReleasePage(update);
    } catch (e) {
      _installError = e;
      notifyListeners();
    }
  }
}
