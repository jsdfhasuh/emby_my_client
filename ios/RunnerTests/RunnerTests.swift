import Flutter
import CryptoKit
import UIKit
import XCTest

final class RunnerTests: XCTestCase {
  func testBundledLibmpvCacheCapabilitiesAndProfileSwitching() throws {
    let snapshot = try PlaybackCacheNativeProbe.probe()

    XCTAssertFalse(snapshot.mpvVersion.isEmpty)
    XCTAssertFalse(snapshot.platform.isEmpty)
    XCTAssertTrue(
      snapshot.supportedOptions.isSubset(
        of: Set(PlaybackCacheNativeProbe.optionNames)
      )
    )
    XCTAssertTrue(Set(snapshot.resetValues.keys).isSubset(of: snapshot.supportedOptions))
    XCTAssertTrue(snapshot.properties.contains("property-list"))
    XCTAssertEqual(
      snapshot.supportedOptions,
      Set(PlaybackCacheNativeProbe.optionNames)
    )
    XCTAssertEqual(
      Set(snapshot.resetValues.keys),
      Set(PlaybackCacheNativeProbe.optionNames)
    )
    XCTAssertTrue(snapshot.unlinkChoices.contains("immediate"))
    XCTAssertNotEqual(snapshot.profileSwitchStrategy, .unsupported)
    XCTAssertTrue(snapshot.diskCapabilityPassed)

    let manifest = try snapshot.safeManifestData()
    let attachment = XCTAttachment(data: manifest)
    attachment.name = "mpv-capability-manifest.json"
    attachment.lifetime = .keepAlways
    add(attachment)

    print("mpv_version=\(snapshot.mpvVersion)")
    print("mpv_platform=\(snapshot.platform)")
    for option in PlaybackCacheNativeProbe.optionNames {
      print("mpv_option_\(option)=\(snapshot.supportedOptions.contains(option))")
      if let reset = snapshot.resetValues[option] {
        print("mpv_option_reset_\(option)=\(reset)")
      }
    }
    for property in PlaybackCacheNativeProbe.requiredProperties {
      print("mpv_property_\(property)=\(snapshot.properties.contains(property))")
    }
    print("mpv_unlink_immediate=\(snapshot.unlinkChoices.contains("immediate"))")
    print("mpv_profile_switch_strategy=\(snapshot.profileSwitchStrategy.rawValue)")
    print("mpv_disk_capability_passed=\(snapshot.diskCapabilityPassed)")
  }

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

