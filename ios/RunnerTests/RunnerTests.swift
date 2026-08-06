import Flutter
import UIKit
import XCTest

final class RunnerTests: XCTestCase {
  func testValidReportPassesAndFilenameUsesOnlyBundleBuildAndTime() throws {
    let data = try JSONSerialization.data(withJSONObject: validReport())
    let result = try SafeDiagnosticExportValidator.validate(
      content: data,
      appVersion: "1.0.0",
      buildNumber: "42",
      now: Date(timeIntervalSince1970: 1_786_019_445)
    )

    XCTAssertEqual(result.data, data)
    XCTAssertEqual(
      result.filename,
      "emby-safe-diagnostics-v1-b42-20260806T123045Z.json"
    )
    XCTAssertFalse(result.filename.contains("/"))
    XCTAssertFalse(result.filename.contains("\\"))
  }

  func testTopLevelAndRecordKeysMustBeExact() throws {
    var extraTopLevel = validReport()
    extraTopLevel["extra"] = "value"
    assertUnsafe(extraTopLevel)

    var missingTopLevel = validReport()
    missingTopLevel.removeValue(forKey: "records")
    assertUnsafe(missingTopLevel)

    var extraRecord = validReport()
    var record = validRecord()
    record["extra"] = "value"
    extraRecord["records"] = [record]
    extraRecord["recordCount"] = 1
    assertUnsafe(extraRecord)

    var missingRecord = validReport()
    var incompleteRecord = validRecord()
    incompleteRecord.removeValue(forKey: "reason")
    missingRecord["records"] = [incompleteRecord]
    missingRecord["recordCount"] = 1
    assertUnsafe(missingRecord)
  }

  func testUnknownSchemaPlatformEnumsAndTypesAreRejected() throws {
    for keyValue in [
      ("schema", "other"),
      ("platform", "iOS"),
    ] {
      var report = validReport()
      report[keyValue.0] = keyValue.1
      assertUnsafe(report)
    }

    for keyValue in [
      ("level", "DEBUG"),
      ("component", "network"),
      ("event", "other"),
      ("stage", "OTHER"),
      ("reason", "other"),
      ("errorType", "NSError"),
      ("diagnosticCode", "LOGIN-EXTERNAL"),
    ] {
      var report = validReport()
      var record = validRecord()
      record[keyValue.0] = keyValue.1
      report["records"] = [record]
      report["recordCount"] = 1
      assertUnsafe(report)
    }

    var wrongRecordCount = validReport()
    wrongRecordCount["recordCount"] = 2
    assertUnsafe(wrongRecordCount)

    var wrongTypes = validReport()
    wrongTypes["recordCount"] = "0"
    assertUnsafe(wrongTypes)
    wrongTypes = validReport()
    wrongTypes["truncated"] = "false"
    assertUnsafe(wrongTypes)
    wrongTypes = validReport()
    wrongTypes["records"] = "[]"
    assertUnsafe(wrongTypes)
  }

  func testBundleMetadataTimestampAndControlCharactersAreRejected() throws {
    let data = try JSONSerialization.data(withJSONObject: validReport())
    XCTAssertThrowsError(
      try SafeDiagnosticExportValidator.validate(
        content: data,
        appVersion: "1.0",
        buildNumber: "42"
      )
    )
    XCTAssertThrowsError(
      try SafeDiagnosticExportValidator.validate(
        content: data,
        appVersion: "1.0.0",
        buildNumber: "42x"
      )
    )

    var timestamp = validReport()
    timestamp["generatedAtUtc"] = "2026-08-06T12:30:45+00:00"
    assertUnsafe(timestamp)

    var recordTimestamp = validReport()
    var record = validRecord()
    record["atUtc"] = "2026-08-06T12:30:45Z\n"
    recordTimestamp["records"] = [record]
    recordTimestamp["recordCount"] = 1
    assertUnsafe(recordTimestamp)

    let controlData = Data("{\"schema\":\n}".utf8)
    XCTAssertThrowsError(
      try SafeDiagnosticExportValidator.validate(
        content: controlData,
        appVersion: "1.0.0",
        buildNumber: "42"
      )
    )
  }

  func testEmptyOversizedAndInvalidUtf8ContentIsRejected() {
    for data in [
      Data(),
      Data(repeating: 0x61, count: SafeDiagnosticExportValidator.maxBytes + 1),
      Data([0xff, 0xfe, 0xfd]),
    ] {
      XCTAssertThrowsError(
        try SafeDiagnosticExportValidator.validate(
          content: data,
          appVersion: "1.0.0",
          buildNumber: "42"
        )
      )
    }
  }

  func testDiagnosticCodeMappingIsLocalAndExact() throws {
    let mappings = [
      ("DEVICE_ID_READ", "secure_storage_missing_entitlement", "LOGIN-DID-READ-KC-MISSING"),
      ("DEVICE_ID_WRITE", "secure_storage_missing_entitlement", "LOGIN-DID-WRITE-KC-MISSING"),
      ("SESSION_SAVE", "secure_storage_missing_entitlement", "LOGIN-SESSION-SAVE-KC-MISSING"),
      ("AUTHENTICATE", "emby_api_failure", "LOGIN-AUTH"),
      ("PREFLIGHT", "unknown", "LOGIN-UNKNOWN"),
    ]
    for (stage, reason, code) in mappings {
      var report = validReport()
      var record = validRecord()
      record["stage"] = stage
      record["reason"] = reason
      record["diagnosticCode"] = code
      if stage == "AUTHENTICATE" {
        record["errorType"] = "EmbyApiException"
      } else if stage == "PREFLIGHT" {
        record["errorType"] = "Unknown"
      }
      report["records"] = [record]
      report["recordCount"] = 1
      assertValid(report)
    }
  }

