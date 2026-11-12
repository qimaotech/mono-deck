import Foundation
import Testing

@testable import MonoDeckCore

struct WorktreeUpdateTests {
  @Test(arguments: ["remote", "absent", "dangling", "malformed", "detached"])
  func groupRootBaseUsesRemoteOrFallsBackOnlyWhenAbsent(_ scenario: String) async throws {
    let fixture = try await Fixture(template: .emptyWorkspace)
    defer { fixture.remove() }
    try await fixture.prepareEmptyGroup("feature")
    let root = fixture.root
    let git = fixture.service.git
    let group = root.appending(path: "worktrees/feature")
    let original = try #require(await git.oid("HEAD", at: group))
    let remote = try await commit(at: root, git: git)
    try Data("shared workspace notes\n".utf8).write(to: root.appending(path: "notes"))
    _ = try await git.run(["add", "notes"], at: root)
    _ = try await git.run(["commit", "-m", "workspace notes"], at: root)
    let local = try #require(await git.oid("HEAD", at: root))
    switch scenario {
    case "remote":
      _ = try await git.run(
        ["config", "remote.origin.url", "git@example.invalid:team/shared-workspace.git"], at: root)
      try await setDefault("trunk", to: remote, at: root, git: git)
    case "dangling":
      _ = try await git.run(
        ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/missing"], at: root)
    case "malformed":
      try FileManager.default.createDirectory(
        at: root.appending(path: ".git/refs/remotes/origin"), withIntermediateDirectories: true)
      try Data("invalid ref\n".utf8).write(
        to: root.appending(path: ".git/refs/remotes/origin/HEAD"))
    case "detached":
      _ = try await git.run(["switch", "--detach"], at: root)
    default: break
    }

    let result = await fixture.service.updateWorktrees(at: root)
    let item = try #require(result.items.first)
    switch scenario {
    case "remote", "absent":
      #expect(item.data?["disposition"] == "updated", "\(item)")
      #expect(item.data?["base"] == (scenario == "remote" ? "origin/trunk" : "main"))
      #expect(try await git.oid("HEAD", at: group) == (scenario == "remote" ? remote : local))
      #expect(PathSafety.exists(group.appending(path: "notes")) == (scenario == "absent"))
      let repeated = await fixture.service.updateWorktrees(at: root)
      #expect(repeated.status == .success && repeated.items.isEmpty)
    default:
      #expect(item.status == .skipped && item.reasonCode == "base-unavailable", "\(item)")
      #expect(try await git.oid("HEAD", at: group) == original)
    }
    #expect(try await git.oid("HEAD", at: root) == local)
  }

  @Test(arguments: [
    "behind", "equal", "ahead", "diverged", "dirty", "staged", "untracked",
    "detached", "operation", "missing-base", "invalid-index",
  ])
  func classifiesMemberAndPreservesOtherCheckouts(_ scenario: String) async throws {
    let fixture = try await Fixture(template: .singleRepository)
    defer { fixture.remove() }
    try await fixture.prepareGroup("feature", repositoryIDs: ["repo"])
    let record = try fixture.service.store.load(fixture.root)
    let git = fixture.service.git
    let main = record.repositoryDirectoryURL("repo")
    let member = record.memberURL("feature", "repo")
    let original = try #require(await git.oid("HEAD", at: main))
    let base =
      ["equal", "ahead"].contains(scenario) ? original : try await commit(at: main, git: git)
    try await setDefault("release/stable", to: base, at: main, git: git)
    if ["ahead", "diverged"].contains(scenario) {
      _ = try await git.run(["commit", "--allow-empty", "-m", "member work"], at: member)
    }
    let before = try #require(await git.oid("HEAD", at: member))
    let gitDirectory = URL(
      fileURLWithPath: try await git.run(["rev-parse", "--absolute-git-dir"], at: member).text)
    switch scenario {
    case "dirty", "staged", "untracked":
      let file = scenario == "untracked" ? "new" : "README"
      try Data("local edit\n".utf8).write(to: member.appending(path: file))
      if scenario == "staged" { _ = try await git.run(["add", file], at: member) }
    case "detached": _ = try await git.run(["switch", "--detach"], at: member)
    case "operation":
      try Data("\(base)\n".utf8).write(to: gitDirectory.appending(path: "MERGE_HEAD"))
    case "missing-base":
      _ = try await git.run(["symbolic-ref", "--delete", "refs/remotes/origin/HEAD"], at: main)
    case "invalid-index":
      try Data("invalid index".utf8).write(to: gitDirectory.appending(path: "index"))
    default: break
    }
    try Data("root edit\n".utf8).write(to: record.groupURL("feature").appending(path: "draft"))
    let trace = fixture.directory.appending(path: "git-trace")
    var traced = git
    traced.runner.environment["GIT_TRACE"] = trace.path
    let service = WorkspaceService(store: fixture.service.store, git: traced)

    let result = await service.updateWorktrees(at: fixture.root)
    let memberResource = Resource.member(groupName: "feature", repositoryID: "repo")
    let omitted = ["equal", "ahead"].contains(scenario)
    #expect(
      result.items.map(\.resource)
        == (omitted ? [.group("feature")] : [.group("feature"), memberResource]))
    #expect(result.items.first?.reasonCode == "working-tree-dirty")
    let item = result.items.first { $0.resource == memberResource }
    switch scenario {
    case "behind":
      #expect(item?.data?["disposition"] == "updated", "\(result.items)")
      #expect(item?.data?["base"] == "origin/release/stable")
      #expect(item?.effects == [.init("fast-forward", PathSafety.canonical(member).path)])
    case "equal", "ahead":
      #expect(result.status == .skipped)
    case "invalid-index":
      #expect(item?.status == .failed && item?.reasonCode == "git-failed", "\(result.items)")
    default:
      let reasons = [
        "diverged": "not-fast-forward", "dirty": "working-tree-dirty",
        "staged": "working-tree-dirty",
        "untracked": "working-tree-dirty", "detached": "detached-head",
        "operation": "git-operation-in-progress",
        "missing-base": "base-unavailable",
      ]
      #expect(item?.status == .skipped && item?.reasonCode == reasons[scenario], "\(result.items)")
      #expect(item?.effects.isEmpty == true)
    }
    #expect(try await git.oid("HEAD", at: member) == (scenario == "behind" ? base : before))
    #expect(try await git.oid("HEAD", at: main) == original)
    if ["dirty", "staged", "untracked"].contains(scenario) {
      let file = member.appending(path: scenario == "untracked" ? "new" : "README")
      #expect(try String(contentsOf: file, encoding: .utf8) == "local edit\n")
    }
    let commands = try String(contentsOf: trace, encoding: .utf8)
    #expect(!commands.contains("git fetch") && !commands.contains("git ls-remote"))
  }