    var fractionalRecordCount = validReport()
    fractionalRecordCount["recordCount"] = 0.5
    assertUnsafe(fractionalRecordCount)
  }

  func testBundleMetadataTimestampAndControlCharactersAreRejected() throws {
    XCTAssertTrue(SafeDiagnosticExportValidator.isValidAppVersion("1.0.0"))
    XCTAssertTrue(SafeDiagnosticExportValidator.isValidBuildNumber("42"))
    XCTAssertFalse(SafeDiagnosticExportValidator.isValidAppVersion("1.0"))
    XCTAssertFalse(SafeDiagnosticExportValidator.isValidAppVersion("1.\u{FF10}.\u{FF10}"))
    XCTAssertFalse(SafeDiagnosticExportValidator.isValidBuildNumber("42x"))
    XCTAssertFalse(SafeDiagnosticExportValidator.isValidBuildNumber("\u{FF14}\u{FF12}"))

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

    var impossibleDate = validReport()
    impossibleDate["generatedAtUtc"] = "2026-02-30T12:30:45.000Z"
    assertUnsafe(impossibleDate)

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

  func testCanonicalUtcTimestampFormsAreAccepted() throws {
    for timestamp in [
      "2026-08-06T12:30:45Z",
      "2026-08-06T12:30:45.000Z",
      "2026-08-06T12:30:45.000000Z",
      "2024-02-29T23:59:59.000Z",
    ] {
      var report = validReport()
      report["generatedAtUtc"] = timestamp
      assertValid(report)
    }

    var report = validReport()
    report["records"] = [
      [
        "atUtc": "2026-08-06T12:30:45.000000Z",
        "level": "ERROR",
        "component": "auth",
        "event": "sign_in_failure",
        "stage": "SESSION_PREPARE",
        "reason": "unknown",
        "errorType": "SignInFailure",
        "diagnosticCode": "LOGIN-SESSION-PREPARE",
      ],
    ]
    report["recordCount"] = 1
    assertValid(report)
  }

  func testValidFixturePredicatesPassBeforeFullValidation() throws {
    XCTAssertTrue(SafeDiagnosticExportValidator.isValidAppVersion("1.0.0"))
    XCTAssertTrue(SafeDiagnosticExportValidator.isValidBuildNumber("42"))
    XCTAssertTrue(
      SafeDiagnosticExportValidator.isValidUtcTimestamp(
        "2026-08-06T12:30:45.000Z"
      )
    )
    XCTAssertTrue(SafeDiagnosticExportValidator.validateRecord(validRecord()))
    XCTAssertEqual(SafeDiagnosticExportValidator.integerValue(0), 0)

    let data = try JSONSerialization.data(withJSONObject: validReport())
    let object = try JSONSerialization.jsonObject(with: data)
    guard let report = object as? [String: Any] else {
      XCTFail("JSON root did not bridge to a string dictionary")
      return
    }
    XCTAssertNotNil(SafeDiagnosticExportValidator.arrayValue(report["records"]))
    XCTAssertEqual(
      SafeDiagnosticExportValidator.booleanValue(report["truncated"]),
      false
    )
    XCTAssertEqual(SafeDiagnosticExportValidator.integerValue(report["recordCount"]), 0)
    XCTAssertFalse(
      SafeDiagnosticExportValidator.containsSensitiveContent(
        String(data: data, encoding: .utf8) ?? ""
      )
    )
  }

  func testJsonIntegerRecordCountsAreAccepted() throws {
    for count in [0, 1] {
      var report = validReport()
      report["recordCount"] = count
      if count == 1 {
        report["records"] = [validRecord()]
      }
      let data = try JSONSerialization.data(withJSONObject: report)
      let decoded = try JSONSerialization.jsonObject(with: data)
      let dictionary = try XCTUnwrap(decoded as? [String: Any])

      XCTAssertEqual(
        SafeDiagnosticExportValidator.integerValue(dictionary["recordCount"]),
        count
      )
      assertValid(report)
    }
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

  func testPresentationCoordinatorMountedCompletedCleansAndReleasesGate() throws {
    let fixture = try makePresentationFixture()
    let state = PresentationOutcomeBox()
    let coordinator = SafeDiagnosticExportPresentationCoordinator(
      driver: fixture.driver,
      completionGate: SafeDiagnosticExportCompletionGate(),
      scheduleWatchdog: { state.watchdog = $0 },
      onFinish: { outcome in
        state.outcomes.append(outcome)
        fixture.store.remove(fixture.directory)
        XCTAssertTrue(fixture.gate.finish())
      }
    )

    fixture.driver.isActivityMounted = true
    coordinator.start()
    fixture.driver.completePresentation()
    fixture.driver.completeActivity(completed: true)
    state.watchdog?()

    XCTAssertEqual(state.outcomes, [.completed])
    XCTAssertFalse(fixture.gate.isInProgress)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: fixture.directory.path)
    )
  }

  func testPresentationCoordinatorPresentationCompletionWithoutMountFailsOnce() throws {
    let fixture = try makePresentationFixture()
    let state = PresentationOutcomeBox()
    let coordinator = makePresentationCoordinator(
      fixture: fixture,
      state: state
    )

    coordinator.start()
    fixture.driver.completePresentation()
    state.watchdog?()
    fixture.driver.completeActivity(completed: false)

    assertPresentationFailure(
      fixture: fixture,
      outcomes: state.outcomes
    )
  }

  func testPresentationCoordinatorWatchdogWithoutMountFailsAndCleans() throws {
    let fixture = try makePresentationFixture()
    let state = PresentationOutcomeBox()
    let coordinator = makePresentationCoordinator(
      fixture: fixture,
      state: state
    )

    coordinator.start()
    state.watchdog?()

    assertPresentationFailure(
      fixture: fixture,
      outcomes: state.outcomes
    )
  }

  func testPresentationCoordinatorCancelledCleansAndCanStartAgain() throws {
    let fixture = try makePresentationFixture()
    let state = PresentationOutcomeBox()
    let coordinator = makePresentationCoordinator(
      fixture: fixture,
      state: state
    )

    fixture.driver.isActivityMounted = true
    coordinator.start()
    fixture.driver.completeActivity(completed: false)

    XCTAssertEqual(state.outcomes, [.cancelled])
    XCTAssertFalse(fixture.gate.isInProgress)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: fixture.directory.path)
    )
    XCTAssertTrue(fixture.gate.begin())
    XCTAssertTrue(fixture.gate.finish())
  }

  func testPresentationCoordinatorActivityErrorUsesShareFailureAndCleans() throws {
    let fixture = try makePresentationFixture()
    let state = PresentationOutcomeBox()
    let coordinator = makePresentationCoordinator(
      fixture: fixture,
      state: state
    )

    fixture.driver.isActivityMounted = true
    coordinator.start()
    fixture.driver.completeActivity(
      completed: false,
      error: NSError(domain: "fixture", code: 1)
    )
    state.watchdog?()

    XCTAssertEqual(state.outcomes, [.shareFailure])
    XCTAssertFalse(fixture.gate.isInProgress)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: fixture.directory.path)
    )
  }

  func testPresentationCoordinatorWatchdogAndCompletionRaceFinishesOnce() throws {
    let fixture = try makePresentationFixture()
    let state = PresentationOutcomeBox()
    let coordinator = makePresentationCoordinator(
      fixture: fixture,
      state: state
    )

    fixture.driver.isActivityMounted = true
    coordinator.start()
    fixture.driver.completeActivity(completed: true)
    state.watchdog?()
    fixture.driver.completePresentation()
    fixture.driver.completeActivity(completed: false)

    XCTAssertEqual(state.outcomes, [.completed])
    XCTAssertFalse(fixture.gate.isInProgress)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: fixture.directory.path)
    )
  }

  func testPresentationCoordinatorRejectsPresenterBeforePresenting() throws {
    let fixture = try makePresentationFixture()
    let state = PresentationOutcomeBox()
    let coordinator = makePresentationCoordinator(
      fixture: fixture,
      state: state
    )

    fixture.driver.canPresent = false
    coordinator.start()
    state.watchdog?()

    XCTAssertEqual(state.outcomes, [.shareFailure])
    XCTAssertEqual(fixture.driver.presentCalls, 0)
    XCTAssertFalse(fixture.gate.isInProgress)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: fixture.directory.path)
    )
  }

  func testFullReportPassesAndFilenameUsesNativeBuildAndTime() throws {
    let data = validFullReport()
    let result = try FullDiagnosticExportValidator.validate(
      content: data,
      appVersion: "1.0.0",
      buildNumber: "42",
      now: Date(timeIntervalSince1970: 1_786_019_445)
    )

    XCTAssertEqual(result.data, data)
    XCTAssertEqual(
      result.filename,
      "emby-full-diagnostics-b42-20260806T123045Z.txt"
    )
    XCTAssertFalse(result.filename.contains("fixture"))
    XCTAssertFalse(result.filename.contains("/"))
    XCTAssertFalse(result.filename.contains("\\"))
  }

  func testFullReportHeaderOrderAndExactFieldsAreRequired() {
    let valid = String(data: validFullReport(), encoding: .utf8)!
    var lines = valid.split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)

    lines.swapAt(0, 1)
    assertFullUnsafe(Data(lines.joined(separator: "\n").utf8))

    lines = valid.split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    lines[0] = "extra=value"
    assertFullUnsafe(Data(lines.joined(separator: "\n").utf8))

    lines = Array(
      valid.split(separator: "\n", omittingEmptySubsequences: false)
        .dropFirst()
        .map(String.init)
    )
    assertFullUnsafe(Data(lines.joined(separator: "\n").utf8))
  }

  func testFullReportMustMatchBundleMetadataAndBodyDigest() {
    let data = validFullReport()
    assertFullUnsafe(data, appVersion: "1.0.1")
    assertFullUnsafe(data, buildNumber: "43")

    var lines = String(data: data, encoding: .utf8)!
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    lines[7] = "sha256=" + String(repeating: "0", count: 64)
    assertFullUnsafe(Data(lines.joined(separator: "\n").utf8))
  }

  func testFullReportRejectsSensitiveContentAndControlCharacters() {
    for value in [
      "password=secret",
      "Authorization: Basic credential",
      "Authorization: Bearer token",
      "Cookie: session=value",
      "X-Emby-Token: secret",
      "https://example.test:8096/path",
      "https%3A%2F%2Fexample.test%3A8096",
      "192.0.2.1",
      "2001:db8::1",
      "example.test:8096",
      "/var/mobile/Containers/Data/file.json",
      "Session JSON",
      "request headers",
      "response body",
    ] {
      assertFullUnsafe(Data(validFullBody(value).utf8))
    }

    assertFullUnsafe(Data(validFullBody("line\u{007F}injected").utf8))
    assertFullUnsafe(Data(validFullBody("line\rinjected").utf8))
  }

  func testFullReportRejectsContentOverNativeSizeLimit() {
    let body = String(
      repeating: "x",
      count: FullDiagnosticExportValidator.maxBytes
    )
    assertFullUnsafe(Data(validFullBody(body).utf8))
  }

  private typealias PresentationFixture = (
    store: SafeDiagnosticExportTemporaryStore,
    directory: URL,
    gate: SafeDiagnosticExportResultGate,
    driver: FakePresentationDriver
  )

  private func makePresentationFixture() throws -> PresentationFixture {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("safe-diagnostic-coordinator-\(UUID().uuidString)")
    let root = base.appendingPathComponent(
      SafeDiagnosticExportTemporaryStore.directoryName,
      isDirectory: true
    )
    let store = SafeDiagnosticExportTemporaryStore(rootURL: root)
    let directory = try store.makeSessionDirectory()
    _ = try store.writeAndVerify(
      data: Data("fixture".utf8),
      filename: "emby-safe-diagnostics-v1-b42-20260806T123045Z.json",
      in: directory
    )
    let gate = SafeDiagnosticExportResultGate()
    XCTAssertTrue(gate.begin())
    addTeardownBlock {
      store.cleanupStale()
      try? FileManager.default.removeItem(at: base)
    }
    return (store, directory, gate, FakePresentationDriver())
  }

  private func makePresentationCoordinator(
    fixture: PresentationFixture,
    state: PresentationOutcomeBox
  ) -> SafeDiagnosticExportPresentationCoordinator {
    SafeDiagnosticExportPresentationCoordinator(
      driver: fixture.driver,
      completionGate: SafeDiagnosticExportCompletionGate(),
      scheduleWatchdog: { state.watchdog = $0 },
      onFinish: { outcome in
        state.outcomes.append(outcome)
        fixture.store.remove(fixture.directory)
        XCTAssertTrue(fixture.gate.finish())
      }
    )
  }

  private func assertPresentationFailure(
    fixture: PresentationFixture,
    outcomes: [SafeDiagnosticExportPresentationOutcome]
  ) {
    XCTAssertEqual(outcomes, [.shareFailure])
    XCTAssertFalse(fixture.gate.isInProgress)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: fixture.directory.path)
    )
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

  private func validFullBody(_ body: String = "event=player_route_enter\n") -> String {
    let digest = SHA256.hash(data: Data(body.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    return [
      "schema=emby-full-diagnostics/v1",
      "generatedAtUtc=2026-08-06T12:30:45.000Z",
      "appVersion=1.0.0",
      "buildNumber=42",
      "platform=iPadOS",
      "redaction=best-effort",
      "truncated=false",
      "sha256=\(digest)",
      body,
    ].joined(separator: "\n")
  }

  private func validFullReport() -> Data {
    Data(validFullBody().utf8)
  }

  private func assertFullUnsafe(
    _ data: Data,
    appVersion: String = "1.0.0",
    buildNumber: String = "42",
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(
      try FullDiagnosticExportValidator.validate(
        content: data,
        appVersion: appVersion,
        buildNumber: buildNumber
      ),
      file: file,
      line: line
    ) { error in
      XCTAssertEqual(
        error as? FullDiagnosticExportValidationError,
        .unsafe,
        file: file,
        line: line
      )
    }
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
      do {
        _ = try SafeDiagnosticExportValidator.validate(
          content: data,
          appVersion: "1.0.0",
          buildNumber: "42"
        )
      } catch {
        XCTFail("validation failed: \(error)", file: file, line: line)
      }
    } catch {
      XCTFail("fixture could not be encoded: \(error)", file: file, line: line)
    }
  }
}

private final class PresentationOutcomeBox {
  var watchdog: (() -> Void)?
  var outcomes: [SafeDiagnosticExportPresentationOutcome] = []
}

private final class FakePresentationDriver:
  SafeDiagnosticExportPresentationDriver
{
  var canPresent = true
  var isActivityMounted = false
  var presentCalls = 0

  private var activityCompletion:
    ((_ completed: Bool, _ error: Error?) -> Void)?
  private var presentationCompletion: (() -> Void)?

  func setActivityCompletion(
    _ handler: @escaping (_ completed: Bool, _ error: Error?) -> Void
  ) {
    activityCompletion = handler
  }

  func present(animated: Bool, completion: @escaping () -> Void) {
    presentCalls += 1
    presentationCompletion = completion
  }

  func completePresentation() {
    presentationCompletion?()
  }

  func completeActivity(completed: Bool, error: Error? = nil) {
    activityCompletion?(completed, error)
  }
}
