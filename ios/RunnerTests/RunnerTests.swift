import Flutter
import CryptoKit
import Network
import UIKit
import XCTest

final class RunnerTests: XCTestCase {
  func testNativeCacheOptionResolverUsesFirstCompleteCandidate() {
    let usable = PlaybackCacheNativeOptionFacts(
      optionNameMatches: true,
      optionExists: true,
      resetAvailable: true,
      requiredChoiceAvailable: true,
      writeReadBackPassed: true
    )
    let incomplete = PlaybackCacheNativeOptionFacts(
      optionNameMatches: true,
      optionExists: true,
      resetAvailable: false,
      requiredChoiceAvailable: false,
      writeReadBackPassed: false
    )

    let modern = PlaybackCacheNativeOptionResolver.resolve(
      logicalName: "cacheDirectory",
      facts: ["demuxer-cache-dir": usable, "cache-dir": usable]
    )
    XCTAssertEqual(modern.selected, "demuxer-cache-dir")
    XCTAssertEqual(modern.evidence.map(\.status), [.usable, .usable])

    let legacy = PlaybackCacheNativeOptionResolver.resolve(
      logicalName: "cacheDirectory",
      facts: ["demuxer-cache-dir": incomplete, "cache-dir": usable]
    )
    XCTAssertEqual(legacy.selected, "cache-dir")
    XCTAssertEqual(legacy.evidence.map(\.status), [.incomplete, .usable])

    let unavailable = PlaybackCacheNativeOptionResolver.resolve(
      logicalName: "cacheDirectory",
      facts: ["demuxer-cache-dir": incomplete, "cache-dir": incomplete]
    )
    XCTAssertNil(unavailable.selected)
    XCTAssertEqual(unavailable.evidence.map(\.status), [.incomplete, .incomplete])
  }

  func testNativeUnlinkResolverRequiresImmediateChoiceAndCanUseLegacy() {
    let modernWithoutImmediate = PlaybackCacheNativeOptionFacts(
      optionNameMatches: true,
      optionExists: true,
      resetAvailable: true,
      requiredChoiceAvailable: false,
      writeReadBackPassed: true
    )
    let legacyUsable = PlaybackCacheNativeOptionFacts(
      optionNameMatches: true,
      optionExists: true,
      resetAvailable: true,
      requiredChoiceAvailable: true,
      writeReadBackPassed: true
    )
    let result = PlaybackCacheNativeOptionResolver.resolve(
      logicalName: "cacheUnlinkFiles",
      facts: [
        "demuxer-cache-unlink-files": modernWithoutImmediate,
        "cache-unlink-files": legacyUsable,
      ]
    )
    XCTAssertEqual(result.selected, "cache-unlink-files")
    XCTAssertEqual(result.evidence.map(\.status), [.incomplete, .usable])
  }

  func testNativeResolverFallsBackWhenModernWriteReadBackFails() {
    let readBackFailure = PlaybackCacheNativeOptionFacts(
      optionNameMatches: true,
      optionExists: true,
      resetAvailable: true,
      requiredChoiceAvailable: true,
      writeReadBackPassed: false
    )
    let usable = PlaybackCacheNativeOptionFacts(
      optionNameMatches: true,
      optionExists: true,
      resetAvailable: true,
      requiredChoiceAvailable: true,
      writeReadBackPassed: true
    )

    let result = PlaybackCacheNativeOptionResolver.resolve(
      logicalName: "cacheDirectory",
      facts: [
        "demuxer-cache-dir": readBackFailure,
        "cache-dir": usable,
      ]
    )

    XCTAssertEqual(result.selected, "cache-dir")
    XCTAssertEqual(result.evidence.map(\.status), [.incomplete, .usable])
  }