  func testSensitiveContentPatternsFailClosed() throws {
    let values = [
      "password=secret",
      "pw=secret",
      "username=fixture",
      "accountName=fixture",
      "Authorization: Basic credential",
      "Authorization: Bearer token",
      "Cookie: session=value",
      "Token=secret",
      "X-Emby-Token: secret",
      "api_key=secret",
      "deviceId=secret",
      "https://example.test:8096/path",
      "https%3A%2F%2Fexample.test%3A8096",
      "192.0.2.1",
      "2001:db8::1",
      "example.test:8096",
      "Session JSON",
      "request headers",
      "response body",
      "/var/mobile/Containers/Data/file.json",
      "C:\\Users\\fixture\\file.json",
      "line\n injected",
    ]

    for value in values {
      XCTAssertTrue(
        SafeDiagnosticExportValidator.containsSensitiveContent(value) ||
          value.contains("\n"),
        "expected sensitive content to be rejected: \(value)"
      )
      var report = validReport()
      report["unsafe"] = value
      assertUnsafe(report)
    }
  }

  func testPopoverRectIntersectsBoundsAndFallsBackToCenter() {
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
    let intersection = SafeDiagnosticExportValidator.safePopoverRect(
      anchor: ["x": -20, "y": 20, "width": 100, "height": 80],
      in: bounds
    )
    XCTAssertEqual(intersection, CGRect(x: 0, y: 20, width: 80, height: 80))

    let fallback = CGRect(x: 499.5, y: 299.5, width: 1, height: 1)
    XCTAssertEqual(
      SafeDiagnosticExportValidator.safePopoverRect(
        anchor: ["x": 2000, "y": 20, "width": 100, "height": 80],
        in: bounds
      ),
      fallback
    )
    XCTAssertEqual(
      SafeDiagnosticExportValidator.safePopoverRect(
        anchor: ["x": 1, "y": 1, "width": 0, "height": 20],
        in: bounds
      ),
      fallback
    )
    XCTAssertEqual(
      SafeDiagnosticExportValidator.safePopoverRect(anchor: nil, in: bounds),
      fallback
    )
  }

  func testTemporaryStoreUsesDedicatedDirectoryAndVerifiesBytes() throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("safe-diagnostic-test-\(UUID().uuidString)")
    let root = base.appendingPathComponent(
      SafeDiagnosticExportTemporaryStore.directoryName,
      isDirectory: true
    )
    let store = SafeDiagnosticExportTemporaryStore(rootURL: root)
    defer { store.cleanupStale(); try? FileManager.default.removeItem(at: base) }

    let directory = try store.makeSessionDirectory()
    let data = Data("{}".utf8)
    let file = try store.writeAndVerify(
      data: data,
      filename: "emby-safe-diagnostics-v1-b42-20260806T123045Z.json",
      in: directory
    )
    XCTAssertTrue(file.path.hasPrefix(root.path))
    XCTAssertEqual(try Data(contentsOf: file), data)
    XCTAssertTrue(SafeDiagnosticExportTemporaryStore.writeOptions.contains(.atomic))
    XCTAssertTrue(
      SafeDiagnosticExportTemporaryStore.writeOptions.contains(.completeFileProtection)
    )
    store.remove(directory)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
  }

  func testExportAndResultGatesAreSingleFlightAndCompleteOnce() {
    let gate = SafeDiagnosticExportResultGate()
    XCTAssertTrue(gate.begin())
    XCTAssertFalse(gate.begin())
    XCTAssertTrue(gate.isInProgress)
    XCTAssertTrue(gate.finish())
    XCTAssertFalse(gate.finish())
    XCTAssertFalse(gate.isInProgress)

    let completion = SafeDiagnosticExportCompletionGate()
    var calls = 0
    XCTAssertTrue(completion.complete { calls += 1 })
    XCTAssertFalse(completion.complete { calls += 1 })
    XCTAssertEqual(calls, 1)
  }

  private func validReport() -> [String: Any] {
    [
      "schema": "emby-safe-diagnostics/v1",
      "generatedAtUtc": "2026-08-06T12:30:45.000Z",
      "appVersion": "1.0.0",
      "buildNumber": "42",
      "platform": "iPadOS",
      "recordCount": 0,
      "truncated": false,
      "records": [],
    ]
  }

  private func validRecord() -> [String: Any] {
    [
      "atUtc": "2026-08-06T12:30:45.000Z",
      "level": "ERROR",
      "component": "auth",
      "event": "sign_in_failure",
      "stage": "SESSION_PREPARE",
      "reason": "unknown",
      "errorType": "SignInFailure",
      "diagnosticCode": "LOGIN-SESSION-PREPARE",
    ]
  }

  private func assertUnsafe(
    _ report: [String: Any],
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    do {
      let data = try JSONSerialization.data(withJSONObject: report)
      XCTAssertThrowsError(
        try SafeDiagnosticExportValidator.validate(
          content: data,
          appVersion: "1.0.0",
          buildNumber: "42"
        ),
        file: file,
        line: line
      ) { error in
        XCTAssertEqual(
          error as? SafeDiagnosticExportValidationError,
          .unsafe,
          file: file,
          line: line
        )
      }
    } catch {
      XCTFail("fixture could not be encoded: \(error)", file: file, line: line)
    }
  }

  private func assertValid(
    _ report: [String: Any],
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    do {
      let data = try JSONSerialization.data(withJSONObject: report)
      XCTAssertNoThrow(
        try SafeDiagnosticExportValidator.validate(
          content: data,
          appVersion: "1.0.0",
          buildNumber: "42"
        ),
        file: file,
        line: line
      )
    } catch {
      XCTFail("fixture could not be encoded: \(error)", file: file, line: line)
    }
  }
}
