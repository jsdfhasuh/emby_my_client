  func testControlledStrmInputDecodesSeeksAndResumes() throws {
    // Uses the exact C bridge linked into Runner, not a mock stream callback.
    let context = try PlaybackCacheNativeProbe.makeTestContext()
    let symbol = try XCTUnwrap(dlsym(dlopen(nil, RTLD_NOW), "mpv_stream_cb_add_ro"))
    let bridge = try XCTUnwrap(strm_create(UnsafeMutableRawPointer(context), symbol))
    let fixture = strmFixtureVideo()
    XCTAssertEqual(strm_add(bridge, 1, Int64(fixture.count)), 1)
    let stopping = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    DispatchQueue(label: "strm-fixture-input").async {
      defer { done.signal() }
      var event = [Int64](repeating: 0, count: 4)
      while stopping.wait(timeout: .now()) == .timedOut {
        if strm_poll(bridge, &event) == 1 {
          let offset = Int(event[2]), count = Int(event[3])
          fixture.withUnsafeBytes { bytes in
            strm_complete(bridge, event[0], event[1],
              bytes.baseAddress!.advanced(by: offset).assumingMemoryBound(to: CChar.self), Int64(count))
          }
        } else { Thread.sleep(forTimeInterval: 0.001) }
      }
    }
    defer {
      strm_release(bridge, 1)
      strm_release(bridge, 2)
      mpv_terminate_destroy(context)
      stopping.signal()
      done.wait()
      strm_destroy(bridge)
    }
    for (name, value) in ["vid": "auto", "vo": "null", "ao": "null",
      "pause": "yes", "demuxer": "lavf", "demuxer-lavf-format": "avi",
      "demuxer-lavf-o": "protocol_whitelist=none", "access-references": "no",
      "ordered-chapters": "no", "sub-auto": "no", "audio-file-auto": "no"] {
      XCTAssertGreaterThanOrEqual(mpv_set_property_string(context, name, value), 0, name)
    }
    func command(_ values: [String]) -> Int32 {
      let strings = values.map { strdup($0)! }
      defer { strings.forEach { free($0) } }
      var pointers = strings.map { UnsafePointer<CChar>($0) as UnsafePointer<CChar>? }
      pointers.append(nil)
      return mpv_command(context, &pointers)
    }
    func property(_ name: String) -> String? {
      guard let text = mpv_get_property_string(context, name) else { return nil }
      defer { mpv_free(text) }
      return String(cString: text)
    }
    func snapshot() -> String {
      ["path", "idle-active", "video-params/w", "time-pos", "pause", "seeking"]
        .map { "\($0)=\(property($0) ?? "unavailable")" }.joined(separator: " ")
    }
    func require(_ condition: Bool, _ stage: String, file: StaticString = #filePath,
                 line: UInt = #line) throws {
      // Stop this scenario on the first failed prerequisite; do not print PASSED afterwards.
      guard !condition else { return }
      _ = try XCTUnwrap(condition ? true : nil, "\(stage): \(snapshot())", file: file, line: line)
    }
    func waitFor(_ name: String, _ predicate: (String) -> Bool) -> Bool {
      let deadline = ProcessInfo.processInfo.systemUptime + 15
      while ProcessInfo.processInfo.systemUptime < deadline {
        if let value = property(name), predicate(value) { return true }
        _ = mpv_wait_event(context, 0.01)
      }
      return false
    }
    func load(_ id: Int64) throws {
      // loadfile returns before loading completes. A decoded, settled first frame
      // on this exact input is the prerequisite for issuing the first seek.
      let path = "embyinput://\(id)"
      try require(command(["loadfile", path, "replace"]) >= 0, "load \(id) command")
      try require(waitFor("time-pos") {
        guard let position = Double($0) else { return false }
        return position >= 0 && position <= 1
          && property("path") == path
          && property("idle-active") == "no"
          && property("video-params/w") == "32"
          && property("seeking") == "no"
      }, "load \(id) decoded first frame ready")
    }
    func seek(_ seconds: Double) throws {
      try require(command(["seek", String(seconds), "absolute+exact"]) >= 0, "seek \(seconds) command")
      try require(waitFor("time-pos") {
        guard let position = Double($0) else { return false }
        return abs(position - seconds) <= 1 && property("seeking") == "no"
      }, "seek \(seconds) settled")
    }
    try load(1)
    try seek(16)
    strm_release(bridge, 1)
    try require(command(["stop"]) >= 0, "stop first input command")
    try require(waitFor("idle-active") { $0 == "yes" }, "stop first input completed")
    try require(strm_add(bridge, 2, Int64(fixture.count)) == 1, "register replacement input")
    try load(2)
    try seek(12)
    strm_release(bridge, 2)
    print("STRM_CUSTOM_INPUT_DECODE_SEEK_RESUME=PASSED")
  }