  func testNativeValueCanonicalizerUsesApprovedEquivalences() {
    XCTAssertEqual(
      PlaybackCacheNativeValueCanonicalizer.canonicalize(
        " YES ", kind: .boolean
      ),
      "true"
    )
    XCTAssertTrue(
      PlaybackCacheNativeValueCanonicalizer.equivalent(
        "1", "true", kind: .boolean
      )
    )
    XCTAssertTrue(
      PlaybackCacheNativeValueCanonicalizer.equivalent(
        "1", "yes", kind: .booleanOrAuto
      )
    )
    XCTAssertEqual(
      PlaybackCacheNativeValueCanonicalizer.canonicalize(
        " AUTO ", kind: .booleanOrAuto
      ),
      "auto"
    )
    XCTAssertTrue(
      PlaybackCacheNativeValueCanonicalizer.equivalent(
        "3600000.0", "3600000", kind: .integer
      )
    )
    XCTAssertTrue(
      PlaybackCacheNativeValueCanonicalizer.equivalent(
        "/tmp/cache/", "/tmp/./cache", kind: .path
      )
    )
    XCTAssertNil(
      PlaybackCacheNativeValueCanonicalizer.canonicalize(
        "NaN", kind: .integer
      )
    )
    XCTAssertNil(
      PlaybackCacheNativeValueCanonicalizer.canonicalize(
        "immediate-ish", kind: .enumeration(["immediate"])
      )
    )
    XCTAssertEqual(
      PlaybackCacheNativeValueCanonicalizer.canonicalize(
        "9223372036854775807.0", kind: .integer
      ),
      "9223372036854775807"
    )
    XCTAssertNil(
      PlaybackCacheNativeValueCanonicalizer.canonicalize(
        "9223372036854775808", kind: .integer
      )
    )
    XCTAssertNil(
      PlaybackCacheNativeValueCanonicalizer.canonicalize(
        "1e3", kind: .integer
      )
    )
  }

  func testNativeProfilePlansKeepMemoryIndependentOfDiskOnlyOptions() {
    let resolved = [
      "cache": "cache",
      "cacheOnDisk": "cache-on-disk",
      "cacheSeconds": "cache-secs",
      "forwardMetadataBytes": "demuxer-max-bytes",
      "backwardMetadataBytes": "demuxer-max-back-bytes",
    ]
    let memory = PlaybackCacheNativeOptionResolver.makeProfileApplyPlan(
      profile: "memory",
      resolvedOptions: resolved,
      resetValues: [:],
      cacheDirectory: "/private/fixture"
    )
    XCTAssertEqual(memory.criticalValues["cache"], "yes")
    XCTAssertEqual(memory.criticalValues["cache-on-disk"], "no")
    XCTAssertFalse(memory.criticalValues.keys.contains("demuxer-cache-dir"))
    XCTAssertFalse(memory.criticalValues.keys.contains("cache-dir"))
    XCTAssertTrue(memory.optionalTuningDegraded)

    let disabled = PlaybackCacheNativeOptionResolver.makeProfileApplyPlan(
      profile: "disabled",
      resolvedOptions: ["cache": "cache"],
      resetValues: [:],
      cacheDirectory: "/private/fixture"
    )
    XCTAssertEqual(disabled.criticalValues, ["cache": "no"])
  }

  func testNativeCacheNodeParserIgnoresUnknownFieldsAndRejectsInvalidApprovedFields() {
    let parsed = PlaybackCacheNativeNodeParser.parse([
      "file-cache-bytes": Int64(1024),
      "raw-input-rate": 8192.0,
      "seekable-ranges": [
        ["start": 0, "end": 10],
      ],
      "cache-duration": 12.5,
      "reader-pts": 4,
      "native-extra-field": "not-exported",
    ] as [String: Any])
    XCTAssertEqual(parsed?.fileCacheBytes, 1024)
    XCTAssertEqual(parsed?.rawInputRate, 8192)
    XCTAssertEqual(parsed?.seekableRangeCount, 1)
    XCTAssertNil(
      PlaybackCacheNativeNodeParser.parse([
        "file-cache-bytes": 1,
        "raw-input-rate": 2,
        "seekable-ranges": [["start": 30, "end": 20]],
      ] as [String: Any])
    )
    XCTAssertNil(
      PlaybackCacheNativeNodeParser.parse([
        "file-cache-bytes": 1,
        "raw-input-rate": "2",
        "seekable-ranges": [],
      ] as [String: Any])
    )
    XCTAssertNil(
      PlaybackCacheNativeNodeParser.parse([
        "file-cache-bytes": 1,
        "raw-input-rate": 2,
        "seekable-ranges": [["start": 0, "end": 1, "unexpected": 2]],
      ] as [String: Any])
    )
    XCTAssertNotNil(
      PlaybackCacheNativeNodeParser.parse([
        "file-cache-bytes": 1,
        "raw-input-rate": 2,
        "seekable-ranges": [],
        "raw-node-dump": "ignored",
      ] as [String: Any])
    )
    XCTAssertNil(
      PlaybackCacheNativeNodeParser.parse([
        "raw-node-dump": "no-approved-fields",
      ] as [String: Any])
    )
  }

