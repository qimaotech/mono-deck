import Foundation

struct WorktreeCreation {
  var resource: Resource
  var mainWorktreeURL: URL
  var destination: URL
  var oid: String
  var branch: String
  var reused: Bool
  var upstream: String?
  var fallbackRef: String?
  var reuseWarning: (message: String, userMessage: UserMessage?, data: [String: String])?
}

private struct WorktreeCreationAttempt {
  var branchAttempted = false
  var branchCreated = false
  var worktreeAttempted = false
  var gitDirectory: RepositoryDirectory?
  var worktreeDirectory: RepositoryDirectory?
}

extension WorkspaceService {
  public func createGroup(
    _ groupName: String, branchName: String? = nil, repositoryIDs: [String], at root: URL,
    expectedRepositories: [Repository]? = nil, dryRun: Bool = false,
    progress: ProgressHandler = { _ in }
  ) async -> OperationResult {
    if dryRun {
      return await previewGroupChange(
        groupName, repositoryIDs: repositoryIDs, root: root, change: .create,
        branchName: branchName, expectedRepositories: expectedRepositories)
    }
    return await changeGroup(
      groupName, repositoryIDs: repositoryIDs, root: root, change: .create, authorization: nil,
      branchName: branchName, expectedRepositories: expectedRepositories, progress: progress)
  }
  public func addGroupMembers(
    _ groupName: String, repositoryIDs: [String], at root: URL, dryRun: Bool = false,
    progress: ProgressHandler = { _ in }
  ) async -> OperationResult {
    if dryRun {
      return await previewGroupChange(
        groupName, repositoryIDs: repositoryIDs, root: root, change: .addMembers)
    }
    return await changeGroup(
      groupName, repositoryIDs: repositoryIDs, root: root, change: .addMembers, authorization: nil,
      progress: progress)
  }
  public func editGroup(
    _ groupName: String, repositoryIDs: [String], at root: URL,
    authorization: [DeletionTarget]? = nil, dryRun: Bool = false,
    progress: ProgressHandler = { _ in }
  ) async -> OperationResult {
    if dryRun {
      return await previewGroupChange(
        groupName, repositoryIDs: repositoryIDs, root: root, change: .edit)
    }
    return await changeGroup(
      groupName, repositoryIDs: repositoryIDs, root: root, change: .edit,
      authorization: authorization, progress: progress)
  }

