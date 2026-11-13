import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // Gene - Nov, 13, 2026: Keep app alive when main window is hidden or closed during active screen recording or capture selection.
    // Old implementation:
    // return true
    return !CapturePlugin.isCaptureOrRecordingActive
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
