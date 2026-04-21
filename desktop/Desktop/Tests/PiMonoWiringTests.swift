import XCTest

@testable import Omi_Computer

final class PiMonoWiringTests: XCTestCase {

  // MARK: - TaskChatState mode-mapping logic
  // Mirrors the branching in TaskChatState.ensureBridge():
  //   let mode = UserDefaults.standard.string(forKey: "chatBridgeMode") ?? "piMono"
  //   let harness = mode == "piMono" ? "piMono" : "acp"

  func testTaskChatModeMappingDefaultNil() {
    // When chatBridgeMode is not set, defaults to "piMono"
    let mode: String? = nil
    let resolved = mode ?? "piMono"
    let harness = resolved == "piMono" ? "piMono" : "acp"

    XCTAssertEqual(harness, "piMono")
  }

  func testTaskChatModeMappingPiMono() {
    let mode = "piMono"
    let harness = mode == "piMono" ? "piMono" : "acp"

    XCTAssertEqual(harness, "piMono")
  }

  func testTaskChatModeMappingClaudeCode() {
    let mode = "claudeCode"
    let harness = mode == "piMono" ? "piMono" : "acp"

    XCTAssertEqual(harness, "acp")
  }

  func testTaskChatModeMappingAgentSDK() {
    // Legacy "agentSDK" mode should fall through to acp harness
    let mode = "agentSDK"
    let harness = mode == "piMono" ? "piMono" : "acp"

    XCTAssertEqual(harness, "acp")
  }

  // MARK: - Source-level wiring assertion
  // Ensures no ACPBridge(passApiKey:) exists in production code (parameter removed in #6594).

  func testNoACPBridgePassApiKeyInSources() throws {
    let sourcesDir = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // Tests/
      .deletingLastPathComponent()  // Desktop/
      .appendingPathComponent("Sources")

    guard FileManager.default.fileExists(atPath: sourcesDir.path) else {
      throw XCTSkip("Sources directory not found at \(sourcesDir.path)")
    }

    let enumerator = FileManager.default.enumerator(
      at: sourcesDir,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    )!

    var violations: [String] = []
    while let url = enumerator.nextObject() as? URL {
      guard url.pathExtension == "swift" else { continue }
      let content = try String(contentsOf: url, encoding: .utf8)
      for (i, line) in content.components(separatedBy: .newlines).enumerated() {
        if line.contains("ACPBridge(passApiKey:") {
          let relativePath = url.lastPathComponent
          violations.append("\(relativePath):\(i + 1): \(line.trimmingCharacters(in: .whitespaces))")
        }
      }
    }

    XCTAssertEqual(
      violations, [],
      "Found ACPBridge(passApiKey:) — passApiKey parameter was removed in #6594. Use ACPBridge(harnessMode:) instead:\n"
        + violations.joined(separator: "\n"))
  }
}
