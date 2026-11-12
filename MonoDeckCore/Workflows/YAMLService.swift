import Foundation
import Yams

private struct WorkspaceConfiguration: Codable {
  struct Group: Codable {
    var branchName: String
    var repositoryIDs: [String]
    enum CodingKeys: String, CodingKey {
      case branchName = "branch-name"
      case repositoryIDs = "repository-ids"
    }
  }

  var version: Int
  var repositories: [Repository]
  var groups: [String: Group]
}

extension WorkspaceService {
  public func exportYAML(at root: URL, to destination: URL) async throws {
    let text = try await exportYAML(at: root)
    if let boundary = store.directoryBoundary { try PathSafety.confined(destination, to: boundary) }
    try Data(text.utf8).write(to: destination, options: .atomic)
  }
  public func exportYAML(at root: URL) async throws -> String {
    let record = try await read(root)
    let groups = record.groups.mapValues {
      WorkspaceConfiguration.Group(branchName: $0.branchName, repositoryIDs: $0.repositoryIDs)
    }
    let encoder = YAMLEncoder()
    encoder.options.sortKeys = true
    return try encoder.encode(
      WorkspaceConfiguration(version: 2, repositories: record.repositories, groups: groups))
  }
  public func importRepositories(
    _ urls: [String], at root: URL, progress: ProgressHandler = { _ in }
  ) async -> OperationResult {
    var result = OperationResult(command: "repo.import", workspace: root.path)
    var staging: RepositoryStaging?
    do {
      guard !urls.isEmpty else {
        throw MonoDeckError("invalid-input", .noCompleteSupportedGitRepositoryURLsWereFound)
      }
      let identities = try Dictionary(
        grouping: Set(urls), by: { try RepositoryIdentity($0).id.lowercased() })
      _ = try store.load(root)
      var seen = Set<String>()
      var stopped = false
      for (index, url) in urls.enumerated() {
        let repo = Repository(url: url)
        var item = ItemResult(.repository(repo.id))
        if stopped || Task.isCancelled {
          item = .notProcessed(item.resource)
          stopped = true
        } else if !seen.insert(url).inserted {
          item.status = .skipped
          item.reasonCode = "duplicate-url"
          item.message = "Duplicate URL."
          item.userMessage = .duplicateURL
        } else if identities[repo.id.lowercased()]!.count > 1 {
          item.status = .failed
          item.reasonCode = "repository-conflict"
          item.message = "Different URLs derive the same repository ID: \(repo.id)"
          item.userMessage = .repositoryIDCollision(repo.id)
        } else {
          progress(.init(repo.id, .importingRepositories, completed: index, total: urls.count))
          let counts = importCounts(result.items)
          let report: ProgressHandler = { value in
            progress(
              .init(
                value.target, value.phase, completed: index, total: urls.count,
                cancellable: value.cancellable, snapshot: value.snapshot, counts: counts))
          }
          do { item = try await add(repo, at: root, staging: &staging, progress: report) } catch {
            fail(&item, error)
            stopped = true
          }
          if item.status == .success, item.data?["disposition"] == "already-exists" {
            item.status = .skipped
            item.reasonCode = "already-exists"
          }
          if [
            "workspace-unavailable", "ignore-unavailable", "ignore-write-failed",
            "workspace-commit-failed", "workspace-record-write-failed", "save-outcome-unknown",
            "cleanup-failed", "cancelled",
          ].contains(item.reasonCode ?? "") {
            stopped = true
          }
        }
        result.items.append(item)
        if item.reasonCode != "not-processed" {
          progress(
            .init(
              repo.id, .importingRepositories, completed: index + 1, total: urls.count,
              counts: importCounts(result.items)))
        }
      }
      result.summarize(
        cancelled: result.items.contains {
          $0.status == .cancelled || $0.reasonCode == "not-processed"
        })
    } catch {
      let failure = MonoDeckError.wrap(error, code: "invalid-input")
      let pending =
        failure.code == "cancelled"
        ? urls.map { ItemResult.notProcessed(.repository(Repository(url: $0).id)) } : []
      result = .init(
        command: result.command, workspace: root.path, status: .failed, items: pending,
        error: failure)
    }
    let cleanupCause = repositoryImportFailureCause(result)
    finishRepositoryStaging(staging, items: &result.items, causeCode: cleanupCause)
    clearCancelledImportFailure(&result)
    if !result.items.isEmpty {
      result.summarize(
        cancelled: result.status == .cancelled
          || result.items.contains { $0.status == .cancelled || $0.reasonCode == "not-processed" })
    }
    return result
  }
  private func importCounts(_ items: [ItemResult]) -> (added: Int, skipped: Int, failed: Int) {
    (
      items.filter { $0.data?["disposition"] == "added" }.count,
      items.filter { ["already-exists", "duplicate-url"].contains($0.reasonCode ?? "") }.count,
      items.filter { $0.status == .failed }.count
    )
  }
  public static func repositoryURLs(in text: String) throws -> [String] {
    guard let node = try Yams.compose(yaml: text) else { return [] }
    var result: [String] = []
    // Yams resolves aliases while composing, so count every visit to the expanded nodes.
    var remainingNodes = 10_000
    func visit(_ node: Node, depth: Int = 0) throws {
      guard remainingNodes > 0, depth <= 100 else {
        throw MonoDeckError("invalid-input", .yamlTooComplexToImport)
      }
      remainingNodes -= 1
      if let map = node.mapping {
        for pair in map { try visit(pair.value, depth: depth + 1) }
      } else if let sequence = node.sequence {
        for child in sequence { try visit(child, depth: depth + 1) }
      } else if let value = node.string {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if (try? RepositoryIdentity(raw)) != nil {
          result.append(raw)
        } else if raw.hasPrefix("https://") || raw.hasPrefix("ssh://"),
          let c = URLComponents(string: raw),
          c.password != nil || (c.scheme == "https" && c.user != nil)
            || (c.query?.lowercased().contains("token") == true)
        {
          throw MonoDeckError(
            "invalid-input", .yamlContainsRepositoryURLWithEmbeddedCredentialsRemove)
        }
      }
    }
    try visit(node)
    return result
  }
  public func importWorkspaceYAML(
    _ text: String, at root: URL, progress: ProgressHandler = { _ in }
  ) async -> OperationResult {
    var result = OperationResult(command: "workspace.configuration.import", workspace: root.path)
    var desired = WorkspaceRecord(root: root.path)
    var staging: RepositoryStaging?
    var plannedItems: [Resource: ItemResult] = [:]
    var prepared: [PreparedRepository] = []
    do {
      desired = try decodeWorkspaceConfiguration(text, at: root)
      (staging, plannedItems) = try await beginWorkspaceImport(desired)
      var failure: ItemResult?
      if let staging {
        for repo in desired.repositories where plannedItems[.repository(repo.id)] == nil {
          progress(.init(repo.id, .checkingRepository, total: desired.repositories.count))
          switch await prepareRepository(
            repo, in: staging, reportCleanupEffects: false, progress: progress)
          {
          case .ready(let repository): prepared.append(repository)
          case .failed(let item): failure = item
          }
          if failure != nil { break }
        }
      }
      if let failure {
        plannedItems[failure.resource] = failure
        result.items = pendingWorkspaceImportItems(desired, known: plannedItems)
      } else {
        result = try await publishWorkspaceImport(
          desired, prepared: prepared, staging: staging, progress: progress)
      }
    } catch {
      result = .init(
        command: result.command, workspace: root.path, status: .failed,
        error: .wrap(error, code: "invalid-input"))
      if staging != nil { result.items = pendingWorkspaceImportItems(desired, known: plannedItems) }
    }
    let cleanupCause = repositoryImportFailureCause(result)
    for repository in prepared {
      guard
        let index = result.items.firstIndex(where: {
          $0.resource == .repository(repository.repository.id)
        })
      else { continue }
      cleanupRepositoryPreparation(
        repository, item: &result.items[index], reportEffects: false, causeCode: cleanupCause,
        progress: progress)
    }
    finishRepositoryStaging(staging, items: &result.items, causeCode: cleanupCause)
    clearCancelledImportFailure(&result)
    if result.reasonCode == nil
      || result.items.contains(where: { $0.reasonCode == "cleanup-failed" })
    {
      let cancelled =
        result.status == .cancelled
        || result.items.contains {
          $0.status == .cancelled || (Task.isCancelled && $0.reasonCode == "not-processed")
        }
      result.summarize(cancelled: cancelled)
      if !cancelled
        && result.items.allSatisfy({ $0.status == .success || $0.reasonCode == "already-exists" })
      {
        result.status = .success
      }
    }
    return result
  }

