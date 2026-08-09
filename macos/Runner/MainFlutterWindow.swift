import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// Below this the Dart side swaps in the phone shell (NileBreakpoints), which
  /// is not a layout a Mac window should ever be able to reach.
  private static let minimumSize = NSSize(width: 740, height: 600)

  /// Cocoa persists the window frame under this key, so the size the user
  /// settles on is what they get next launch.
  private static let frameAutosaveName = "NileMainWindow"

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    self.minSize = MainFlutterWindow.minimumSize

    // First launch only: open filling the screen rather than at the
    // storyboard's default, which lands in the narrow layout and makes the
    // desktop shell look like a phone app in a window.
    // setFrameUsingName returns false when nothing has been saved yet.
    //
    // setIsZoomed rather than setFrame(screen.visibleFrame): AppKit works out
    // the maximised rect itself, accounting for the menu bar, the Dock, the
    // notch and the title bar. Doing that arithmetic by hand lands ~30 pt short
    // at the top.
    if !self.setFrameUsingName(MainFlutterWindow.frameAutosaveName) {
      self.setIsZoomed(true)
    }
    _ = self.setFrameAutosaveName(MainFlutterWindow.frameAutosaveName)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