  @Test func limitsConcurrencyAndKeepsCompletedFastForwardsWhenCancelled() async throws {
    let fixture = try await Fixture(template: .singleRepository)
    defer { fixture.remove() }
    let git = fixture.service.git
    var record = try fixture.service.store.load(fixture.root)
    let ids = (0..<7).map { "repo\($0)" }
    for id in ids {
      let repository = Repository(url: "https://mono-deck-test.invalid/\(id).git")
      let path = record.repositoryDirectoryURL(id)
      try FileManager.default.copyItem(at: record.repositoryDirectoryURL("repo"), to: path)
      _ = try await git.run(["config", "remote.origin.url", repository.url], at: path)
      record.repositories.append(repository)
    }
    try fixture.service.store.save(record)
    _ = try await git.ensureIgnore(ids, at: fixture.root)
    try await fixture.commitWorkspace()
    try await fixture.prepareGroup("a", repositoryIDs: ids)
    try await fixture.prepareGroup("b", repositoryIDs: [ids[0]])
    _ = try await git.run(["commit", "--allow-empty", "-m", "workspace update"], at: fixture.root)
    for id in ids {
      let path = record.repositoryDirectoryURL(id)
      let base = try await commit(at: path, git: git)
      try await setDefault("main", to: base, at: path, git: git)
    }
    let gate = try WorktreeUpdateGate(fixture)
    let operation = Task { await gate.service.updateWorktrees(at: fixture.root) }
    do {
      try await gate.waitFor("a_repo4")
      for name in ["a", "a_repo0", "a_repo1", "a_repo2", "a_repo3"] { try await gate.waitFor(name) }
      #expect(try gate.started() == Set(["a"] + ids.prefix(5).map { "a_\($0)" }))
      #expect(throws: MonoDeckError.self) { try fixture.service.store.tryLock(fixture.root) }
      try gate.release("a_repo1")
      try await gate.waitFor("a_repo5")
      #expect(try !gate.started().contains("b_repo0"))
      operation.cancel()
      try gate.releaseAll()
      let result = await operation.value
      let expected: [Resource] =
        [.group("a")] + ids.map { .member(groupName: "a", repositoryID: $0) }
        + [.group("b"), .member(groupName: "b", repositoryID: ids[0])]
      #expect(result.status == .cancelled)
      #expect(result.items.map(\.resource) == expected)
      #expect(
        result.items.prefix(7).allSatisfy {
          $0.data?["disposition"] == "updated" && $0.effects.first?.state == "applied"
        })
      #expect(
        result.items.suffix(3).allSatisfy { $0.reasonCode == "not-processed" && $0.effects.isEmpty }
      )
      #expect(try gate.started().count == 7)
    } catch {
      operation.cancel()
      try? gate.releaseAll()
      let result = await operation.value
      Issue.record("Worktree update results at failure: \(result.items)")
      throw error
    }
  }

  @Test func branchChangedDuringFinalCheckIsSkipped() async throws {
    let fixture = try await Fixture(template: .emptyWorkspace)
    defer { fixture.remove() }
    try await fixture.prepareEmptyGroup("feature")
    let root = fixture.root
    let git = fixture.service.git
    let group = root.appending(path: "worktrees/feature")
    let original = try #require(await git.oid("HEAD", at: group))
    _ = try await git.run(["branch", "replacement", original], at: root)
    _ = try await git.run(["commit", "--allow-empty", "-m", "workspace update"], at: root)
    let first = fixture.directory.appending(path: "first-status")
    let gate = try WorktreeUpdateGate(
      fixture,
      fsmonitorPreamble: """
        if [ ! -e "\(first.path)" ]; then
            : > "\(first.path)"
            printf 'first\\000/\\000'
            exit 0
        fi
        """)
    let operation = Task { await gate.service.updateWorktrees(at: root) }
    do {
      try await gate.waitFor("feature")
      _ = try await git.run(["symbolic-ref", "HEAD", "refs/heads/replacement"], at: group)
      try gate.release("feature")
      let result = await operation.value
      #expect(result.items.first?.reasonCode == "worktree-changed", "\(result.items)")
      #expect(result.items.first?.effects.isEmpty == true)
      #expect(try await git.oid("HEAD", at: group) == original)
      #expect(try await git.oid("refs/heads/feature", at: group) == original)
    } catch {
      operation.cancel()
      try? gate.releaseAll()
      _ = await operation.value
      throw error
    }
  }

  @Test(arguments: ["reserved-member-path", "ignored-file"])
  func preservesFilesWhenBaseWouldOverwriteThem(_ scenario: String) async throws {
    let fixture = try await Fixture(template: .singleRepository)
    defer { fixture.remove() }
    try await fixture.prepareGroup("feature", repositoryIDs: ["repo"])
    let record = try fixture.service.store.load(fixture.root)
    let git = fixture.service.git
    let main = record.repositoryDirectoryURL("repo")
    let member = record.memberURL("feature", "repo")
    let group = record.groupURL("feature")
    let isRoot = scenario == "reserved-member-path"
    let target = isRoot ? group : member
    let baseCheckout = isRoot ? fixture.root : main
    let path = isRoot ? "repo/README" : "local.txt"
    let original = try #require(await git.oid("HEAD", at: target))
    if isRoot {
      try FileManager.default.createDirectory(
        at: baseCheckout.appending(path: "repo"), withIntermediateDirectories: false)
    } else {
      let exclude = main.appending(path: ".git/info/exclude")
      try Data("/local.txt\n".utf8).write(to: exclude)
      try Data("keep local\n".utf8).write(to: member.appending(path: path))
    }
    let localFile = target.appending(path: path)
    let localData = try Data(contentsOf: localFile)
    try Data("base content\n".utf8).write(to: baseCheckout.appending(path: path))
    _ = try await git.run(["add", "--force", "--", path], at: baseCheckout)
    _ = try await git.run(["commit", "-m", "add file in base"], at: baseCheckout)
    if !isRoot {
      let base = try #require(await git.oid("HEAD", at: main))
      try await setDefault("main", to: base, at: main, git: git)
    }

    let result = await fixture.service.updateWorktrees(at: fixture.root)
    let item = try #require(isRoot ? result.items.first : result.items.last)
    #expect(
      item.status == .failed && item.reasonCode == (isRoot ? "path-conflict" : "git-failed"),
      "\(item)")
    #expect(try await git.oid("HEAD", at: target) == original)
    #expect(try Data(contentsOf: localFile) == localData)
  }

  private func commit(at path: URL, git: Git) async throws -> String {
    try await git.run(
      ["commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "remote update"], at: path
    ).text
  }

  private func setDefault(_ branch: String, to oid: String, at path: URL, git: Git) async throws {
    let ref = "refs/remotes/origin/\(branch)"
    _ = try await git.run(["update-ref", ref, oid], at: path)
    _ = try await git.run(["symbolic-ref", "refs/remotes/origin/HEAD", ref], at: path)
  }
}

