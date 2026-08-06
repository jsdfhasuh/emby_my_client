import CoreGraphics
import Foundation
import UIKit

enum SafeDiagnosticExportValidationError: Error, Equatable {
  case unsafe
}

struct SafeDiagnosticExportValidatedReport {
  let data: Data
  let filename: String
}

enum SafeDiagnosticExportValidator {
  static let schema = "emby-safe-diagnostics/v1"
  static let platform = "iPadOS"
  static let maxBytes = 256 * 1024
  static let maxRecords = 1000

  private static let topLevelKeys: Set<String> = [
    "schema",
    "generatedAtUtc",
    "appVersion",
    "buildNumber",
    "platform",
    "recordCount",
    "truncated",
    "records",
  ]
  private static let recordKeys: Set<String> = [
    "atUtc",
    "level",
    "component",
    "event",
    "stage",
    "reason",
    "errorType",
    "diagnosticCode",
  ]
  private static let levels: Set<String> = ["INFO", "ERROR"]
  private static let components: Set<String> = ["auth", "storage"]
  private static let events: Set<String> = [
    "sign_in_stage_start",
    "sign_in_stage_success",
    "sign_in_failure",
    "session_restore_failure",
    "session_delete_failure",
  ]
  private static let stages: Set<String> = [
    "PREFLIGHT",
    "SESSION_READ",
    "DEVICE_ID_READ",
    "DEVICE_ID_WRITE",
    "AUTHENTICATE",
    "SESSION_PREPARE",
    "SESSION_SAVE",
    "ACTIVATE",
    "SESSION_DELETE",
    "ROLLBACK",
  ]
  private static let reasons: Set<String> = [
    "secure_storage_missing_entitlement",
    "secure_storage_unavailable",
    "secure_storage_access_denied",
    "secure_storage_unexpected",
    "session_prepare_failed",
    "session_save_failed",
    "activation_failed",
    "already_in_progress",
    "already_signed_in",
    "emby_api_failure",
    "unknown",
  ]
  private static let errorTypes: Set<String> = [
    "SecureStorageFailure",
    "SignInFailure",
    "EmbyApiException",
    "Unknown",
  ]

  static func validate(
    content: Data,
    appVersion: String,
    buildNumber: String,
    now: Date = Date()
  ) throws -> SafeDiagnosticExportValidatedReport {
    guard
      !content.isEmpty,
      content.count <= maxBytes,
      content.allSatisfy({ $0 >= 0x20 }),
      let text = String(data: content, encoding: .utf8),
      !text.isEmpty,
      isValidAppVersion(appVersion),
      isValidBuildNumber(buildNumber)
    else {
      throw SafeDiagnosticExportValidationError.unsafe
    }

    guard
      let object = try? JSONSerialization.jsonObject(with: content),
      let report = exactDictionary(object, keys: topLevelKeys),
      report["schema"] as? String == schema,
      report["platform"] as? String == platform,
      report["appVersion"] as? String == appVersion,
      report["buildNumber"] as? String == buildNumber,
      let generatedAtUtc = report["generatedAtUtc"] as? String,
      isValidUtcTimestamp(generatedAtUtc),
      let recordCount = integerValue(report["recordCount"]),
      let truncated = report["truncated"] as? Bool,
      let records = report["records"] as? [Any],
      recordCount == records.count,
      recordCount >= 0,
      recordCount <= maxRecords,
      records.allSatisfy({ validateRecord($0) })
    else {
      throw SafeDiagnosticExportValidationError.unsafe
    }

    guard !containsSensitiveContent(text) else {
      throw SafeDiagnosticExportValidationError.unsafe
    }

    _ = truncated
    return SafeDiagnosticExportValidatedReport(
      data: content,
      filename: try makeFilename(buildNumber: buildNumber, date: now)
    )
  }

  static func isValidAppVersion(_ value: String) -> Bool {
    value.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil
  }

