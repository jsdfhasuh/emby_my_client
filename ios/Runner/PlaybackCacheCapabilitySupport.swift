import Foundation

enum PlaybackCacheNativeOptionCandidateStatus: String {
  case unavailable
  case incomplete
  case usable
}

struct PlaybackCacheNativeOptionCandidateEvidence {
  let nativeName: String
  let status: PlaybackCacheNativeOptionCandidateStatus
  let optionNameMatches: Bool
  let optionExists: Bool
  let resetAvailable: Bool
  let requiredChoiceAvailable: Bool
  let writeReadBackPassed: Bool
}

struct PlaybackCacheNativeOptionFacts {
  let optionNameMatches: Bool
  let optionExists: Bool
  let resetAvailable: Bool
  let requiredChoiceAvailable: Bool
  let writeReadBackPassed: Bool
}

enum PlaybackCacheNativeValueKind {
  case boolean
  case booleanOrAuto
  case integer
  case enumeration(Set<String>)
  case path
}

enum PlaybackCacheNativeValueCanonicalizer {
  static func canonicalize(
    _ raw: String,
    kind: PlaybackCacheNativeValueKind
  ) -> String? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
      return nil
    }
    switch kind {
    case .boolean:
      switch value.lowercased() {
      case "yes", "true", "1": return "true"
      case "no", "false", "0": return "false"
      default: return nil
      }
    case .booleanOrAuto:
      if value.lowercased() == "auto" { return "auto" }
      return canonicalize(value, kind: .boolean)
    case .integer:
      guard value.range(
        of: #"^[+-]?[0-9]+(?:\.0+)?$"#,
        options: .regularExpression
      ) != nil else {
        return nil
      }
      let integer = value.split(separator: ".", omittingEmptySubsequences: false)[0]
      guard let number = Int64(integer) else { return nil }
      return String(number)
    case let .enumeration(allowed):
      let normalized = value.lowercased()
      return allowed.contains(normalized) ? normalized : nil
    case .path:
      return normalizePath(value)
    }
  }

  static func equivalent(
    _ actual: String?,
    _ expected: String?,
    kind: PlaybackCacheNativeValueKind
  ) -> Bool {
    guard let actual, let expected,
          let left = canonicalize(actual, kind: kind),
          let right = canonicalize(expected, kind: kind)
    else { return false }
    return left == right
  }

  private static func normalizePath(_ value: String) -> String {
    guard !value.isEmpty else { return "" }
    let unified = value.replacingOccurrences(of: "\\", with: "/")
    let absolute = unified.hasPrefix("/")
    var parts: [String] = []
    for part in unified.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
      if part == "." { continue }
      if part == ".." {
        if let last = parts.last, last != ".." {
          parts.removeLast()
        } else if !absolute {
          parts.append(part)
        }
      } else {
        parts.append(part)
      }
    }
    let result = parts.joined(separator: "/")
    if absolute { return result.isEmpty ? "/" : "/" + result }
    return result
  }
}

enum PlaybackCacheNativeOptionResolver {
  static let candidates: [String: [String]] = [
    "cache": ["cache"],
    "cacheOnDisk": ["cache-on-disk"],
    "cacheDirectory": ["demuxer-cache-dir", "cache-dir"],
    "cacheUnlinkFiles": ["demuxer-cache-unlink-files", "cache-unlink-files"],
    "cacheSeconds": ["cache-secs"],
    "forwardMetadataBytes": ["demuxer-max-bytes"],
    "backwardMetadataBytes": ["demuxer-max-back-bytes"],
    "donateBuffer": ["demuxer-donate-buffer"],
    "seekableCache": ["demuxer-seekable-cache"],
    "cachePause": ["cache-pause"],
    "cachePauseWait": ["cache-pause-wait"],
    "streamBufferSize": ["stream-buffer-size"],
  ]

  static let criticalLogicalOptions: Set<String> = [
    "cache", "cacheOnDisk", "cacheDirectory", "cacheUnlinkFiles",
    "cacheSeconds", "forwardMetadataBytes", "backwardMetadataBytes",
  ]

  static let optionalLogicalOptions: Set<String> = [
    "donateBuffer", "seekableCache", "cachePause", "cachePauseWait",
    "streamBufferSize",
  ]

  static func valueKind(for logicalName: String) -> PlaybackCacheNativeValueKind {
    switch logicalName {
    case "cache":
      return .booleanOrAuto
    case "seekableCache":
      return .enumeration(["auto", "yes", "no"])
    case "cacheOnDisk", "donateBuffer", "cachePause":
      return .boolean
    case "cacheDirectory":
      return .path
    case "cacheUnlinkFiles":
      return .enumeration(["no", "whendone", "immediate"])
    default:
      return .integer
    }
  }