private struct WorktreeUpdateGate {
  let service: WorkspaceService
  private let directory: URL

  init(_ fixture: Fixture, fsmonitorPreamble: String? = nil) throws {
    directory = fixture.directory.appending(path: "update-gate")
    for name in ["started", "released"] {
      try FileManager.default.createDirectory(
        at: directory.appending(path: name), withIntermediateDirectories: true)
    }
    let hook = directory.appending(path: fsmonitorPreamble == nil ? "post-merge" : "fsmonitor")
    try Data(
      """
      #!/bin/sh
      \(fsmonitorPreamble ?? "")
      target=$(printf '%s' "${PWD#*/worktrees/}" | tr '/' '_')
      : > "\(directory.path)/started/$target"
      trap 'exit 143' TERM INT
      while [ ! -e "\(directory.path)/released/$target" ] && [ ! -e "\(directory.path)/released-all" ]; do
          sleep 0.02
      done
      \(fsmonitorPreamble == nil ? "" : "printf 'checked\\000/\\000'")
      """.utf8
    ).write(to: hook)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    var git = fixture.service.git
    git.runner.environment["GIT_CONFIG_COUNT"] = fsmonitorPreamble == nil ? "1" : "2"
    git.runner.environment["GIT_CONFIG_KEY_0"] =
      fsmonitorPreamble == nil ? "core.hooksPath" : "core.fsmonitor"
    git.runner.environment["GIT_CONFIG_VALUE_0"] =
      fsmonitorPreamble == nil ? directory.path : hook.path
    git.runner.environment["GIT_CONFIG_KEY_1"] = "core.fsmonitorHookVersion"
    git.runner.environment["GIT_CONFIG_VALUE_1"] = "2"
    service = WorkspaceService(store: fixture.service.store, git: git)
  }

  func started() throws -> Set<String> {
    Set(
      try FileManager.default.contentsOfDirectory(atPath: directory.appending(path: "started").path)
    )
  }

  func waitFor(_ target: String) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
      if try started().contains(target) { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    throw MonoDeckError("test-timeout", "Waiting for \(target), started \(try started()).")
  }

  func release(_ target: String) throws {
    try Data().write(to: directory.appending(path: "released/\(target)"))
  }

  func releaseAll() throws { try Data().write(to: directory.appending(path: "released-all")) }
}