  func testNativeActiveContextReaderFreesNodeOnEveryResultPath() {
    let cases: [(Int32, Any?, PlaybackCacheNativeTelemetryReadStatus)] = [
      (0, ["file-cache-bytes": Int64(1)], .available),
      (0, ["file-cache-bytes": "invalid"], .readFailed),
      (
        PlaybackCacheNativeActiveContextReader.propertyNotFoundErrorCode,
        nil,
        .unsupported
      ),
      (
        PlaybackCacheNativeActiveContextReader.propertyUnavailableErrorCode,
        nil,
        .fieldTemporarilyAbsent
      ),
      (-11, nil, .readFailed),
    ]
    for (nativeStatus, copiedNode, expectedStatus) in cases {
      var freeCount = 0
      let result = PlaybackCacheNativeActiveContextReader.read(
        getProperty: { _ in nativeStatus },
        copyNode: { _ in copiedNode },
        freeNode: { _ in freeCount += 1 }
      )
      XCTAssertEqual(result.status, expectedStatus)
      XCTAssertEqual(result.state == nil, expectedStatus != .available)
      XCTAssertEqual(freeCount, 1)
    }
  }

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

    let manifest = try snapshot.safeManifestData()
    let attachment = XCTAttachment(data: manifest)
    attachment.name = "mpv-capability-manifest.json"
    attachment.lifetime = .keepAlways
    add(attachment)

    let decoded = try XCTUnwrap(
      JSONSerialization.jsonObject(with: manifest) as? [String: Any]
    )
    let options = try XCTUnwrap(decoded["options"] as? [String: Bool])
    let properties = try XCTUnwrap(decoded["properties"] as? [String: Bool])
    let missingResets = try XCTUnwrap(decoded["missingResetValues"] as? [String])
    XCTAssertEqual(Set(options.keys), Set(PlaybackCacheNativeProbe.optionNames))
    XCTAssertEqual(Set(properties.keys), Set(PlaybackCacheNativeProbe.requiredProperties))
    XCTAssertEqual(
      Set(missingResets),
      Set(snapshot.resolvedOptions.values).subtracting(snapshot.resetValues.keys)
    )
    XCTAssertEqual(decoded["resetValuesComplete"] as? Bool, snapshot.hasCompleteResetValues)
    XCTAssertEqual(decoded["diskCapabilityPassed"] as? Bool, snapshot.diskCapabilityPassed)
    XCTAssertEqual(
      decoded["diskProfileReadBack"] as? Bool,
      snapshot.profileReadBack["disk"] ?? false
    )
    XCTAssertEqual(
      decoded["memoryProfileReadBack"] as? Bool,
      snapshot.profileReadBack["memory"] ?? false
    )
    XCTAssertEqual(
      decoded["disabledProfileReadBack"] as? Bool,
      snapshot.profileReadBack["disabled"] ?? false
    )
    if snapshot.diskCapabilityPassed {
      XCTAssertTrue(
        PlaybackCacheNativeOptionResolver.criticalLogicalOptions.isSubset(
          of: Set(snapshot.resolvedOptions.keys)
        )
      )
      XCTAssertEqual(snapshot.profileReadBack["disk"], true)
      XCTAssertTrue(snapshot.unlinkChoices.contains("immediate"))
      XCTAssertNotEqual(snapshot.profileSwitchStrategy, .unsupported)
    }
    let candidateTableComplete = PlaybackCacheNativeOptionResolver.candidates.allSatisfy {
      logicalName, candidates in
      guard let evidence = snapshot.candidateEvidence[logicalName] else {
        return false
      }
      return evidence.map(\.nativeName) == candidates
        && evidence.allSatisfy { candidate in
          switch candidate.status {
          case .usable:
            return candidate.optionNameMatches
              && candidate.optionExists
              && candidate.resetAvailable
              && candidate.requiredChoiceAvailable
              && candidate.writeReadBackPassed
          case .incomplete:
            return candidate.optionExists
              && (!candidate.resetAvailable
                || !candidate.requiredChoiceAvailable
                || !candidate.writeReadBackPassed)
          case .unavailable:
            return !candidate.optionExists || !candidate.optionNameMatches
          }
        }
        && snapshot.resolvedOptions[logicalName]
          == evidence.first(where: { $0.status == .usable })?.nativeName
    }
    guard candidateTableComplete else {
      XCTFail("Native option candidate evidence is incomplete")
      return
    }
    print("STOP_GATE_CACHE_OPTION_BINDING_IMPLEMENTATION=PASSED")

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

