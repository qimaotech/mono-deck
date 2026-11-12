import Foundation

extension WorkspaceService {
  public func prepareResourceRead(_ resource: Resource, in record: WorkspaceRecord) async throws
    -> ResourceReadContext
  {
    try await prepareResourceRead(resource, in: record, repository: nil)
  }

  func prepareResourceRead(
    _ resource: Resource, in record: WorkspaceRecord, repository inspection: RepositoryInspection?
  ) async throws -> ResourceReadContext {
    let reader = inspectionService()
    let repository: RepositoryInspection
    if let inspection {
      repository = inspection
    } else {
      repository = try await reader.checkedRepository(for: resource, in: record)
    }
    let path = try PathSafety.child(resource.path, of: record.rootURL, allowMissing: false)
    try await reader.checkWorktree(resource, at: path, repository: repository, validateHEAD: false)
    let directory = try await reader.git.run(["rev-parse", "--absolute-git-dir"], at: path).text
    try reader.checkCancellation()
    return try ResourceReadContext(
      resource: resource, workspace: record, path: path,
      gitDirectory: URL(fileURLWithPath: directory),
      commonDirectory: URL(fileURLWithPath: repository.commonDirectory),
      mainWorktreeURL: repository.mainWorktreeURL)
  }

  public func detailCacheIdentity(_ resource: Resource, in record: WorkspaceRecord) throws
    -> ResourceDetailCacheIdentity
  {
    try store.checkBoundary(record.rootURL)
    guard resources(record).contains(resource) else {
      throw MonoDeckError("target-not-configured", .resourceIsNotConfigured)
    }
    let path = try PathSafety.child(resource.path, of: record.rootURL, allowMissing: false)
    let mainWorktreeURL =
      try resource.repositoryID.map {
        try PathSafety.child("repositories/\($0)", of: record.rootURL, allowMissing: false)
      } ?? record.rootURL
    let commonDirectory = mainWorktreeURL.appending(path: ".git")
    try PathSafety.directory(commonDirectory)
    let gitDirectory: URL
    if resource.kind == .repository {
      gitDirectory = commonDirectory
    } else {
      gitDirectory = try cacheGitPath(at: path.appending(path: ".git"), prefix: "gitdir: ")
      let common = try cacheGitPath(at: gitDirectory.appending(path: "commondir"))
      guard PathSafety.identity(common) == PathSafety.identity(commonDirectory) else {
        throw MonoDeckError("resource-unavailable", .gitDetailsAreUnavailable)
      }
    }
    return try ResourceDetailCacheIdentity(
      resource: resource, workspace: record, path: path,
      gitDirectory: gitDirectory, commonDirectory: commonDirectory)
  }

  public func workingState(_ context: ResourceReadContext, visibility: GitChangeVisibility = .all)
    async throws -> GitWorkingState
  {
    try store.checkBoundary(context.workspace.rootURL)
    guard context.isValid(in: context.workspace) else {
      throw MonoDeckError("resource-unavailable", .gitDetailsAreUnavailable)
    }
    let start = ContinuousClock.now
    defer { git.runner.diagnostics?.record("status", duration: start.duration(to: .now)) }
    return try await inspectionService().git.workingState(at: context.path, visibility: visibility)
  }

  public func summary(_ context: ResourceReadContext, workingState: GitWorkingState) async throws
    -> GitSummary
  {
    try store.checkBoundary(context.workspace.rootURL)
    guard context.isValid(in: context.workspace) else {
      throw MonoDeckError("resource-unavailable", .gitDetailsAreUnavailable)
    }
    let start = ContinuousClock.now
    defer { git.runner.diagnostics?.record("summary", duration: start.duration(to: .now)) }
    return try await inspectionService().git.summary(at: context.path, workingState: workingState)
  }

  func localSnapshot(
    _ context: ResourceReadContext, content: InspectionContent,
    visibility: GitChangeVisibility = .all
  ) async throws -> ResourceSnapshot {
    var snapshot = ResourceSnapshot(resource: context.resource)
    do {
      let state = try await workingState(context, visibility: visibility)
      snapshot.changes = state.changes
      try checkCancellation()
      if case .withSummary = content {
        do { snapshot.summary = try await summary(context, workingState: state) } catch {
          snapshot.summaryError = .wrap(error)
        }
      }
    } catch {
      try checkCancellation()
      snapshot.changesError = .wrap(error)
      if case .withSummary = content { snapshot.summaryError = .wrap(error) }
    }
    try checkCancellation()
    return snapshot
  }

  func inspectionService() -> WorkspaceService {
    var reader = git
    reader.runner.environment["GIT_OPTIONAL_LOCKS"] = "0"
    return WorkspaceService(store: store, git: reader, trash: trashDirectory)
  }

  private func cacheGitPath(at file: URL, prefix: String = "") throws -> URL {
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular else {
      throw MonoDeckError("resource-unavailable", .gitDetailsAreUnavailable)
    }
    let contents = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .newlines)
    let path = String(contents.dropFirst(prefix.count))
    guard contents.hasPrefix(prefix), !path.isEmpty else {
      throw MonoDeckError("resource-unavailable", .gitDetailsAreUnavailable)
    }
    return PathSafety.canonical(
      path.hasPrefix("/")
        ? URL(fileURLWithPath: path) : file.deletingLastPathComponent().appending(path: path))
  }
}