  static func isValidBuildNumber(_ value: String) -> Bool {
    value.range(of: #"^\d+$"#, options: .regularExpression) != nil
  }

  static func makeFilename(buildNumber: String, date: Date) throws -> String {
    guard isValidBuildNumber(buildNumber) else {
      throw SafeDiagnosticExportValidationError.unsafe
    }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    let timestamp = formatter.string(from: date)
    return "emby-safe-diagnostics-v1-b\(buildNumber)-\(timestamp).json"
  }

  static func safePopoverRect(
    anchor: [String: Any]?,
    in bounds: CGRect
  ) -> CGRect {
    let fallback = CGRect(
      x: bounds.midX - 0.5,
      y: bounds.midY - 0.5,
      width: 1,
      height: 1
    )
    guard
      !bounds.isNull,
      !bounds.isEmpty,
      let anchor,
      Set(anchor.keys) == ["x", "y", "width", "height"],
      let x = finiteNumber(anchor["x"]),
      let y = finiteNumber(anchor["y"]),
      let width = finiteNumber(anchor["width"]),
      let height = finiteNumber(anchor["height"]),
      width > 0,
      height > 0
    else {
      return fallback
    }

    let requested = CGRect(x: x, y: y, width: width, height: height)
    let intersection = requested.intersection(bounds)
    guard !intersection.isNull, !intersection.isEmpty else {
      return fallback
    }
    return intersection
  }

  private static func exactDictionary(
    _ value: Any?,
    keys: Set<String>
  ) -> [String: Any]? {
    guard let dictionary = value as? [String: Any], Set(dictionary.keys) == keys else {
      return nil
    }
    return dictionary
  }

  private static func validateRecord(_ value: Any) -> Bool {
    guard let record = exactDictionary(value, keys: recordKeys) else {
      return false
    }
    guard
      let atUtc = record["atUtc"] as? String,
      let level = record["level"] as? String,
      let component = record["component"] as? String,
      let event = record["event"] as? String,
      let stage = record["stage"] as? String,
      let reason = record["reason"] as? String,
      let errorType = record["errorType"] as? String,
      let diagnosticCode = record["diagnosticCode"] as? String,
      isValidUtcTimestamp(atUtc),
      levels.contains(level),
      components.contains(component),
      events.contains(event),
      stages.contains(stage),
      reasons.contains(reason),
      errorTypes.contains(errorType),
      diagnosticCode == diagnosticCodeFor(stage: stage, reason: reason),
      [level, component, event, stage, reason, errorType, diagnosticCode]
        .allSatisfy({ !hasControlCharacter($0) })
    else {
      return false
    }
    return !hasControlCharacter(atUtc)
  }

  private static func diagnosticCodeFor(stage: String, reason: String) -> String {
    switch (stage, reason) {
    case ("DEVICE_ID_READ", "secure_storage_missing_entitlement"):
      return "LOGIN-DID-READ-KC-MISSING"
    case ("DEVICE_ID_READ", "secure_storage_unavailable"):
      return "LOGIN-DID-READ-KC-UNAVAILABLE"
    case ("DEVICE_ID_READ", "secure_storage_access_denied"):
      return "LOGIN-DID-READ-KC-DENIED"
    case ("DEVICE_ID_READ", "secure_storage_unexpected"):
      return "LOGIN-DID-READ-KC-UNEXPECTED"
    case ("DEVICE_ID_WRITE", "secure_storage_missing_entitlement"):
      return "LOGIN-DID-WRITE-KC-MISSING"
    case ("DEVICE_ID_WRITE", "secure_storage_unavailable"):
      return "LOGIN-DID-WRITE-KC-UNAVAILABLE"
    case ("DEVICE_ID_WRITE", "secure_storage_access_denied"):
      return "LOGIN-DID-WRITE-KC-DENIED"
    case ("DEVICE_ID_WRITE", "secure_storage_unexpected"):
      return "LOGIN-DID-WRITE-KC-UNEXPECTED"
    case ("SESSION_SAVE", "secure_storage_missing_entitlement"):
      return "LOGIN-SESSION-SAVE-KC-MISSING"
    case ("SESSION_SAVE", "secure_storage_unavailable"):
      return "LOGIN-SESSION-SAVE-KC-UNAVAILABLE"
    case ("SESSION_SAVE", "secure_storage_access_denied"):
      return "LOGIN-SESSION-SAVE-KC-DENIED"
    case ("SESSION_SAVE", "secure_storage_unexpected"):
      return "LOGIN-SESSION-SAVE-KC-UNEXPECTED"
    case ("SESSION_PREPARE", _):
      return "LOGIN-SESSION-PREPARE"
    case ("ACTIVATE", _):
      return "LOGIN-ACTIVATE"
    case ("AUTHENTICATE", "emby_api_failure"):
      return "LOGIN-AUTH"
    default:
      return "LOGIN-UNKNOWN"
    }
  }

  private static func isValidUtcTimestamp(_ value: String) -> Bool {
    guard
      value.range(
        of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3}|\.\d{6})?Z$"#,
        options: .regularExpression
      ) != nil
    else {
      return false
    }

