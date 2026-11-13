import Darwin
import Foundation
import Testing

@testable import MonoDeckCore

struct TestTaskTests {
  @Test func cancellationStopsOwnedHelpersAndCleansTheEnvironment() async throws {
    let fixture = try TestTaskFixture()
    defer { fixture.remove() }
    let operation = Task { try await fixture.runCapturingLog() }
    do {
      let pidFile = fixture.directory.appending(path: "helper.pid")
      let deadline = ContinuousClock.now.advanced(by: .seconds(5))
      while !PathSafety.exists(pidFile), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      let pid = try #require(try? Int32(String(contentsOf: pidFile, encoding: .utf8)))
      let invocation = try fixture.invocation()
      operation.cancel()
      do {
        _ = try await operation.value
        Issue.record("Expected cancellation")
      } catch { #expect((error as? MonoDeckError)?.code == "cancelled") }
      #expect(kill(pid, 0) == -1)
      let log = try String(
        contentsOf: fixture.directory.appending(path: "cancellation.log"), encoding: .utf8)
      #expect(!PathSafety.exists(invocation.directory), "\(log)")
      #expect(
        try await fixture.defaultsExist(invocation.environment["MONO_DECK_TEST_DEFAULTS"]!)
          == false, "\(log)")
      #expect(PathSafety.exists(fixture.sentinel))
    } catch {
      operation.cancel()
      _ = try? await operation.value
      throw error
    }
  }
}

private struct TestTaskInvocation: Decodable {
  let environment: [String: String]
  var directory: URL { URL(fileURLWithPath: environment["MONO_DECK_TEST_SESSION_DIRECTORY"]!) }
}

private struct TestTaskFixture {
  let directory: URL
  let sentinel: URL
  let runner: CommandRunner
  private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent()

  init() throws {
    directory = TestEnvironment.temporaryDirectory.appending(
      path: "mono-deck test task \(UUID().uuidString)")
    sentinel = directory.appending(path: "unrelated.txt")
    let bin = directory.appending(path: "bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try Data("keep me".utf8).write(to: sentinel)
    for name in ["xcodebuild", "xcrun"] {
      let fixture = Self.root.appending(path: "script/tests/fixtures/\(name).py")
      let file = bin.appending(path: name)
      let contents = try "#!/usr/bin/python3\n" + String(contentsOf: fixture, encoding: .utf8)
      try Data(contents.utf8).write(to: file)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = bin.path + ":/usr/bin:/bin"
    environment["TMPDIR"] = directory.path
    environment["MONO_DECK_TEST_DEFAULTS"] = "inherited-preferences"
    environment["MONO_DECK_TEST_WORKSPACE"] = "/unrelated-workspace"
    environment["MONO_DECK_UNIT_TEST_HOST"] = "1"
    environment["TEST_RUNNER_MONO_DECK_UNIT_TEST_HOST"] = "1"
    environment["MONO_DECK_SCRIPT_TEST_DIRECTORY"] = directory.path
    environment["MONO_DECK_SCRIPT_TEST_OUTCOME"] = "waiting"
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    runner = CommandRunner(environment: environment)
  }

  func invocation() throws -> TestTaskInvocation {
    try JSONDecoder().decode(
      TestTaskInvocation.self, from: Data(contentsOf: directory.appending(path: "invocation.json")))
  }

  func runCapturingLog() async throws -> CommandOutput {
    try await runner.run(
      "/bin/bash",
      [
        "-c", "exec /usr/bin/python3 \"$1\" > \"$2\" 2>&1", "mono-deck-test-task-cancellation",
        Self.root.appending(path: "script/run_tests.py").path,
        directory.appending(path: "cancellation.log").path,
      ])
  }

  func defaultsExist(_ suite: String) async throws -> Bool {
    try await runner.run("/usr/bin/defaults", ["read", suite]).status == 0
  }

  func remove() {
    if let invocation = try? invocation(),
      let suite = invocation.environment["MONO_DECK_TEST_DEFAULTS"]
    {
      TestEnvironment.removePreferences(named: suite)
    }
    try? FileManager.default.removeItem(at: directory)
  }
}
