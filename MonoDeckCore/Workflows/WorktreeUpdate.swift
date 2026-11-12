import Foundation

extension WorkspaceService {
  public func updateWorktrees(at root: URL, progress: ProgressHandler = { _ in }) async
    -> OperationResult
  {
    var result = OperationResult(command: "worktree.update", workspace: root.path)
    do {
      let lease = try await store.lock(root)
      defer { lease.unlock() }
      let record = try store.load(root)
      let targets = resources(record).filter { $0.kind == .group || $0.kind == .member }
      var offlineGit = git
      offlineGit.runner.environment["GIT_NO_LAZY_FETCH"] = "1"
      offlineGit.runner.environment["GIT_ALLOW_PROTOCOL"] = ""
      let updater = WorkspaceService(store: store, git: offlineGit, trash: trashDirectory)
      result.items = await updater.updateWorktrees(targets, in: record, progress: progress)
      result.summarize(
        cancelled: Task.isCancelled || result.items.contains { $0.status == .cancelled })
    } catch {
      result = .init(
        command: result.command, workspace: root.path, status: .failed, error: .wrap(error))
    }
    return result
  }

  private func updateWorktrees(
    _ targets: [Resource], in record: WorkspaceRecord, progress: ProgressHandler
  ) async -> [ItemResult] {
    var items: [ItemResult?] = targets.map { ItemResult.notProcessed($0) }
    // Worktrees of one repository share refs and Git metadata.
    var queues = Dictionary(grouping: targets.indices, by: { targets[$0].repositoryID ?? "" })
      .values.sorted { $0[0] < $1[0] }.map { $0[...] }
    progress(.init("", .updatingWorktrees, total: targets.count))
    await withTaskGroup(of: (Int, Int, ItemResult?).self) { group in
      func enqueue(_ queue: Int) {
        guard let index = queues[queue].popFirst() else { return }
        _ = group.addTaskUnlessCancelled {
          (queue, index, await updateWorktree(targets[index], in: record))
        }
      }
      let initial = min(6, queues.count)
      for queue in 0..<initial { enqueue(queue) }
      var next = initial
      var completed = 0
      while let (queue, index, item) = await group.next() {
        items[index] = item
        completed += 1
        progress(
          .init(targets[index].path, .updatingWorktrees, completed: completed, total: targets.count)
        )
        guard !Task.isCancelled else { continue }
        if !queues[queue].isEmpty {
          enqueue(queue)
        } else if next < queues.count {
          enqueue(next)
          next += 1
        }
      }
    }
    return items.compactMap { $0 }
  }

  private func updateWorktree(_ resource: Resource, in record: WorkspaceRecord) async -> ItemResult?
  {
    var item = ItemResult(resource)
    item.data = [:]
    do {
      try checkCancellation()
      let repository = try await checkedRepository(for: resource, in: record)
      let context = try await prepareResourceRead(resource, in: record, repository: repository)
      let state = try await worktreeUpdateState(context)
      item.data?["branch"] = state.branch.map { String($0.dropFirst("refs/heads/".count)) }
      let base = try await worktreeUpdateBase(
        repository.mainWorktreeURL, isGroupRoot: resource.kind == .group)
      item.data?["base"] = base?.name
      let head = try state.checkedHead()
      guard let base else {
        throw WorktreeUpdateSkip("base-unavailable", .worktreeUpdateBaseUnavailable)
      }

      if try await isUpdateAncestor(base.oid, of: head, at: context.path) {
        return nil
      }
      guard try await isUpdateAncestor(head, of: base.oid, at: context.path) else {
        throw WorktreeUpdateSkip("not-fast-forward", .worktreeUpdateCannotFastForward)
      }
      if let group = resource.groupName, resource.kind == .group {
        try await git.checkRootCommit(
          base.oid, repositoryIDs: record.groups[group]?.repositoryIDs ?? [],
          at: repository.mainWorktreeURL)
      }
      try await fastForwardWorktree(context, from: state, to: base, in: repository, item: &item)
    } catch let skip as WorktreeUpdateSkip {
      item.status = .skipped
      item.reasonCode = skip.error.code
      item.message = skip.error.message
      item.userMessage = skip.error.userMessage
    } catch {
      fail(&item, error)
    }
    return item
  }