  private func decodeWorkspaceConfiguration(_ text: String, at root: URL) throws -> WorkspaceRecord
  {
    try WorkspaceDocumentValidation.validateConfigurationDocument(text)
    let document = try YAMLDecoder().decode(WorkspaceConfiguration.self, from: text)
    var desired = WorkspaceRecord(root: root.path)
    desired.version = document.version
    desired.repositories = document.repositories
    desired.groups = document.groups.mapValues {
      WorktreeGroup(branchName: $0.branchName, repositoryIDs: $0.repositoryIDs)
    }
    do { try store.validate(desired) } catch let failure as MonoDeckError
      where failure.code == "invalid-workspace-record"
    {
      throw MonoDeckError("invalid-workspace-configuration", failure.userMessage)
    }
    return desired
  }

  private func beginWorkspaceImport(_ desired: WorkspaceRecord) async throws -> (
    RepositoryStaging?, [Resource: ItemResult]
  ) {
    let root = desired.rootURL
    let lease = try await store.lock(root)
    defer { lease.unlock() }
    let record = try store.load(root)
    try await git.checkRepository(root, main: true)
    try await validateWorkspaceImportBranch(at: root)
    var items: [Resource: ItemResult] = [:]
    for repository in desired.repositories {
      if let item = workspaceImportRepositoryOutcome(repository, in: record) {
        items[item.resource] = item
      }
    }
    let needsClones = items.count < desired.repositories.count
    for name in desired.groups.keys where record.groups[name] != nil {
      items[.group(name)] = workspaceImportSkip(.group(name))
    }
    return (needsClones ? try RepositoryStaging(at: root) : nil, items)
  }