    let bytes = Array(value.utf8)
    guard bytes.count == 20 || bytes.count == 24 || bytes.count == 27 else {
      return false
    }

    let fixedSeparators: [Int: UInt8] = [
      4: 45,
      7: 45,
      10: 84,
      13: 58,
      16: 58,
      bytes.count - 1: 90,
    ]
    guard fixedSeparators.allSatisfy({ bytes[$0.key] == $0.value }) else {
      return false
    }
    if bytes.count > 20 {
      guard bytes[19] == 46 else {
        return false
      }
    }

    func number(_ start: Int, _ end: Int) -> Int? {
      Int(String(decoding: bytes[start..<end], as: UTF8.self))
    }

    let fractionRange = bytes.count > 20 ? 20..<(bytes.count - 1) : 0..<0
    let digitRanges = [0..<4, 5..<7, 8..<10, 11..<13, 14..<16, 17..<19]
      + (bytes.count > 20 ? [fractionRange] : [])
    guard digitRanges.allSatisfy({ range in
      range.allSatisfy { index in
        let byte = bytes[index]
        return byte >= 48 && byte <= 57
      }
    }) else {
      return false
    }

    guard
      let year = number(0, 4),
      let month = number(5, 7),
      let day = number(8, 10),
      let hour = number(11, 13),
      let minute = number(14, 16),
      let second = number(17, 19)
    else {
      return false
    }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    var components = DateComponents()
    components.calendar = calendar
    components.timeZone = calendar.timeZone
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    components.second = second

    guard let date = calendar.date(from: components) else {
      return false
    }
    let normalized = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second],
      from: date
    )
    return normalized.year == year
      && normalized.month == month
      && normalized.day == day
      && normalized.hour == hour
      && normalized.minute == minute
      && normalized.second == second
  }

  private static func integerValue(_ value: Any?) -> Int? {
    guard !(value is Bool), let number = value as? NSNumber else {
      return nil
    }
    let type = String(cString: number.objCType)
    guard type != "c", type != "f", type != "d" else {
      return nil
    }
    let integer = number.int64Value
    guard integer >= Int64(Int.min), integer <= Int64(Int.max) else {
      return nil
    }
    guard Double(integer) == number.doubleValue else {
      return nil
    }
    return Int(integer)
  }

  private static func finiteNumber(_ value: Any?) -> CGFloat? {
    guard !(value is Bool) else {
      return nil
    }

    let doubleValue: Double?
    if let number = value as? NSNumber {
      doubleValue = number.doubleValue
    } else if let number = value as? CGFloat {
      doubleValue = Double(number)
    } else if let number = value as? Double {
      doubleValue = number
    } else if let number = value as? Float {
      doubleValue = Double(number)
    } else if let number = value as? Int {
      doubleValue = Double(number)
    } else if let number = value as? Int64 {
      doubleValue = Double(number)
    } else if let number = value as? UInt64 {
      doubleValue = Double(number)
    } else {
      doubleValue = nil
    }

    guard let doubleValue else {
      return nil
    }
    let result = CGFloat(doubleValue)
    return result.isFinite ? result : nil
  }

  private static func hasControlCharacter(_ value: String) -> Bool {
    value.unicodeScalars.contains { scalar in
      scalar.value < 0x20 || scalar.value == 0x7F
    }
  }

  static func containsSensitiveContent(_ value: String) -> Bool {
    let patterns = [
      #"(?i)(?:^|[^a-z0-9])(?:password|pw|username|account|accountname|accesstoken|token|x-emby-token|api_key|authorization|basic|bearer|cookie|deviceid|device_id|serverurl|baseurl|address|host|hostname|url|ip)(?:$|[^a-z0-9])"#,
      #"(?i)(?:https?|wss?)://|(?:https?|wss?)%3a%2f%2f"#,
      #"(?:^|[^0-9])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?:$|[^0-9])"#,
      #"(?i)(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}:\d{2,5}|(?:localhost|emby):\d{2,5}|\[[0-9a-f:]+\]:\d{2,5}"#,
      #"(?i)(?:[a-z]:[\\/]|/(?:home|users|private|var|tmp|data|documents|library)(?:[\\/]))"#,
      #"(?i)\\Users\\|\\private\\|\\var\\|\\tmp\\|/Users/|/private/|/var/|/tmp/"#,
      #"(?i)\"session(?:json|object|data)?\"\s*:|\bsession\s+(?:json|object|data)\b"#,
      #"(?i)\"(?:request|response)(?:body|headers?)\"\s*:|\b(?:request|response)\s+(?:body|headers?)\b"#,
      #"\\(?:r|n|t|u000[0-9a-f]{1,4})"#,
    ]
    guard !containsIPv6Address(value) else {
      return true
    }
    return patterns.contains {
      value.range(of: $0, options: .regularExpression) != nil
    }
  }

  private static func containsIPv6Address(_ value: String) -> Bool {
    guard let regex = try? NSRegularExpression(pattern: #"[0-9a-fA-F:]{2,}"#) else {
      return true
    }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return regex.matches(in: value, range: range).contains { match in
      guard let candidateRange = Range(match.range, in: value) else {
        return true
      }
      return isIPv6Candidate(String(value[candidateRange]))
    }
  }

  private static func isIPv6Candidate(_ candidate: String) -> Bool {
    guard candidate.contains(":"), !candidate.contains(":::") else {
      return false
    }

    let hasCompression = candidate.contains("::")
    guard candidate.components(separatedBy: "::").count == (hasCompression ? 2 : 1) else {
      return false
    }

    let normalized = hasCompression
      ? candidate.replacingOccurrences(of: "::", with: ":")
      : candidate
    let groups = normalized.split(separator: ":", omittingEmptySubsequences: true)
    guard groups.allSatisfy({ group in
      group.count <= 4 && group.unicodeScalars.allSatisfy { scalar in
        switch scalar.value {
        case 48...57, 65...70, 97...102:
          return true
        default:
          return false
        }
      }
    }) else {
      return false
    }

    return hasCompression ? groups.count <= 7 : groups.count == 8
  }
}