  func createImportedGroup(
    _ name: String, branchName: String, repositoryIDs: [String], record: inout WorkspaceRecord,
    progress: ProgressHandler
  ) async -> [ItemResult] {
    let resources =
      [Resource.group(name)]
      + repositoryIDs.map { Resource.member(groupName: name, repositoryID: $0) }
    var items = resources.map(ItemResult.notProcessed)
    var existing: [Int: RepositoryDirectory] = [:]
    var creations: [(index: Int, plan: WorktreeCreation, attempt: WorktreeCreationAttempt)] = []
    var failedIndex = 0
    do {
      progress(.init(resources[0].path, .checkingRepository))
      try checkCancellation()
      try validateGroupChange(.create, groupName: name, record: record)
      try await validateMembers(
        name, branchName: branchName, repositoryIDs: repositoryIDs, record: record)
      for (index, resource) in resources.enumerated()
      where PathSafety.exists(record.rootURL.appending(path: resource.path)) {
        failedIndex = index
        existing[index] = try await checkedImportedWorktree(
          resource, branchName: branchName, in: record)
      }
      let missingRepositoryIDs = resources.indices.filter { existing[$0] == nil }.compactMap {
        resources[$0].repositoryID
      }
      if let root = existing[0], !missingRepositoryIDs.isEmpty {
        failedIndex = 0
        guard let head = try await git.oid("HEAD", at: root.url) else {
          throw MonoDeckError("resource-unavailable", .groupRootHEADIsUnavailable)
        }
        try await git.checkRootCommit(head, repositoryIDs: missingRepositoryIDs, at: record.rootURL)
      }
      for index in resources.indices where existing[index] == nil {
        failedIndex = index
        let plan: WorktreeCreation
        if let repositoryID = resources[index].repositoryID {
          plan = try await memberCreationPlan(
            name, branchName: branchName, repositoryID: repositoryID, record: record)
        } else {
          plan = try await rootCreationPlan(
            name, branchName: branchName, repositoryIDs: repositoryIDs, record: record,
            preferRemoteBranch: true
          )
        }
        creations.append((index, plan, .init()))
      }
      for position in creations.indices {
        let (index, plan, _) = creations[position]
        failedIndex = index
        try await applyCreation(
          plan, attempt: &creations[position].attempt, forImport: true, progress: progress,
          completed: max(0, index - 1), total: repositoryIDs.count)
        items[index] = completedCreation(plan)
        if let fallback = plan.fallbackRef {
          let warning = UserMessage.importedBranchUsesFallback(fallback)
          items[index].message = warning.englishDescription
          items[index].userMessage = warning
          items[index].data = [
            "warning-code": "import-branch-fallback", "start-ref": fallback, "start-oid": plan.oid,
          ]
        }
      }
      failedIndex = 0
      progress(.init(resources[0].path, .saving, cancellable: false))
      try checkCancellation()
      for index in resources.indices {
        if let directory = existing[index] {
          failedIndex = index
          _ = try await checkedImportedWorktree(
            resources[index], branchName: branchName, in: record, existing: directory)
        }
      }
      for creation in creations {
        failedIndex = creation.index
        try creation.attempt.gitDirectory?.validate()
        try creation.attempt.worktreeDirectory?.validate()
      }
      try checkCancellation()
      failedIndex = 0
      var candidate = record
      candidate.groups[name] = WorktreeGroup(branchName: branchName, repositoryIDs: repositoryIDs)
      do { try persist(candidate, into: &record) } catch {
        let failure = MonoDeckError.wrap(error)
        guard failure.code == "save-outcome-unknown" || record.groups[name] != nil else {
          throw failure
        }
        for index in existing.keys { items[index] = reusedImportedWorktree(resources[index]) }
        fail(&items[0], failure)
        items[0].effects.append(.init("save-workspace-record", resources[0].path, state: "unknown"))
        return items
      }
      for index in existing.keys { items[index] = reusedImportedWorktree(resources[index]) }
      items[0].effects.append(.init("save-workspace-record", resources[0].path))
      progress(
        .init(
          resources[0].path, .created, completed: repositoryIDs.count, total: repositoryIDs.count,
          snapshot: record))
    } catch {
      let failure = MonoDeckError.wrap(error)
      if items[failedIndex].effects.isEmpty,
        let creation = creations.first(where: { $0.index == failedIndex })
      {
        let attempt = creation.attempt
        if attempt.worktreeAttempted {
          items[failedIndex].effects.append(
            .init(
              "create-worktree", creation.plan.destination.path,
              state: attempt.worktreeDirectory == nil ? "unknown" : "applied"))
        }
        if attempt.branchAttempted {
          items[failedIndex].effects.append(
            .init(
              "create-branch", creation.plan.branch,
              state: attempt.branchCreated ? "applied" : "unknown"))
        }
      }
      fail(&items[failedIndex], failure)
      if failure.code == "import-worktree-mismatch" { items[failedIndex].status = .skipped }
    }
    return items
  }

  private func checkedImportedWorktree(
    _ resource: Resource, branchName: String, in record: WorkspaceRecord,
    existing: RepositoryDirectory? = nil
  ) async throws -> RepositoryDirectory {
    let mismatch = MonoDeckError(
      "import-worktree-mismatch", .importedWorktreeDoesNotMatch(resource.path, branchName))
    do {
      let path = try PathSafety.child(resource.path, of: record.rootURL, allowMissing: false)
      let directory = try existing ?? RepositoryDirectory(path)
      try directory.validate()
      guard
        try FileManager.default.attributesOfItem(atPath: path.appending(path: ".git").path)[.type]
          as? FileAttributeType == .typeRegular
      else { throw mismatch }
      let repository: RepositoryInspection
      if let id = resource.repositoryID {
        repository = try await checkedRepository(for: .repository(id), in: record)
      } else {
        repository = try await inspectRepository(atMainWorktree: record.rootURL)
      }
      try await checkWorktree(resource, at: path, repository: repository)
      let current = try await git.run(
        ["symbolic-ref", "--quiet", "--no-recurse", "HEAD"], at: path, allowFailure: true)
      guard current.status == 0, current.text == "refs/heads/\(branchName)" else { throw mismatch }
      try directory.validate()
      return directory
    } catch {
      try checkCancellation()
      throw mismatch
    }
  }

