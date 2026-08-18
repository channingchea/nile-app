import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // P4 phase 1 — Declared Age Range. Registered against the same registry as
    // the generated plugins; the root view controller is resolved lazily
    // because the framework needs one to present its sheet on, and it does not
    // exist yet at registration time.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NileAgeSignals") {
      AgeSignalsChannel.register(with: registrar) { [weak self] in
        self?.window?.rootViewController
      }
    }
  }
}
