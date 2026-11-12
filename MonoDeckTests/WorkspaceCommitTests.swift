import Foundation
import Testing

@testable import MonoDeckCore

struct WorkspaceCommitTests {
  @Test func unchangedManagedFilesKeepStagedEditsAndSkipStagingAndCommit() async throws {
    let f = try await Fixture(template: .emptyWorkspace)
    defer { f.remove() }
    let ignore = f.root.appending(path: ".gitignore")
    let original = try Data(contentsOf: ignore)
    var staged = original
    staged.append(Data("# staged edit\n".utf8))
    try staged.write(to: ignore)
    _ = try await f.service.git.run(["add", ".gitignore"], at: f.root)
    try original.write(to: ignore)
    let head = try await f.service.git.oid("HEAD", at: f.root)
    let trace = f.directory.appending(path: "unchanged-trace")
    var runner = f.service.git.runner
    runner.environment["GIT_TRACE"] = trace.path
    let service = WorkspaceService(store: f.service.store, git: Git(runner: runner))
    #expect(await service.openWorkspace(f.root).status == .success)
    #expect(try await f.service.git.oid("HEAD", at: f.root) == head)
    #expect(try await f.service.git.run(["show", ":.gitignore"], at: f.root).stdout == staged)
    #expect(try Data(contentsOf: ignore) == original)
    let commands = try String(contentsOf: trace, encoding: .utf8)
    #expect(!commands.contains("built-in: git add ") && !commands.contains("built-in: git commit "))
  }

