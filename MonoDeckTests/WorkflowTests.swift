import Darwin
import Foundation
import Synchronization
import Testing

@testable import MonoDeckCore

struct WorkflowTests {
  @Test func deletionPreviewKeepsSixChecksRunningAndPreservesOrderAndRisks() async throws {
    let f = try await Fixture(template: .singleRepository)
    defer { f.remove() }
    var record = try f.service.store.load(f.root)
    let others = (1...6).map { Repository(url: "https://mono-deck-test.invalid/other\($0).git") }
    for other in others {
      try FileManager.default.copyItem(
        at: record.repositoryDirectoryURL("repo"), to: record.repositoryDirectoryURL(other.id))
      _ = try await f.service.git.run(
        ["config", "remote.origin.url", other.url], at: record.repositoryDirectoryURL(other.id))
      record.repositories.append(other)
    }
    try f.service.store.save(record)
    _ = try await f.service.git.ensureIgnore(others.map(\.id), at: f.root)
    try await f.commitWorkspace()
    let members = ["repo"] + others.map(\.id)
    try await f.prepareGroup("feature", repositoryIDs: members)
    record = try f.service.store.load(f.root)
    let member = record.memberURL("feature", "repo")
    try Data("/ignored/\n/ignored.txt\n".utf8).write(
      to: record.repositoryDirectoryURL("repo").appending(path: ".git/info/exclude"))
    let ignored = member.appending(path: "ignored/nested")
    try FileManager.default.createDirectory(at: ignored, withIntermediateDirectories: true)
    try Data("ignored".utf8).write(to: ignored.appending(path: "file.txt"))
    try Data("ignored".utf8).write(to: member.appending(path: "ignored.txt"))
    try Data("changed".utf8).write(
      to: record.memberURL("feature", "other1").appending(path: "README"))

    let probe = f.directory.appending(path: "delete-probe")
    try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false)
    let monitor = probe.appending(path: "fsmonitor")
    try Data(
      """
      #!/bin/sh
      member=$(basename "$PWD")
      : > "$MONO_DECK_DELETE_PROBE/$member"
      trap 'exit 143' TERM INT
      while [ ! -e "$MONO_DECK_DELETE_PROBE/release" ] && [ ! -e "$MONO_DECK_DELETE_PROBE/release-$member" ]; do sleep 0.02; done
      printf 'test-token\\000/\\000'
      """.utf8
    ).write(to: monitor)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: monitor.path)
    for repo in members {
      for arguments in [
        ["config", "core.fsmonitor", monitor.path], ["config", "core.fsmonitorHookVersion", "2"],
      ] {
        _ = try await f.service.git.run(arguments, at: record.repositoryDirectoryURL(repo))
      }
    }
    var runner = f.service.git.runner
    runner.environment["MONO_DECK_DELETE_PROBE"] = probe.path
    let service = WorkspaceService(store: f.service.store, git: Git(runner: runner))
    let preview = Task { try await service.previewDelete(.group("feature"), at: f.root) }
    do {
      let deadline = ContinuousClock.now.advanced(by: .seconds(10))
      while !members.prefix(6).allSatisfy({ PathSafety.exists(probe.appending(path: $0)) }),
        ContinuousClock.now < deadline
      {
        try await Task.sleep(for: .milliseconds(20))
      }
      try #require(members.prefix(6).allSatisfy { PathSafety.exists(probe.appending(path: $0)) })
      #expect(!PathSafety.exists(probe.appending(path: "other6")))
      try Data().write(to: probe.appending(path: "release-other1"))
      let nextDeadline = ContinuousClock.now.advanced(by: .seconds(10))
      while !PathSafety.exists(probe.appending(path: "other6")), ContinuousClock.now < nextDeadline
      {
        try await Task.sleep(for: .milliseconds(20))
      }
      try #require(PathSafety.exists(probe.appending(path: "other6")))
      try Data().write(to: probe.appending(path: "release"))
      let targets = try await preview.value
      try #require(
        targets.map(\.resource) == members.map {
          Resource.member(groupName: "feature", repositoryID: $0)
        } + [.group("feature")])
      #expect(targets.allSatisfy { $0.branch == "feature" && $0.exists && $0.gitRegistered })
      #expect(targets[0].risks.contains("Working tree is clean."))
      #expect(!targets[0].risks.contains("Ignored files will be permanently deleted."))
      #expect(targets[1].risks.contains("1 changed paths will be permanently deleted."))
      #expect(!targets.last!.risks.contains { $0.contains("commits are not reachable") })
    } catch {
      try? Data().write(to: probe.appending(path: "release"))
      preview.cancel()
      _ = try? await preview.value
      throw error
    }
  }
  @Test func actualBranchDeletionAndConfirmationChange() async throws {
    let f = try await Fixture(template: .singleRepository)
    defer { f.remove() }
    try await f.prepareGroup("feature", branchName: "feature/task", repositoryIDs: ["repo"])
    let member = f.root.appending(path: "worktrees/feature/repo")
    let old = try await f.service.previewDelete(
      .member(groupName: "feature", repositoryID: "repo"), at: f.root)
    _ = try await f.service.git.run(["switch", "-c", "external/task"], at: member)
    let changed = await f.service.delete(
      .member(groupName: "feature", repositoryID: "repo"), at: f.root, authorization: old)
    #expect(changed.reasonCode == "confirmation-changed")
    #expect(PathSafety.exists(member))
    let deleted = await f.service.deleteConfirmed(
      .member(groupName: "feature", repositoryID: "repo"), at: f.root)
    #expect(deleted.status == .success)
    let main = f.root.appending(path: "repositories/repo")
    #expect(try await f.service.git.oid("refs/heads/feature/task", at: main) != nil)
    #expect(try await f.service.git.oid("refs/heads/external/task", at: main) == nil)

    let record = try f.service.store.load(f.root)
    let changedEdit = await f.service.editGroup(
      "feature", repositoryIDs: ["repo"], at: f.root, authorization: old)
    #expect(changedEdit.reasonCode == "confirmation-changed" && changedEdit.items.isEmpty)
    #expect(try f.service.store.load(f.root) == record)
    #expect(!PathSafety.exists(member))
  }
  @Test func detachedAndMissingWorktrees() async throws {
    let f = try await Fixture(template: .singleRepository)
    defer { f.remove() }
    try await f.prepareGroup("feature", repositoryIDs: ["repo"])
    let member = f.root.appending(path: "worktrees/feature/repo")
    _ = try await f.service.git.run(["checkout", "--detach"], at: member)
    let preview = try await f.service.previewDelete(
      .member(groupName: "feature", repositoryID: "repo"), at: f.root)
    let target = try #require(preview.first)
    #expect(target.detached)
    #expect(target.branch == nil)
    #expect(
      await f.service.deleteConfirmed(
        .member(groupName: "feature", repositoryID: "repo"), at: f.root
      ).status == .success)
    #expect(
      try await f.service.git.oid(
        "refs/heads/feature", at: f.root.appending(path: "repositories/repo")) != nil)
    #expect(
      await f.service.addGroupMembers("feature", repositoryIDs: ["repo"], at: f.root).status
        == .success)
    try FileManager.default.removeItem(at: member)
    let missing = await f.service.deleteConfirmed(
      .member(groupName: "feature", repositoryID: "repo"), at: f.root)
    #expect(missing.status == .success, "\(missing.message ?? "") \(missing.items)")
  }
  @Test func deletionPreviewSupportsWorkspacePathsContainingNewlines() async throws {
    let f = try await Fixture(template: .singleRepository)
    defer { f.remove() }
    let root = f.directory.appending(path: "workspace\nwith spaces")
    try FileManager.default.copyItem(at: f.root, to: root)
    var record = try f.service.store.load(f.root)
    record.root = PathSafety.canonical(root).path
    try f.service.store.save(record)
    try #require(
      await f.service.createGroup("feature", repositoryIDs: ["repo"], at: root).status == .success)

    let targets = try await f.service.previewDelete(.group("feature"), at: root)

    #expect(
      targets.map(\.resource) == [
        .member(groupName: "feature", repositoryID: "repo"), .group("feature"),
      ])
    #expect(targets.allSatisfy { $0.branch == "feature" && $0.exists && $0.gitRegistered })
    #expect(
      PathSafety.exists(record.memberURL("feature", "repo"))
        && PathSafety.exists(record.groupURL("feature")))
  }
  @Test func creationFailureRetainsSavedRootAndCleansNewBranch() async throws {
    let f = try await Fixture(template: .singleRepository)
    defer { f.remove() }
    let failingStore = WorkspaceStore(support: f.service.store.support) { data, url in
      let record = try JSONDecoder().decode(WorkspaceRecord.self, from: data)
      if record.groups["feature"]?.repositoryIDs.isEmpty == false {
        throw MonoDeckError("fixture-write-failed", "Injected member save failure")
      }
      try data.write(to: url, options: .atomic)
    }
    let service = WorkspaceService(store: failingStore, git: f.service.git)
    let result = await service.createGroup("feature", repositoryIDs: ["repo"], at: f.root)
    #expect(result.status == .partialSuccess)
    let record = try f.service.store.load(f.root)
    #expect(record.groups["feature"]?.repositoryIDs == [])
    #expect(PathSafety.exists(record.groupURL("feature")))
    #expect(!PathSafety.exists(record.memberURL("feature", "repo")))
    #expect(
      try await f.service.git.oid("refs/heads/feature", at: record.repositoryDirectoryURL("repo"))
        == nil)
  }
  @Test func uncertainSaveKeepsResourcesAndRecordsEffects() async throws {
    let f = try await Fixture(template: .singleRepository)
    defer { f.remove() }
    let failing = WorkspaceStore(support: f.service.store.support) { data, url in
      let record = try JSONDecoder().decode(WorkspaceRecord.self, from: data)
      if record.groups["feature"] != nil {
        try Data("invalid".utf8).write(to: url)
        throw MonoDeckError("fixture-failure", "Injected uncertain save")
      }
      try data.write(to: url)
    }
    let result = await WorkspaceService(store: failing, git: f.service.git).createGroup(
      "feature", repositoryIDs: ["repo"], at: f.root)
    #expect(result.items.first?.reasonCode == "save-outcome-unknown")
    #expect(result.items.last?.resource == .member(groupName: "feature", repositoryID: "repo"))
    #expect(result.items.last?.reasonCode == "not-processed")
    #expect(PathSafety.exists(f.root.appending(path: "worktrees/feature")))
  }
  @Test func yamlRoundTripFromClonedWorkspaceUsesPublishedTaskBranches() async throws {
    let f = try await Fixture(template: .singleRepository)
    defer { f.remove() }
    try await f.prepareGroup("feature", branchName: "feature/task", repositoryIDs: ["repo"])
    try await f.prepareEmptyGroup("empty", branchName: "feature/empty")
    var original = try f.service.store.load(f.root)
    original.groups["feature"]?.createdAt = "2026-01-01T00:00:00Z"
    original.repositories[0].displayNameOverride = "Shared name"
    try f.service.store.save(original)
    let group = original.groupURL("feature")
    let member = original.memberURL("feature", "repo")
    _ = try await f.service.git.run(["commit", "--allow-empty", "-m", "group task"], at: group)
    _ = try await f.service.git.run(["commit", "--allow-empty", "-m", "member task"], at: member)
    _ = try await f.service.git.run(["push", f.remoteURL, "refs/heads/feature/task"], at: member)
    let export = f.directory.appending(path: "mono-deck.yaml")
    try await f.service.exportYAML(at: f.root, to: export)
    let yaml = try String(contentsOf: export, encoding: .utf8)
    #expect(!yaml.contains("root:") && !yaml.contains("created-at:"))
    #expect(yaml.contains("branch-name: feature/task"))
    let second = f.directory.appending(path: "second")
    _ = try await f.service.git.run(["clone", f.root.path, second.path], at: f.directory)
    try #require(await f.service.openWorkspace(second).status == .success)
    _ = try await f.service.git.run(
      ["commit", "--allow-empty", "-m", "local workspace change"], at: second)
    let before = try Data(contentsOf: f.service.store.recordURL(second))
    let oldVersion = await f.service.importWorkspaceYAML(
      "version: 1\nrepositories: []\ngroups: {}", at: second)
    #expect(oldVersion.reasonCode == "invalid-workspace-configuration" && oldVersion.items.isEmpty)
    #expect(try Data(contentsOf: f.service.store.recordURL(second)) == before)
    for replacement in ["", "branch-name: ''", "branch-name: feature//task"] {
      let invalid = yaml.replacingOccurrences(of: "branch-name: feature/task", with: replacement)
      let rejected = await f.service.importWorkspaceYAML(invalid, at: second)
      #expect(rejected.status == .failed && rejected.items.isEmpty)
      #expect(try Data(contentsOf: f.service.store.recordURL(second)) == before)
      #expect(!PathSafety.exists(second.appending(path: "repositories/repo")))
    }
    let imported = await f.service.importWorkspaceYAML(yaml, at: second)
    #expect(imported.status == .success, "\(imported.message ?? "") \(imported.items)")
    let restored = try await f.service.load(second)
    #expect(restored.repositories == original.repositories)
    #expect(restored.groups["feature"]?.repositoryIDs == ["repo"])
    #expect(restored.groups["feature"]?.branchName == "feature/task")
    #expect(restored.groups["feature"]?.createdAt != original.groups["feature"]?.createdAt)
    #expect(restored.groups["empty"]?.repositoryIDs == [])
    #expect(restored.groups["empty"]?.branchName == "feature/empty")
    for (path, branch) in [
      (restored.groupURL("feature"), "feature/task"),
      (restored.memberURL("feature", "repo"), "feature/task"),
      (restored.groupURL("empty"), "feature/empty"),
    ] {
      #expect(
        try await f.service.git.run(["symbolic-ref", "HEAD"], at: path).text
          == "refs/heads/\(branch)")
    }
    #expect(
      try await f.service.git.oid("HEAD", at: restored.groupURL("feature"))
        == f.service.git.oid("HEAD", at: group))
    #expect(
      try await f.service.git.oid("HEAD", at: restored.memberURL("feature", "repo"))
        == f.service.git.oid("HEAD", at: member))
  }

  @Test(arguments: [false, true])
  func workspaceYAMLRejectsMismatchedOrDetachedBranchWhenOriginHEADIsKnown(_ detached: Bool)
    async throws
  {
    let f = try await Fixture()
    defer { f.remove() }
    try await f.prepareWorkspace()
    let git = f.service.git
    let before = try f.service.store.load(f.root)
    let ignore = f.root.appending(path: ".gitignore")
    let originalIgnore = try Data(contentsOf: ignore)
    let head = try #require(await git.oid("HEAD", at: f.root))
    _ = try await git.run(["update-ref", "refs/remotes/origin/main", head], at: f.root)
    _ = try await git.run(
      ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"], at: f.root)
    _ = try await git.run(
      detached ? ["switch", "--detach"] : ["switch", "-c", "feature/other"], at: f.root)
    let yaml = """
      version: 2
      repositories: [{url: \(f.remoteURL)}]
      groups: {feature: {branch-name: feature/task, repository-ids: [repo]}}
      """

    let trace = f.directory.appending(path: "import-trace")
    var runner = git.runner
    runner.environment["GIT_TRACE"] = trace.path
    let service = WorkspaceService(
      store: f.service.store, git: Git(runner: runner), trash: f.service.trashDirectory)
    let result = await service.importWorkspaceYAML(yaml, at: f.root)

    #expect(
      result.status == .failed && result.reasonCode == "workspace-branch-mismatch", "\(result)")
    #expect(try f.service.store.load(f.root) == before)
    #expect(!PathSafety.exists(before.repositoryDirectoryURL("repo")))
    #expect(!PathSafety.exists(before.groupURL("feature")))
    #expect(try await git.oid("HEAD", at: f.root) == head)
    #expect(try Data(contentsOf: ignore) == originalIgnore)
    let commands = try String(contentsOf: trace, encoding: .utf8)
    #expect(
      !commands.contains("built-in: git ls-remote ") && !commands.contains("built-in: git clone "))
  }

  @Test(arguments: ["local", "remote", "missing"])
  func workspaceYAMLRequiresWorkspaceHEADOnlyForRootFallback(_ source: String) async throws {
    let f = try await Fixture(template: .singleRepository)
    defer { f.remove() }
    let git = f.service.git
    let before = try f.service.store.load(f.root)
    let start = try #require(await git.oid("HEAD", at: f.root))
    switch source {
    case "local":
      _ = try await git.run(["update-ref", "refs/heads/feature/task", start], at: f.root)
    case "remote":
      _ = try await git.run(["update-ref", "refs/remotes/origin/feature/task", start], at: f.root)
      _ = try await git.run(
        ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/missing"], at: f.root)
    default:
      _ = try await git.run(["update-ref", "refs/remotes/origin/unborn", start], at: f.root)
      _ = try await git.run(
        ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/unborn"], at: f.root)
    }
    _ = try await git.run(["switch", "--orphan", "unborn"], at: f.root)
    try #require(try await git.oid("HEAD", at: f.root) == nil)
    let yaml = """
      version: 2
      repositories: [{url: \(f.remoteURL)}]
      groups: {feature: {branch-name: feature/task, repository-ids: [repo]}}
      """

    let result = await f.service.importWorkspaceYAML(yaml, at: f.root)

    if source == "missing" {
      #expect(result.status == .failed)
      #expect(
        result.items.first { $0.resource == .group("feature") }?.reasonCode
          == "workspace-commit-required", "\(result.items)")
      #expect(try f.service.store.load(f.root) == before)
      #expect(!PathSafety.exists(before.groupURL("feature")))
    } else {
      #expect(result.status == .success, "\(result.items)")
      #expect(try f.service.store.load(f.root).groups["feature"]?.repositoryIDs == ["repo"])
      #expect(try await git.oid("HEAD", at: before.groupURL("feature")) == start)
    }
    #expect(try await git.oid("HEAD", at: f.root) == nil)
  }

  @Test(arguments: [false, true])
  func workspaceYAMLAppendsMissingItemsAndRepeatLeavesLocalStateAlone(_ stageIgnore: Bool)
    async throws
  {
    let f = try await Fixture(template: .singleRepository)
    defer { f.remove() }
    try await f.prepareGroup("existing", branchName: "local/task", repositoryIDs: ["repo"])
    var before = try f.service.store.load(f.root)
    before.repositories[0].displayNameOverride = "Local name"
    try f.service.store.save(before)
    let other = "https://mono-deck-test.invalid/other.git"
    let remote = f.directory.appending(path: "repo.git")
    _ = try await f.service.git.run(
      ["config", "--global", "--add", "url.\(remote.path).insteadOf", other], at: f.root)
    let yaml = """
      version: 2
      repositories:
        - url: \(f.remoteURL)
          display-name: Imported name
        - url: \(other)
      groups:
        existing:
          branch-name: imported/task
          repository-ids: [other]
        new:
          branch-name: new
          repository-ids: [repo, other]
      """
    let imported = await f.service.importWorkspaceYAML(yaml, at: f.root)
    #expect(imported.status == .success, "\(imported.items)")
    #expect(imported.items.first { $0.resource == .repository("repo") }?.status == .skipped)
    #expect(imported.items.first { $0.resource == .group("existing") }?.status == .skipped)
    #expect(
      !imported.items.contains {
        $0.resource.kind == .member && $0.resource.groupName == "existing"
      })
    let saved = try f.service.store.load(f.root)
    #expect(saved.repositories == before.repositories + [Repository(url: other)])
    #expect(saved.groups["existing"] == before.groups["existing"])
    #expect(saved.groups["new"]?.repositoryIDs == ["repo", "other"])
    #expect(!PathSafety.exists(saved.memberURL("existing", "other")))
    #expect(try await f.service.git.oid("refs/heads/imported/task", at: f.root) == nil)

    let ignore = f.root.appending(path: ".gitignore")
    let editedIgnore = try Data(contentsOf: ignore) + Data("# private edits\n".utf8)
    if stageIgnore {
      try editedIgnore.write(to: ignore)
      _ = try await f.service.git.run(["add", "--", ".gitignore"], at: f.root)
    }
    let index = try await f.service.git.run(["show", ":.gitignore"], at: f.root).stdout
    let dirtyIgnore = editedIgnore + Data("# unstaged edits\n".utf8)
    try dirtyIgnore.write(to: ignore)
    let head = try await f.service.git.oid("HEAD", at: f.root)
    try FileManager.default.removeItem(at: remote)
    let refusingWrites = WorkspaceStore(support: f.service.store.support) { _, _ in
      throw MonoDeckError("fixture-write-failed", "A repeated import must not write the record.")
    }
    let service = WorkspaceService(store: refusingWrites, git: f.service.git)
    let repeated = await service.importWorkspaceYAML(yaml, at: f.root)
    #expect(repeated.status == .success, "\(repeated.items)")
    #expect(
      Set(repeated.items.map(\.resource))
        == Set([.repository("repo"), .repository("other"), .group("existing"), .group("new")]))
    #expect(repeated.items.allSatisfy { $0.status == .skipped && $0.effects.isEmpty })
    #expect(try f.service.store.load(f.root) == saved)
    #expect(try Data(contentsOf: ignore) == dirtyIgnore)
    #expect(try await f.service.git.run(["show", ":.gitignore"], at: f.root).stdout == index)
    #expect(try await f.service.git.oid("HEAD", at: f.root) == head)
  }
  @Test func workspaceYAMLRepositoryConflictBlocksOnlyDependentGroups() async throws {
    let f = try await Fixture(template: .singleRepository)
    defer { f.remove() }
    let conflict = "https://mono-deck-test.invalid/different/Repo.git"
    let other = "https://mono-deck-test.invalid/other.git"
    for url in [conflict, other] {
      _ = try await f.service.git.run(
        [
          "config", "--global", "--add",
          "url.\(f.directory.appending(path: "repo.git").path).insteadOf", url,
        ], at: f.root)
    }
    let yaml = """
      version: 2
      repositories:
        - url: \(conflict)
        - url: \(other)
      groups:
        blocked:
          branch-name: blocked
          repository-ids: [Repo]
        independent:
          branch-name: independent
          repository-ids: [other]
      """
    let imported = await f.service.importWorkspaceYAML(yaml, at: f.root)
    #expect(imported.status == .partialSuccess, "\(imported.items)")
    #expect(
      imported.items.contains {
        $0.resource.kind == .repository && $0.reasonCode == "repository-conflict"
      })
    #expect(
      imported.items.contains {
        $0.resource == .group("blocked") && $0.reasonCode == "not-processed"
      })
    let saved = try f.service.store.load(f.root)
    #expect(saved.repositories.map(\.url) == [f.remoteURL, other])
    #expect(saved.groups["blocked"] == nil && !PathSafety.exists(saved.groupURL("blocked")))
    #expect(saved.groups["independent"]?.repositoryIDs == ["other"])
  }
  @Test(arguments: [false, true])
  func workspaceYAMLInterruptedGroupKeepsCompletedWorktreesAndCanRetry(_ cancelDuringCreation: Bool)
    async throws
  {
    let f = try await Fixture(template: .singleRepository)
    defer { f.remove() }
    let before = try f.service.store.load(f.root)
    let git = f.service.git
    let group = before.groupURL("feature")
    let member = before.memberURL("feature", "repo")
    let main = before.repositoryDirectoryURL("repo")
    let start = try #require(await git.oid("HEAD", at: f.root))
    let memberResource = Resource.member(groupName: "feature", repositoryID: "repo")
    let failingStore = WorkspaceStore(support: f.service.store.support) { data, _ in
      let record = try JSONDecoder().decode(WorkspaceRecord.self, from: data)
      #expect(record.groups["feature"]?.repositoryIDs == ["repo"])
      #expect(
        PathSafety.exists(record.groupURL("feature"))
          && PathSafety.exists(record.memberURL("feature", "repo")))
      throw MonoDeckError("fixture-write-failed", "Injected group save failure.")
    }
    let service = WorkspaceService(store: failingStore, git: git)
    let yaml = """
      version: 2
      repositories: [{url: \(f.remoteURL)}]
      groups:
        feature:
          branch-name: feature
          repository-ids: [repo]
      """
    let interrupted = await Task {
      await service.importWorkspaceYAML(yaml, at: f.root) { progress in
        if cancelDuringCreation, progress.target == memberResource.path, progress.phase == .creating
        {
          withUnsafeCurrentTask { $0?.cancel() }
        }
      }
    }.value
    #expect(
      interrupted.status == (cancelDuringCreation ? .cancelled : .partialSuccess),
      "\(interrupted.items)")
    let rootItem = try #require(interrupted.items.first { $0.resource == .group("feature") })
    let memberItem = try #require(interrupted.items.first { $0.resource == memberResource })
    #expect(rootItem.status == (cancelDuringCreation ? .success : .failed))
    #expect(rootItem.reasonCode == (cancelDuringCreation ? nil : "workspace-record-write-failed"))
    #expect(rootItem.effects.contains(.init("create-worktree", group.path)))
    #expect(rootItem.effects.contains(.init("create-branch", "feature")))
    #expect(!rootItem.effects.contains { $0.action == "save-workspace-record" })
    #expect(memberItem.status == (cancelDuringCreation ? .cancelled : .success))
    if cancelDuringCreation {
      #expect(memberItem.reasonCode == "cancelled" && memberItem.effects.isEmpty)
    } else {
      #expect(memberItem.effects.contains(.init("create-worktree", member.path)))
      #expect(memberItem.effects.contains(.init("create-branch", "feature")))
    }
    #expect(try f.service.store.load(f.root) == before)
    #expect(PathSafety.exists(group))
    #expect(PathSafety.exists(member) == !cancelDuringCreation)
    #expect(try await git.registrations(at: f.root).count == 2)
    #expect(try await git.registrations(at: main).count == (cancelDuringCreation ? 1 : 2))
    #expect(try await git.oid("refs/heads/feature", at: f.root) == start)
    let memberBranch = try await git.oid("refs/heads/feature", at: main)
    #expect((memberBranch != nil) == !cancelDuringCreation)

    let retried = await f.service.importWorkspaceYAML(yaml, at: f.root)
    #expect(retried.status == .success, "\(retried.items)")
    #expect(try f.service.store.load(f.root).groups["feature"]?.repositoryIDs == ["repo"])
    #expect(PathSafety.exists(member))
    let created = retried.items.flatMap(\.effects).filter { $0.action == "create-worktree" }
    #expect(created.map(\.target) == (cancelDuringCreation ? [member.path] : []))
  }

  @Test func workspaceYAMLFinishesTrackingBeforeRespondingToCancellation() async throws {
    let f = try await Fixture(template: .singleRepository)
    defer { f.remove() }
    let record = try f.service.store.load(f.root)
    let git = f.service.git
    _ = try await git.run(["update-ref", "refs/remotes/origin/feature/task", "HEAD"], at: f.root)
    let config = f.root.appending(path: ".git/config")
    let operation = Mutex<Task<OperationResult, Never>?>(nil)
    let service = f.service.withDiagnostics(
      .init { event in
        guard event.name == "command.git.config",
          let contents = try? String(contentsOf: config, encoding: .utf8),
          contents.contains("[branch \"feature/task\"]"),
          !contents.contains("merge = refs/heads/feature/task")
        else { return }
        // The command runner reports the write before resuming the import task.
        operation.withLock { $0?.cancel() }
      })
    let yaml = """
      version: 2
      repositories: [{url: \(f.remoteURL)}]
      groups: {feature: {branch-name: feature/task, repository-ids: [repo]}}
      """
    let task = operation.withLock { operation in
      let task = Task { await service.importWorkspaceYAML(yaml, at: f.root) }
      operation = task
      return task
    }

    let result = await task.value

    #expect(result.status == .cancelled, "\(result.items)")
    #expect(result.items.first { $0.resource == .group("feature") }?.reasonCode == "cancelled")
    #expect(
      try await git.run(["config", "--local", "--get", "branch.feature/task.remote"], at: f.root)
        .text == "origin")
    #expect(
      try await git.run(["config", "--local", "--get", "branch.feature/task.merge"], at: f.root)
        .text == "refs/heads/feature/task")
    #expect(try f.service.store.load(f.root) == record)
    #expect(PathSafety.exists(record.groupURL("feature")))
    #expect(!PathSafety.exists(record.memberURL("feature", "repo")))
  }

  @Test(arguments: [false, true])
  func workspaceYAMLRetryRegistersRetainedWorktrees(_ removeMemberBeforeRetry: Bool) async throws {
    let f = try await Fixture(template: .singleRepository)
    defer { f.remove() }
    let record = try f.service.store.load(f.root)
    let recordURL = f.service.store.recordURL(f.root)
    let originalRecord = try Data(contentsOf: recordURL)
    let group = record.groupURL("feature")
    let member = record.memberURL("feature", "repo")
    let main = record.repositoryDirectoryURL("repo")
    let git = f.service.git
    let failingStore = WorkspaceStore(support: f.service.store.support) { _, url in
      try Data("invalid".utf8).write(to: url)
      throw MonoDeckError("fixture-write-failed", "Injected unknown group save outcome.")
    }
    let service = WorkspaceService(store: failingStore, git: git)
    let yaml = """
      version: 2
      repositories: [{url: \(f.remoteURL)}]
      groups: {feature: {branch-name: feature/task, repository-ids: [repo]}}
      """
    let interrupted = await service.importWorkspaceYAML(yaml, at: f.root)
    let rootItem = try #require(interrupted.items.first { $0.resource == .group("feature") })
    #expect(rootItem.reasonCode == "save-outcome-unknown")
    #expect(
      rootItem.effects.contains { $0.action == "save-workspace-record" && $0.state == "unknown" })
    let memberItem = try #require(
      interrupted.items.first { $0.resource == .member(groupName: "feature", repositoryID: "repo") }
    )
    #expect(memberItem.status == .success)
    #expect(memberItem.effects.contains { $0.action == "create-worktree" && $0.state == "applied" })
    try #require(PathSafety.exists(group) && PathSafety.exists(member))
    try originalRecord.write(to: recordURL, options: .atomic)

    let note = Data("keep local changes\n".utf8)
    let groupNote = group.appending(path: "notes.txt")
    let memberNote = member.appending(path: "notes.txt")
    try note.write(to: groupNote)
    if removeMemberBeforeRetry {
      _ = try await git.run(["worktree", "remove", "--", member.path], at: main)
    } else {
      try note.write(to: memberNote)
      _ = try await git.run(["add", "--", "notes.txt"], at: member)
    }
    let rootLink = try Data(contentsOf: group.appending(path: ".git"))
    let memberCommit = try #require(await git.oid("refs/heads/feature/task", at: main))

    let retried = await f.service.importWorkspaceYAML(yaml, at: f.root)
    #expect(retried.status == .success, "\(retried.items)")
    let created = retried.items.flatMap(\.effects).filter { $0.action == "create-worktree" }
    #expect(created.count == (removeMemberBeforeRetry ? 1 : 0))
    #expect(try f.service.store.load(f.root).groups["feature"]?.repositoryIDs == ["repo"])
    #expect(try f.service.store.load(f.root).groups["feature"]?.branchName == "feature/task")
    #expect(try Data(contentsOf: group.appending(path: ".git")) == rootLink)
    #expect(try Data(contentsOf: groupNote) == note)
    #expect(try await git.oid("HEAD", at: member) == memberCommit)
    if !removeMemberBeforeRetry {
      #expect(try Data(contentsOf: memberNote) == note)
      #expect(try await git.run(["show", ":notes.txt"], at: member).stdout == note)
    }
  }

  @Test(arguments: [false, true])
  func workspaceYAMLSkipsGroupWithMismatchedWorktree(_ wrongRepository: Bool) async throws {
    let f = try await Fixture(template: .singleRepository)
    defer { f.remove() }
    let git = f.service.git
    let other = "https://mono-deck-test.invalid/other.git"
    let remote = f.directory.appending(path: "repo.git")
    _ = try await git.run(
      ["config", "--global", "--add", "url.\(remote.path).insteadOf", other], at: f.root)
    try #require(await f.service.addRepository(.init(url: other), at: f.root).status == .success)
    let record = try f.service.store.load(f.root)
    try await f.prepareEmptyGroup("feature", branchName: "feature/task")
    try f.service.store.save(record)
    let member = record.memberURL("feature", "repo")
    let expectedMain = record.repositoryDirectoryURL("repo")
    let owner = wrongRepository ? f.directory.appending(path: "source") : expectedMain
    let actualBranch = wrongRepository ? "feature/task" : "different/task"
    if wrongRepository {
      _ = try await git.run(["config", "remote.origin.url", f.remoteURL], at: owner)
    }
    _ = try await git.run(["worktree", "add", "-b", actualBranch, member.path, "HEAD"], at: owner)
    let note = member.appending(path: "notes.txt")
    let data = Data("keep occupied worktree\n".utf8)
    try data.write(to: note)
    let yaml = """
      version: 2
      repositories: [{url: \(f.remoteURL)}, {url: \(other)}]
      groups:
        feature: {branch-name: feature/task, repository-ids: [other, repo]}
        independent: {branch-name: independent, repository-ids: []}
      """

    let imported = await f.service.importWorkspaceYAML(yaml, at: f.root)
    let skipped = try #require(
      imported.items.first { $0.resource == .member(groupName: "feature", repositoryID: "repo") })
    #expect(
      skipped.status == .skipped && skipped.reasonCode == "import-worktree-mismatch",
      "\(imported.items)")
    let saved = try f.service.store.load(f.root)
    #expect(saved.groups["feature"] == nil)
    #expect(saved.groups["independent"]?.repositoryIDs == [])
    #expect(!PathSafety.exists(record.memberURL("feature", "other")))
    #expect(
      try await git.oid("refs/heads/feature/task", at: record.repositoryDirectoryURL("other"))
        == nil)
    #expect(
      try await git.run(["symbolic-ref", "HEAD"], at: member).text == "refs/heads/\(actualBranch)")
    #expect(try Data(contentsOf: note) == data)
  }

  @Test func yamlAppendDeduplicatesAndDoesNotChangeName() async throws {
    let f = try await Fixture(template: .singleRepository)
    defer { f.remove() }
    var record = try f.service.store.load(f.root)
    record.repositories[0].displayNameOverride = "Custom"
    try f.service.store.save(record)
    let result = await f.service.importRepositories(
      try WorkspaceService.repositoryURLs(in: "values: [\(f.remoteURL), \(f.remoteURL)]"),
      at: f.root)
    #expect(result.status == .skipped)
    #expect(try await f.service.load(f.root).repositories.first?.displayNameOverride == "Custom")
    #expect(result.items.map(\.reasonCode) == ["already-exists", "duplicate-url"])
    let conflict = await f.service.importRepositories(
      try WorkspaceService.repositoryURLs(
        in: "a: https://other.invalid/repo.git\nb: https://another.invalid/repo.git"), at: f.root)
    #expect(conflict.items.allSatisfy { $0.reasonCode == "repository-conflict" })
  }
  @Test func repositoryUpdatePreservesIgnoredFilesThatBecomeTrackedUpstream() async throws {
    let f = try await Fixture(template: .singleRepository)
    defer { f.remove() }
    let source = f.directory.appending(path: "source")
    let main = f.root.appending(path: "repositories/repo")
    try Data("/secret\n".utf8).write(to: main.appending(path: ".git/info/exclude"))
    try Data("local-secret".utf8).write(to: main.appending(path: "secret"))
    try Data("remote".utf8).write(to: source.appending(path: "secret"))
    _ = try await f.service.git.run(["add", "secret"], at: source)
    _ = try await f.service.git.run(["commit", "-m", "add secret path"], at: source)
    _ = try await f.service.git.run(
      ["push", f.directory.appending(path: "repo.git").path, "main"], at: source)
    let protected = await f.service.updateRepositories(at: f.root)
    #expect(protected.status == .failed)
    #expect(
      try String(contentsOf: main.appending(path: "secret"), encoding: .utf8) == "local-secret")
  }
  @Test(arguments: [false, true])
  func groupInspectionShowsOwnGitStateWithoutRequiringOrigin(_ hasRemote: Bool) async throws {
    let f = try await Fixture(template: .singleRepository)
    defer { f.remove() }
    if hasRemote {
      _ = try await f.service.git.run(["remote", "add", "upstream", f.remoteURL], at: f.root)
    }
    try await f.prepareGroup("feature", repositoryIDs: ["repo"])
    let record = try f.service.store.load(f.root)
    let group = Resource.group("feature")
    let head = try #require(await f.service.git.oid("HEAD", at: record.groupURL("feature")))
    try Data("member".utf8).write(
      to: record.memberURL("feature", "repo").appending(path: "member.txt"))
    let cleanInspection = await f.service.inspect(f.root)
    let clean = try #require(cleanInspection.items.first { $0.resource == group })
    #expect(clean.status == .success)
    #expect(clean.data?["working-tree"] == "clean")
    #expect(clean.data?["head"] == "feature" && clean.data?["head-oid"] == head)
    #expect(clean.data?["base"] == nil)
    #expect((clean.data?["base-error"] != nil) == hasRemote)

    try Data("group".utf8).write(to: record.groupURL("feature").appending(path: "group.txt"))
    let dirtyInspection = await f.service.inspect(f.root)
    let dirty = try #require(dirtyInspection.items.first { $0.resource == group })
    #expect(dirty.status == .success && dirty.data?["working-tree"] == "dirty")
    #expect(dirty.data?["head-oid"] == head)
  }
  @Test func unsafeResourcesAndUncommittedIgnoreAreRejected() async throws {
    let f = try await Fixture()
    defer { f.remove() }
    let outside = f.directory.appending(path: "outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(
      at: f.root.appending(path: "repositories"), withDestinationURL: outside)
    #expect(await f.service.openWorkspace(f.root).status == .failed)
    try FileManager.default.removeItem(at: f.root.appending(path: "repositories"))
    _ = await f.service.openWorkspace(f.root)
    #expect(await f.service.addRepository(.init(url: f.remoteURL), at: f.root).status == .success)
    _ = try await f.service.git.run(["branch", "feature", "HEAD~1"], at: f.root)
    let result = await f.service.createGroup("feature", repositoryIDs: ["repo"], at: f.root)
    #expect(result.status == .failed && result.items.first?.resource == .group("feature"))
    #expect(result.items.first?.reasonCode == "workspace-ignore-required")
    #expect(result.items.last?.reasonCode == "not-processed")
    #expect(!PathSafety.exists(f.root.appending(path: "worktrees/feature")))
  }
  @Test func cliJSONContractAndMissingUpdateMembersHaveNoEffects() async throws {
    let f = try await Fixture(template: .singleRepository)
    defer { f.remove() }
    let original = try Data(contentsOf: f.service.store.recordURL(f.root))
    let failure = try await f.runCLI([
      "--workspace", f.root.path, "group", "edit", "feature", "--yes", "--json",
    ])
    #expect(failure.status == 2)
    let json = try #require(JSONSerialization.jsonObject(with: failure.stdout) as? [String: Any])
    #expect(json["schema-version"] as? Int == 2)
    #expect(json["reason-code"] as? String == "invalid-input")
    #expect(try Data(contentsOf: f.service.store.recordURL(f.root)) == original)
    let preview = try await f.runCLI([
      "repo", "delete", "repo", "--json", "--workspace", f.root.path,
    ])
    #expect(preview.status == 1)
    #expect(
      try JSONDecoder().decode(OperationResult.self, from: preview.stdout).status
        == .confirmationRequired)
  }

  @Test func cliGlobalOptionsRemainBeforeArgumentTerminator() async throws {
    let f = try await Fixture(template: .emptyWorkspace)
    defer { f.remove() }
    for placement in ["leading", "interleaved", "trailing", "equals"] {
      let arguments: [String]
      switch placement {
      case "leading": arguments = ["--json", "--workspace", f.root.path, "repo", "list", "--"]
      case "interleaved": arguments = ["repo", "--workspace", f.root.path, "list", "--json", "--"]
      case "trailing": arguments = ["repo", "list", "--json", "--workspace", f.root.path, "--"]
      default: arguments = ["--workspace=\(f.root.path)", "repo", "--json", "list", "--"]
      }
      let output = try await f.runCLI(arguments)
      try #require(output.status == 0, "\(output.text)")
      let result = try JSONDecoder().decode(OperationResult.self, from: output.stdout)
      #expect(result.command == "repo.list" && result.status == .success && result.items.isEmpty)
      #expect(result.workspace == PathSafety.canonical(f.root).path)
    }
  }

  @Test func cliRepositoryURLAfterArgumentTerminatorIsPreserved() async throws {
    let f = try await Fixture()
    defer { f.remove() }
    try await f.prepareWorkspace()
    let workspace = ["--workspace=\(f.root.path)"]
    let output = try await f.runCLI(["--json"] + workspace + ["repo", "add", "--", f.remoteURL])
    try #require(output.status == 0, "\(output.text)")
    let result = try JSONDecoder().decode(OperationResult.self, from: output.stdout)
    #expect(result.command == "repo.add" && result.status == .success)
    #expect(result.items.first?.data?["disposition"] == "added")
    #expect(try f.service.store.load(f.root).repositories == [.init(url: f.remoteURL)])
  }

  @Test func cliWorkspaceTreeUsesThePhysicalHierarchyAndReadOnlyQueries() async throws {
    let f = try await Fixture(template: .singleRepository)
    defer { f.remove() }
    try await f.prepareGroup("feature", repositoryIDs: ["repo"])
    let record = try f.service.store.load(f.root)
    _ = try await f.service.git.run(
      ["symbolic-ref", "--delete", "refs/remotes/origin/HEAD"],
      at: record.repositoryDirectoryURL("repo"))
    let original = try Data(contentsOf: f.service.store.recordURL(f.root))
    let trace = f.directory.appending(path: "tree-trace")
    let arguments = ["workspace", "tree", "--workspace", f.root.path]
    let plain = try await f.runCLI(arguments, environment: ["GIT_TRACE": trace.path])
    #expect(plain.status == 0)
    #expect(
      plain.text == """
        \(PathSafety.canonical(f.root).path)/
        |-- repositories/
        |   `-- repo/
        `-- worktrees/
            `-- feature/
                `-- repo/
        """)
    let json = try await f.runCLI(arguments + ["--json"], environment: ["GIT_TRACE": trace.path])
    #expect(json.status == 0)
    let result = try JSONDecoder().decode(OperationResult.self, from: json.stdout)
    let tree = try #require(result.data?.tree)
    #expect(tree.children?.first?.children?.first?.path == "repo")
    let envelope = try #require(JSONSerialization.jsonObject(with: json.stdout) as? [String: Any])
    let document = try #require((envelope["data"] as? [String: Any])?["tree"] as? [String: Any])
    #expect(Set(document.keys) == ["type", "path", "children"])
    #expect(document["type"] as? String == "workspace")
    let children = try #require(document["children"] as? [[String: Any]])
    let repositories = try #require(children.first?["children"] as? [[String: Any]])
    #expect(repositories.first?["type"] as? String == "main-worktree")
    #expect(repositories.first?["children"] is NSNull)
    let commands = try String(contentsOf: trace, encoding: .utf8)
    #expect(
      !commands.contains("built-in: git fetch ") && !commands.contains("built-in: git status "))
    #expect(try Data(contentsOf: f.service.store.recordURL(f.root)) == original)
  }

  @Test func cliWorkspaceTreeCancellationReturnsOnlyTheFailureDocument() async throws {
    let f = try await Fixture(template: .emptyWorkspace)
    defer { f.remove() }
    let fifo = f.directory.appending(path: "tree-config-gate")
    try #require(fifo.path.withCString { mkfifo($0, 0o600) } == 0)
    _ = try await f.service.git.run(["config", "--add", "include.path", fifo.path], at: f.root)
    let executable = try #require(Bundle.main.url(forResource: "mono-deck", withExtension: nil))
    var runner = f.service.git.runner
    runner.environment["MONO_DECK_TEST_SUPPORT_DIRECTORY"] = f.service.store.support.path
    let controller = """
      import os, signal, subprocess, sys, time
      process = subprocess.Popen([sys.argv[1], 'workspace', 'tree', '--json', '--workspace', sys.argv[2]])
      descriptor = None
      try:
          deadline = time.monotonic() + 5
          while time.monotonic() < deadline:
              try:
                  descriptor = os.open(sys.argv[3], os.O_WRONLY | os.O_NONBLOCK)
                  break
              except OSError:
                  if process.poll() is not None:
                      raise RuntimeError('CLI exited before reading the Git configuration')
                  time.sleep(0.01)
          if descriptor is None:
              raise RuntimeError('CLI did not reach the Git configuration gate')
          os.kill(process.pid, signal.SIGINT)
          status = process.wait(timeout=5)
      finally:
          if descriptor is not None:
              os.close(descriptor)
          if process.poll() is None:
              process.kill()
              process.wait()
      sys.exit(status)
      """
    let output = try await runner.run(
      "/usr/bin/python3", ["-c", controller, executable.path, f.root.path, fifo.path],
      at: f.directory)
    let result = try JSONDecoder().decode(OperationResult.self, from: output.stdout)
    #expect(output.status == 130 && result.status == .cancelled && result.reasonCode == "cancelled")
    #expect(result.command == "workspace.tree" && result.items.isEmpty)
  }

  @Test(arguments: ["repo", "group"])
  func cliInspectionCancellationReturnsExitCode130(_ command: String) async throws {
    let f = try await Fixture(template: .singleRepository)
    defer { f.remove() }
    try await f.prepareGroup("feature", repositoryIDs: ["repo"])
    let record = try f.service.store.load(f.root)
    let probe = f.directory.appending(path: "inspection-cancelled")
    let monitor = f.directory.appending(path: "inspection-fsmonitor")
    try Data(
      """
      #!/bin/sh
      : > "$MONO_DECK_INSPECTION_CANCEL_PROBE"
      trap 'exit 143' TERM INT
      kill -INT "$MONO_DECK_INSPECTION_CLI_PID" || exit 1
      while :; do sleep 0.02; done
      """.utf8
    ).write(to: monitor)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: monitor.path)
    let target =
      command == "group" ? record.groupURL("feature") : record.repositoryDirectoryURL("repo")
    for arguments in [
      ["config", "core.fsmonitor", monitor.path], ["config", "core.fsmonitorHookVersion", "2"],
    ] {
      _ = try await f.service.git.run(arguments, at: target)
    }
    let executable = try #require(Bundle.main.url(forResource: "mono-deck", withExtension: nil))
    var runner = f.service.git.runner
    runner.environment["MONO_DECK_TEST_SUPPORT_DIRECTORY"] = f.service.store.support.path
    runner.environment["MONO_DECK_INSPECTION_CANCEL_PROBE"] = probe.path
    let launch = """
      export MONO_DECK_INSPECTION_CLI_PID=$$
      exec "$@"
      """
    let operation = command == "workspace" ? "tree" : "list"
    let output = try await runner.run(
      "/bin/bash",
      [
        "-c", launch, "mono-deck-inspection-cancellation", executable.path,
        command, operation, "--json", "--workspace", f.root.path,
      ])
    #expect(PathSafety.exists(probe))
    let result = try JSONDecoder().decode(OperationResult.self, from: output.stdout)
    #expect(output.status == 130 && result.exitCode == 130)
    #expect(
      result.command == "\(command).\(operation)" && result.status == .cancelled
        && result.reasonCode == "cancelled")
    #expect(result.items.contains { $0.status == .cancelled })
  }

  @Test(arguments: [false, true])
  func cliListsPreserveWorkspaceFailures(_ hasRepository: Bool) async throws {
    let f = try await Fixture(template: hasRepository ? .singleRepository : .emptyWorkspace)
    defer { f.remove() }
    let original = try Data(contentsOf: f.service.store.recordURL(f.root))
    try FileManager.default.moveItem(
      at: f.root.appending(path: ".git"), to: f.directory.appending(path: "workspace-git"))
    let inspection = await f.service.inspect(f.root)
    let failure = try #require(inspection.items.first { $0.resource.kind == .workspace })
    #expect(failure.status == .failed && failure.reasonCode != nil && failure.message != nil)
    #expect(inspection.reasonCode == nil)

    for command in ["repo", "group"] {
      let status = command == "repo" && hasRepository ? "partial-success" : "failed"
      let failureMessage = try #require(failure.message)
      for json in [false, true] {
        let output = try await f.runCLI(
          [command, "list", "--workspace", f.root.path] + (json ? ["--json"] : []))
        #expect(output.status == 1, "\(output.text)")
        if json {
          let result = try JSONDecoder().decode(OperationResult.self, from: output.stdout)
          #expect(result.command == "\(command).list" && result.status.rawValue == status)
          #expect(result.workspace == PathSafety.canonical(f.root).path)
          #expect(result.reasonCode == nil && result.message == nil)
          let workspace = try #require(result.items.first { $0.resource.kind == .workspace })
          #expect(workspace.resource.path == "." && workspace.status == .failed)
          #expect(
            workspace.reasonCode == failure.reasonCode && workspace.message == failure.message)
          #expect(workspace.data == nil && workspace.effects.isEmpty)
          #expect(result.items.count == (command == "repo" && hasRepository ? 2 : 1))
        } else {
          #expect(output.text.contains("\(command).list: \(status)"))
          #expect(output.text.contains(".: failed"))
          #expect(output.text.contains(failureMessage))
        }
      }
      #expect(try Data(contentsOf: f.service.store.recordURL(f.root)) == original)
      #expect(!PathSafety.exists(f.root.appending(path: ".git")))
    }
  }

  @Test func cliListsIgnoreUnrelatedResourceFailures() async throws {
    let f = try await Fixture(template: .singleRepository)
    defer { f.remove() }
    try await f.prepareGroup("feature", repositoryIDs: ["repo"])
    let saved = try f.service.store.load(f.root)
    for kind in ["repository", "group", "member"] {
      var record = saved
      let metadata =
        (kind == "member" ? saved.memberURL("feature", "repo") : saved.groupURL("feature"))
        .appending(path: ".git")
      let gitFile = try Data(contentsOf: metadata)
      if kind == "repository" {
        record.groups["feature"]?.repositoryIDs = []
        _ = try await f.service.git.run(
          ["config", "remote.origin.url", "https://mono-deck-test.invalid/other.git"],
          at: saved.repositoryDirectoryURL("repo"))
      } else {
        try Data("gitdir: missing-git-directory\n".utf8).write(to: metadata)
      }
      try f.service.store.save(record)
      let original = try Data(contentsOf: f.service.store.recordURL(f.root))
      for command in ["repo", "group"] {
        let output = try await f.runCLI([command, "list", "--json", "--workspace", f.root.path])
        let result = try JSONDecoder().decode(OperationResult.self, from: output.stdout)
        let related = kind == "repository" ? command == "repo" : command == "group"
        #expect(output.status == (related ? 1 : 0), "\(output.text)")
        #expect(result.command == "\(command).list" && result.reasonCode == nil)
        #expect(!result.items.contains { $0.resource.kind == .workspace })
        if related {
          #expect(result.status.rawValue == (kind == "repository" ? "failed" : "partial-success"))
          #expect(
            result.items.contains {
              $0.resource.kind.rawValue == kind && $0.status == .failed && $0.reasonCode != nil
            })
        } else {
          #expect(result.status == .success && result.items.count == 1)
          #expect(result.items.allSatisfy { $0.status == .success })
        }
      }
      #expect(try Data(contentsOf: f.service.store.recordURL(f.root)) == original)
      #expect(PathSafety.exists(saved.memberURL("feature", "repo")))
      if kind == "repository" {
        _ = try await f.service.git.run(
          ["config", "remote.origin.url", f.remoteURL], at: saved.repositoryDirectoryURL("repo"))
      } else {
        try gitFile.write(to: metadata)
      }
    }
    try f.service.store.save(saved)
  }

  @Test(arguments: ["workspace", "repo", "group"])
  func cliQueriesDoNotWaitForTheWorkspaceLock(_ command: String) async throws {
    let f = try await Fixture(template: .emptyWorkspace)
    defer { f.remove() }
    let lease = try f.service.store.tryLock(f.root)
    defer { lease.unlock() }
    let operation = command == "workspace" ? "tree" : "list"
    let output = try await f.runCLI([command, operation, "--json", "--workspace", f.root.path])
    #expect(output.status == 0)
    if command == "workspace" {
      let result = try JSONDecoder().decode(OperationResult.self, from: output.stdout)
      let tree = try #require(result.data?.tree)
      #expect(tree.path == PathSafety.canonical(f.root).path)
    } else {
      let result = try JSONDecoder().decode(OperationResult.self, from: output.stdout)
      #expect(result.status == .success && result.command == "\(command).list")
    }
  }

  @Test(arguments: ["empty", "invalid-record", "missing-root"])
  func cliListsKeepRequestErrorsAndHealthyEmptyResults(_ kind: String) async throws {
    let f = try await Fixture(template: .emptyWorkspace)
    defer { f.remove() }
    switch kind {
    case "invalid-record": try Data("invalid".utf8).write(to: f.service.store.recordURL(f.root))
    case "missing-root": try FileManager.default.removeItem(at: f.root)
    default: break
    }
    for command in ["repo", "group"] {
      let output = try await f.runCLI([command, "list", "--json", "--workspace", f.root.path])
      let result = try JSONDecoder().decode(OperationResult.self, from: output.stdout)
      #expect(result.command == "\(command).list" && result.items.isEmpty)
      if kind == "empty" {
        #expect(output.status == 0 && result.status == .success)
        #expect(result.reasonCode == nil && result.message == nil)
      } else {
        #expect(output.status == 2 && result.status == .failed)
        let reason = kind == "missing-root" ? "workspace-not-found" : "invalid-workspace-record"
        #expect(result.reasonCode == reason && result.message != nil)
      }
    }
  }

  @Test func cliInvalidRepositoryURLIsARequestErrorWithExitCodeTwo() async throws {
    let f = try await Fixture(template: .emptyWorkspace)
    defer { f.remove() }
    let trace = f.directory.appending(path: "invalid-input-cli-trace")
    let before = try Data(contentsOf: f.service.store.recordURL(f.root))
    for json in [false, true] {
      for url in ["file:///tmp/repo.git", "https://user:sensitive-token@example.test/repo.git"] {
        let output = try await f.runCLI(
          ["repo", "add", url, "--workspace", f.root.path] + (json ? ["--json"] : []),
          environment: ["GIT_TRACE": trace.path])
        #expect(output.status == 2)
        if json {
          let result = try JSONDecoder().decode(OperationResult.self, from: output.stdout)
          #expect(
            result.command == "repo.add" && result.status == .failed
              && result.reasonCode == "invalid-input")
          #expect(result.items.isEmpty && result.workspace == PathSafety.canonical(f.root).path)
        } else {
          #expect(output.text.contains("repo.add: failed"))
        }
        #expect(!output.text.contains("sensitive-token"))
        #expect(!String(decoding: output.stderr, as: UTF8.self).contains("sensitive-token"))
        #expect(!PathSafety.exists(trace))
        #expect(try Data(contentsOf: f.service.store.recordURL(f.root)) == before)
        #expect(
          try FileManager.default.contentsOfDirectory(
            atPath: f.root.appending(path: "repositories").path
          ).isEmpty)
      }
    }
  }

  @Test func workspaceOpeningUsesHistoryWithoutRecoveringDiskResources() async throws {
    let f = try await Fixture(template: .singleRepository)
    defer { f.remove() }
    try await f.prepareGroup("feature", repositoryIDs: ["repo"])
    try await f.prepareEmptyGroup("empty")
    let group = f.root.appending(path: "worktrees/feature")
    let member = group.appending(path: "repo")
    _ = try await f.service.git.run(["checkout", "-b", "different-branch"], at: group)
    _ = try await f.service.git.run(["checkout", "--detach"], at: member)
    let head = try await f.service.git.oid("HEAD", at: member)
    try Data("user changes".utf8).write(to: member.appending(path: "README"))
    let record = f.service.store.recordURL(f.root)
    var saved = try f.service.store.load(f.root)
    saved.repositories[0].displayNameOverride = "Custom"
    saved.groups["feature"]?.createdAt = "2001-01-01T00:00:00Z"
    saved.groups["empty"]?.createdAt = "2002-01-01T00:00:00Z"
    let unmanaged = f.root.appending(path: "repositories/unmanaged")
    try FileManager.default.createDirectory(at: unmanaged, withIntermediateDirectories: false)
    for history in ["saved", "missing", "corrupt", "stale"] {
      switch history {
      case "missing": try FileManager.default.removeItem(at: record)
      case "corrupt": try Data("invalid".utf8).write(to: record)
      case "stale":
        try f.service.store.save(WorkspaceRecord(root: PathSafety.canonical(f.root).path))
      default: try f.service.store.save(saved)
      }
      let original = PathSafety.exists(record) ? try Data(contentsOf: record) : nil
      let opened = await f.service.openWorkspace(f.root)
      if history == "saved" || history == "stale" {
        #expect(opened.status == .success, "\(opened.items)")
        #expect(
          try await f.service.load(f.root)
            == (history == "saved"
              ? saved : WorkspaceRecord(root: PathSafety.canonical(f.root).path)))
      } else {
        #expect(opened.status == .failed)
        #expect(
          opened.items.first?.reasonCode
            == (history == "missing" ? "workspace-not-empty" : "invalid-workspace-record"))
      }
      if let original {
        #expect(try Data(contentsOf: record) == original)
      } else {
        #expect(!PathSafety.exists(record))
      }
      #expect(PathSafety.exists(unmanaged))
      #expect(try await f.service.git.oid("HEAD", at: member) == head)
      #expect(
        try await f.service.git.run(["symbolic-ref", "--short", "HEAD"], at: group).text
          == "different-branch")
      #expect(
        try await f.service.git.run(["symbolic-ref", "HEAD"], at: member, allowFailure: true).status
          != 0)
      #expect(
        try String(contentsOf: member.appending(path: "README"), encoding: .utf8) == "user changes")
      #expect(opened.items.allSatisfy { $0.effects.isEmpty })
    }
  }

  @Test func unavailableDiskResourcesKeepHistoryAndReportTheirState() async throws {
    let f = try await Fixture(template: .singleRepository)
    defer { f.remove() }
    try await f.prepareGroup("feature", repositoryIDs: ["repo"])
    let saved = try f.service.store.load(f.root)
    let repository = saved.repositoryDirectoryURL("repo")
    let group = saved.groupURL("feature")
    let record = f.service.store.recordURL(f.root)
    let original = try Data(contentsOf: record)
    let notes = saved.memberURL("feature", "repo").appending(path: "notes.txt")
    try Data("keep user changes".utf8).write(to: notes)
    for kind in ["origin", "name", "symlink", "group", "member", "root"] {
      var expected = saved
      let metadata = (kind == "member" ? saved.memberURL("feature", "repo") : group).appending(
        path: ".git")
      let gitFile = try Data(contentsOf: metadata)
      switch kind {
      case "origin":
        _ = try await f.service.git.run(
          ["config", "remote.origin.url", "/tmp/local-repo"], at: repository)
      case "name":
        try FileManager.default.moveItem(
          at: repository, to: repository.deletingLastPathComponent().appending(path: "wrong-name"))
        expected.repositories = []
        expected.groups["feature"]?.repositoryIDs = []
      case "symlink":
        let outside = f.directory.appending(path: "outside-repo")
        try FileManager.default.moveItem(at: repository, to: outside)
        try FileManager.default.createSymbolicLink(at: repository, withDestinationURL: outside)
      case "group", "member":
        try Data("gitdir: \(f.directory.appending(path: "source/.git").path)\n".utf8).write(
          to: metadata)
      default: try FileManager.default.removeItem(at: f.root.appending(path: ".git"))
      }
      #expect(await f.service.openWorkspace(f.root).status == .success)
      #expect(try f.service.store.load(f.root) == expected)
      if kind != "name" { #expect(try Data(contentsOf: record) == original) }
      let inspection = await f.service.inspect(f.root)
      if kind != "name" {
        let resource: Resource =
          kind == "group" || kind == "root"
          ? .group("feature")
          : kind == "member"
            ? .member(groupName: "feature", repositoryID: "repo") : .repository("repo")
        #expect(inspection.items.first { $0.resource == resource }?.status == .failed)
      }
      #expect(PathSafety.exists(group) && PathSafety.exists(notes))
      #expect(try String(contentsOf: notes, encoding: .utf8) == "keep user changes")
      switch kind {
      case "origin":
        _ = try await f.service.git.run(
          ["config", "remote.origin.url", f.remoteURL], at: repository)
      case "name":
        try FileManager.default.moveItem(
          at: repository.deletingLastPathComponent().appending(path: "wrong-name"), to: repository)
        try f.service.store.save(saved)
      case "symlink":
        try FileManager.default.removeItem(at: repository)
        try FileManager.default.moveItem(
          at: f.directory.appending(path: "outside-repo"), to: repository)
      case "group", "member": try gitFile.write(to: metadata)
      default: break
      }
      #expect(PathSafety.exists(repository))
    }
  }

}