  private func validateWorkspaceImportBranch(at root: URL) async throws {
    let prefix = "refs/remotes/origin/"
    let ref = try await git.run(
      ["symbolic-ref", "--quiet", "\(prefix)HEAD"], at: root, allowFailure: true)
    guard ref.status == 0, ref.text.hasPrefix(prefix), try await git.oid(ref.text, at: root) != nil
    else { return }
    let branch = String(ref.text.dropFirst(prefix.count))
    guard try await git.checkedOutLocalBranchRef(at: root) == "refs/heads/\(branch)" else {
      throw MonoDeckError("workspace-branch-mismatch", .workspaceImportRequiresBranch(branch))
    }
  }

  private func publishWorkspaceImport(
    _ desired: WorkspaceRecord, prepared: [PreparedRepository], staging: RepositoryStaging?,
    progress: ProgressHandler
  ) async throws -> OperationResult {
    let root = desired.rootURL
    let lease = try await store.lock(root)
    defer { lease.unlock() }
    var record = try store.load(root)
    try staging?.validate()
    try await git.checkRepository(root, main: true)
    var result = OperationResult(command: "workspace.configuration.import", workspace: root.path)
    let preparedByID = Dictionary(uniqueKeysWithValues: prepared.map { ($0.repository.id, $0) })
    var blockedRepositories = Set<String>()
    var stopped = false
    for repository in desired.repositories {
      let resource = Resource.repository(repository.id)
      let item: ItemResult
      if let outcome = workspaceImportRepositoryOutcome(repository, in: record) {
        item = outcome
      } else if stopped || Task.isCancelled {
        item = .notProcessed(resource)
      } else if let prepared = preparedByID[repository.id] {
        item = await publishRepository(
          prepared, record: &record, commitIgnore: false, progress: progress)
        stopped = item.status != .success
      } else {
        item = ItemResult(
          resource, status: .failed,
          error: MonoDeckError(
            "repository-selection-changed", .workspaceImportRepositoryChanged(repository.id)))
      }
      if item.status != .success && item.reasonCode != "already-exists" {
        blockedRepositories.insert(repository.id)
      }
      result.items.append(item)
    }
    let addedRepositories = result.items.contains { $0.data?["disposition"] == "added" }
    let skippedRepositoryIDs = result.items.compactMap {
      $0.reasonCode == "already-exists" ? $0.resource.repositoryID : nil
    }
    if addedRepositories || (!skippedRepositoryIDs.isEmpty && !Task.isCancelled) {
      var item = ItemResult(.workspace())
      do {
        let needsCommit =
          addedRepositories
          ? true : try await git.hasPendingRepositoryIgnoreRules(skippedRepositoryIDs, at: root)
        if needsCommit {
          progress(.init(root.path, .saving, cancellable: false))
          if let oid = try await git.commitWorkspaceFiles(
            [".gitignore"], message: "chore: import MonoDeck workspace repositories", at: root)
          {
            item.effects.append(.init("commit-workspace-files", oid))
          }
        }
      } catch {
        fail(&item, error)
        stopped = true
      }
      if !item.effects.isEmpty || item.status != .success { result.items.append(item) }
    }
    for name in desired.groups.keys.sorted() {
      let group = desired.groups[name]!
      if record.groups[name] != nil {
        result.items.append(workspaceImportSkip(.group(name)))
      } else if stopped || Task.isCancelled
        || !blockedRepositories.isDisjoint(with: group.repositoryIDs)
      {
        result.items.append(.notProcessed(.group(name)))
        result.items += group.repositoryIDs.map {
          .notProcessed(.member(groupName: name, repositoryID: $0))
        }
      } else {
        let items = await createImportedGroup(
          name, branchName: group.branchName, repositoryIDs: group.repositoryIDs, record: &record,
          progress: progress)
        result.items += items
        stopped = items.contains { $0.status == .failed || $0.status == .cancelled }
      }
    }
    return result
  }

