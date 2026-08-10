import Foundation

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

  var diskCapabilityPassed: Bool {
    let requiredOptions = Set([
      "cache",
      "cache-on-disk",
      "demuxer-cache-dir",
      "demuxer-cache-unlink-files",
    ])
    return requiredOptions.isSubset(of: supportedOptions)
      && unlinkChoices.contains("immediate")
      && properties.contains("demuxer-cache-state")
      && profileSwitchStrategy != .unsupported
  }
}

enum PlaybackCacheNativeProbeError: Error {
  case createFailed
  case initializeFailed(Int32)
  case temporaryMediaFailed
}

enum PlaybackCacheNativeProbe {
  static let optionNames = [
    "cache",
    "cache-on-disk",
    "demuxer-cache-dir",
    "demuxer-cache-unlink-files",
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

  static func probe() throws -> PlaybackCacheNativeCapabilitySnapshot {
    let context = try makeContext()
    defer { mpv_terminate_destroy(context) }

    let supportedOptions = Set(optionNames.filter {
      stringProperty(context, "option-info/\($0)/name") == $0
    })
    let properties = Set((nodeProperty(context, "property-list") as? [Any] ?? [])
      .compactMap { $0 as? String })
    let choices = Set((nodeProperty(
      context,
      "option-info/demuxer-cache-unlink-files/choices"
    ) as? [Any] ?? []).compactMap { $0 as? String })
    var resetValues: [String: String] = [:]
    for option in supportedOptions {
      if let value = nodeProperty(context, "option-info/\(option)/default-value") {
        resetValues[option] = nativeString(value)
      }
    }

    let requiredOptions = Set([
      "cache",
      "cache-on-disk",
      "demuxer-cache-dir",
      "demuxer-cache-unlink-files",
    ])
    let strategy: PlaybackCacheNativeProfileSwitchStrategy
    if requiredOptions.isSubset(of: supportedOptions)
      && choices.contains("immediate")
    {
      strategy = try profileSwitchStrategy(resetValues: resetValues)
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
      profileSwitchStrategy: strategy
    )
  }

  private static func profileSwitchStrategy(
    resetValues: [String: String]
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
      resetValues: resetValues
    ) {
      return .inPlaceAfterMediaStop
    }
    if try runRecreatedProfiles(
      media: media,
      cacheDirectory: root,
      resetValues: resetValues
    ) {
      return .requiresPlayerRecreation
    }
    return .unsupported
  }

  private static func runSequence(
    media: URL,
    cacheDirectory: URL,
    resetValues: [String: String]
  ) throws -> Bool {
    let context = try makeContext()
    defer { mpv_terminate_destroy(context) }
    for profile in Profile.allCases {
      guard apply(
        profile,
        context: context,
        cacheDirectory: cacheDirectory,
        resetValues: resetValues
      ), openAndStop(context, media: media) else {
        return false
      }
    }
    return true
  }

  private static func runRecreatedProfiles(
    media: URL,
    cacheDirectory: URL,
    resetValues: [String: String]
  ) throws -> Bool {
    for profile in Profile.allCases {
      let context = try makeContext()
      let passed = apply(
        profile,
        context: context,
        cacheDirectory: cacheDirectory,
        resetValues: resetValues
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
    resetValues: [String: String]
  ) -> Bool {
    let directoryReset = resetValues["demuxer-cache-dir"] ?? ""
    let values: [String: String]
    switch profile {
    case .disk:
      values = [
        "cache": "yes",
        "cache-on-disk": "yes",
        "demuxer-cache-dir": cacheDirectory.path,
        "demuxer-cache-unlink-files": "immediate",
        "cache-secs": "30",
        "demuxer-max-bytes": "16777216",
        "demuxer-max-back-bytes": "8388608",
        "demuxer-donate-buffer": "yes",
        "demuxer-seekable-cache": "auto",
        "cache-pause": "yes",
        "cache-pause-wait": "1",
        "stream-buffer-size": "131072",
      ]
    case .memory:
      values = [
        "cache": "yes",
        "cache-on-disk": "no",
        "demuxer-cache-dir": directoryReset,
        "demuxer-cache-unlink-files": "immediate",
        "cache-secs": "30",
        "demuxer-max-bytes": "16777216",
        "demuxer-max-back-bytes": "8388608",
        "demuxer-donate-buffer": "yes",
        "demuxer-seekable-cache": "auto",
        "cache-pause": "yes",
        "cache-pause-wait": "1",
        "stream-buffer-size": "131072",
      ]
    case .disabled:
      values = [
        "cache": "no",
        "cache-on-disk": "no",
        "demuxer-cache-dir": directoryReset,
        "demuxer-cache-unlink-files": "immediate",
        "cache-secs": "0",
        "demuxer-max-bytes": "16777216",
        "demuxer-max-back-bytes": "8388608",
        "demuxer-donate-buffer": "yes",
        "demuxer-seekable-cache": "auto",
        "cache-pause": "no",
        "cache-pause-wait": "1",
        "stream-buffer-size": "131072",
      ]
    }
    for (name, value) in values {
      guard setString(context, name, value) else { return false }
    }
    for name in ["cache", "cache-on-disk", "demuxer-cache-dir", "cache-secs"] {
      guard normalized(stringProperty(context, name)) == normalized(values[name]) else {
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
    let status = name.withCString { pointer in
      mpv_get_property(context, pointer, MPV_FORMAT_NODE, &node)
    }
    guard status >= 0 else { return nil }
    defer { mpv_free_node_contents(&node) }
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
      return (0..<Int(list.pointee.num)).map {
        nodeValue(list.pointee.values[$0]) as Any
      }
    case MPV_FORMAT_NODE_MAP:
      guard let list = node.u.list else { return [String: Any]() }
      var result: [String: Any] = [:]
      for index in 0..<Int(list.pointee.num) {
        guard let keyPointer = list.pointee.keys?[index] else { continue }
        let key = String(cString: keyPointer)
        result[key] = nodeValue(list.pointee.values[index])
      }
      return result
    default:
      return nil
    }
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
    (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
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