  private func fastForwardWorktree(
    _ context: ResourceReadContext, from state: WorktreeUpdateState, to base: WorktreeUpdateBase,
    in repository: RepositoryInspection, item: inout ItemResult
  ) async throws {
    let path = context.path
    let record = context.workspace
    let changed = WorktreeUpdateSkip("worktree-changed", .worktreeChangedDuringUpdate)
    guard context.isValid(in: record) else { throw changed }
    let current = try await checkedRepository(for: context.resource, in: record)
    guard current.commonDirectory == repository.commonDirectory else { throw changed }
    try await checkWorktree(context.resource, at: path, repository: current, validateHEAD: false)
    if let branch = state.branch {
      let pathIdentity = PathSafety.identity(path)
      let registrationPath = current.registrations.first {
        PathSafety.identity(URL(fileURLWithPath: $0.path)) == pathIdentity
      }?.path
      do {
        try await git.checkBranchNotInUse(
          String(branch.dropFirst("refs/heads/".count)), registrations: current.registrations,
          at: current.mainWorktreeURL, excluding: registrationPath,
          commonDirectory: current.commonDirectory)
      } catch let error as MonoDeckError where error.code == "branch-in-use" {
        throw WorktreeUpdateSkip(error.code, error.userMessage)
      }
    }
    let currentBase = try await worktreeUpdateBase(
      current.mainWorktreeURL, isGroupRoot: context.resource.kind == .group)
    let latest = try await worktreeUpdateState(context)
    _ = try latest.checkedHead()
    guard latest.branch == state.branch, latest.head == state.head, currentBase == base,
      context.isValid(in: record)
    else {
      throw changed
    }
    try checkCancellation()

    item.effects.append(.init("fast-forward", path.path, state: "unknown"))
    do {
      _ = try await git.run(
        [
          "-c", "submodule.recurse=false", "merge", "--ff-only", "--no-autostash",
          "--no-overwrite-ignore", base.oid,
        ], at: path, cancellable: false)
      guard context.isValid(in: record),
        try await git.oid("HEAD", at: path, cancellable: false) == base.oid
      else {
        throw MonoDeckError("worktree-changed", .worktreeChangedDuringUpdate)
      }
      item.effects[0].state = "applied"
      item.data?["disposition"] = "updated"
    } catch {
      if context.isValid(in: record) {
        item.data?["actual-head"] = try? await git.oid("HEAD", at: path, cancellable: false)
        let status = try? await git.run(
          ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=none"],
          at: path, cancellable: false)
        if let status { item.data?["working-tree"] = status.stdout.isEmpty ? "clean" : "dirty" }
      }
      throw error
    }
  }

  private func worktreeUpdateState(_ context: ResourceReadContext) async throws
    -> WorktreeUpdateState
  {
    let status = try await git.run(
      [
        "status", "--porcelain=v2", "--branch", "--no-ahead-behind",
        "-z", "--untracked-files=normal", "--ignore-submodules=none",
      ], at: context.path)
    let state = try Git.parseWorkingState(status.stdout)
    let ref = try await git.run(
      ["symbolic-ref", "--quiet", "HEAD"], at: context.path, allowFailure: true)
    guard ref.status == 0 || ref.status == 1 else {
      throw worktreeUpdateGitFailure("symbolic-ref", ref)
    }
    let branch = ref.status == 0 && ref.text.hasPrefix("refs/heads/") ? ref.text : nil
    let operationInProgress = [
      "MERGE_HEAD", "rebase-merge", "rebase-apply", "CHERRY_PICK_HEAD",
      "REVERT_HEAD", "sequencer", "BISECT_START",
    ].contains {
      PathSafety.exists(context.gitDirectory.appending(path: $0))
    }
    return .init(
      branch: branch, head: state.headOID, dirty: !state.changes.isEmpty,
      operationInProgress: operationInProgress)
  }

  private func worktreeUpdateBase(_ repository: URL, isGroupRoot: Bool) async throws
    -> WorktreeUpdateBase?
  {
    let prefix = "refs/remotes/origin/"
    let reference = prefix + "HEAD"
    let existence = try await git.run(
      ["show-ref", "--exists", reference], at: repository, allowFailure: true)
    let ref: String
    switch existence.status {
    case 0:
      let target = try await git.run(
        ["symbolic-ref", "--quiet", reference], at: repository, allowFailure: true)
      guard target.status == 0, target.text.hasPrefix(prefix), target.text != reference else {
        return nil
      }
      ref = target.text
    case 2 where isGroupRoot:
      guard let branch = try await git.checkedOutLocalBranchRef(at: repository) else { return nil }
      ref = branch
    case 1, 2: return nil
    default: throw worktreeUpdateGitFailure("show-ref", existence)
    }
    guard let oid = try await git.oid(ref, at: repository) else { return nil }
    let namespace = ref.hasPrefix(prefix) ? "refs/remotes/" : "refs/heads/"
    return .init(ref: ref, name: String(ref.dropFirst(namespace.count)), oid: oid)
  }

  private func isUpdateAncestor(_ ancestor: String, of descendant: String, at path: URL)
    async throws -> Bool
  {
    let output = try await git.run(
      ["merge-base", "--is-ancestor", ancestor, descendant], at: path, allowFailure: true)
    switch output.status {
    case 0: return true
    case 1: return false
    default: throw worktreeUpdateGitFailure("merge-base", output)
    }
  }

  private func worktreeUpdateGitFailure(_ command: String, _ output: CommandOutput) -> MonoDeckError
  {
    let diagnostic = Git.sanitize(String(decoding: output.stderr, as: UTF8.self))
    return MonoDeckError(
      "git-failed", .gitFailed(command, Int(output.status), .diagnostic(diagnostic)))
  }
}

private struct WorktreeUpdateState {
  let branch: String?
  let head: String?
  let dirty: Bool
  let operationInProgress: Bool

  func checkedHead() throws -> String {
    if operationInProgress {
      throw WorktreeUpdateSkip("git-operation-in-progress", .worktreeUpdateOperationInProgress)
    }
    if dirty { throw WorktreeUpdateSkip("working-tree-dirty", .workingTreeHasChanges) }
    guard branch != nil else { throw WorktreeUpdateSkip("detached-head", .detachedHEAD) }
    guard let head else { throw MonoDeckError("resource-unavailable", .headIsUnavailable) }
    return head
  }
}

private struct WorktreeUpdateBase: Equatable {
  let ref: String
  let name: String
  let oid: String
}

private struct WorktreeUpdateSkip: Error {
  let error: MonoDeckError

  init(_ code: String, _ message: UserMessage) { error = .init(code, message) }
}
