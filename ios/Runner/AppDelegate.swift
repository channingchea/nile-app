import Flutter
import StoreKit
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var captureChannel: FlutterMethodChannel?
  private var captureObserver: NSObjectProtocol?

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

    // Premiere's recording blackout (lib/services/capture_guard.dart): while
    // a film plays, tell Dart whenever the screen starts or stops being
    // recorded, mirrored or AirPlayed, so it can cover the film.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NileCaptureGuard") {
      let channel = FlutterMethodChannel(
        name: "nile/capture_guard", binaryMessenger: registrar.messenger())
      captureChannel = channel
      channel.setMethodCallHandler { [weak self] call, result in
        guard call.method == "protect", let self else { return result(FlutterMethodNotImplemented) }
        let on = call.arguments as? Bool ?? false
        if let o = self.captureObserver {
          NotificationCenter.default.removeObserver(o)
          self.captureObserver = nil
        }
        if on {
          self.captureObserver = NotificationCenter.default.addObserver(
            forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main
          ) { [weak self] _ in
            self?.captureChannel?.invokeMethod("captured", arguments: UIScreen.main.isCaptured)
          }
        }
        result(on && UIScreen.main.isCaptured)
      }
    }

    // Apple's refund form for a ticket bought through the App Store
    // (lib/services/iap_service.dart, IapService.requestRefund). The Flutter
    // purchase plugin has no refund API.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NileStoreRefund") {
      let channel = FlutterMethodChannel(
        name: "nile/store_refund", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        guard call.method == "request",
          let id = (call.arguments as? String).flatMap({ UInt64($0) })
        else { return result(FlutterMethodNotImplemented) }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        else { return result("unavailable") }
        Task { @MainActor in
          do {
            let status = try await Transaction.beginRefundRequest(for: id, in: scene)
            result(status == .success ? "submitted" : "cancelled")
          } catch {
            result("failed")
          }
        }
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