  private func workspaceImportRepositoryOutcome(
    _ repository: Repository, in record: WorkspaceRecord
  ) -> ItemResult? {
    let resource = Resource.repository(repository.id)
    if let existing = record.repositories.first(where: {
      $0.id.lowercased() == repository.id.lowercased()
    }) {
      if existing.url == repository.url { return workspaceImportSkip(resource) }
      return ItemResult(
        resource, status: .failed,
        error: MonoDeckError("repository-conflict", .repositoryIDCollision(repository.id)))
    }
    do {
      let path = try PathSafety.child("repositories", of: record.rootURL).appending(
        path: repository.id)
      guard !PathSafety.exists(path) else {
        throw MonoDeckError("path-conflict", .repositoryTargetAlreadyExists(path.path))
      }
      return nil
    } catch {
      var item = ItemResult(resource)
      fail(&item, error)
      return item
    }
  }

  private func workspaceImportSkip(_ resource: Resource) -> ItemResult {
    var item = ItemResult(resource, status: .skipped)
    item.reasonCode = "already-exists"
    item.data = ["disposition": "already-exists"]
    return item
  }

  private func pendingWorkspaceImportItems(
    _ desired: WorkspaceRecord, known: [Resource: ItemResult]
  ) -> [ItemResult] {
    resources(desired).compactMap { resource in
      if case .member(let group, _) = resource, known[.group(group)]?.reasonCode == "already-exists"
      {
        return nil
      }
      return known[resource] ?? .notProcessed(resource)
    }
  }

  private func repositoryImportFailureCause(_ result: OperationResult) -> String? {
    if let reason = result.reasonCode { return reason }
    if let failed = result.items.first(where: { $0.status == .failed }) {
      return failed.reasonCode == "cleanup-failed"
        ? failed.causeCode ?? failed.reasonCode : failed.reasonCode
    }
    return result.status == .cancelled || Task.isCancelled ? "cancelled" : nil
  }

  private func clearCancelledImportFailure(_ result: inout OperationResult) {
    guard result.reasonCode == "cancelled",
      result.items.contains(where: { $0.reasonCode == "cleanup-failed" })
    else { return }
    result.reasonCode = nil
    result.message = nil
    result.userMessage = nil
  }
}
