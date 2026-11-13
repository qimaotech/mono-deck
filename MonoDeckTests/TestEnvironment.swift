import Darwin
import Foundation
import Testing

enum TestEnvironment {
  static var temporaryDirectory: URL {
    // Xcode may override TMPDIR after launching the hosted test process.
    if let session = ProcessInfo.processInfo.environment["MONO_DECK_TEST_SESSION_DIRECTORY"] {
      return URL(fileURLWithPath: session).appending(path: "tmp", directoryHint: .isDirectory)
    }
    return FileManager.default.temporaryDirectory
  }

  static func removePreferences(named suite: String) {
    let prefixes = [
      "mono-deck-tests-", "mono-deck-fixture-template-", "mono-deck update tests ",
      "mono-deck-presentation-", "MonoDeckTests.SplitView.", "WorkspaceActionTests.",
      "MonoDeckLoadingTests.", "MonoDeckTests.", "MonoDeckMock.",
    ]
    guard
      prefixes.contains(where: { prefix in
        guard suite.hasPrefix(prefix) else { return false }
        let suffix = String(suite.dropFirst(prefix.count))
        return suffix.count == 36 && UUID(uuidString: suffix) != nil
      })
    else {
      Issue.record("Refusing to remove preferences outside a unique test suite: \(suite)")
      return
    }
    let preferences = FileManager.default.homeDirectoryForCurrentUser.appending(
      path: "Library/Preferences/\(suite).plist")
    guard let defaults = UserDefaults(suiteName: suite) else {
      Issue.record("Could not open test preferences: \(suite)")
      return
    }
    guard
      defaults.persistentDomain(forName: suite) != nil
        || FileManager.default.fileExists(atPath: preferences.path)
    else { return }
    defaults.removePersistentDomain(forName: suite)
    guard defaults.synchronize() else {
      Issue.record("Could not synchronize test preferences before cleanup: \(suite)")
      return
    }
    do {
      if try defaultsOutput(["delete", suite]).status != 0 {
        let remaining = try defaultsOutput(["read", suite])
        if remaining.status == 0 {
          let domain =
            try PropertyListSerialization.propertyList(
              from: remaining.data, options: [], format: nil) as? [String: Any]
          guard domain?.isEmpty == true else {
            Issue.record("Could not delete test preferences: \(suite)")
            return
          }
        }
      }
      // macOS 27 can retain an empty plist after the preferences daemon deletes a domain.
      let deadline = ContinuousClock.now.advanced(by: .seconds(2))
      while FileManager.default.fileExists(atPath: preferences.path) {
        let values = try preferences.resourceValues(forKeys: [
          .isRegularFileKey, .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
          Issue.record("Keeping unexpected test preferences file: \(preferences.path)")
          return
        }
        let contents = try PropertyListSerialization.propertyList(
          from: Data(contentsOf: preferences), options: [], format: nil)
        guard let domain = contents as? [String: Any] else {
          Issue.record("Keeping unrecognized test preferences: \(preferences.path)")
          return
        }
        if domain.isEmpty {
          try FileManager.default.removeItem(at: preferences)
          return
        }
        guard ContinuousClock.now < deadline else {
          Issue.record("Keeping nonempty test preferences after deletion: \(preferences.path)")
          return
        }
        Thread.sleep(forTimeInterval: 0.01)
      }
    } catch {
      let failure = error as NSError
      let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError
      if failure.domain == NSCocoaErrorDomain
        && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code)
        || failure.domain == NSPOSIXErrorDomain && failure.code == Int(ENOENT)
        || underlying?.domain == NSPOSIXErrorDomain && underlying?.code == Int(ENOENT)
      {
        return
      }
      Issue.record("Could not clean test preferences \(suite): \(error)")
    }
  }

  private static func defaultsOutput(_ arguments: [String]) throws -> (status: Int32, data: Data) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    try process.run()
    try output.fileHandleForWriting.close()
    guard exited.wait(timeout: .now() + 5) == .success else {
      process.terminate()
      if exited.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
        kill(process.processIdentifier, SIGKILL)
        _ = exited.wait(timeout: .now() + 1)
      }
      throw PreferencesCleanupFailure.defaultsTimedOut
    }
    return (process.terminationStatus, output.fileHandleForReading.readDataToEndOfFile())
  }

  private enum PreferencesCleanupFailure: Error {
    case defaultsTimedOut
  }
}
