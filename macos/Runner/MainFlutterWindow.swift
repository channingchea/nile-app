import Cocoa
import FlutterMacOS
import ServiceManagement

class MainFlutterWindow: NSWindow {
  /// Below this the Dart side swaps in the phone shell (NileBreakpoints), which
  /// is not a layout a Mac window should ever be able to reach.
  private static let minimumSize = NSSize(width: 740, height: 600)

  /// Cocoa persists the window frame under this key, so the size the user
  /// settles on is what they get next launch.
  private static let frameAutosaveName = "NileMainWindow"

  /// Retained for the window's lifetime. A FlutterMethodChannel stops
  /// delivering the moment nothing holds a reference to it.
  private var hostChannel: FlutterMethodChannel?

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
    installHostChannel(flutterViewController)

    super.awakeFromNib()
  }

  /// Closing the window hides it instead of destroying it.
  ///
  /// Nile deliberately outlives its window (see AppDelegate) so that a replay
  /// keeps playing and the menu-bar item keeps reporting who is live. A real
  /// close would take the FlutterViewController — and with it the engine's
  /// view — down as well, so the red button, ⌘W and Window ▸ Close all order
  /// out instead. ⌘Q still quits, and clicking the Dock icon brings this
  /// window back.
  override func performClose(_ sender: Any?) {
    self.orderOut(sender)
  }

  // MARK: - nile/macos

  /// The AppKit surface Dart needs and no plugin owns: the window title, the
  /// Dock badge, showing and hiding this window, and the login item.
  private func installHostChannel(_ controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "nile/macos",
      binaryMessenger: controller.engine.binaryMessenger
    )

    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "setWindowTitle":
        self?.title = call.arguments as? String ?? "Nile"
        result(nil)

      case "setDockBadge":
        // Empty string clears it — nil badgeLabel is "no badge", "" is a badge
        // with nothing in it.
        let label = call.arguments as? String ?? ""
        NSApp.dockTile.badgeLabel = label.isEmpty ? nil : label
        result(nil)

      case "showWindow":
        NSApp.activate(ignoringOtherApps: true)
        self?.makeKeyAndOrderFront(nil)
        result(nil)

      case "hideWindow":
        self?.orderOut(nil)
        result(nil)

      case "quit":
        NSApp.terminate(nil)
        result(nil)

      // The emoji picker. Normally the "Emoji & Symbols" item in the Edit menu
      // sends this, but that menu comes from MainMenu.xib and Flutter's
      // PlatformMenuBar replaces the whole bar on the first frame — so the Dart
      // side owns the item and calls the selector through here instead.
      case "showCharacterPalette":
        NSApp.orderFrontCharacterPalette(nil)
        result(nil)

      // SMAppService rather than the launch_at_startup plugin: that plugin has
      // no macOS implementation of its own and expects the LaunchAtLogin Swift
      // Package to be added to this Xcode project. SMAppService is one system
      // API, needs no new dependency, and is what Apple points at now that the
      // old login-item helper is deprecated. It arrived in macOS 13 and the
      // deployment target is 12.0, so on Monterey both calls report unsupported
      // by returning nil and Settings hides the row rather than showing a
      // switch that cannot move.
      case "launchAtLoginState":
        if #available(macOS 13.0, *) {
          result(SMAppService.mainApp.status == .enabled)
        } else {
          result(nil)
        }

      case "setLaunchAtLogin":
        guard #available(macOS 13.0, *) else {
          result(nil)
          return
        }
        do {
          // register() throws when it is already registered, and the two can
          // drift out of step if the user removed the item in System Settings,
          // so both directions check the live status first.
          if call.arguments as? Bool ?? false {
            if SMAppService.mainApp.status != .enabled {
              try SMAppService.mainApp.register()
            }
          } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
          }
          result(SMAppService.mainApp.status == .enabled)
        } catch {
          result(
            FlutterError(
              code: "launch_at_login",
              message: error.localizedDescription,
              details: nil
            )
          )
        }

      default:
        result(FlutterMethodNotImplemented)
      }
    }

    hostChannel = channel
  }
}