  static func makeProfileApplyPlan(
    profile: String,
    resolvedOptions: [String: String],
    resetValues: [String: String],
    cacheDirectory: String
  ) -> PlaybackCacheNativeProfileApplyPlan {
    func add(_ target: inout [String: String], _ logical: String, _ value: String) {
      if let native = resolvedOptions[logical] { target[native] = value }
    }
    func reset(_ logical: String) -> String? {
      guard let native = resolvedOptions[logical] else { return nil }
      return resetValues[native]
    }
    var critical: [String: String] = [:]
    var optional: [String: String] = [:]
    switch profile {
    case "disk":
      add(&critical, "cache", "yes")
      add(&critical, "cacheOnDisk", "yes")
      add(&critical, "cacheDirectory", cacheDirectory)
      add(&critical, "cacheUnlinkFiles", "immediate")
      add(&critical, "cacheSeconds", "30")
      add(&critical, "forwardMetadataBytes", "16777216")
      add(&critical, "backwardMetadataBytes", "8388608")
    case "memory":
      add(&critical, "cache", "yes")
      add(&critical, "cacheOnDisk", "no")
      add(&critical, "cacheSeconds", "30")
      add(&critical, "forwardMetadataBytes", "16777216")
      add(&critical, "backwardMetadataBytes", "8388608")
      if let value = reset("cacheDirectory") { add(&optional, "cacheDirectory", value) }
      if let value = reset("cacheUnlinkFiles") { add(&optional, "cacheUnlinkFiles", value) }
    default:
      add(&critical, "cache", "no")
      add(&critical, "cacheOnDisk", "no")
    }
    add(&optional, "donateBuffer", "yes")
    add(&optional, "seekableCache", "auto")
    add(&optional, "cachePause", profile == "disabled" ? "no" : "yes")
    add(&optional, "cachePauseWait", "1")
    add(&optional, "streamBufferSize", "131072")
    let selectedLogical = Set(resolvedOptions.keys)
    let degraded = !PlaybackCacheNativeOptionResolver.optionalLogicalOptions
      .isSubset(of: selectedLogical)
    return PlaybackCacheNativeProfileApplyPlan(
      criticalValues: critical,
      optionalValues: optional,
      criticalReadBack: Set(critical.keys),
      optionalReadBack: Set(optional.keys),
      optionalTuningDegraded: degraded
    )
  }

  static func resolve(
    logicalName: String,
    facts: [String: PlaybackCacheNativeOptionFacts]
  ) -> (selected: String?, evidence: [PlaybackCacheNativeOptionCandidateEvidence]) {
    let names = candidates[logicalName] ?? []
    var selected: String?
    var evidence: [PlaybackCacheNativeOptionCandidateEvidence] = []
    for name in names {
      let fact = facts[name] ?? PlaybackCacheNativeOptionFacts(
        optionNameMatches: false,
        optionExists: false,
        resetAvailable: false,
        requiredChoiceAvailable: false,
        writeReadBackPassed: false
      )
      let status: PlaybackCacheNativeOptionCandidateStatus
      if !fact.optionExists || !fact.optionNameMatches {
        status = .unavailable
      } else if (logicalName == "cacheDirectory" || logicalName == "cacheUnlinkFiles") && !fact.resetAvailable {
        status = .incomplete
      } else if logicalName == "cacheUnlinkFiles" && !fact.requiredChoiceAvailable {
        status = .incomplete
      } else if !fact.writeReadBackPassed {
        status = .incomplete
      } else {
        status = .usable
      }
      evidence.append(
        PlaybackCacheNativeOptionCandidateEvidence(
          nativeName: name,
          status: status,
          optionNameMatches: fact.optionNameMatches,
          optionExists: fact.optionExists,
          resetAvailable: fact.resetAvailable,
          requiredChoiceAvailable: fact.requiredChoiceAvailable,
          writeReadBackPassed: fact.writeReadBackPassed
        )
      )
      if selected == nil && status == .usable { selected = name }
    }
    return (selected, evidence)
  }
}

struct PlaybackCacheNativeProfileApplyPlan {
  let criticalValues: [String: String]
  let optionalValues: [String: String]
  let criticalReadBack: Set<String>
  let optionalReadBack: Set<String>
  let optionalTuningDegraded: Bool
}

struct PlaybackCacheNativeTelemetryState: Equatable {
  let fileCacheBytes: Int64?
  let rawInputRate: Double?
  let cacheDuration: Double?
  let readerPts: Double?
  let seekableRangeCount: Int
}

enum PlaybackCacheNativeNodeParser {
  static let allowedKeys: Set<String> = [
    "file-cache-bytes", "raw-input-rate", "seekable-ranges",
    "cache-duration", "reader-pts",
  ]