  func testLoopbackPlaybackReadsTelemetryFromTheSameActiveContext() throws {
    let snapshot = try PlaybackCacheNativeProbe.probe()
    guard snapshot.profileReadBack["memory"] == true else {
      XCTFail("Memory profile native read-back did not pass")
      return
    }

    let server = try PlaybackCacheLoopbackRangeServer(
      body: playbackCacheFixtureWaveData()
    )
    let mediaURL = try server.start()
    defer { server.stop() }

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "emby-active-context-test-\(UUID().uuidString)", isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let memoryContext = try PlaybackCacheNativeProbe.makeTestContext()
    defer { mpv_terminate_destroy(memoryContext) }
    guard PlaybackCacheNativeProbe.configureProfileForTesting(
      "memory",
      context: memoryContext,
      cacheDirectory: root,
      snapshot: snapshot
    ) else {
      XCTFail("Memory profile configuration failed")
      return
    }
    guard PlaybackCacheNativeProbe.loadForTesting(memoryContext, url: mediaURL) else {
      XCTFail("Memory fixture load failed")
      return
    }
    defer { PlaybackCacheNativeProbe.stopForTesting(memoryContext) }

    let memoryRead = waitForActiveTelemetry(memoryContext)
    guard memoryRead.status == .available, memoryRead.state != nil else {
      XCTFail("Active-context memory telemetry was unavailable")
      return
    }
    guard PlaybackCacheNativeValueCanonicalizer.equivalent(
      PlaybackCacheNativeProbe.stringPropertyForTesting(
        memoryContext, name: "cache"
      ),
      "yes",
      kind: .booleanOrAuto
    ) else {
      XCTFail("Memory cache enable read-back failed")
      return
    }
    guard PlaybackCacheNativeValueCanonicalizer.equivalent(
      PlaybackCacheNativeProbe.stringPropertyForTesting(
        memoryContext, name: "cache-on-disk"
      ),
      "no",
      kind: .boolean
    ) else {
      XCTFail("Memory cache-on-disk read-back failed")
      return
    }
    guard server.requestCount > 0 else {
      XCTFail("Loopback fixture received no requests")
      return
    }
    print("STOP_GATE_MEMORY_CACHE_PROFILE=PASSED")
    print("STOP_GATE_ACTIVE_CONTEXT_TELEMETRY_READER=PASSED")

    guard snapshot.diskCapabilityPassed else {
      print("STOP_GATE_DISK_CACHE_CAPABILITY=BLOCKED_BY_BUNDLED_LIBMPV")
      print("STOP_GATE_DISK_TELEMETRY_EVIDENCE=BLOCKED_BY_BUNDLED_LIBMPV")
      return
    }

    let diskContext = try PlaybackCacheNativeProbe.makeTestContext()
    defer { mpv_terminate_destroy(diskContext) }
    guard PlaybackCacheNativeProbe.configureProfileForTesting(
      "disk",
      context: diskContext,
      cacheDirectory: root,
      snapshot: snapshot
    ) else {
      XCTFail("Disk profile configuration failed")
      return
    }
    guard PlaybackCacheNativeProbe.loadForTesting(diskContext, url: mediaURL) else {
      XCTFail("Disk fixture load failed")
      return
    }
    defer { PlaybackCacheNativeProbe.stopForTesting(diskContext) }

    let diskRead = waitForActiveTelemetry(
      diskContext,
      predicate: { state in
        (state.fileCacheBytes ?? 0) > 0 && state.seekableRangeCount > 0
      }
    )
    guard diskRead.status == .available,
          (diskRead.state?.fileCacheBytes ?? 0) > 0,
          (diskRead.state?.seekableRangeCount ?? 0) > 0 else {
      XCTFail("Disk telemetry did not prove nonzero cache data and a valid range")
      return
    }
    guard PlaybackCacheNativeValueCanonicalizer.equivalent(
      PlaybackCacheNativeProbe.stringPropertyForTesting(
        diskContext, name: "cache-on-disk"
      ),
      "yes",
      kind: .boolean
    ) else {
      XCTFail("Disk cache-on-disk read-back failed")
      return
    }
    print("STOP_GATE_DISK_CACHE_CAPABILITY=PASSED")
    print("STOP_GATE_DISK_TELEMETRY_EVIDENCE=PASSED")
  }

