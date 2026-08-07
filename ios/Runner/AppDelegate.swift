import Flutter
import Foundation
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let safeDiagnosticChannelName = "emby_my_client/safe_diagnostic_export"
  private let safeDiagnosticExportGate = SafeDiagnosticExportResultGate()
  private let safeDiagnosticTemporaryStore = SafeDiagnosticExportTemporaryStore()
  private var safeDiagnosticPresentationCoordinator:
    SafeDiagnosticExportPresentationCoordinator?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    safeDiagnosticTemporaryStore.cleanupStale()
    GeneratedPluginRegistrant.register(with: self)
    let didFinishLaunching = super.application(
      application,
      didFinishLaunchingWithOptions: launchOptions
    )
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: safeDiagnosticChannelName,
        binaryMessenger: controller.binaryMessenger
      )
      channel.setMethodCallHandler { [weak self] call, result in
        guard let self else {
          result(Self.safeDiagnosticError(code: "DIAG-EXPORT-SHARE"))
          return
        }
        self.handleSafeDiagnosticCall(call, result: result)
      }
    }
    return didFinishLaunching
  }

  private func handleSafeDiagnosticCall(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    switch call.method {
    case "metadata":
      guard
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
        SafeDiagnosticExportValidator.isValidAppVersion(appVersion),
        SafeDiagnosticExportValidator.isValidBuildNumber(buildNumber)
      else {
        result(Self.safeDiagnosticError(code: "DIAG-EXPORT-UNSAFE"))
        return
      }
      result(["appVersion": appVersion, "buildNumber": buildNumber])

    case "share":
      handleSafeDiagnosticShare(call.arguments, result: result)

    default:
      result(Self.safeDiagnosticError(code: "DIAG-EXPORT-UNSAFE"))
    }
  }

  private func handleSafeDiagnosticShare(
    _ argumentsValue: Any?,
    result: @escaping FlutterResult
  ) {
    guard safeDiagnosticExportGate.begin() else {
      result(Self.safeDiagnosticError(code: "DIAG-EXPORT-BUSY"))
      return
    }

    let completionGate = SafeDiagnosticExportCompletionGate()
    var sessionDirectory: URL?
    func finish(_ value: Any?) {
      completionGate.complete { [weak self] in
        self?.finishSafeDiagnosticShare(
          value,
          sessionDirectory: sessionDirectory,
          result: result
        )
      }
    }

    safeDiagnosticTemporaryStore.cleanupStale()
    guard
      let arguments = argumentsValue as? [String: Any],
      Set(arguments.keys) == Set(["content", "x", "y", "width", "height"]),
      let content = arguments["content"] as? String,
      let data = content.data(using: .utf8),
      let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
      let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    else {
      finish(Self.safeDiagnosticError(code: "DIAG-EXPORT-UNSAFE"))
      return
    }

    let anchor: [String: Any] = [
      "x": arguments["x"] as Any,
      "y": arguments["y"] as Any,
      "width": arguments["width"] as Any,
      "height": arguments["height"] as Any,
    ]
    let exportDate = Date()
    let validated: SafeDiagnosticExportValidatedReport
    do {
      validated = try SafeDiagnosticExportValidator.validate(
        content: data,
        appVersion: appVersion,
        buildNumber: buildNumber,
        now: exportDate
      )
    } catch {
      finish(Self.safeDiagnosticError(code: "DIAG-EXPORT-UNSAFE"))
      return
    }

    do {
      let directory = try safeDiagnosticTemporaryStore.makeSessionDirectory()
      sessionDirectory = directory
      let fileURL = try safeDiagnosticTemporaryStore.writeAndVerify(
        data: validated.data,
        filename: validated.filename,
        in: directory
      )
      let reread = try Data(contentsOf: fileURL)
      guard reread == validated.data else {
        finish(Self.safeDiagnosticError(code: "DIAG-EXPORT-UNSAFE"))
        return
      }
      _ = try SafeDiagnosticExportValidator.validate(
        content: reread,
        appVersion: appVersion,
        buildNumber: buildNumber,
        now: exportDate
      )
    } catch SafeDiagnosticExportValidationError.unsafe {
      finish(Self.safeDiagnosticError(code: "DIAG-EXPORT-UNSAFE"))
      return
    } catch {
      finish(Self.safeDiagnosticError(code: "DIAG-EXPORT-WRITE"))
      return
    }

    presentSafeDiagnosticShare(
      anchor: anchor,
      directory: sessionDirectory!,
      filename: validated.filename,
      completionGate: completionGate,
      finish: { [weak self] outcome in
        let value: Any?
        switch outcome {
        case .completed:
          value = "completed"
        case .cancelled:
          value = "cancelled"
        case .writeFailure:
          value = Self.safeDiagnosticError(code: "DIAG-EXPORT-WRITE")
        case .shareFailure:
          value = Self.safeDiagnosticError(code: "DIAG-EXPORT-SHARE")
        }
        self?.finishSafeDiagnosticShare(
          value,
          sessionDirectory: sessionDirectory,
          result: result
        )
      }
    )
  }

  private func presentSafeDiagnosticShare(
    anchor: [String: Any],
    directory: URL,
    filename: String,
    completionGate: SafeDiagnosticExportCompletionGate,
    finish: @escaping (SafeDiagnosticExportPresentationOutcome) -> Void
  ) {
    guard let rootViewController = window?.rootViewController else {
      completionGate.complete {
        finish(.shareFailure)
      }
      return
    }
    let presenter = topViewController(rootViewController)

    let fileURL = directory.appendingPathComponent(filename, isDirectory: false)
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      completionGate.complete {
        finish(.writeFailure)
      }
      return
    }

    let activity = UIActivityViewController(
      activityItems: [fileURL],
      applicationActivities: nil
    )
    if let popover = activity.popoverPresentationController {
      popover.sourceView = presenter.view
      popover.sourceRect = SafeDiagnosticExportValidator.safePopoverRect(
        anchor: anchor,
        in: presenter.view.bounds
      )
      popover.permittedArrowDirections = []
    }
    let driver = SafeDiagnosticExportUIKitPresentationDriver(
      presenter: presenter,
      activity: activity
    )
    let coordinator = SafeDiagnosticExportPresentationCoordinator(
      driver: driver,
      completionGate: completionGate,
      onFinish: finish
    )
    safeDiagnosticPresentationCoordinator = coordinator
    coordinator.start()
  }

  private func finishSafeDiagnosticShare(
    _ value: Any?,
    sessionDirectory: URL?,
    result: @escaping FlutterResult
  ) {
    if let sessionDirectory {
      safeDiagnosticTemporaryStore.remove(sessionDirectory)
    }
    safeDiagnosticPresentationCoordinator = nil
    safeDiagnosticExportGate.finish()
    result(value)
  }

  private func topViewController(_ viewController: UIViewController) -> UIViewController {
    if let presented = viewController.presentedViewController {
      return topViewController(presented)
    }
    if let navigation = viewController as? UINavigationController,
      let visible = navigation.visibleViewController
    {
      return topViewController(visible)
    }
    if let tab = viewController as? UITabBarController,
      let selected = tab.selectedViewController
    {
      return topViewController(selected)
    }
    return viewController
  }

  private static func safeDiagnosticError(code: String) -> FlutterError {
    FlutterError(code: code, message: nil, details: nil)
  }
}