  static func parse(_ value: Any) -> PlaybackCacheNativeTelemetryState? {
    guard let map = value as? [String: Any] else { return nil }
    let recognizedKeys = Set(map.keys).intersection(allowedKeys)
    guard !recognizedKeys.isEmpty else { return nil }
    let bytes: Int64?
    if let value = map["file-cache-bytes"] {
      guard let parsed = nonnegativeInt64(value) else { return nil }
      bytes = parsed
    } else {
      bytes = nil
    }
    let rawRate: Double?
    if let value = map["raw-input-rate"] {
      guard let parsed = finiteDouble(value) else { return nil }
      guard parsed >= 0 else { return nil }
      rawRate = parsed
    } else {
      rawRate = nil
    }
    let duration: Double?
    if let value = map["cache-duration"] {
      guard let parsed = finiteDouble(value) else { return nil }
      guard parsed >= 0 else { return nil }
      duration = parsed
    } else {
      duration = nil
    }
    let pts: Double?
    if let value = map["reader-pts"] {
      guard let parsed = finiteDouble(value) else { return nil }
      pts = parsed
    } else {
      pts = nil
    }
    let rangeCount: Int
    if let rawRanges = map["seekable-ranges"] {
      guard let ranges = rawRanges as? [Any] else { return nil }
      var validRanges = 0
      for value in ranges {
        guard let range = value as? [String: Any],
              Set(range.keys) == ["start", "end"],
              let start = finiteDouble(range["start"]),
              let end = finiteDouble(range["end"]),
              start >= 0, end > start else { continue }
        validRanges += 1
      }
      if validRanges != ranges.count { return nil }
      rangeCount = validRanges
    } else {
      rangeCount = 0
    }
    return PlaybackCacheNativeTelemetryState(
      fileCacheBytes: bytes,
      rawInputRate: rawRate,
      cacheDuration: duration,
      readerPts: pts,
      seekableRangeCount: rangeCount
    )
  }

  private static func finiteDouble(_ value: Any?) -> Double? {
    guard let value else { return nil }
    let number: Double?
    if let value = value as? Double { number = value }
    else if let value = value as? Int { number = Double(value) }
    else if let value = value as? Int64 { number = Double(value) }
    else { number = nil }
    guard let number, number.isFinite else { return nil }
    return number
  }

  private static func nonnegativeInt64(_ value: Any) -> Int64? {
    if let value = value as? Int64 { return value >= 0 ? value : nil }
    if let value = value as? Int { return value >= 0 ? Int64(value) : nil }
    return nil
  }
}

enum PlaybackCacheNativeTelemetryReadStatus: String {
  case available
  case fieldTemporarilyAbsent
  case unsupported
  case readFailed
}

struct PlaybackCacheNativeTelemetryReadResult: Equatable {
  let status: PlaybackCacheNativeTelemetryReadStatus
  let state: PlaybackCacheNativeTelemetryState?
}

enum PlaybackCacheNativeActiveContextReader {
  static let propertyNotFoundErrorCode = Int32(MPV_ERROR_PROPERTY_NOT_FOUND)
  static let propertyUnavailableErrorCode = Int32(MPV_ERROR_PROPERTY_UNAVAILABLE)

  static func read(_ context: OpaquePointer) -> PlaybackCacheNativeTelemetryReadResult {
    read(
      getProperty: { node in
        "demuxer-cache-state".withCString { property in
          mpv_get_property(context, property, MPV_FORMAT_NODE, node)
        }
      },
      copyNode: PlaybackCacheNativeProbe.nodeValueForTesting,
      freeNode: mpv_free_node_contents
    )
  }

  static func read(
    getProperty: (UnsafeMutablePointer<mpv_node>) -> Int32,
    copyNode: (mpv_node) -> Any?,
    freeNode: (UnsafeMutablePointer<mpv_node>) -> Void
  ) -> PlaybackCacheNativeTelemetryReadResult {
    var node = mpv_node()
    defer { freeNode(&node) }
    let status = getProperty(&node)
    guard status >= 0 else {
      let readStatus: PlaybackCacheNativeTelemetryReadStatus
      switch status {
      case propertyNotFoundErrorCode:
        readStatus = .unsupported
      case propertyUnavailableErrorCode:
        readStatus = .fieldTemporarilyAbsent
      default:
        readStatus = .readFailed
      }
      return PlaybackCacheNativeTelemetryReadResult(
        status: readStatus,
        state: nil
      )
    }
    guard let value = copyNode(node),
          let state = PlaybackCacheNativeNodeParser.parse(value)
    else {
      return PlaybackCacheNativeTelemetryReadResult(status: .readFailed, state: nil)
    }
    return PlaybackCacheNativeTelemetryReadResult(status: .available, state: state)
  }
}

enum PlaybackCacheNativeProfileSwitchStrategy: String {
  case inPlaceAfterMediaStop
  case requiresPlayerRecreation
  case unsupported
}

struct PlaybackCacheNativeCapabilitySnapshot {
  let mpvVersion: String
  let platform: String
  let supportedOptions: Set<String>
  let properties: Set<String>
  let unlinkChoices: Set<String>
  let resetValues: [String: String]
  let profileSwitchStrategy: PlaybackCacheNativeProfileSwitchStrategy
  let resolvedOptions: [String: String]
  let candidateEvidence: [String: [PlaybackCacheNativeOptionCandidateEvidence]]
  let profileReadBack: [String: Bool]

  init(
    mpvVersion: String,
    platform: String,
    supportedOptions: Set<String>,
    properties: Set<String>,
    unlinkChoices: Set<String>,
    resetValues: [String: String],
    profileSwitchStrategy: PlaybackCacheNativeProfileSwitchStrategy,
    resolvedOptions: [String: String] = [:],
    candidateEvidence: [String: [PlaybackCacheNativeOptionCandidateEvidence]] = [:],
    profileReadBack: [String: Bool] = [:]
  ) {
    self.mpvVersion = mpvVersion
    self.platform = platform
    self.supportedOptions = supportedOptions
    self.properties = properties
    self.unlinkChoices = unlinkChoices
    self.resetValues = resetValues
    self.profileSwitchStrategy = profileSwitchStrategy
    self.resolvedOptions = resolvedOptions
    self.candidateEvidence = candidateEvidence
    self.profileReadBack = profileReadBack
  }