  func testLoopbackRangeServerProtocolContract() throws {
    let body = Data((0..<1024).map { UInt8($0 % 251) })
    let server = try PlaybackCacheLoopbackRangeServer(body: body)
    let url = try server.start()
    defer { server.stop() }

    var head = URLRequest(url: url)
    head.httpMethod = "HEAD"
    let (headResponse, headData) = try performLoopbackRequest(head)
    XCTAssertEqual(headResponse.statusCode, 200)
    XCTAssertEqual(headData.count, 0)
    XCTAssertEqual(headResponse.value(forHTTPHeaderField: "Accept-Ranges"), "bytes")
    XCTAssertEqual(headResponse.value(forHTTPHeaderField: "Content-Length"), "1024")
    XCTAssertEqual(headResponse.value(forHTTPHeaderField: "ETag"), "\"emby-mpv-cache-v1\"")

    let (getResponse, getData) = try performLoopbackRequest(URLRequest(url: url))
    XCTAssertEqual(getResponse.statusCode, 200)
    XCTAssertEqual(getData, body)

    var range = URLRequest(url: url)
    range.setValue("bytes=10-19", forHTTPHeaderField: "Range")
    let (rangeResponse, rangeData) = try performLoopbackRequest(range)
    XCTAssertEqual(rangeResponse.statusCode, 206)
    XCTAssertEqual(rangeData, body.subdata(in: 10..<20))
    XCTAssertEqual(
      rangeResponse.value(forHTTPHeaderField: "Content-Range"),
      "bytes 10-19/1024"
    )

    var suffix = URLRequest(url: url)
    suffix.setValue("bytes=-16", forHTTPHeaderField: "Range")
    let (suffixResponse, suffixData) = try performLoopbackRequest(suffix)
    XCTAssertEqual(suffixResponse.statusCode, 206)
    XCTAssertEqual(suffixData, Data(body.suffix(16)))
    XCTAssertEqual(
      suffixResponse.value(forHTTPHeaderField: "Content-Range"),
      "bytes 1008-1023/1024"
    )

    var invalid = URLRequest(url: url)
    invalid.setValue("bytes=2048-4095", forHTTPHeaderField: "Range")
    let (invalidResponse, invalidData) = try performLoopbackRequest(invalid)
    XCTAssertEqual(invalidResponse.statusCode, 416)
    XCTAssertEqual(invalidData.count, 0)
    XCTAssertEqual(
      invalidResponse.value(forHTTPHeaderField: "Content-Range"),
      "bytes */1024"
    )
  }