  @Test(arguments: [false, true])
  func automaticWorkspaceCommitRequiresLocalBranch(_ remoteAlias: Bool) async throws {
    let f = try await Fixture(template: .emptyWorkspace)
    defer { f.remove() }
    let git = f.service.git
    let head = try #require(await git.oid("HEAD", at: f.root))
    if remoteAlias {
      _ = try await git.run(["update-ref", "refs/remotes/origin/main", head], at: f.root)
      _ = try await git.run(
        ["symbolic-ref", "refs/heads/alias", "refs/remotes/origin/main"], at: f.root)
      _ = try await git.run(["symbolic-ref", "HEAD", "refs/heads/alias"], at: f.root)
    } else {
      _ = try await git.run(["switch", "--detach"], at: f.root)
    }
    #expect(await f.service.openWorkspace(f.root).status == .success)

    let ignore = f.root.appending(path: ".gitignore")
    let staged = try Data(contentsOf: ignore) + Data("# staged edit\n".utf8)
    try staged.write(to: ignore)
    _ = try await git.run(["add", "--", ".gitignore"], at: f.root)
    let working = staged + Data("# unstaged edit\n".utf8)
    try working.write(to: ignore)

    let result = await f.service.openWorkspace(f.root)

    #expect(
      result.status == .failed && result.items.first?.reasonCode == "workspace-commit-failed",
      "\(result.items)")
    #expect(try await git.oid("HEAD", at: f.root) == head)
    #expect(try await git.run(["show", ":.gitignore"], at: f.root).stdout == staged)
    #expect(try Data(contentsOf: ignore) == working)
  }

  @Test(arguments: [false, true])
  func initializationCommitsSkillAndIgnoreAndPreservesOtherStaging(_ existingCommit: Bool)
    async throws
  {
    let f = try await Fixture()
    defer { f.remove() }
    _ = try await f.service.git.run(["init"], at: f.root)
    let notes = f.root.appending(path: "notes.txt")
    try Data("original\n".utf8).write(to: notes)
    _ = try await f.service.git.run(["add", "notes.txt"], at: f.root)
    if existingCommit {
      _ = try await f.service.git.run(["commit", "-m", "user files"], at: f.root)
    }
    try Data("staged\n".utf8).write(to: notes)
    _ = try await f.service.git.run(["add", "notes.txt"], at: f.root)
    try Data("unstaged\n".utf8).write(to: notes)
    let index = try await f.service.git.run(["show", ":notes.txt"], at: f.root).stdout
    let source = f.directory.appending(path: "SKILL.md")
    try Data("# Workflow\n".utf8).write(to: source)
    let policy = f.directory.appending(path: "agents/openai.yaml")
    try FileManager.default.createDirectory(
      at: policy.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("policy:\n  allow_implicit_invocation: false\n".utf8).write(to: policy)
    let installer = InstallationService(support: f.service.store.support)
    let opened = await f.service.openWorkspaceWithRecord(
      f.root, skill: source, installer: installer)
    #expect(opened.result.status == .success && opened.skillError == nil, "\(opened.result.items)")
    #expect(
      try await f.service.git.run(["show", "--no-patch", "--format=%B", "HEAD"], at: f.root).text
        == "chore: initialize MonoDeck workspace\n\nAuto-committed-by: MonoDeck")
    #expect(
      try await changedPaths(f) == [
        ".agents/skills/mono-deck-workflow/SKILL.md",
        ".agents/skills/mono-deck-workflow/agents/openai.yaml", ".gitignore",
      ])
    #expect(try await f.service.git.run(["show", ":notes.txt"], at: f.root).stdout == index)
    #expect(try Data(contentsOf: notes) == Data("unstaged\n".utf8))
    #expect(
      try await f.service.git.run(["diff", "--cached", "--name-only"], at: f.root).text
        == "notes.txt")
    let head = try await f.service.git.oid("HEAD", at: f.root)
    #expect(
      await f.service.openWorkspace(f.root, skill: source, installer: installer).status == .success)
    #expect(try await f.service.git.oid("HEAD", at: f.root) == head)

    #expect(await f.service.addRepository(.init(url: f.remoteURL), at: f.root).status == .success)
    #expect(
      try await f.service.git.run(["show", "--no-patch", "--format=%B", "HEAD"], at: f.root).text
        == "chore: ignore MonoDeck repository repo\n\nAuto-committed-by: MonoDeck")
    #expect(try await changedPaths(f) == [".gitignore"])
    #expect(try await f.service.git.run(["show", ":notes.txt"], at: f.root).stdout == index)
    #expect(
      await f.service.createGroup("feature", repositoryIDs: ["repo"], at: f.root).status == .success
    )
    let skill = f.root.appending(
      path: "worktrees/feature/.agents/skills/mono-deck-workflow/SKILL.md")
    #expect(try Data(contentsOf: skill) == Data(contentsOf: source))
    #expect(
      try Data(contentsOf: skill.deletingLastPathComponent().appending(path: "agents/openai.yaml"))
        == Data(contentsOf: policy))
  }

  @Test(arguments: [false, true])
  func skillPolicyUpdatePreservesWorkspaceChangesAndCommitsOnlyManagedFiles(_ existingPolicy: Bool)
    async throws
  {
    let f = try await Fixture(createRemote: false)
    defer { f.remove() }
    let source = f.directory.appending(path: "SKILL.md")
    try Data("# Workflow\n".utf8).write(to: source)
    let policy = f.directory.appending(path: "agents/openai.yaml")
    if existingPolicy {
      try FileManager.default.createDirectory(
        at: policy.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("policy:\n  allow_implicit_invocation: true\n".utf8).write(to: policy)
    }
    #expect(await f.service.openWorkspace(f.root, skill: source).status == .success)
    try FileManager.default.createDirectory(
      at: policy.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("policy:\n  allow_implicit_invocation: false\n".utf8).write(to: policy)
    let extra = f.root.appending(path: ".agents/skills/mono-deck-workflow/notes.txt")
    try Data("user notes\n".utf8).write(to: extra)
    _ = try await f.service.git.run(["add", extra.path], at: f.root)
    try Data("unstaged notes\n".utf8).write(to: extra)
    let opened = await f.service.openWorkspaceWithRecord(f.root, skill: source)
    #expect(opened.result.status == .success && opened.skillError == nil, "\(opened.result.items)")
    #expect(try await changedPaths(f) == [".agents/skills/mono-deck-workflow/agents/openai.yaml"])
    #expect(
      try await f.service.git.run(
        ["show", "HEAD:.agents/skills/mono-deck-workflow/agents/openai.yaml"], at: f.root
      ).stdout == Data(contentsOf: policy))
    #expect(
      try await f.service.git.run(
        ["show", ":.agents/skills/mono-deck-workflow/notes.txt"], at: f.root
      ).stdout == Data("user notes\n".utf8))
    #expect(try Data(contentsOf: extra) == Data("unstaged notes\n".utf8))
    #expect(try await f.service.git.run(["stash", "list"], at: f.root).stdout.isEmpty)
    let head = try await f.service.git.oid("HEAD", at: f.root)
    #expect(await f.service.openWorkspace(f.root, skill: source).status == .success)
    #expect(try await f.service.git.oid("HEAD", at: f.root) == head)
  }

  @Test func conflictingSkillIsKeptAndExcludedFromAutomaticCommit() async throws {
    let f = try await Fixture(createRemote: false)
    defer { f.remove() }
    let path = ".agents/skills/mono-deck-workflow"
    let skill = f.root.appending(path: path)
    try FileManager.default.createDirectory(
      at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("user content".utf8).write(to: skill)
    let source = f.directory.appending(path: "SKILL.md")
    try Data("bundled content".utf8).write(to: source)
    let opened = await f.service.openWorkspaceWithRecord(f.root, skill: source)
    #expect(opened.result.status == .success && opened.skillError?.code == "skill-conflict")
    #expect(try await changedPaths(f) == [".gitignore"])
    #expect(try Data(contentsOf: skill) == Data("user content".utf8))
  }

  @Test func legacySkillLinkIsMigratedAndCommittedWithoutChangingItsTarget() async throws {
    let f = try await Fixture(createRemote: false)
    defer { f.remove() }
    let source = f.directory.appending(path: "SKILL.md")
    let installer = InstallationService(support: f.service.store.support)
    try Data("old skill\n".utf8).write(to: source)
    #expect(
      await f.service.openWorkspace(f.root, skill: source, installer: installer).status == .success)
    let directory = f.root.appending(path: ".agents/skills/mono-deck-workflow")
    let target = installer.support.appending(path: "versions/0.1.0/mono-deck-workflow")
    try FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: directory, to: target)
    try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: target)
    try Data("new skill\n".utf8).write(to: source)
    let opened = await f.service.openWorkspaceWithRecord(
      f.root, skill: source, installer: installer)
    #expect(opened.result.status == .success && opened.skillError == nil, "\(opened.result.items)")
    #expect(try await changedPaths(f) == [".agents/skills/mono-deck-workflow/SKILL.md"])
    #expect(
      try await f.service.git.run(
        ["show", "HEAD:.agents/skills/mono-deck-workflow/SKILL.md"], at: f.root
      ).stdout == Data(contentsOf: source))
    #expect(try await f.service.git.run(["status", "--porcelain"], at: f.root).stdout.isEmpty)
    #expect(!opened.result.items.flatMap(\.effects).contains { $0.action == "stash-workspace" })
    #expect(try Data(contentsOf: target.appending(path: "SKILL.md")) == Data("old skill\n".utf8))
  }

  @Test func skillUpdateRestoresDirtyWorkspaceAndPreservesExistingStashes() async throws {
    let f = try await Fixture(createRemote: false)
    defer { f.remove() }
    let source = try await prepareSkillUpdate(f)
    let savedFile = f.root.appending(path: "already-stashed.txt")
    try Data("previous stash\n".utf8).write(to: savedFile)
    _ = try await f.service.git.run(
      ["stash", "push", "--include-untracked", "-m", "user stash"], at: f.root)
    let previousStashes = try await f.service.git.run(["stash", "list", "--format=%H"], at: f.root)
      .stdout
    let notes = f.root.appending(path: "notes.txt")
    try Data("staged\n".utf8).write(to: notes)
    _ = try await f.service.git.run(["add", "notes.txt"], at: f.root)
    try Data("unstaged\n".utf8).write(to: notes)
    try FileManager.default.removeItem(at: f.root.appending(path: "deleted.txt"))
    try Data("new file\n".utf8).write(to: f.root.appending(path: "untracked file.txt"))
    let ignore = f.root.appending(path: ".gitignore")
    var ignoreData = try Data(contentsOf: ignore)
    ignoreData.append(Data("# user change\n".utf8))
    try ignoreData.write(to: ignore)
    let ignored = f.root.appending(path: "repositories/ignored.txt")
    try Data("ignored resource\n".utf8).write(to: ignored)
    let status = try await f.service.git.run(["status", "--porcelain=v1", "-z"], at: f.root).stdout
    let index = try await f.service.git.run(["show", ":notes.txt"], at: f.root).stdout
    let managedPaths = [
      ".agents/skills/mono-deck-workflow/SKILL.md",
      ".agents/skills/mono-deck-workflow/agents/openai.yaml",
    ]
    for path in managedPaths {
      try Data("staged user customization\n".utf8).write(to: f.root.appending(path: path))
      _ = try await f.service.git.run(["add", "--", path], at: f.root)
      try Data("unstaged user customization\n".utf8).write(to: f.root.appending(path: path))
    }
    let policy = source.deletingLastPathComponent().appending(path: "agents/openai.yaml")
    try Data("new policy\n".utf8).write(to: policy)
    let opened = await f.service.openWorkspaceWithRecord(f.root, skill: source)
    #expect(opened.result.status == .success && opened.skillError == nil, "\(opened.result.items)")
    #expect(try await changedPaths(f) == managedPaths)
    #expect(
      try Data(contentsOf: f.root.appending(path: managedPaths[0])) == Data(contentsOf: source))
    #expect(
      try Data(contentsOf: f.root.appending(path: managedPaths[1])) == Data(contentsOf: policy))
    #expect(
      try await f.service.git.run(["status", "--porcelain=v1", "-z"], at: f.root).stdout == status)
    #expect(try await f.service.git.run(["show", ":notes.txt"], at: f.root).stdout == index)
    #expect(try Data(contentsOf: notes) == Data("unstaged\n".utf8))
    #expect(try Data(contentsOf: ignore) == ignoreData)
    #expect(try Data(contentsOf: ignored) == Data("ignored resource\n".utf8))
    #expect(
      try await f.service.git.run(["stash", "list", "--format=%H"], at: f.root).stdout
        == previousStashes)
    #expect(opened.result.items.flatMap(\.effects).contains { $0.action == "restore-workspace" })
  }

  @Test func failedSkillCommitStillRestoresWorkspaceChanges() async throws {
    let f = try await Fixture(createRemote: false)
    defer { f.remove() }
    let source = try await prepareSkillUpdate(f)
    let notes = f.root.appending(path: "notes.txt")
    try Data("staged\n".utf8).write(to: notes)
    _ = try await f.service.git.run(["add", "notes.txt"], at: f.root)
    try Data("unstaged\n".utf8).write(to: notes)
    let skillPath = ".agents/skills/mono-deck-workflow/SKILL.md"
    try Data("user customization\n".utf8).write(to: f.root.appending(path: skillPath))
    _ = try await f.service.git.run(["add", "--", skillPath], at: f.root)
    let head = try await f.service.git.oid("HEAD", at: f.root)
    try await failSigning(f)
    let opened = await f.service.openWorkspaceWithRecord(f.root, skill: source)
    #expect(
      opened.result.items.first?.reasonCode == "workspace-commit-failed", "\(opened.result.items)")
    #expect(opened.record == nil)
    #expect(try await f.service.git.oid("HEAD", at: f.root) == head)
    #expect(
      try Data(contentsOf: f.root.appending(path: ".agents/skills/mono-deck-workflow/SKILL.md"))
        == Data(contentsOf: source))
    #expect(
      try await f.service.git.run(["show", ":notes.txt"], at: f.root).stdout
        == Data("staged\n".utf8))
    #expect(try Data(contentsOf: notes) == Data("unstaged\n".utf8))
    #expect(try await f.service.git.run(["stash", "list"], at: f.root).stdout.isEmpty)
  }

  @Test func failedStashDoesNotOverwriteSkill() async throws {
    let f = try await Fixture(createRemote: false)
    defer { f.remove() }
    let source = try await prepareSkillUpdate(f)
    try Data("untracked\n".utf8).write(to: f.root.appending(path: "new.txt"))
    let lock = f.root.appending(path: ".git/index.lock")
    try Data().write(to: lock)
    let opened = await f.service.openWorkspaceWithRecord(f.root, skill: source)
    #expect(opened.result.items.first?.reasonCode == "workspace-stash-failed")
    #expect(
      try Data(contentsOf: f.root.appending(path: ".agents/skills/mono-deck-workflow/SKILL.md"))
        == Data("old skill\n".utf8))
    #expect(try Data(contentsOf: f.root.appending(path: "new.txt")) == Data("untracked\n".utf8))
    #expect(!opened.result.items.flatMap(\.effects).contains { $0.action == "install-skill" })
  }

  @Test func differingSkillWithoutHeadUsesIsolatedInitialCommit() async throws {
    let f = try await Fixture(createRemote: false)
    defer { f.remove() }
    let source = f.directory.appending(path: "SKILL.md")
    let path = ".agents/skills/mono-deck-workflow/SKILL.md"
    let skill = f.root.appending(path: path)
    try FileManager.default.createDirectory(
      at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("old skill\n".utf8).write(to: skill)
    try Data("new skill\n".utf8).write(to: source)
    _ = try await f.service.git.run(["init"], at: f.root)
    try Data("user content\n".utf8).write(to: f.root.appending(path: "notes.txt"))
    _ = try await f.service.git.run(["add", "notes.txt"], at: f.root)
    let opened = await f.service.openWorkspaceWithRecord(f.root, skill: source)
    #expect(opened.result.status == .success && opened.skillError == nil)
    #expect(try Data(contentsOf: skill) == Data(contentsOf: source))
    #expect(try await changedPaths(f) == [path, ".gitignore"])
    #expect(
      try await f.service.git.run(["diff", "--cached", "--name-only"], at: f.root).text
        == "notes.txt")
  }

  @Test func cancellationDuringSkillUpdateStillCommitsAndRestoresStash() async throws {
    let f = try await Fixture(createRemote: false)
    defer { f.remove() }
    let source = try await prepareSkillUpdate(f)
    let notes = f.root.appending(path: "notes.txt")
    try Data("user change\n".utf8).write(to: notes)
    let opened = await Task {
      await f.service.openWorkspaceWithRecord(f.root, skill: source) { value in
        if value.phase == .saving { withUnsafeCurrentTask { $0?.cancel() } }
      }
    }.value
    #expect(opened.result.status == .success, "\(opened.result.items)")
    #expect(try await changedPaths(f) == [".agents/skills/mono-deck-workflow/SKILL.md"])
    #expect(try Data(contentsOf: notes) == Data("user change\n".utf8))
    #expect(try await f.service.git.run(["stash", "list"], at: f.root).stdout.isEmpty)
  }

  @Test func initializationCommitFailureKeepsFilesAndCanBeRetried() async throws {
    let f = try await Fixture(createRemote: false)
    defer { f.remove() }
    _ = try await f.service.git.run(["init"], at: f.root)
    try await failSigning(f)
    let source = f.directory.appending(path: "SKILL.md")
    try Data("# Workflow\n".utf8).write(to: source)
    let opened = await f.service.openWorkspaceWithRecord(f.root, skill: source)
    #expect(opened.result.items.first?.reasonCode == "workspace-commit-failed")
    #expect(opened.record == nil && opened.result.status == .failed)
    #expect(PathSafety.exists(f.service.store.recordURL(f.root)))
    #expect(try await f.service.git.oid("HEAD", at: f.root) == nil)
    #expect(PathSafety.exists(f.root.appending(path: ".agents/skills/mono-deck-workflow/SKILL.md")))
    _ = try await f.service.git.run(["config", "commit.gpgSign", "false"], at: f.root)
    #expect(await f.service.openWorkspace(f.root, skill: source).status == .success)
    #expect(
      try await changedPaths(f) == [".agents/skills/mono-deck-workflow/SKILL.md", ".gitignore"])
  }

  @Test func repositoryCommitFailureKeepsRepositoryAndRetryOnlyCommitsIgnore() async throws {
    let f = try await Fixture()
    defer { f.remove() }
    try await f.prepareWorkspace()
    let head = try await f.service.git.oid("HEAD", at: f.root)
    try await failSigning(f)
    let added = await f.service.addRepository(.init(url: f.remoteURL), at: f.root)
    #expect(added.items.first?.reasonCode == "workspace-commit-failed")
    #expect(added.items.first?.data?["disposition"] == "added")
    #expect(try f.service.store.load(f.root).repositories.map(\.id) == ["repo"])
    #expect(PathSafety.exists(f.root.appending(path: "repositories/repo")))
    #expect(try await f.service.git.oid("HEAD", at: f.root) == head)
    _ = try await f.service.git.run(["config", "commit.gpgSign", "false"], at: f.root)
    let retried = await f.service.addRepository(.init(url: f.remoteURL), at: f.root)
    #expect(
      retried.status == .success && retried.items.first?.data?["disposition"] == "already-exists")
    #expect(retried.items.first?.effects.map(\.action) == ["commit-workspace-files"])
    #expect(try await changedPaths(f) == [".gitignore"])
    let committed = try await f.service.git.oid("HEAD", at: f.root)
    #expect(await f.service.addRepository(.init(url: f.remoteURL), at: f.root).status == .success)
    #expect(try await f.service.git.oid("HEAD", at: f.root) == committed)
  }

  @Test func workspaceImportClonesAllRepositoriesThenCommitsOnceBeforeGroups() async throws {
    let f = try await Fixture()
    defer { f.remove() }
    try await f.prepareWorkspace()
    let other = "https://mono-deck-test.invalid/other.git"
    _ = try await f.service.git.run(
      [
        "config", "--global", "--add",
        "url.\(f.directory.appending(path: "repo.git").path).insteadOf", other,
      ], at: f.root)
    let trace = f.directory.appending(path: "trace")
    var runner = f.service.git.runner
    runner.environment["GIT_TRACE"] = trace.path
    let service = WorkspaceService(
      store: f.service.store, git: Git(runner: runner), trash: f.service.trashDirectory)
    let result = await service.importWorkspaceYAML(workspaceYAML(f, other: other), at: f.root)
    #expect(result.status == .success, "\(result.items)")
    #expect(
      try await f.service.git.run(["show", "--no-patch", "--format=%B", "HEAD"], at: f.root).text
        == "chore: import MonoDeck workspace repositories\n\nAuto-committed-by: MonoDeck")
    #expect(try await f.service.git.run(["rev-list", "--count", "HEAD"], at: f.root).text == "2")
    #expect(try await changedPaths(f) == [".gitignore"])
    let commands = try String(contentsOf: trace, encoding: .utf8).components(separatedBy: "\n")
      .filter { $0.contains("built-in: git ") }
    let clones = commands.indices.filter { commands[$0].contains("git clone ") }
    let commits = commands.indices.filter { commands[$0].contains("git commit --only ") }
    let worktrees = commands.indices.filter { commands[$0].contains("git worktree add ") }
    #expect(clones.count == 2 && commits.count == 1)
    #expect(try #require(clones.last) < #require(commits.first))
    #expect(try #require(commits.first) < #require(worktrees.first))
    let record = try f.service.store.load(f.root)
    #expect(record.groups["feature"]?.repositoryIDs == ["repo", "other"])
    #expect(
      try await f.service.git.oid("HEAD", at: record.groupURL("feature"))
        == f.service.git.oid("HEAD", at: f.root))
    #expect(try await f.service.git.changes(at: record.groupURL("feature")).isEmpty)
  }

  enum ImportIgnoreState: CaseIterable {
    case missingRule, stagedRule, committedRule
  }

  @Test(arguments: ImportIgnoreState.allCases)
  func workspaceImportRequiresLocalBranchOnlyWhenIgnoreNeedsCommit(_ ignoreState: ImportIgnoreState)
    async throws
  {
    let f = try await Fixture()
    defer { f.remove() }
    try await f.prepareWorkspace()
    let git = f.service.git
    if ignoreState != .missingRule {
      try #require(await git.ensureIgnore(["repo"], at: f.root))
      if ignoreState == .committedRule {
        try await f.commitWorkspace()
      } else {
        _ = try await git.run(["add", "--", ".gitignore"], at: f.root)
      }
    }
    let branch = try await git.run(["symbolic-ref", "--short", "HEAD"], at: f.root).text
    let head = try await git.oid("HEAD", at: f.root)
    _ = try await git.run(["switch", "--detach"], at: f.root)
    let before = try f.service.store.load(f.root)
    let ignore = f.root.appending(path: ".gitignore")
    let originalIgnore = try Data(contentsOf: ignore)
    let originalStatus = try await git.run(["status", "--porcelain"], at: f.root).stdout
    let repositories = before.repositoryDirectoryURL("repo").deletingLastPathComponent()
    let originalEntries = try FileManager.default.contentsOfDirectory(atPath: repositories.path)
    let yaml = workspaceYAML(f)

    let result = await f.service.importWorkspaceYAML(yaml, at: f.root)

    if ignoreState == .committedRule {
      #expect(result.status == .success, "\(result)")
      #expect(try await git.oid("HEAD", at: f.root) == head)
    } else {
      #expect(result.status == .failed, "\(result)")
      #expect(
        result.reasonCode == "workspace-branch-required"
          || result.items.contains { $0.reasonCode == "workspace-branch-required" })
      #expect(try f.service.store.load(f.root) == before)
      #expect(
        try Set(FileManager.default.contentsOfDirectory(atPath: repositories.path))
          == Set(originalEntries))
      #expect(!PathSafety.exists(before.groupURL("feature")))
      #expect(try Data(contentsOf: ignore) == originalIgnore)
      #expect(try await git.run(["status", "--porcelain"], at: f.root).stdout == originalStatus)
      #expect(try await git.oid("HEAD", at: f.root) == head)

      _ = try await git.run(["switch", branch], at: f.root)
      let retried = await f.service.importWorkspaceYAML(yaml, at: f.root)
      #expect(retried.status == .success, "\(retried)")
      #expect(try await changedPaths(f) == [".gitignore"])
      #expect(try await git.oid("HEAD", at: f.root) != head)
    }
    let record = try f.service.store.load(f.root)
    #expect(record.repositories.map(\.id) == ["repo"])
    #expect(record.groups["feature"]?.repositoryIDs == ["repo"])
    #expect(try await git.run(["status", "--porcelain"], at: f.root).stdout.isEmpty)
  }

  @Test func workspaceImportCommitFailureKeepsRepositoriesAndRetryCommitsBeforeGroups() async throws
  {
    let f = try await Fixture()
    defer { f.remove() }
    try await f.prepareWorkspace()
    let head = try await f.service.git.oid("HEAD", at: f.root)
    try await failSigning(f)
    let yaml = workspaceYAML(f)
    let result = await f.service.importWorkspaceYAML(yaml, at: f.root)
    #expect(result.status == .partialSuccess)
    #expect(
      result.items.contains {
        $0.resource.kind == .workspace && $0.reasonCode == "workspace-commit-failed"
      })
    #expect(
      result.items.filter { [.group, .member].contains($0.resource.kind) }.allSatisfy {
        $0.reasonCode == "not-processed"
      })
    #expect(try f.service.store.load(f.root).repositories.map(\.id) == ["repo"])
    #expect(try f.service.store.load(f.root).groups.isEmpty)
    #expect(!PathSafety.exists(f.root.appending(path: "worktrees/feature")))
    #expect(
      try String(contentsOf: f.root.appending(path: ".gitignore"), encoding: .utf8).contains(
        "/repo/"))
    #expect(try await f.service.git.oid("HEAD", at: f.root) == head)

    _ = try await f.service.git.run(["config", "commit.gpgSign", "false"], at: f.root)
    let note = Data("keep this staged\n".utf8)
    try note.write(to: f.root.appending(path: "notes.txt"))
    _ = try await f.service.git.run(["add", "--", "notes.txt"], at: f.root)
    let ignore = f.root.appending(path: ".gitignore")
    let ignoreWithManualEdit = try Data(contentsOf: ignore) + Data("# private edits\n".utf8)
    try ignoreWithManualEdit.write(to: ignore)
    let service = WorkspaceService(store: f.service.store, git: f.service.git)
    let retried = await service.importWorkspaceYAML(yaml, at: f.root)
    #expect(retried.status == .success, "\(retried.items)")
    #expect(retried.items.first?.data?["disposition"] == "already-exists")
    #expect(retried.items.first?.effects.isEmpty == true)
    let commits = retried.items.flatMap(\.effects).filter { $0.action == "commit-workspace-files" }
    #expect(commits.count == 1)
    #expect(try await changedPaths(f) == [".gitignore"])
    #expect(
      try await f.service.git.run(["show", "HEAD:.gitignore"], at: f.root).stdout
        == ignoreWithManualEdit)
    #expect(try await f.service.git.run(["show", ":notes.txt"], at: f.root).stdout == note)
    let record = try f.service.store.load(f.root)
    #expect(record.groups["feature"]?.repositoryIDs == ["repo"])
    let committed = try await f.service.git.oid("HEAD", at: f.root)
    #expect(committed != head)
    #expect(try await f.service.git.oid("HEAD", at: record.groupURL("feature")) == committed)
  }

  @Test(arguments: [false, true])
  func cancelledWorkspaceImportFinishesIgnoreCommitAndStopsPendingGroups(_ hasGroups: Bool)
    async throws
  {
    let f = try await Fixture()
    defer { f.remove() }
    try await f.prepareWorkspace()
    let yaml =
      hasGroups
      ? workspaceYAML(f) : "version: 2\nrepositories: [{url: \(f.remoteURL)}]\ngroups: {}\n"
    let result = await Task {
      await f.service.importWorkspaceYAML(yaml, at: f.root) { value in
        if value.phase == .added { withUnsafeCurrentTask { $0?.cancel() } }
      }
    }.value
    #expect(result.status.rawValue == (hasGroups ? "cancelled" : "success"))
    #expect(
      try await f.service.git.run(["show", "HEAD:.gitignore"], at: f.root).text.contains("/repo/"))
    #expect(try f.service.store.load(f.root).groups.isEmpty)
    if hasGroups {
      #expect(
        result.items.filter { [.group, .member].contains($0.resource.kind) }.allSatisfy {
          $0.reasonCode == "not-processed"
        })
    }
  }

  @Test(arguments: [false, true])
  func repositoryYAMLStopsAfterAutomaticCommitFailure(_ alreadyExists: Bool) async throws {
    let f = try await Fixture()
    defer { f.remove() }
    try await f.prepareWorkspace()
    if alreadyExists {
      #expect(await f.service.addRepository(.init(url: f.remoteURL), at: f.root).status == .success)
      let file = f.root.appending(path: ".gitignore")
      var contents = try Data(contentsOf: file)
      contents.append(Data("# pending change\n".utf8))
      try contents.write(to: file)
    }
    try await failSigning(f)
    let result = await f.service.importRepositories(
      [f.remoteURL, "https://mono-deck-test.invalid/other.git"], at: f.root)
    #expect(result.items.first?.reasonCode == "workspace-commit-failed")
    #expect(result.items.last?.reasonCode == "not-processed")
    #expect(try f.service.store.load(f.root).repositories.map(\.id) == ["repo"])
  }

  @Test func automaticCommitsDoNotRunHooksThatCouldAddOtherFiles() async throws {
    let f = try await Fixture(createRemote: false)
    defer { f.remove() }
    _ = try await f.service.git.run(["init"], at: f.root)
    let hook = f.root.appending(path: ".git/hooks/pre-commit")
    try Data("#!/bin/sh\nprintf 'extra' > extra.txt\ngit add extra.txt\n".utf8).write(to: hook)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    #expect(await f.service.openWorkspace(f.root).status == .success)
    #expect(try await changedPaths(f) == [".gitignore"])
    #expect(!PathSafety.exists(f.root.appending(path: "extra.txt")))
  }

  private func prepareSkillUpdate(_ f: Fixture) async throws -> URL {
    let source = f.directory.appending(path: "SKILL.md")
    try Data("old skill\n".utf8).write(to: source)
    let policy = f.directory.appending(path: "agents/openai.yaml")
    try FileManager.default.createDirectory(
      at: policy.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("old policy\n".utf8).write(to: policy)
    #expect(await f.service.openWorkspace(f.root, skill: source).status == .success)
    for name in ["notes.txt", "deleted.txt"] {
      try Data("original\n".utf8).write(to: f.root.appending(path: name))
    }
    _ = try await f.service.git.run(["add", "notes.txt", "deleted.txt"], at: f.root)
    _ = try await f.service.git.run(["commit", "-m", "user files"], at: f.root)
    try Data("new skill\n".utf8).write(to: source)
    return source
  }

  private func changedPaths(_ f: Fixture) async throws -> [String] {
    try await f.service.git.run(
      ["diff-tree", "--root", "--no-commit-id", "-r", "--name-only", "HEAD"], at: f.root
    ).text.components(separatedBy: "\n")
  }

  private func failSigning(_ f: Fixture) async throws {
    _ = try await f.service.git.run(["config", "commit.gpgSign", "true"], at: f.root)
    _ = try await f.service.git.run(["config", "gpg.program", "/usr/bin/false"], at: f.root)
  }

  private func workspaceYAML(_ f: Fixture, other: String? = nil) -> String {
    """
    version: 2
    repositories:
      - url: \(f.remoteURL)
    \(other.map { "  - url: \($0)\n" } ?? "")groups:
      feature:
        branch-name: feature
        repository-ids: [repo\(other == nil ? "" : ", other")]
    """
  }
}