  var hasCompleteResetValues: Bool {
    let expected = Set(resolvedOptions.values)
    return expected.isSubset(of: Set(resetValues.keys))
  }

  var diskCapabilityPassed: Bool {
    let requiredLogicalOptions = PlaybackCacheNativeOptionResolver.criticalLogicalOptions
    return requiredLogicalOptions.isSubset(of: Set(resolvedOptions.keys))
      && requiredLogicalOptions.allSatisfy {
        guard let nativeName = resolvedOptions[$0] else { return false }
        return resetValues[nativeName] != nil
      }
      && unlinkChoices.contains("immediate")
      && properties.contains("demuxer-cache-state")
      && mediaDurationCacheSecondsReadBack
      && profileReadBack["disk"] == true
      && profileSwitchStrategy != .unsupported
  }

  var mediaDurationCacheSecondsReadBack: Bool {
    guard let nativeName = resolvedOptions["cacheSeconds"] else { return false }
    return candidateEvidence["cacheSeconds"]?.contains {
      $0.nativeName == nativeName && $0.writeReadBackPassed
    } ?? false
  }
}

enum PlaybackCacheNativeProbeError: Error {
  case createFailed
  case initializeFailed(Int32)
  case temporaryMediaFailed
  case unsafeManifest
}

enum PlaybackCacheNativeProbe {
  static let mediaDurationCacheSeconds = "1800"

  static let optionNames = [
    "cache",
    "cache-on-disk",
    "demuxer-cache-dir",
    "cache-dir",
    "demuxer-cache-unlink-files",
    "cache-unlink-files",
    "cache-secs",
    "demuxer-max-bytes",
    "demuxer-max-back-bytes",
    "demuxer-donate-buffer",
    "demuxer-seekable-cache",
    "cache-pause",
    "cache-pause-wait",
    "stream-buffer-size",
  ]

  static let requiredProperties = [
    "mpv-version",
    "platform",
    "property-list",
    "demuxer-cache-state",
  ]

  static func makeTestContext() throws -> OpaquePointer {
    try makeContext()
  }

  static func configureProfileForTesting(
    _ profileName: String,
    context: OpaquePointer,
    cacheDirectory: URL,
    snapshot: PlaybackCacheNativeCapabilitySnapshot
  ) -> Bool {
    let profile: Profile
    switch profileName {
    case "disk": profile = .disk
    case "memory": profile = .memory
    case "disabled": profile = .disabled
    default: return false
    }
    return apply(
      profile,
      context: context,
      cacheDirectory: cacheDirectory,
      resetValues: snapshot.resetValues,
      resolvedOptions: snapshot.resolvedOptions
    )
  }

  static func setStringForTesting(
    _ context: OpaquePointer,
    name: String,
    value: String
  ) -> Bool {
    setString(context, name, value)
  }

  static func stringPropertyForTesting(
    _ context: OpaquePointer,
    name: String
  ) -> String? {
    stringProperty(context, name)
  }

  static func loadForTesting(_ context: OpaquePointer, url: URL) -> Bool {
    guard command(context, ["loadfile", url.absoluteString, "replace"]) else {
      return false
    }
    return waitForIdle(context, expected: false, timeout: 10)
  }

  static func stopForTesting(_ context: OpaquePointer) {
    _ = command(context, ["stop"])
    _ = waitForIdle(context, expected: true, timeout: 2)
  }

  static func nodeValueForTesting(_ node: mpv_node) -> Any? {
    nodeValue(node)
  }