  private func reusedImportedWorktree(_ resource: Resource) -> ItemResult {
    var item = ItemResult(resource)
    item.userMessage = .importedWorktreeReused
    item.message = item.userMessage?.englishDescription
    return item
  }

  private func changeGroup(
    _ groupName: String, repositoryIDs: [String], root: URL, change: GroupChange,
    authorization: [DeletionTarget]?, branchName: String? = nil,
    expectedRepositories: [Repository]? = nil, progress: ProgressHandler
  ) async -> OperationResult {
    let command = change.command
    let replace = change == .edit
    var result = OperationResult(command: command, workspace: root.path)
    var cleanup = WorktreeRemovalBatch(removal: worktreeRemoval)
    if replace, authorization == nil {
      let preview = await editGroupPreview(groupName, repositoryIDs: repositoryIDs, at: root)
      guard preview.status == .success else { return preview }
    }
    do {
      let lease = try await store.lock(root)
      defer { lease.unlock() }
      var record = try store.load(root)
      if let expectedRepositories {
        try validateRepositorySelection(
          expectedRepositories, repositoryIDs: repositoryIDs, record: record)
      }
      try await validateMembers(
        groupName, branchName: branchName, repositoryIDs: repositoryIDs, record: record)
      try validateGroupChange(change, groupName: groupName, record: record)
      if !replace && repositoryIDs.isEmpty {
        throw MonoDeckError("invalid-input", .chooseAtLeastOneRepository)
      }
      let existing = record.groups[groupName]?.repositoryIDs ?? []
      let removals =
        replace
        ? existing.filter { !repositoryIDs.contains($0) }.map {
          Resource.member(groupName: groupName, repositoryID: $0)
        } : []
      guard removals.isEmpty || authorization != nil else {
        throw MonoDeckError(
          "confirmation-changed", .deletionTargetsOrCheckedOutBranchesChangedNothing)
      }
      let deletion = try await deletionTargets(removals, record: record, readRisks: false)
      if let authorization { try verifyAuthorization(authorization, actual: deletion) }
      let additions = repositoryIDs.filter { !existing.contains($0) }
      if !replace {
        for repositoryID in repositoryIDs where existing.contains(repositoryID) {
          _ = try await checked(
            .member(groupName: groupName, repositoryID: repositoryID), in: record)
        }
      }
      let branch = branchName ?? record.groups[groupName]?.branchName ?? groupName
      let createsRoot = record.groups[groupName] == nil
      let creations =
        (createsRoot ? [Resource.group(groupName)] : [])
        + additions.map { Resource.member(groupName: groupName, repositoryID: $0) }
      var rootChecked = createsRoot
      var completedMembers = 0
      for (index, resource) in creations.enumerated() {
        var item: ItemResult
        do {
          try checkCancellation()
          if !rootChecked {
            try await validateGroupRootForMembers(
              groupName, repositoryIDs: additions, record: record)
            rootChecked = true
          }
          let plan: WorktreeCreation
          if resource.kind == .group {
            plan = try await rootCreationPlan(
              groupName, branchName: branch, repositoryIDs: additions, record: record)
          } else {
            plan = try await memberCreationPlan(
              groupName, branchName: branch, repositoryID: resource.repositoryID!, record: record)
          }
          item = await create(
            plan, record: &record, progress: progress, completed: completedMembers,
            total: additions.count)
        } catch {
          item = ItemResult(resource)
          fail(&item, error)
        }
        if item.status == .success && resource.kind == .member { completedMembers += 1 }
        result.items.append(item)
        if item.status != .success {
          result.items += (Array(creations.dropFirst(index + 1)) + deletion.map(\.resource)).map(
            ItemResult.notProcessed)
          result.summarize(cancelled: item.status == .cancelled)
          return result
        }
      }
      for (index, target) in deletion.enumerated() {
        let item = await delete(target, record: &record, cleanup: &cleanup, progress: progress)
        result.items.append(item)
        if item.status != .success {
          result.items += deletion.dropFirst(index + 1).map { .notProcessed($0.resource) }
          result.summarize(cancelled: item.status == .cancelled)
          await cleanup.finish()
          return result
        }
      }
      if result.items.isEmpty {
        result.items =
          change == .addMembers
          ? repositoryIDs.map { ItemResult(.member(groupName: groupName, repositoryID: $0)) }
          : [ItemResult(.group(groupName))]
      }
      result.summarize()
    } catch {
      result = .init(command: command, workspace: root.path, status: .failed, error: .wrap(error))
    }
    await cleanup.finish()
    return result
  }

