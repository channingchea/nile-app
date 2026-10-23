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

    // Studio status link: battery and heat, sent to the Studio while this
    // phone is a camera (lib/services/camera_status.dart, DeviceStatus).
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NileDeviceStatus") {
      let channel = FlutterMethodChannel(
        name: "nile/device_status", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        guard call.method == "read" else { return result(FlutterMethodNotImplemented) }
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let level = device.batteryLevel  // -1 when unknown
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "nominal"
        }
        var out: [String: Any] = [
          "charging": device.batteryState == .charging || device.batteryState == .full,
          "thermal": thermal,
        ]
        if level >= 0 { out["battery"] = Int((level * 100).rounded()) }
        result(out)
      }
    }
  }
}