  static func probe() throws -> PlaybackCacheNativeCapabilitySnapshot {
    let context = try makeContext()
    defer { mpv_terminate_destroy(context) }
    let probeRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      "emby-mpv-option-probe-\(UUID().uuidString)", isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: probeRoot, withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: probeRoot) }

    let supportedOptions = Set(optionNames.filter {
      stringProperty(context, "option-info/\($0)/name") == $0
    })
    let properties = propertyNames(nodeProperty(context, "property-list"))
    var choices = Set<String>()
    var resolvedOptions: [String: String] = [:]
    var candidateEvidence: [String: [PlaybackCacheNativeOptionCandidateEvidence]] = [:]
    for (logicalName, candidates) in PlaybackCacheNativeOptionResolver.candidates {
      var facts: [String: PlaybackCacheNativeOptionFacts] = [:]
      for candidate in candidates {
        let optionName = stringProperty(context, "option-info/\(candidate)/name")
        let reset = nodeProperty(context, "option-info/\(candidate)/default-value")
          .map(nativeString)
        let candidateChoices = Set((nodeProperty(
          context,
          "option-info/\(candidate)/choices"
        ) as? [Any] ?? []).compactMap { $0 as? String })
        if logicalName == "cacheUnlinkFiles" { choices.formUnion(candidateChoices) }
        let valueKind = PlaybackCacheNativeOptionResolver.valueKind(for: logicalName)
        let resetAvailable = reset != nil &&
          PlaybackCacheNativeValueCanonicalizer.canonicalize(
            reset!, kind: valueKind
          ) != nil
        let readBack = resetAvailable && candidateWriteReadBack(
          context: context,
          logicalName: logicalName,
          nativeName: candidate,
          resetValue: reset,
          probeDirectory: probeRoot,
          valueKind: valueKind
        )
        facts[candidate] = PlaybackCacheNativeOptionFacts(
          optionNameMatches: optionName == candidate,
          optionExists: optionName == candidate,
          resetAvailable: resetAvailable,
          requiredChoiceAvailable: logicalName != "cacheUnlinkFiles" || candidateChoices.contains("immediate"),
          writeReadBackPassed: readBack
        )
      }
      let resolution = PlaybackCacheNativeOptionResolver.resolve(
        logicalName: logicalName, facts: facts
      )
      candidateEvidence[logicalName] = resolution.evidence
      if let selected = resolution.selected { resolvedOptions[logicalName] = selected }
    }
    for candidate in ["demuxer-cache-unlink-files", "cache-unlink-files"] {
      if let candidateChoices = nodeProperty(
        context, "option-info/\(candidate)/choices"
      ) as? [Any] {
        choices.formUnion(candidateChoices.compactMap { $0 as? String })
      }
    }
    var resetValues: [String: String] = [:]
    for option in supportedOptions {
      if let value = nodeProperty(context, "option-info/\(option)/default-value") {
        resetValues[option] = nativeString(value)
      }
    }

    let requiredLogicalOptions = PlaybackCacheNativeOptionResolver.criticalLogicalOptions
    let memoryLogicalOptions: Set<String> = [
      "cache", "cacheOnDisk", "cacheSeconds", "forwardMetadataBytes",
      "backwardMetadataBytes",
    ]
    let diskReadBack = requiredLogicalOptions.isSubset(of: Set(resolvedOptions.keys))
      && probeProfileReadBack(
        .disk, resetValues: resetValues, resolvedOptions: resolvedOptions
      )
    let memoryReadBack = memoryLogicalOptions.isSubset(of: Set(resolvedOptions.keys))
      && probeProfileReadBack(
        .memory, resetValues: resetValues, resolvedOptions: resolvedOptions
      )
    let disabledReadBack = resolvedOptions["cache"] != nil
      && probeProfileReadBack(
        .disabled, resetValues: resetValues, resolvedOptions: resolvedOptions
      )
    let strategy: PlaybackCacheNativeProfileSwitchStrategy
    let criticalResolved = requiredLogicalOptions.allSatisfy {
      guard let nativeName = resolvedOptions[$0] else { return false }
      return resetValues[nativeName] != nil
    }
    if criticalResolved && choices.contains("immediate") && diskReadBack
    {
      strategy = try profileSwitchStrategy(
        resetValues: resetValues, resolvedOptions: resolvedOptions
      )
    } else {
      strategy = .unsupported
    }
    return PlaybackCacheNativeCapabilitySnapshot(
      mpvVersion: stringProperty(context, "mpv-version") ?? "",
      platform: stringProperty(context, "platform") ?? "",
      supportedOptions: supportedOptions,
      properties: properties,
      unlinkChoices: choices,
      resetValues: resetValues,
      profileSwitchStrategy: strategy,
      resolvedOptions: resolvedOptions,
      candidateEvidence: candidateEvidence,
      profileReadBack: [
        "disk": diskReadBack,
        "memory": memoryReadBack,
        "disabled": disabledReadBack,
      ]
    )
  }

  private static func candidateWriteReadBack(
    context: OpaquePointer,
    logicalName: String,
    nativeName: String,
    resetValue: String?,
    probeDirectory: URL,
    valueKind: PlaybackCacheNativeValueKind
  ) -> Bool {
    let expected: String
    switch logicalName {
    case "cache":
      expected = "yes"
    case "cacheOnDisk":
      expected = "no"
    case "cacheDirectory":
      expected = probeDirectory.path
    case "cacheUnlinkFiles":
      expected = "immediate"
    case "cacheSeconds":
      expected = Self.mediaDurationCacheSeconds
    case "forwardMetadataBytes", "backwardMetadataBytes",
         "cachePauseWait", "streamBufferSize":
      expected = "1"
    case "donateBuffer", "cachePause":
      expected = "yes"
    case "seekableCache":
      expected = "auto"
    default:
      guard let resetValue else { return false }
      expected = resetValue
    }
    guard let resetValue, setString(context, nativeName, expected) else {
      return false
    }
    let probePassed = PlaybackCacheNativeValueCanonicalizer.equivalent(
      stringProperty(context, nativeName), expected, kind: valueKind
    )
    let resetPassed = setString(context, nativeName, resetValue)
      && PlaybackCacheNativeValueCanonicalizer.equivalent(
        stringProperty(context, nativeName), resetValue, kind: valueKind
      )
    return probePassed && resetPassed
  }

  private static func probeProfileReadBack(
    _ profile: Profile,
    resetValues: [String: String],
    resolvedOptions: [String: String]
  ) -> Bool {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "emby-mpv-profile-readback-\(UUID().uuidString)", isDirectory: true
    )
    do {
      try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: true
      )
      defer { try? FileManager.default.removeItem(at: root) }
      let context = try makeContext()
      defer { mpv_terminate_destroy(context) }
      return apply(
        profile,
        context: context,
        cacheDirectory: root,
        resetValues: resetValues,
        resolvedOptions: resolvedOptions
      )
    } catch {
      return false
    }
  }

  private static func profileSwitchStrategy(
    resetValues: [String: String],
    resolvedOptions: [String: String]
  ) throws -> PlaybackCacheNativeProfileSwitchStrategy {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "emby-mpv-capability-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let media = root.appendingPathComponent("probe.wav", isDirectory: false)
    try waveProbeData().write(to: media, options: .atomic)

    if try runSequence(
      media: media,
      cacheDirectory: root,
      resetValues: resetValues,
      resolvedOptions: resolvedOptions
    ) {
      return .inPlaceAfterMediaStop
    }
    if try runRecreatedProfiles(
      media: media,
      cacheDirectory: root,
      resetValues: resetValues,
      resolvedOptions: resolvedOptions
    ) {
      return .requiresPlayerRecreation
    }
    return .unsupported
  }

  private static func runSequence(
    media: URL,
    cacheDirectory: URL,
    resetValues: [String: String],
    resolvedOptions: [String: String]
  ) throws -> Bool {
    let context = try makeContext()
    defer { mpv_terminate_destroy(context) }
    for profile in Profile.allCases {
      guard apply(
        profile,
        context: context,
        cacheDirectory: cacheDirectory,
        resetValues: resetValues,
        resolvedOptions: resolvedOptions
      ), openAndStop(context, media: media) else {
        return false
      }
    }
    return true
  }

  private static func runRecreatedProfiles(
    media: URL,
    cacheDirectory: URL,
    resetValues: [String: String],
    resolvedOptions: [String: String]
  ) throws -> Bool {
    for profile in Profile.allCases {
      let context = try makeContext()
      let passed = apply(
        profile,
        context: context,
        cacheDirectory: cacheDirectory,
        resetValues: resetValues,
        resolvedOptions: resolvedOptions
      ) && openAndStop(context, media: media)
      mpv_terminate_destroy(context)
      if !passed { return false }
    }
    return true
  }

  private enum Profile: CaseIterable {
    case disk
    case memory
    case disabled
  }

  private static func apply(
    _ profile: Profile,
    context: OpaquePointer,
    cacheDirectory: URL,
    resetValues: [String: String],
    resolvedOptions: [String: String]
  ) -> Bool {
    func name(_ logical: String) -> String? { resolvedOptions[logical] }
    func reset(_ logical: String) -> String? {
      guard let native = name(logical) else { return nil }
      return resetValues[native]
    }
    var values: [String: String] = [:]
    func add(_ logical: String, _ value: String) -> Bool {
      guard let native = name(logical) else { return false }
      values[native] = value
      return true
    }
    switch profile {
    case .disk:
      guard add("cache", "yes"), add("cacheOnDisk", "yes"),
            add("cacheDirectory", cacheDirectory.path),
            add("cacheUnlinkFiles", "immediate"),
            add("cacheSeconds", "30"), add("forwardMetadataBytes", "16777216"),
            add("backwardMetadataBytes", "8388608") else { return false }
    case .memory:
      guard add("cache", "yes"), add("cacheOnDisk", "no"),
            add("cacheSeconds", "30"), add("forwardMetadataBytes", "16777216"),
            add("backwardMetadataBytes", "8388608") else { return false }
      if let directory = reset("cacheDirectory"), let native = name("cacheDirectory") {
        values[native] = directory
      }
      if let unlink = reset("cacheUnlinkFiles"), let native = name("cacheUnlinkFiles") {
        values[native] = unlink
      }
    case .disabled:
      guard add("cache", "no") else { return false }
      if name("cacheOnDisk") != nil && !add("cacheOnDisk", "no") { return false }
    }
    for (name, value) in values {
      guard setString(context, name, value) else { return false }
    }
    for (nativeName, expected) in values {
      let logicalName = resolvedOptions.first(where: { $0.value == nativeName })?.key ?? ""
      let kind = PlaybackCacheNativeOptionResolver.valueKind(for: logicalName)
      guard PlaybackCacheNativeValueCanonicalizer.equivalent(
        stringProperty(context, nativeName), expected, kind: kind
      ) else {
        return false
      }
    }
    return true
  }

  private static func makeContext() throws -> OpaquePointer {
    guard let context = mpv_create() else {
      throw PlaybackCacheNativeProbeError.createFailed
    }
    _ = setOption(context, "terminal", "no")
    _ = setOption(context, "vo", "null")
    _ = setOption(context, "ao", "null")
    _ = setOption(context, "idle", "yes")
    let status = mpv_initialize(context)
    guard status >= 0 else {
      mpv_terminate_destroy(context)
      throw PlaybackCacheNativeProbeError.initializeFailed(status)
    }
    return context
  }

  private static func openAndStop(_ context: OpaquePointer, media: URL) -> Bool {
    guard command(context, ["loadfile", media.path, "replace"]) else {
      return false
    }
    guard waitForIdle(context, expected: false, timeout: 2) else {
      return false
    }
    guard command(context, ["stop"]) else { return false }
    return waitForIdle(context, expected: true, timeout: 2)
  }

  private static func waitForIdle(
    _ context: OpaquePointer,
    expected: Bool,
    timeout: TimeInterval
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      let value = stringProperty(context, "idle-active")
      if (value == "yes") == expected { return true }
      _ = mpv_wait_event(context, 0.02)
    }
    return false
  }

  private static func setOption(
    _ context: OpaquePointer,
    _ name: String,
    _ value: String
  ) -> Bool {
    name.withCString { namePointer in
      value.withCString { valuePointer in
        mpv_set_option_string(context, namePointer, valuePointer) >= 0
      }
    }
  }

  private static func setString(
    _ context: OpaquePointer,
    _ name: String,
    _ value: String
  ) -> Bool {
    name.withCString { namePointer in
      value.withCString { valuePointer in
        mpv_set_property_string(context, namePointer, valuePointer) >= 0
      }
    }
  }

  private static func stringProperty(
    _ context: OpaquePointer,
    _ name: String
  ) -> String? {
    name.withCString { pointer in
      guard let value = mpv_get_property_string(context, pointer) else {
        return nil
      }
      defer { mpv_free(value) }
      return String(cString: value)
    }
  }

  private static func nodeProperty(
    _ context: OpaquePointer,
    _ name: String
  ) -> Any? {
    var node = mpv_node()
    defer { mpv_free_node_contents(&node) }
    let status = name.withCString { pointer in
      mpv_get_property(context, pointer, MPV_FORMAT_NODE, &node)
    }
    guard status >= 0 else { return nil }
    return nodeValue(node)
  }

  private static func nodeValue(_ node: mpv_node) -> Any? {
    switch node.format {
    case MPV_FORMAT_STRING, MPV_FORMAT_OSD_STRING:
      guard let string = node.u.string else { return nil }
      return String(cString: string)
    case MPV_FORMAT_FLAG:
      return node.u.flag != 0
    case MPV_FORMAT_INT64:
      return node.u.int64
    case MPV_FORMAT_DOUBLE:
      return node.u.double_
    case MPV_FORMAT_NODE_ARRAY:
      guard let list = node.u.list else { return [] }
      guard list.pointee.num >= 0 else { return nil }
      if list.pointee.num == 0 { return [Any]() }
      guard let values = list.pointee.values else { return nil }
      var result: [Any] = []
      for index in 0..<Int(list.pointee.num) {
        guard let value = nodeValue(values[index]) else { return nil }
        result.append(value)
      }
      return result
    case MPV_FORMAT_NODE_MAP:
      guard let list = node.u.list else { return [String: Any]() }
      guard list.pointee.num >= 0 else { return nil }
      if list.pointee.num == 0 { return [String: Any]() }
      guard let keys = list.pointee.keys,
            let values = list.pointee.values else { return nil }
      var result: [String: Any] = [:]
      for index in 0..<Int(list.pointee.num) {
        guard let keyPointer = keys[index],
              let value = nodeValue(values[index]) else { return nil }
        let key = String(cString: keyPointer)
        result[key] = value
      }
      return result
    default:
      return nil
    }
  }

  private static func propertyNames(_ value: Any?) -> Set<String> {
    guard let entries = value as? [Any] else { return [] }
    return Set(entries.compactMap { entry in
      if let name = entry as? String { return name }
      if let map = entry as? [String: Any], let name = map["name"] as? String {
        return name
      }
      return nil
    })
  }

  private static func command(_ context: OpaquePointer, _ args: [String]) -> Bool {
    var allocated = args.map { strdup($0) }
    allocated.append(nil)
    defer {
      for pointer in allocated where pointer != nil { free(pointer) }
    }
    return allocated.withUnsafeMutableBufferPointer { buffer in
      guard let baseAddress = buffer.baseAddress else { return false }
      let argsPointer = UnsafeMutableRawPointer(baseAddress)
        .assumingMemoryBound(to: UnsafePointer<CChar>?.self)
      return mpv_command(context, argsPointer) >= 0
    }
  }

  private static func normalized(_ value: String?) -> String {
    (value ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
  }

  private static func equivalent(_ actual: String?, _ expected: String?) -> Bool {
    let left = normalized(actual)
    let right = normalized(expected)
    if left == right { return true }
    guard let leftNumber = Double(left), let rightNumber = Double(right) else {
      return false
    }
    return leftNumber == rightNumber
  }

  private static func nativeString(_ value: Any) -> String {
    if let value = value as? String { return value }
    if let value = value as? Bool { return value ? "yes" : "no" }
    return String(describing: value)
  }

  private static func waveProbeData() -> Data {
    var data = Data()
    func append(_ value: UInt32) {
      var littleEndian = value.littleEndian
      withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
    func append16(_ value: UInt16) {
      var littleEndian = value.littleEndian
      withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
    data.append(contentsOf: Array("RIFF".utf8))
    append(38)
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    append(16)
    append16(1)
    append16(1)
    append(8_000)
    append(16_000)
    append16(2)
    append16(16)
    data.append(contentsOf: Array("data".utf8))
    append(2)
    append16(0)
    return data
  }
}

extension PlaybackCacheNativeCapabilitySnapshot {
  func safeManifestData() throws -> Data {
    let optionNames = Set(PlaybackCacheNativeProbe.optionNames)
    guard
      let version = Self.safeMpvVersionFingerprint(mpvVersion),
      let safePlatform = Self.safePlatform(platform),
      Set(resetValues.keys).isSubset(of: optionNames),
      Set(resetValues.keys).isSubset(of: supportedOptions)
    else {
      throw PlaybackCacheNativeProbeError.unsafeManifest
    }
    let expectedResetOptions = Set(resolvedOptions.values)
    let missingResetValues = expectedResetOptions.filter {
      resetValues[$0] == nil
    }.sorted()
    var safeResetValues: [String: String] = [:]
    for (option, value) in resetValues {
      if PlaybackCacheNativeOptionResolver.candidates["cacheDirectory"]?
        .contains(option) == true {
        safeResetValues[option] = "available"
        continue
      }
      guard Self.isSafeValue(value) else {
        throw PlaybackCacheNativeProbeError.unsafeManifest
      }
      safeResetValues[option] = value
    }
    let safeCandidateEvidence = Dictionary(uniqueKeysWithValues: candidateEvidence.map {
      logical, evidence in
      (logical, evidence.map { candidate in
        [
          "nativeName": candidate.nativeName,
          "status": candidate.status.rawValue,
          "optionNameMatches": candidate.optionNameMatches,
          "optionExists": candidate.optionExists,
          "resetAvailable": candidate.resetAvailable,
          "requiredChoiceAvailable": candidate.requiredChoiceAvailable,
          "writeReadBackPassed": candidate.writeReadBackPassed,
        ] as [String: Any]
      })
    })
    func variant(_ logical: String) -> String {
      guard let selected = resolvedOptions[logical],
            let candidates = PlaybackCacheNativeOptionResolver.candidates[logical],
            let index = candidates.firstIndex(of: selected) else { return "unavailable" }
      return index == 0 ? "modern" : "legacy"
    }
    func status(_ logical: String, _ index: Int) -> String {
      candidateEvidence[logical]?[safe: index]?.status.rawValue ?? "unavailable"
    }
    let manifest: [String: Any] = [
      "schema": "emby-mpv-capabilities/v1",
      "mpvVersionFingerprint": version,
      "platform": safePlatform,
      "options": Dictionary(uniqueKeysWithValues:
        PlaybackCacheNativeProbe.optionNames.map {
          ($0, supportedOptions.contains($0))
        }
      ),
      "properties": Dictionary(uniqueKeysWithValues:
        PlaybackCacheNativeProbe.requiredProperties.map {
          ($0, properties.contains($0))
        }
      ),
      "unlinkChoices": unlinkChoices.filter {
        ["no", "whendone", "immediate"].contains($0)
      }.sorted(),
      "resetValues": safeResetValues,
      "resetValuesComplete": hasCompleteResetValues,
      "missingResetValues": missingResetValues,
      "resolvedOptions": resolvedOptions,
      "candidateEvidence": safeCandidateEvidence,
      "cacheDirectoryVariant": variant("cacheDirectory"),
      "cacheDirectoryModernStatus": status("cacheDirectory", 0),
      "cacheDirectoryLegacyStatus": status("cacheDirectory", 1),
      "cacheUnlinkVariant": variant("cacheUnlinkFiles"),
      "cacheUnlinkModernStatus": status("cacheUnlinkFiles", 0),
      "cacheUnlinkLegacyStatus": status("cacheUnlinkFiles", 1),
      "diskProfileReadBack": profileReadBack["disk"] ?? false,
      "memoryProfileReadBack": profileReadBack["memory"] ?? false,
      "disabledProfileReadBack": profileReadBack["disabled"] ?? false,
      "mediaDurationCacheSecondsReadBack": mediaDurationCacheSecondsReadBack,
      "profileSwitchStrategy": profileSwitchStrategy.rawValue,
      "diskCapabilityPassed": diskCapabilityPassed,
    ]
    return try JSONSerialization.data(
      withJSONObject: manifest,
      options: [.prettyPrinted, .sortedKeys]
    )
  }

  private static func safePlatform(_ value: String) -> String? {
    switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "darwin", "ios", "ipados":
      return "iPadOS"
    case "android":
      return "Android"
    default:
      return nil
    }
  }

  private static func safeMpvVersionFingerprint(_ value: String) -> String? {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let pattern = #"(?i)^mpv(?:\s+v?|[-_]v?)?([0-9]+(?:\.[0-9]+){1,3}(?:[-+][A-Za-z0-9._-]+)?)"#
    guard
      let expression = try? NSRegularExpression(pattern: pattern),
      let match = expression.firstMatch(
        in: normalized,
        range: NSRange(normalized.startIndex..., in: normalized)
      ),
      match.numberOfRanges == 2,
      let versionRange = Range(match.range(at: 1), in: normalized)
    else {
      return nil
    }
    let version = String(normalized[versionRange])
    guard version.utf8.count <= 59, isSafeValue(version) else {
      return nil
    }
    return "mpv-\(version)"
  }

  private static func isSafeValue(_ value: String) -> Bool {
    value.range(of: "^[A-Za-z0-9._+\\-]*$", options: .regularExpression) != nil
  }
}

private extension Array {
  subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