  private func previewGroupChange(
    _ groupName: String, repositoryIDs: [String], root: URL, change: GroupChange,
    branchName: String? = nil, expectedRepositories: [Repository]? = nil
  ) async -> OperationResult {
    var result = OperationResult(command: change.command, workspace: root.path)
    result.dryRun = true
    do {
      let record = try await read(root)
      if let expectedRepositories {
        try validateRepositorySelection(
          expectedRepositories, repositoryIDs: repositoryIDs, record: record)
      }
      let reader = inspectionService()
      try validateGroupChange(change, groupName: groupName, record: record)
      try await reader.validateMembers(
        groupName, branchName: branchName, repositoryIDs: repositoryIDs, record: record)
      guard change == .edit || !repositoryIDs.isEmpty else {
        throw MonoDeckError("invalid-input", .chooseAtLeastOneRepository)
      }
      let existing = record.groups[groupName]?.repositoryIDs ?? []
      for repositoryID in repositoryIDs where existing.contains(repositoryID) {
        _ = try await reader.checked(
          .member(groupName: groupName, repositoryID: repositoryID), in: record)
      }
      let creations = try await reader.creationPlans(
        groupName, branchName: branchName,
        repositoryIDs: repositoryIDs.filter { !existing.contains($0) },
        record: record)
      let removals =
        change == .edit
        ? existing.filter { !repositoryIDs.contains($0) }.map {
          Resource.member(groupName: groupName, repositoryID: $0)
        } : []
      let targets = try await reader.deletionTargets(removals, record: record)
      var plan = deletionPlan(targets)
      plan.actions =
        creations.flatMap { creation -> [PlannedAction] in
          var actions = [
            PlannedAction(
              "create-worktree", resource: creation.resource, target: creation.destination.path)
          ]
          if !creation.reused {
            actions.insert(
              .init("create-branch", resource: creation.resource, target: creation.branch), at: 0)
          }
          actions.append(
            .init(
              "save-workspace-record", resource: creation.resource, target: creation.resource.path))
          return actions
        } + plan.actions
      result.plan = plan
    } catch {
      result.status = .failed
      let failure = MonoDeckError.wrap(error)
      result.reasonCode = failure.code
      result.message = failure.message
      result.userMessage = failure.userMessage
      if failure.code == "cancelled" { result.status = .cancelled }
    }
    return result
  }

  public func validateRepositorySelection(
    _ expected: [Repository], repositoryIDs: [String], record: WorkspaceRecord
  ) throws {
    guard Set(expected.map(\.id)) == Set(repositoryIDs),
      expected.allSatisfy({ repository in
        record.repositories.contains { $0.id == repository.id && $0.url == repository.url }
      })
    else {
      throw MonoDeckError("repository-selection-changed", .selectedRepositoriesChanged)
    }
  }

