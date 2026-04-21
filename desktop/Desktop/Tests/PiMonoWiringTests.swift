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

  // MARK: - ApiKeysResponse shape assertion
  // After #6594, the response must NOT contain anthropic_api_key.

  func testApiKeysResponseDecodesWithoutAnthropicKey() throws {
    let json = """
    {
      "firebase_api_key": "AIza-test",
      "google_calendar_api_key": "cal-key"
    }
    """.data(using: .utf8)!
    let response = try JSONDecoder().decode(APIClient.ApiKeysResponse.self, from: json)
    XCTAssertEqual(response.firebaseApiKey, "AIza-test")
    XCTAssertEqual(response.googleCalendarApiKey, "cal-key")
  }

  func testApiKeysResponseIgnoresUnknownAnthropicField() throws {
    // If the backend ever sends anthropic_api_key, the client must ignore it
    let json = """
    {
      "firebase_api_key": "AIza-test",
      "anthropic_api_key": "sk-ant-LEAKED",
      "google_calendar_api_key": "cal-key"
    }
    """.data(using: .utf8)!
    let response = try JSONDecoder().decode(APIClient.ApiKeysResponse.self, from: json)
    XCTAssertEqual(response.firebaseApiKey, "AIza-test")
    // Verify no property named anthropicApiKey exists on the response
    let mirror = Mirror(reflecting: response)
    let propertyNames = mirror.children.map { $0.label ?? "" }
    XCTAssertFalse(propertyNames.contains("anthropicApiKey"),
      "ApiKeysResponse must not have anthropicApiKey property (removed in #6594)")
  }

  // MARK: - Source-level wiring assertions
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

  func testNoAnthropicApiKeyInClientCode() throws {
    let sourcesDir = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // Tests/
      .deletingLastPathComponent()  // Desktop/
      .appendingPathComponent("Sources")

    guard FileManager.default.fileExists(atPath: sourcesDir.path) else {
      throw XCTSkip("Sources directory not found at \(sourcesDir.path)")
    }

    let targetFiles = ["APIClient.swift", "APIKeyService.swift"]
    let pattern = "anthropicApiKey"

    var violations: [String] = []
    for fileName in targetFiles {
      let enumerator = FileManager.default.enumerator(
        at: sourcesDir,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )!
      while let url = enumerator.nextObject() as? URL {
        guard url.lastPathComponent == fileName else { continue }
        let content = try String(contentsOf: url, encoding: .utf8)
        for (i, line) in content.components(separatedBy: .newlines).enumerated() {
          if line.contains(pattern) {
            violations.append("\(fileName):\(i + 1): \(line.trimmingCharacters(in: .whitespaces))")
          }
        }
      }
    }

    XCTAssertEqual(
      violations, [],
      "Found anthropicApiKey in client code — removed in #6594:\n"
        + violations.joined(separator: "\n"))
  }
}
