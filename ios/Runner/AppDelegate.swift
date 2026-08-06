import Flutter
import Foundation
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let safeDiagnosticChannelName = "emby_my_client/safe_diagnostic_export"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
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
          result(Self.safeDiagnosticError())
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
        appVersion.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil,
        buildNumber.range(of: #"^\d+$"#, options: .regularExpression) != nil
      else {
        result(Self.safeDiagnosticError())
        return
      }
      result(["appVersion": appVersion, "buildNumber": buildNumber])

    case "share":
      guard let arguments = call.arguments as? [String: Any],
        Set(arguments.keys) == Set<String>(["filename", "content"]),
        let filename = arguments["filename"] as? String,
        let content = arguments["content"] as? String,
        filename.range(
          of: #"^emby-safe-diagnostics-v1-b\d+-\d{8}T\d{6}Z\.json$"#,
          options: .regularExpression
        ) != nil,
        let data = content.data(using: .utf8),
        data.count <= 256 * 1024,
        (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
      else {
        result(Self.safeDiagnosticError())
        return
      }
      presentSafeDiagnosticShare(
        filename: filename,
        data: data,
        result: result
      )

    default:
      result(Self.safeDiagnosticError())
    }
  }

  private func presentSafeDiagnosticShare(
    filename: String,
    data: Data,
    result: @escaping FlutterResult
  ) {
    guard let rootViewController = window?.rootViewController else {
      result(Self.safeDiagnosticError())
      return
    }
    let presenter = topViewController(rootViewController)
    guard presenter.viewIfLoaded?.window != nil else {
      result(Self.safeDiagnosticError())
      return
    }
    let temporaryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(filename, isDirectory: false)
    do {
      try data.write(to: temporaryURL, options: .atomic)
    } catch {
      result(Self.safeDiagnosticError())
      return
    }

    let activity = UIActivityViewController(
      activityItems: [temporaryURL],
      applicationActivities: nil
    )
    if let popover = activity.popoverPresentationController {
      popover.sourceView = presenter.view
      popover.sourceRect = CGRect(
        x: presenter.view.bounds.midX,
        y: presenter.view.bounds.midY,
        width: 0,
        height: 0
      )
      popover.permittedArrowDirections = []
    }
    activity.completionWithItemsHandler = { _, _, _, _ in
      try? FileManager.default.removeItem(at: temporaryURL)
      result(nil)
    }
    presenter.present(activity, animated: true)
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

  private static func safeDiagnosticError() -> FlutterError {
    FlutterError(code: "DIAG-EXPORT-UNSAFE", message: nil, details: nil)
  }
}