  private func validateGroupChange(
    _ change: GroupChange, groupName: String, record: WorkspaceRecord
  ) throws {
    if change == .create {
      guard record.groups[groupName] == nil else {
        throw MonoDeckError("group-already-exists", .groupNameConflictsWithExistingGroup)
      }
    } else {
      guard record.groups[groupName] != nil else {
        throw MonoDeckError("target-not-configured", .groupIsNotConfigured)
      }
    }
  }
  func validateMembers(
    _ groupName: String, branchName: String? = nil, repositoryIDs: [String], record: WorkspaceRecord
  ) async throws {
    try PathSafety.groupName(groupName)
    try await git.validateRef(
      branchName ?? record.groups[groupName]?.branchName ?? groupName, at: record.rootURL)
    guard Set(repositoryIDs).count == repositoryIDs.count,
      repositoryIDs.allSatisfy({ repositoryID in
        record.repositories.contains { $0.id == repositoryID }
      })
    else {
      throw MonoDeckError("invalid-input", .groupMembersMustReferenceDistinctConfiguredRepositories)
    }
    guard
      !record.groups.keys.contains(where: {
        $0 != groupName
          && PathSafety.identity(record.groupURL($0))
            == PathSafety.identity(record.groupURL(groupName))
      })
    else { throw MonoDeckError("group-conflict", .groupNameConflictsWithExistingGroup) }
  }
  func creationPlans(
    _ groupName: String, branchName: String? = nil, repositoryIDs: [String], record: WorkspaceRecord
  ) async throws -> [WorktreeCreation] {
    let branch = branchName ?? record.groups[groupName]?.branchName ?? groupName
    var plans: [WorktreeCreation] = []
    if record.groups[groupName] == nil {
      plans.append(
        try await rootCreationPlan(
          groupName, branchName: branch, repositoryIDs: repositoryIDs, record: record))
    } else if !repositoryIDs.isEmpty {
      try await validateGroupRootForMembers(groupName, repositoryIDs: repositoryIDs, record: record)
    }
    for repositoryID in repositoryIDs {
      plans.append(
        try await memberCreationPlan(
          groupName, branchName: branch, repositoryID: repositoryID, record: record))
    }
    return plans
  }
  private func rootCreationPlan(
    _ groupName: String, branchName: String, repositoryIDs: [String], record: WorkspaceRecord,
    preferRemoteBranch: Bool = false
  ) async throws -> WorktreeCreation {
    let repository = try await inspectRepository(atMainWorktree: record.rootURL)
    let plan = try await creationPlan(
      .group(groupName), branchName: branchName, repository: repository, record: record,
      preferRemoteBranch: preferRemoteBranch)
    try await git.checkRootCommit(plan.oid, repositoryIDs: repositoryIDs, at: record.rootURL)
    return plan
  }
  private func validateGroupRootForMembers(
    _ groupName: String, repositoryIDs: [String], record: WorkspaceRecord
  ) async throws {
    let root = try await checked(.group(groupName), in: record)
    guard let oid = try await git.oid("HEAD", at: root) else {
      throw MonoDeckError("resource-unavailable", .groupRootHEADIsUnavailable)
    }
    try await git.checkRootCommit(oid, repositoryIDs: repositoryIDs, at: record.rootURL)
  }
  private func memberCreationPlan(
    _ groupName: String, branchName: String, repositoryID: String, record: WorkspaceRecord
  ) async throws -> WorktreeCreation {
    let resource = Resource.repository(repositoryID)
    let repository = try await checkedRepository(for: resource, in: record)
    let path = try PathSafety.child(resource.path, of: record.rootURL, allowMissing: false)
    try await checkWorktree(resource, at: path, repository: repository, validateHEAD: false)
    let plan = try await creationPlan(
      .member(groupName: groupName, repositoryID: repositoryID), branchName: branchName,
      repository: repository, record: record)
    let tree = try await git.run(["ls-tree", "-r", "-z", plan.oid], at: repository.mainWorktreeURL)
    guard
      !tree.stdout.split(separator: 0).contains(where: { $0.starts(with: Data("160000 ".utf8)) })
    else {
      throw MonoDeckError(
        "submodule-unsupported",
        .linkedWorktreesForRepositoriesContainingSubmodulesAreNot(repositoryID))
    }
    return plan
  }
  private func creationPlan(
    _ resource: Resource, branchName: String, repository: RepositoryInspection,
    record: WorkspaceRecord, preferRemoteBranch: Bool = false
  ) async throws -> WorktreeCreation {
    let destination = try PathSafety.child(resource.path, of: record.rootURL)
    guard !PathSafety.exists(destination) else {
      throw MonoDeckError("path-conflict", .worktreePathAlreadyExists(destination.path))
    }
    guard
      !repository.registrations.contains(where: {
        PathSafety.identity(URL(fileURLWithPath: $0.path)) == PathSafety.identity(destination)
      })
    else { throw MonoDeckError("path-conflict", .worktreePathIsAlreadyRegistered) }
    try await git.checkBranchNotInUse(
      branchName, registrations: repository.registrations, at: repository.mainWorktreeURL,
      commonDirectory: repository.commonDirectory)
    let isGroupRoot = resource.kind == .group
    let mayUseRemote = !isGroupRoot || preferRemoteBranch
    let references =
      mayUseRemote
      ? try await git.creationReferences(
        branchName, at: repository.mainWorktreeURL, commonDirectory: repository.commonDirectory)
      : nil
    let local: String?
    if let references {
      local = references["refs/heads/\(branchName)"]
    } else {
      local = try await git.oid("refs/heads/\(branchName)", at: repository.mainWorktreeURL)
    }
    var upstream: String?
    var fallbackRef: String?
    var start = local
    if start == nil && mayUseRemote {
      let remote: String?
      if let references {
        remote = references["refs/remotes/origin/\(branchName)"]
      } else {
        remote = try await git.oid(
          "refs/remotes/origin/\(branchName)", at: repository.mainWorktreeURL)
      }
      if let remote {
        start = remote
        upstream = "origin/\(branchName)"
      }
    }
    if start == nil {
      fallbackRef = isGroupRoot ? "HEAD" : "origin/HEAD"
      if isGroupRoot {
        guard let head = try await git.oid("HEAD", at: repository.mainWorktreeURL) else {
          throw MonoDeckError(
            "workspace-commit-required", .commitWorkspaceGitignoreBeforeCreatingGroupWorkspaceHas)
        }
        start = head
      } else if let references {
        start = references["refs/remotes/origin/HEAD"]
      } else {
        let base = try await git.run(
          ["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"], at: repository.mainWorktreeURL,
          allowFailure: true)
        if base.status == 0, base.text.hasPrefix("refs/remotes/origin/") {
          start = try await git.oid(base.text, at: repository.mainWorktreeURL)
        }
      }
    }
    guard let start else {
      throw MonoDeckError(
        "base-unavailable",
        .memberRepositoryStartingCommitUnavailable(
          resource.repositoryID ?? resource.groupName!))
    }
    let warning: (message: String, userMessage: UserMessage?, data: [String: String])?
    if let local {
      warning = try await branchReuseWarning(
        branchName, oid: local, isGroupRoot: isGroupRoot, at: repository.mainWorktreeURL)
    } else {
      warning = nil
    }
    return .init(
      resource: resource, mainWorktreeURL: repository.mainWorktreeURL, destination: destination,
      oid: start,
      branch: branchName, reused: local != nil, upstream: upstream, fallbackRef: fallbackRef,
      reuseWarning: warning)
  }
  private func create(
    _ plan: WorktreeCreation, record: inout WorkspaceRecord, progress: ProgressHandler,
    completed: Int = 0, total: Int = 0
  ) async -> ItemResult {
    var item = ItemResult(plan.resource)
    var attempt = WorktreeCreationAttempt()
    do {
      try await applyCreation(
        plan, attempt: &attempt, progress: progress, completed: completed, total: total)
      progress(
        .init(plan.resource.path, .saving, completed: completed, total: total, cancellable: false))
      var candidate = record
      let group = plan.resource.groupName!
      if let repositoryID = plan.resource.repositoryID {
        candidate.groups[group]!.repositoryIDs.append(repositoryID)
      } else {
        candidate.groups[group] = WorktreeGroup(branchName: plan.branch)
      }
      try persist(candidate, into: &record)
      item = completedCreation(plan)
      item.effects.insert(.init("save-workspace-record", plan.resource.path), at: 1)
      progress(
        .init(
          plan.resource.path, .created,
          completed: completed + (plan.resource.kind == .member ? 1 : 0), total: total,
          snapshot: record))
    } catch {
      fail(&item, error)
      if attempt.worktreeAttempted || attempt.branchAttempted {
        if item.reasonCode == "save-outcome-unknown" {
          recordUnknownCreation(plan, attempt: attempt, item: &item)
        } else {
          progress(.init(plan.resource.path, .cleaningUp, cancellable: false))
          var worktreePending = attempt.worktreeAttempted
          var branchPending = attempt.branchAttempted
          do {
            if worktreePending {
              let registrations = try await git.run(
                ["worktree", "list", "--porcelain", "-z"], at: plan.mainWorktreeURL,
                cancellable: false)
              let registered = registrations.stdout.split(separator: 0).contains {
                String(decoding: $0, as: UTF8.self) == "worktree \(plan.destination.path)"
              }
              if registered || PathSafety.exists(plan.destination) {
                _ = try await git.run(
                  ["worktree", "remove", "--force", "--", plan.destination.path],
                  at: plan.mainWorktreeURL, cancellable: false)
                item.effects.append(
                  .init("create-worktree", plan.destination.path, state: "reverted"))
              }
              worktreePending = false
            }
            if branchPending {
              if try await removeCreatedBranch(plan) {
                item.effects.append(.init("create-branch", plan.branch, state: "reverted"))
              }
              branchPending = false
            }
          } catch {
            item.causeCode = item.reasonCode
            item.reasonCode = "cleanup-failed"
            item.status = .failed
            item.userMessage = .joined(
              [item.userMessage, .cleanupFailed(MonoDeckError.wrap(error).userMessage)].compactMap {
                $0
              }, separator: " ")
            item.message = "\(item.message ?? "") Cleanup failed: \(error.localizedDescription)"
            if worktreePending {
              item.effects.append(.init("create-worktree", plan.destination.path, state: "unknown"))
            }
            if branchPending {
              item.effects.append(.init("create-branch", plan.branch, state: "unknown"))
            }
          }
        }
      }
    }
    return item
  }

