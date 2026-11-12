import ArgumentParser
import Foundation
import MonoDeckCore

struct Group: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Manage worktree groups and their members.",
    subcommands: [List.self, Create.self, Edit.self, Delete.self, Member.self])

  struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "List group roots and member worktrees with their local status.")
    @OptionGroup var options: Options
    mutating func run() async throws {
      let service = WorkspaceService()
      var result = await service.inspect(try await options.root(service), scope: .worktrees)
      result.command = "group.list"
      result.items.removeAll { item in
        if item.resource.kind == .workspace { return item.status != .failed }
        return ![.group, .member].contains(item.resource.kind)
      }
      if result.reasonCode == nil { result.summarize() }
      finish(result, json: options.json)
    }
  }

  struct Create: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Create a worktree group from selected repositories.",
      discussion:
        "The group must not already exist. Uses local Git refs without fetching. Use group member add to extend an existing group."
    )
    @OptionGroup var options: Options
    @OptionGroup var mutation: MutationOptions
    @Argument(
      help: ArgumentHelp(
        "The group name used for its directory and identity.", valueName: "group-name"))
    var groupName: String
    @Option(
      name: .customLong("branch"),
      help: ArgumentHelp(
        "The initial branch for the group root and members, also used for future members. Defaults to the group name; allows '/' and cannot be changed after creation.",
        valueName: "branch-name")) var branchName: String?
    @Option(
      name: .customLong("repo"), parsing: .singleValue,
      help: ArgumentHelp(
        "A repository ID. Repeat for multiple repositories.", valueName: "repository-id"))
    var repositoryIDs: [String] = []
    mutating func validate() throws {
      guard !repositoryIDs.isEmpty else {
        throw ValidationError("At least one --repo is required.")
      }
    }
    mutating func run() async throws {
      let service = WorkspaceService()
      let root = try await options.root(service)
      finish(
        await service.createGroup(
          groupName, branchName: branchName, repositoryIDs: repositoryIDs, at: root,
          dryRun: mutation.dryRun, progress: reportProgress), json: options.json)
    }
  }

  struct Edit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Choose which repositories have worktrees in an existing group.",
      discussion: """
        Pass --repo for every repository that should have a worktree in the group. MonoDeck deletes existing worktrees for omitted repositories and their current local branches.

        Use --clear-members to remove all worktrees registered in the group. Both forms keep the group root and name.
        """
    )
    @OptionGroup var options: Options
    @OptionGroup var mutation: MutationOptions
    @Argument(
      help: ArgumentHelp("The name of the worktree group to edit.", valueName: "group-name"))
    var groupName: String
    @Option(
      name: .customLong("repo"), parsing: .singleValue,
      help: ArgumentHelp("A repository ID to include in the group.", valueName: "repository-id"))
    var repositoryIDs: [String] = []
    @Flag(help: "Delete all worktrees registered in the group and their current local branches.")
    var clearMembers = false
    mutating func validate() throws {
      guard clearMembers != !repositoryIDs.isEmpty else {
        throw ValidationError("Specify either one or more --repo options or --clear-members.")
      }
    }
    mutating func run() async throws {
      let service = WorkspaceService()
      let root = try await options.root(service)
      let groupName = groupName
      let repositoryIDs = repositoryIDs
      await runMutation(
        options: options, mutation: mutation,
        preview: {
          await service.editGroup(groupName, repositoryIDs: repositoryIDs, at: root, dryRun: true)
        },
        execute: { plan in
          await service.editGroup(
            groupName, repositoryIDs: repositoryIDs, at: root, authorization: plan?.deletions,
            progress: reportProgress)
        })
    }
  }

  struct Delete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Delete a worktree group, its worktrees, and their current local branches.")
    @OptionGroup var options: Options
    @OptionGroup var mutation: MutationOptions
    @Argument(help: ArgumentHelp("The group to delete.", valueName: "group-name")) var groupName:
      String
    mutating func run() async throws {
      let service = WorkspaceService()
      let root = try await options.root(service)
      let request = DeleteRequest.group(groupName)
      if mutation.yes && !mutation.dryRun {
        finish(
          await service.delete(
            request, at: root, confirmCurrentTargets: true, progress: reportProgress),
          json: options.json)
      }
      await runMutation(
        options: options, mutation: mutation,
        preview: { await service.delete(request, at: root, dryRun: true) },
        execute: { plan in
          await service.delete(
            request, at: root, authorization: plan?.deletions, progress: reportProgress)
        })
    }
  }

  struct Member: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Add or delete individual worktrees in a group.",
      subcommands: [Add.self, Delete.self])
    struct Add: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        abstract: "Add missing worktrees to an existing group.")
      @OptionGroup var options: Options
      @OptionGroup var mutation: MutationOptions
      @Argument(help: ArgumentHelp("The existing group name.", valueName: "group-name"))
      var groupName: String
      @Argument(help: ArgumentHelp("Repository IDs to add.", valueName: "repository-id"))
      var repositoryIDs: [String] = []
      mutating func validate() throws {
        guard !repositoryIDs.isEmpty else {
          throw ValidationError("At least one repository ID is required.")
        }
      }
      mutating func run() async throws {
        let service = WorkspaceService()
        let root = try await options.root(service)
        finish(
          await service.addGroupMembers(
            groupName, repositoryIDs: repositoryIDs, at: root, dryRun: mutation.dryRun,
            progress: reportProgress), json: options.json)
      }
    }
    struct Delete: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        abstract: "Delete worktrees and their current local branches, keeping the group root.")
      @OptionGroup var options: Options
      @OptionGroup var mutation: MutationOptions
      @Argument(help: ArgumentHelp("The existing group name.", valueName: "group-name"))
      var groupName: String
      @Argument(
        help: ArgumentHelp("Repository IDs of members to delete.", valueName: "repository-id"))
      var repositoryIDs: [String] = []
      mutating func validate() throws {
        guard !repositoryIDs.isEmpty else {
          throw ValidationError("At least one repository ID is required.")
        }
      }
      mutating func run() async throws {
        let service = WorkspaceService()
        let root = try await options.root(service)
        let request = DeleteRequest.members(groupName: groupName, repositoryIDs: repositoryIDs)
        await runMutation(
          options: options, mutation: mutation,
          preview: { await service.delete(request, at: root, dryRun: true) },
          execute: { plan in
            await service.delete(
              request, at: root, authorization: plan?.deletions, progress: reportProgress)
          })
      }
    }
  }
}