struct SafeDiagnosticExportTemporaryStore {
  static let directoryName = "emby-safe-diagnostics-export"
  static let writeOptions: Data.WritingOptions = [
    .atomic,
    .completeFileProtection,
  ]

  let fileManager: FileManager
  let rootURL: URL

  init(
    fileManager: FileManager = .default,
    rootURL: URL? = nil
  ) {
    self.fileManager = fileManager
    self.rootURL = rootURL
      ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent(Self.directoryName, isDirectory: true)
  }

  func cleanupStale() {
    try? fileManager.removeItem(at: rootURL)
  }

  func makeSessionDirectory() throws -> URL {
    cleanupStale()
    try fileManager.createDirectory(
      at: rootURL,
      withIntermediateDirectories: true,
      attributes: nil
    )
    let directory = rootURL.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
      attributes: nil
    )
    return directory
  }

  func writeAndVerify(data: Data, filename: String, in directory: URL) throws -> URL {
    var isDirectory: ObjCBool = false
    guard
      fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
      isDirectory.boolValue,
      directory.deletingLastPathComponent().standardizedFileURL == rootURL.standardizedFileURL,
      !filename.isEmpty,
      filename == URL(fileURLWithPath: filename).lastPathComponent,
      !filename.contains("..")
    else {
      throw SafeDiagnosticExportValidationError.unsafe
    }

    let fileURL = directory.appendingPathComponent(filename, isDirectory: false)
    try data.write(to: fileURL, options: Self.writeOptions)
    try fileManager.setAttributes(
      [.protectionKey: FileProtectionType.complete],
      ofItemAtPath: fileURL.path
    )
    guard try Data(contentsOf: fileURL) == data else {
      throw SafeDiagnosticExportValidationError.unsafe
    }
    return fileURL
  }

  func remove(_ directory: URL) {
    try? fileManager.removeItem(at: directory)
  }
}

final class SafeDiagnosticExportResultGate {
  private let lock = NSLock()
  private var value = false

  var isInProgress: Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  @discardableResult
  func begin() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !value else { return false }
    value = true
    return true
  }

  @discardableResult
  func finish() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard value else { return false }
    value = false
    return true
  }
}

final class SafeDiagnosticExportCompletionGate {
  private let lock = NSLock()
  private var completed = false

  @discardableResult
  func complete(_ action: () -> Void) -> Bool {
    lock.lock()
    guard !completed else {
      lock.unlock()
      return false
    }
    completed = true
    lock.unlock()
    action()
    return true
  }
}