  private func applyCreation(
    _ plan: WorktreeCreation, attempt: inout WorktreeCreationAttempt, forImport: Bool = false,
    progress: ProgressHandler, completed: Int, total: Int
  ) async throws {
    try checkCancellation()
    progress(
      .init(
        plan.resource.path, plan.resource.kind == .group ? .creatingGroupRootWorktree : .creating,
        completed: completed, total: total))
    if forImport {
      try checkCancellation()
      attempt.gitDirectory = try RepositoryDirectory(plan.mainWorktreeURL.appending(path: ".git"))
    }
    if !plan.reused {
      // A cancelled update-ref may have committed its reference before its hook exits.
      attempt.branchAttempted = true
      _ = try await git.run(
        [
          "update-ref", "refs/heads/\(plan.branch)", plan.oid,
          String(repeating: "0", count: plan.oid.count),
        ], at: plan.mainWorktreeURL)
      attempt.branchCreated = true
    }
    attempt.worktreeAttempted = true
    // Full refs are detached by worktree add; attach HEAD explicitly to avoid checkout shorthand.
    _ = try await git.run(
      ["worktree", "add", "--detach", "--", plan.destination.path, plan.oid],
      at: plan.mainWorktreeURL)
    if forImport { attempt.worktreeDirectory = try RepositoryDirectory(plan.destination) }
    _ = try await git.run(
      ["symbolic-ref", "HEAD", "refs/heads/\(plan.branch)"], at: plan.destination)
    if let upstream = plan.upstream {
      let tracking = [
        ("branch.\(plan.branch).remote", "origin"),
        ("branch.\(plan.branch).merge", "refs/heads/\(upstream.dropFirst(7))"),
      ]
      if forImport {
        try await setImportedBranchTracking(tracking, plan: plan)
      } else {
        for (key, value) in tracking {
          _ = try await git.run(["config", key, value], at: plan.mainWorktreeURL)
        }
      }
    }
    try checkCancellation()
  }

