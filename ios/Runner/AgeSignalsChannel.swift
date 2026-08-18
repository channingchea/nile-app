import Flutter
import UIKit

#if canImport(DeclaredAgeRange)
import DeclaredAgeRange
#endif

/// Bridges Apple's Declared Age Range framework to Dart (P4 phase 1).
///
/// Why this exists: a birthday the user types is a claim, not age assurance.
/// Texas SB 2420 (and now Utah and Louisiana) require the app to read the age
/// category the *App Store* holds, which is the only signal a parent can
/// actually control. This channel is that read.
///
/// Everything here is optional at runtime. The framework is iOS 26+, Nile
/// deploys to iOS 13, and the request itself can fail or be declined — every
/// path returns a value Dart can act on rather than throwing, so the compliance
/// gate can always fall back to asking for a birthday.
enum AgeSignalsChannel {
  static let name = "nile/age_signals"

  static func register(
    with registrar: FlutterPluginRegistrar,
    // @escaping: the channel handler outlives this call, and resolves the
    // controller each time rather than capturing one that doesn't exist yet.
    rootViewController: @escaping () -> UIViewController?
  ) {
    let channel = FlutterMethodChannel(name: name, binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "requestAgeRange":
        let gates = (call.arguments as? [String: Any])?["gates"] as? [Int] ?? [13]
        requestAgeRange(gates: gates, presentingFrom: rootViewController(), result: result)
      case "regulatoryFeatures":
        regulatoryFeatures(result: result)
      case "showSignificantUpdate":
        let text = (call.arguments as? [String: Any])?["description"] as? String ?? ""
        showSignificantUpdate(description: text, from: rootViewController(), result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: - requestAgeRange

  private static func requestAgeRange(
    gates: [Int],
    presentingFrom controller: UIViewController?,
    result: @escaping FlutterResult
  ) {
    #if canImport(DeclaredAgeRange)
    guard #available(iOS 26.0, *), let controller else {
      result(["status": "unsupported"])
      return
    }
    // The framework takes up to three thresholds as separate arguments, so the
    // list is unpacked rather than passed along.
    let g1 = gates.first ?? 13
    let g2 = gates.count > 1 ? gates[1] : nil
    let g3 = gates.count > 2 ? gates[2] : nil

    Task { @MainActor in
      do {
        let response = try await AgeRangeService.shared.requestAgeRange(
          ageGates: g1, g2, g3, in: controller
        )
        switch response {
        case .declinedSharing:
          result(["status": "declined"])
        case .sharing(let range):
          result([
            "status": "shared",
            "lowerBound": range.lowerBound as Any,
            "upperBound": range.upperBound as Any,
            "declaration": describe(range.ageRangeDeclaration),
            // A guardian has limited who this person can communicate with.
            // Nile reads it as "no DMs, no live chat".
            "communicationLimits":
              range.activeParentalControls.contains(.communicationLimits),
          ])
        @unknown default:
          result(["status": "unsupported"])
        }
      } catch {
        // notAvailable is the ordinary case outside a regulated region, so it
        // is a value, not an error the UI has to explain.
        result(["status": "unsupported", "error": error.localizedDescription])
      }
    }
    #else
    result(["status": "unsupported"])
    #endif
  }

  #if canImport(DeclaredAgeRange)
  @available(iOS 26.0, *)
  private static func describe(_ declaration: AgeRangeService.AgeRangeDeclaration?) -> String {
    guard let declaration else { return "unknown" }
    switch declaration {
    case .selfDeclared: return "selfDeclared"
    case .guardianDeclared: return "guardianDeclared"
    default:
      // .confirmed (26.5+) and the deprecated per-method cases it replaced all
      // mean the same thing to us: something stronger than a typed birthday.
      return "confirmed"
    }
  }
  #endif

  // MARK: - regulatoryFeatures

  /// Which age rules actually apply to THIS user, per the App Store. Lets Nile
  /// enforce the strict path only where the law requires it instead of
  /// everywhere. iOS 26.4+; anything older reports nothing.
  private static func regulatoryFeatures(result: @escaping FlutterResult) {
    #if canImport(DeclaredAgeRange)
    guard #available(iOS 26.4, *) else {
      result(["supported": false, "features": [String]()])
      return
    }
    Task {
      do {
        let features = try await AgeRangeService.shared.requiredRegulatoryFeatures
        var names: [String] = []
        for feature in features {
          switch feature {
          case .declaredAgeRangeRequired: names.append("declaredAgeRangeRequired")
          case .significantAppChangeRequiresParentalConsent:
            names.append("significantAppChangeRequiresParentalConsent")
          case .significantAppChangeRequiresAdultNotification:
            names.append("significantAppChangeRequiresAdultNotification")
          @unknown default: break
          }
        }
        result(["supported": true, "features": names])
      } catch {
        result(["supported": false, "features": [String]()])
      }
    }
    #else
    result(["supported": false, "features": [String]()])
    #endif
  }

  // MARK: - showSignificantUpdate

  /// Presents Apple's system sheet telling an adult (or asking a guardian)
  /// about a significant change to the app. Phase 3 calls this; it is here now
  /// so the whole framework surface lives in one file.
  private static func showSignificantUpdate(
    description: String,
    from controller: UIViewController?,
    result: @escaping FlutterResult
  ) {
    #if canImport(DeclaredAgeRange)
    guard #available(iOS 26.4, *), let scene = controller?.view.window?.windowScene else {
      result(["status": "unsupported"])
      return
    }
    Task { @MainActor in
      do {
        try await AgeRangeService.shared.showSignificantUpdateAcknowledgment(
          in: scene, updateDescription: description
        )
        result(["status": "acknowledged"])
      } catch {
        result(["status": "failed", "error": error.localizedDescription])
      }
    }
    #else
    result(["status": "unsupported"])
    #endif
  }
}