  func testLoopbackRangeServerRejectsEmptyFixture() {
    XCTAssertThrowsError(try PlaybackCacheLoopbackRangeServer(body: Data())) { error in
      XCTAssertEqual(error as? PlaybackCacheLoopbackError, .emptyBody)
    }
  }

  func testIncompleteNativeResetEvidenceBlocksDiskWithoutGuessing() throws {
    let snapshot = PlaybackCacheNativeCapabilitySnapshot(
      mpvVersion: "mpv 0.40.0-test Copyright build path must not escape",
      platform: "darwin",
      supportedOptions: Set(PlaybackCacheNativeProbe.optionNames),
      properties: Set(PlaybackCacheNativeProbe.requiredProperties),
      unlinkChoices: ["immediate"],
      resetValues: ["cache": "auto"],
      profileSwitchStrategy: .unsupported,
      resolvedOptions: [
        "cache": "cache",
        "cacheOnDisk": "cache-on-disk",
      ]
    )

    XCTAssertFalse(snapshot.hasCompleteResetValues)
    XCTAssertFalse(snapshot.diskCapabilityPassed)
    let manifest = try snapshot.safeManifestData()
    let decoded = try XCTUnwrap(
      JSONSerialization.jsonObject(with: manifest) as? [String: Any]
    )
    XCTAssertEqual(decoded["mpvVersionFingerprint"] as? String, "mpv-0.40.0-test")
    XCTAssertEqual(decoded["platform"] as? String, "iPadOS")
    XCTAssertEqual(decoded["resetValuesComplete"] as? Bool, false)
    XCTAssertEqual(
      Set(try XCTUnwrap(decoded["missingResetValues"] as? [String])),
      ["cache-on-disk"]
    )
  }

  func testNativeManifestRejectsVersionlessMpvIdentity() {
    for identity in ["mpv", "mpv-test"] {
      let snapshot = PlaybackCacheNativeCapabilitySnapshot(
        mpvVersion: identity,
        platform: "darwin",
        supportedOptions: [],
        properties: [],
        unlinkChoices: [],
        resetValues: [:],
        profileSwitchStrategy: .unsupported
      )

      XCTAssertThrowsError(try snapshot.safeManifestData(), identity)
    }
  }

