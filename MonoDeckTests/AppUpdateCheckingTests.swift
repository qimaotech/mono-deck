import Foundation
import Testing

@testable import MonoDeck
@testable import MonoDeckCore

@MainActor struct AppUpdateCheckingTests {
  @Test func automaticChecksPersistTheirPreferenceAndManualChecksRemainAvailable() async throws {
    let fixture = try AppUpdateFixture()
    defer { fixture.remove() }
    let preferences = try fixture.preferences()
    let session = checkSession()
    defer { session.invalidateAndCancel() }
    let model = AppUpdateModel(preferences: preferences, service: .init(session: session))
    #expect(model.automaticallyChecksForUpdates)

    model.automaticallyChecksForUpdates = false
    #expect(try !fixture.preferences().automaticallyChecksForUpdates)
    model.checkAutomatically()
    #expect(!model.checking)

    model.check()
    try #require(model.checking)
    try await waitUntil { !model.checking }
    #expect(model.update?.version == "99.0.0" && !model.automaticUpdatePending)
    #expect(try fixture.preferences().lastUpdateCheck != nil)
    model.check()
    try #require(model.checking)
    try await waitUntil { !model.checking }
    #expect(model.error == nil && !model.automaticUpdatePending)
  }

  @Test func automaticDiscoveryOnlyOffersAnUpdateAndThrottlesAcrossLaunches() async throws {
    let fixture = try AppUpdateFixture()
    defer { fixture.remove() }
    let session = checkSession()
    defer { session.invalidateAndCancel() }
    let model = AppUpdateModel(
      preferences: try fixture.preferences(), service: .init(session: session))
    let now = Date()
    model.checkAutomatically(now: now)
    try #require(model.checking)
    try await waitUntil { !model.checking }
    #expect(model.automaticUpdatePending && model.phase == .available)
    #expect(
      model.update?.releaseURL.absoluteString
        == "https://github.com/qimaotech/mono-deck/releases/tag/v99.0.0")
    #expect(model.installerURL == nil && !model.downloading && !model.restartPending)
    model.windowOpened()
    #expect(!model.automaticUpdatePending)
    model.windowClosed()