  private func setImportedBranchTracking(_ tracking: [(String, String)], plan: WorktreeCreation)
    async throws
  {
    for (key, _) in tracking {
      let existing = try await git.run(
        ["config", "--local", "--get-all", key], at: plan.mainWorktreeURL, allowFailure: true)
      if existing.status == 0 { return }
      guard existing.status == 1 else {
        throw MonoDeckError(
          "git-failed",
          .gitFailed(
            "config", Int(existing.status),
            .diagnostic(Git.sanitize(String(decoding: existing.stderr, as: UTF8.self)))))
      }
    }
    try checkCancellation()
    // Finish both tracking settings before honoring a later cancellation.
    for (key, value) in tracking {
      _ = try await git.run(
        ["config", "--local", "--add", key, value], at: plan.mainWorktreeURL, cancellable: false)
    }
  }

  private func completedCreation(_ plan: WorktreeCreation) -> ItemResult {
    var item = ItemResult(plan.resource)
    item.effects = [.init("create-worktree", plan.destination.path)]
    if !plan.reused { item.effects.append(.init("create-branch", plan.branch)) }
    item.data = plan.reuseWarning?.data
    item.message = plan.reuseWarning?.message
    item.userMessage = plan.reuseWarning?.userMessage
    return item
  }

  private func recordUnknownCreation(
    _ plan: WorktreeCreation, attempt: WorktreeCreationAttempt, item: inout ItemResult
  ) {
    if attempt.worktreeAttempted {
      item.effects.append(.init("create-worktree", plan.destination.path, state: "unknown"))
    }
    if attempt.branchAttempted {
      item.effects.append(.init("create-branch", plan.branch, state: "unknown"))
    }
  }

