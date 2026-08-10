import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// Nile outlives its window on purpose.
  ///
  /// The default (true) quits the app the moment the last window closes, which
  /// on a media app means the red button silently kills a replay you were
  /// listening to and takes the menu-bar "who's live" item with it. Closing now
  /// hides the window instead (MainFlutterWindow.performClose) and the app
  /// keeps running in the Dock and the menu bar. ⌘Q is the way out.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  /// The other half of that bargain: clicking the Dock icon — or picking
  /// "Open Nile" in the menu bar — has to bring the hidden window back, or the
  /// app is running with no way to reach it.
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag { mainFlutterWindow?.makeKeyAndOrderFront(nil) }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