    let relaunched = AppUpdateModel(
      preferences: try fixture.preferences(), service: .init(session: session))
    relaunched.checkAutomatically(now: now.addingTimeInterval(60 * 60))
    #expect(!relaunched.checking)
    relaunched.windowOpened()
    relaunched.checkAutomatically(now: now.addingTimeInterval(24 * 60 * 60))
    #expect(!relaunched.checking)
    relaunched.windowClosed()
    relaunched.checkAutomatically(now: now.addingTimeInterval(24 * 60 * 60))
    try #require(relaunched.checking)
    try await waitUntil { !relaunched.checking }
    #expect(relaunched.automaticUpdatePending)
  }

  @Test(arguments: ["current", "failure"])
  func automaticChecksStaySilentWithoutAnUpgradeAndDoNotImmediatelyRetry(_ response: String)
    async throws
  {
    let fixture = try AppUpdateFixture()
    defer { fixture.remove() }
    let session = checkSession(response: response)
    defer { session.invalidateAndCancel() }
    let model = AppUpdateModel(
      preferences: try fixture.preferences(), service: .init(session: session))
    let now = Date()
    model.checkAutomatically(now: now)
    try #require(model.checking)
    try await waitUntil { !model.checking }
    #expect(model.update == nil && model.error == nil && !model.automaticUpdatePending)
    model.checkAutomatically(now: now.addingTimeInterval(60))
    #expect(!model.checking)
    if response == "failure" {
      model.check()
      try await waitUntil { !model.checking }
      #expect(model.error != nil)
    }
  }

  @Test(arguments: [false, true])
  func cancellingOrTakingOverABackgroundCheckDoesNotPublishItsResult(_ manual: Bool) async throws {
    let fixture = try AppUpdateFixture()
    defer { fixture.remove() }
    let session = checkSession()
    defer { session.invalidateAndCancel() }
    let model = AppUpdateModel(
      preferences: try fixture.preferences(), service: .init(session: session))
    model.checkAutomatically()
    try #require(model.checking)
    if manual {
      model.check()
      try #require(model.checking)
      try await waitUntil { !model.checking }
      #expect(model.update != nil && !model.automaticUpdatePending)
    } else {
      model.automaticallyChecksForUpdates = false
      #expect(!model.checking)
    }
    #expect(await model.prepareToTerminate())
    #expect(
      !model.automaticUpdatePending && model.error == nil && !model.needsTerminationPreparation)
    if !manual { #expect(model.update == nil) }
  }

  @Test func releasesWithoutAManifestFallBackToTheAPI() async throws {
    let session = checkSession(response: "legacy")
    defer { session.invalidateAndCancel() }
    let update = try await AppUpdateService(session: session).check(currentVersion: "1.0.0")
    #expect(update?.version == "99.0.0")
  }

  @Test(arguments: ["forbidden", "failure", "legacy-failure"])
  func failedRequestsPreserveHTTPErrors(_ response: String) async throws {
    let session = checkSession(response: response)
    defer { session.invalidateAndCancel() }
    do {
      _ = try await AppUpdateService(session: session).check(currentVersion: "1.0.0")
      Issue.record("Failed update request succeeded")
    } catch let error as MonoDeckError {
      #expect(error.code == "update-request-failed")
      #expect(
        error.userMessage
          == .githubRequestFailedHTTPPleaseTryAgainLater(
            response == "forbidden" ? 403 : 503))
    }
  }

  @Test func invalidManifestDoesNotFallBackToTheAPI() async throws {
    let session = checkSession(response: "invalid")
    defer { session.invalidateAndCancel() }
    await #expect(throws: DecodingError.self) {
      _ = try await AppUpdateService(session: session).check(currentVersion: "1.0.0")
    }
  }

  private func checkSession(response: String = "upgrade") -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [UpdateCheckProtocol.self]
    configuration.httpAdditionalHeaders = ["X-MonoDeck-Test-Response": response]
    return URLSession(configuration: configuration)
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(condition())
  }
}

private final class UpdateCheckProtocol: URLProtocol, @unchecked Sendable {
  private let queue = DispatchQueue(label: "MonoDeckTests.UpdateCheck")
  private var completion: DispatchWorkItem?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    queue.async { [self] in
      let completion = DispatchWorkItem { [self] in
        guard let url = request.url else { return }
        let mode = request.value(forHTTPHeaderField: "X-MonoDeck-Test-Response")
        let legacy = ["legacy", "legacy-failure"].contains(mode)
        let api = url.host == "api.github.com"
        #expect(
          url.absoluteString
            == (api
              ? "https://api.github.com/repos/qimaotech/mono-deck/releases/latest"
              : "https://github.com/qimaotech/mono-deck/releases/latest/download/MonoDeck-update.json")
        )
        #expect(!api || legacy, "Only a missing manifest should use the API")
        #expect(
          request.value(forHTTPHeaderField: "Accept")
            == (api ? "application/vnd.github+json" : "application/json"))
        let status: Int
        if !api && legacy {
          status = 404
        } else if mode == "forbidden" {
          status = 403
        } else {
          status = mode == "failure" || mode == "legacy-failure" ? 503 : 200
        }
        let version = mode == "current" ? MonoDeckVersion.current : "99.0.0"
        let response = HTTPURLResponse(
          url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        let data =
          mode == "invalid"
          ? Data("invalid".utf8)
          : Data(
            """
            {"tag_name":"v\(version)","draft":false,"prerelease":false,
             "html_url":"https://github.com/qimaotech/mono-deck/releases/tag/v\(version)",
             "assets":[{"name":"MonoDeck-\(version)-arm64.dmg","size":3,
             "browser_download_url":"https://github.com/qimaotech/mono-deck/releases/download/v\(version)/MonoDeck-\(version)-arm64.dmg"}]}
            """.utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
      }
      self.completion = completion
      queue.asyncAfter(deadline: .now() + 0.05, execute: completion)
    }
  }

  override func stopLoading() {
    queue.async { [self] in
      completion?.cancel()
      completion = nil
    }
  }
}