  func testNativeManifestRejectsUnsafeIdentitySubstrings() {
    let identities = [
      ("Copyright mpv 0.40.0", "darwin"),
      ("mpv 0.40.0", "username@host:8096"),
      ("mpv 0.40.0", "linux"),
      ("mpv 0.40.0", "192.168.0.1"),
      ("mpv 1.2-" + String(repeating: "a", count: 60), "darwin"),
    ]
    for (version, platform) in identities {
      let snapshot = PlaybackCacheNativeCapabilitySnapshot(
        mpvVersion: version,
        platform: platform,
        supportedOptions: [],
        properties: [],
        unlinkChoices: [],
        resetValues: [:],
        profileSwitchStrategy: .unsupported
      )

      XCTAssertThrowsError(try snapshot.safeManifestData(), "\(version) \(platform)")
    }
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

  private func waitForActiveTelemetry(
    _ context: OpaquePointer,
    predicate: (PlaybackCacheNativeTelemetryState) -> Bool = { _ in true }
  ) -> PlaybackCacheNativeTelemetryReadResult {
    let deadline = Date().addingTimeInterval(10)
    var latest = PlaybackCacheNativeTelemetryReadResult(
      status: .fieldTemporarilyAbsent,
      state: nil
    )
    while Date() < deadline {
      latest = PlaybackCacheNativeActiveContextReader.read(context)
      if let state = latest.state, latest.status == .available, predicate(state) {
        return latest
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    return latest
  }

  private func performLoopbackRequest(
    _ request: URLRequest
  ) throws -> (HTTPURLResponse, Data) {
    let completed = DispatchSemaphore(value: 0)
    let result = PlaybackCacheLoopbackResponseBox()
    let session = URLSession(configuration: .ephemeral)
    var request = request
    request.cachePolicy = .reloadIgnoringLocalCacheData
    session.dataTask(with: request) { receivedData, receivedResponse, error in
      result.store(
        response: receivedResponse,
        data: receivedData ?? Data(),
        error: error
      )
      completed.signal()
    }.resume()
    guard completed.wait(timeout: .now() + 5) == .success else {
      session.invalidateAndCancel()
      throw PlaybackCacheLoopbackError.requestTimedOut
    }
    session.finishTasksAndInvalidate()
    let snapshot = result.snapshot()
    if let requestError = snapshot.error { throw requestError }
    return (try XCTUnwrap(snapshot.response as? HTTPURLResponse), snapshot.data)
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

private enum PlaybackCacheLoopbackError: Error, Equatable {
  case emptyBody
  case listenerFailed
  case listenerTimedOut
  case requestTimedOut
}

private final class PlaybackCacheLoopbackResponseBox: @unchecked Sendable {
  private let lock = NSLock()
  private var response: URLResponse?
  private var data = Data()
  private var error: Error?

  func store(response: URLResponse?, data: Data, error: Error?) {
    lock.lock()
    defer { lock.unlock() }
    self.response = response
    self.data = data
    self.error = error
  }

  func snapshot() -> (response: URLResponse?, data: Data, error: Error?) {
    lock.lock()
    defer { lock.unlock() }
    return (response, data, error)
  }
}

private final class PlaybackCacheLoopbackListenerStateBox: @unchecked Sendable {
  private let lock = NSLock()
  private var failed = false

  func markFailed() {
    lock.lock()
    failed = true
    lock.unlock()
  }

  func didFail() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return failed
  }
}

private final class PlaybackCacheLoopbackRangeServer: @unchecked Sendable {
  init(body: Data) throws {
    guard !body.isEmpty else { throw PlaybackCacheLoopbackError.emptyBody }
    self.body = body
    listener = try NWListener(using: .tcp, on: .any)
  }

  private let body: Data
  private let listener: NWListener
  private let queue = DispatchQueue(label: "emby.playback-cache-loopback")
  private let lock = NSLock()
  private var requests = 0

  var requestCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return requests
  }

  func start() throws -> URL {
    let ready = DispatchSemaphore(value: 0)
    let listenerState = PlaybackCacheLoopbackListenerStateBox()
    listener.stateUpdateHandler = { state in
      switch state {
      case .ready:
        ready.signal()
      case .failed:
        listenerState.markFailed()
        ready.signal()
      default:
        break
      }
    }
    listener.newConnectionHandler = { [weak self] connection in
      self?.handle(connection)
    }
    listener.start(queue: queue)
    guard ready.wait(timeout: .now() + 3) == .success else {
      listener.cancel()
      throw PlaybackCacheLoopbackError.listenerTimedOut
    }
    guard !listenerState.didFail(), let port = listener.port,
          let url = URL(string: "http://127.0.0.1:\(port.rawValue)/fixture.wav") else {
      listener.cancel()
      throw PlaybackCacheLoopbackError.listenerFailed
    }
    return url
  }

  func stop() {
    listener.cancel()
  }

  private func handle(_ connection: NWConnection) {
    connection.start(queue: queue)
    receive(connection, accumulated: Data())
  }

  private func receive(_ connection: NWConnection, accumulated: Data) {
    connection.receive(
      minimumIncompleteLength: 1,
      maximumLength: 64 * 1024
    ) { [weak self] data, _, isComplete, error in
      guard let self else {
        connection.cancel()
        return
      }
      var request = accumulated
      if let data { request.append(data) }
      if request.range(of: Data("\r\n\r\n".utf8)) != nil {
        respond(connection, request: request)
        return
      }
      if error != nil || isComplete || request.count >= 64 * 1024 {
        connection.cancel()
        return
      }
      receive(connection, accumulated: request)
    }
  }

  private func respond(_ connection: NWConnection, request: Data) {
    guard let text = String(data: request, encoding: .utf8) else {
      send(connection, status: "400 Bad Request", headers: [], data: Data())
      return
    }
    lock.lock()
    requests += 1
    lock.unlock()

    let lines = text.components(separatedBy: "\r\n")
    let requestLine = lines.first?.split(separator: " ") ?? []
    guard requestLine.count >= 2 else {
      send(connection, status: "400 Bad Request", headers: [], data: Data())
      return
    }
    let method = String(requestLine[0]).uppercased()
    guard method == "GET" || method == "HEAD" else {
      send(
        connection,
        status: "405 Method Not Allowed",
        headers: ["Allow: HEAD, GET"],
        data: Data()
      )
      return
    }

    let rangeLine = lines.first {
      $0.lowercased().hasPrefix("range:")
    }
    let parsedRange = rangeLine.flatMap(parseRange)
    if rangeLine != nil && parsedRange == nil {
      send(
        connection,
        status: "416 Range Not Satisfiable",
        headers: ["Content-Range: bytes */\(body.count)"],
        data: Data()
      )
      return
    }

    let range = parsedRange ?? 0...(body.count - 1)
    let responseData = method == "HEAD"
      ? Data()
      : body.subdata(in: range.lowerBound..<(range.upperBound + 1))
    var headers = [
      "Accept-Ranges: bytes",
      "Content-Type: audio/wav",
      "Content-Length: \(range.count)",
      "ETag: \"emby-mpv-cache-v1\"",
      "Connection: close",
    ]
    if parsedRange != nil {
      headers.append(
        "Content-Range: bytes \(range.lowerBound)-\(range.upperBound)/\(body.count)"
      )
    }
    send(
      connection,
      status: parsedRange == nil ? "200 OK" : "206 Partial Content",
      headers: headers,
      data: responseData
    )
  }

  private func parseRange(_ header: String) -> ClosedRange<Int>? {
    guard let separator = header.firstIndex(of: ":") else { return nil }
    let value = header[header.index(after: separator)...]
      .trimmingCharacters(in: .whitespaces)
    guard value.hasPrefix("bytes="), !value.contains(",") else { return nil }
    let bounds = value.dropFirst("bytes=".count).split(
      separator: "-", omittingEmptySubsequences: false
    )
    guard bounds.count == 2 else { return nil }
    if bounds[0].isEmpty {
      guard let suffixLength = Int(bounds[1]), suffixLength > 0 else { return nil }
      let length = min(suffixLength, body.count)
      return (body.count - length)...(body.count - 1)
    }
    guard let start = Int(bounds[0]), start >= 0, start < body.count else {
      return nil
    }
    let requestedEnd = bounds[1].isEmpty ? body.count - 1 : Int(bounds[1])
    guard let requestedEnd, requestedEnd >= start else { return nil }
    return start...min(requestedEnd, body.count - 1)
  }

  private func send(
    _ connection: NWConnection,
    status: String,
    headers: [String],
    data: Data
  ) {
    let head = (["HTTP/1.1 \(status)"] + headers + ["", ""])
      .joined(separator: "\r\n")
    var response = Data(head.utf8)
    response.append(data)
    connection.send(content: response, completion: .contentProcessed { _ in
      connection.cancel()
    })
  }
}

private func playbackCacheFixtureWaveData() -> Data {
  let sampleRate: UInt32 = 8_000
  let durationSeconds: UInt32 = 60
  let pcmBytes = sampleRate * durationSeconds * 2
  var result = Data()
  func append32(_ value: UInt32) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { result.append(contentsOf: $0) }
  }
  func append16(_ value: UInt16) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { result.append(contentsOf: $0) }
  }
  result.append(contentsOf: Array("RIFF".utf8))
  append32(36 + pcmBytes)
  result.append(contentsOf: Array("WAVEfmt ".utf8))
  append32(16)
  append16(1)
  append16(1)
  append32(sampleRate)
  append32(sampleRate * 2)
  append16(2)
  append16(16)
  result.append(contentsOf: Array("data".utf8))
  append32(pcmBytes)
  result.append(Data(repeating: 0, count: Int(pcmBytes)))
  return result
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