  private func removeCreatedBranch(_ plan: WorktreeCreation) async throws -> Bool {
    let ref = "refs/heads/\(plan.branch)"
    let exists = try await git.run(
      ["show-ref", "--verify", "--quiet", ref], at: plan.mainWorktreeURL, allowFailure: true,
      cancellable: false)
    if exists.status == 1 { return false }
    guard exists.status == 0 else {
      throw MonoDeckError("git-failed", .couldNotVerifyNewBranch(plan.branch))
    }
    let actual = try await git.run(
      ["rev-parse", "--verify", "--end-of-options", ref], at: plan.mainWorktreeURL,
      cancellable: false)
    guard actual.text == plan.oid else {
      throw MonoDeckError("branch-changed", .newBranchChangedDuringCreationAndWasKept(plan.branch))
    }
    _ = try await git.run(
      ["branch", "-D", "--", plan.branch], at: plan.mainWorktreeURL, cancellable: false)
    return true
  }

  private func branchReuseWarning(
    _ branch: String, oid: String, isGroupRoot: Bool, at repository: URL
  ) async throws -> (message: String, userMessage: UserMessage?, data: [String: String])? {
    var data = ["reused-branch": branch, "comparison-base": isGroupRoot ? "HEAD" : "origin/HEAD"]
    var base = isGroupRoot ? "workspace HEAD" : "origin/HEAD"
    do {
      let baseOID: String
      if isGroupRoot {
        guard let head = try await git.oid("HEAD", at: repository) else { return nil }
        baseOID = head
      } else {
        let ref = try await git.run(
          ["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"], at: repository,
          allowFailure: true)
        guard ref.status == 0, ref.text.hasPrefix("refs/remotes/origin/"),
          let oid = try await git.oid(ref.text, at: repository)
        else {
          throw MonoDeckError("base-unavailable", .originHEADDoesNotIdentifyValidComparisonCommit)
        }
        baseOID = oid
        base = String(ref.text.dropFirst("refs/remotes/".count))
        data["comparison-base"] = base
      }
      let count = try await git.run(
        ["rev-list", "--count", "\(oid)..\(baseOID)", "--"], at: repository
      ).text
      guard let behind = Int(count), behind >= 0 else {
        throw MonoDeckError("git-output-invalid", .couldNotReadBranchComparisonCount)
      }
      guard behind > 0 else { return nil }
      data["warning-code"] = "branch-behind-base"
      data["behind-count"] = String(behind)
      return (
        "Reused branch '\(branch)' is \(behind) \(behind == 1 ? "commit" : "commits") behind '\(base)'. Its commits were kept.",
        .branchReuseBehind(branch, behind, base, isWorkspace: isGroupRoot), data
      )
    } catch let error as MonoDeckError where error.code == "cancelled" { throw error } catch {
      try checkCancellation()
      data["warning-code"] = "branch-comparison-unavailable"
      data["comparison-error"] = MonoDeckError.wrap(error).message
      return (
        "Reused branch '\(branch)', but its comparison with '\(base)' is unavailable. \(MonoDeckError.wrap(error).message)",
        .branchReuseComparisonUnavailable(
          branch, base, MonoDeckError.wrap(error).userMessage, isWorkspace: isGroupRoot), data
      )
    }
  }
}

extension WorkspaceService {
  public func editGroupPreview(_ groupName: String, repositoryIDs: [String], at root: URL) async
    -> OperationResult
  {
    do {
      let record = try await read(root)
      let reader = inspectionService()
      try await reader.validateMembers(groupName, repositoryIDs: repositoryIDs, record: record)
      guard let group = record.groups[groupName] else {
        throw MonoDeckError("target-not-configured", .groupIsNotConfigured)
      }
      let removals = group.repositoryIDs.filter { !repositoryIDs.contains($0) }.map {
        Resource.member(groupName: groupName, repositoryID: $0)
      }
      let targets = try await reader.deletionTargets(removals, record: record)
      var result = OperationResult(
        command: "group.edit", workspace: root.path,
        status: targets.isEmpty ? .success : .confirmationRequired)
      result.plan = deletionPlan(targets)
      return result
    } catch {
      return .init(
        command: "group.edit", workspace: root.path, status: .failed, error: .wrap(error))
    }
  }
}

private enum GroupChange {
  case create, edit, addMembers
  var command: String {
    switch self {
    case .create: "group.create"
    case .edit: "group.edit"
    case .addMembers: "group.member.add"
    }
  }
}
