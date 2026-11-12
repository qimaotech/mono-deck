# Agent Instructions

## Product boundaries

- A workspace manages member repositories and task worktree groups. Each group contains a task member worktree for each selected repository. The workspace root is the workspace repository's main worktree, and group roots are its linked worktrees. Each member repository has a main worktree under `repositories/`, and its task member worktrees are linked worktrees of that repository.
- Git Browser shows local changes, unique commits, and behind commits. Use external tools for development, commits, and merges in member repositories. MonoDeck automatically commits the workspace's `.gitignore` and bundled workflow files when needed.
- Cancellation or partial failure can leave completed changes in place. Distinguish completed work, unfinished work, and retained data in feedback. Avoid promising a full rollback.

## Repository layout

| Path | Contents |
| --- | --- |
| [MonoDeckCore/](MonoDeckCore/) | Domain models, workflows, and infrastructure shared by the app and CLI |
| [MonoDeck/](MonoDeck/) | App coordination, feature models and views, platform adapters, and resources |
| [MonoDeckCLI/](MonoDeckCLI/) | CLI commands and argument parsing |
| [MonoDeckTests/](MonoDeckTests/) | Unit, Git integration, and CLI tests and fixtures |
| [Taskfile.yml](Taskfile.yml), [script/](script/) | Build, launch, test, packaging, and temporary workspace entry points |

## Engineering conventions

- Before implementing business logic, consult [GLOSSARY.md](GLOSSARY.md) for domain terminology and semantics. If a new business concept is introduced, propose an update to the glossary.
- Read the relevant implementation and tests before making changes. Treat the code as the source of truth for business rules, data formats, and command arguments.
- `MonoDeck` and `MonoDeckCLI` share `MonoDeckCore`. Keep Core independent of the UI, put business logic and side effects in Core, and limit views to rendering state and forwarding user intent. Preserve the existing target boundaries without adding frameworks or packages.
- `AppModel` assembles dependencies and coordinates startup, workspace switching, external tools, and shutdown. Keep feature state in the models under `Features/`.
- Keep UI state on `@MainActor`, make asynchronous tasks cancellable, and check lifecycle identifiers and the current feature context before publishing results.
- Use [CommandRunner.swift](MonoDeckCore/Infrastructure/Process/CommandRunner.swift) for Git and external commands.
- Reuse existing SwiftUI and AppKit components, system semantic fonts, and system materials. Keep resources in the app's resource directory.
- Change the product version and build number only in `Version.xcconfig`. Leave the generated `MonoDeckVersion` to the build. Version the workspace YAML, CLI JSON schema, and dependencies independently.

## Verification and delivery

- Review the final diff for business correctness, edge cases, error and cancellation handling, asynchronous context, and any related code or documentation that needs updating.
- Focus tests on core workflows, user data, critical failure and cancellation paths, public contracts, and concurrency that is hard to verify by review. Add cases only when there is a specific regression risk that existing tests do not cover.
- Ordinary feature changes do not automatically require new tests or the full suite. Reuse or adjust existing cases and run the narrowest relevant checks first. Broaden verification when changes span workflows, checks fail, or risks remain unresolved.
- Skip tests for copy or styling, simple mappings, implementation details, or coverage alone. Consolidate or remove redundant, outdated, or low-value cases where appropriate.
- Use temporary directories, local bare remotes, and controlled test doubles. Keep tests off the real network and away from user repositories.
- Keep UI test targets and persistent UI automation out of the project.
- Report review findings, checks actually run, cleanup results, and why any items remain unfinished.

## Key risks

- Running `run`, `debug`, `logs`, or `telemetry` without a mock stops existing MonoDeck instances first. Debug builds use separate preferences but share workspace data, locks, and the CLI with the release build. Prefer an isolated mock for temporary verification.
- For temporary verification, confirm that the instance exits and clean up its data and helper processes even after failure or interruption. Preserve an instance when the user asks to keep it running.
- Handle only processes and data confirmed to belong to the current verification. Stop processes only by verified identity and clean up directories only by exact path. Leave existing instances, shared caches, and external tools alone.
- Pushing a `v*` tag triggers a CI release. See [Packaging and releases](DEVELOPMENT.md#packaging-and-releases) for the authorization scope.

## Task-specific references

Consult the relevant sections, source files, and tests before starting these tasks.

| Task | References |
| --- | --- |
| Product and usage | [README.md](README.md) |
| Feature models or asynchronous coordination | [Model responsibilities and lifecycle](DEVELOPMENT.md#model-responsibilities-and-lifecycle) |
| Git reads, scheduling, or caching | [Git reads and caching](DEVELOPMENT.md#git-reads-and-caching), [GitBrowserModel](MonoDeck/Features/GitBrowser/GitBrowserModel.swift), [read scheduling tests](MonoDeckTests/RepositoryReadSchedulingTests.swift) |
| Workspace loading, startup, or onboarding | [Workspace loading and maintenance](DEVELOPMENT.md#workspace-loading-and-maintenance), [Startup and settings](DEVELOPMENT.md#startup-and-settings), [WorkspaceModel](MonoDeck/Features/Workspace/WorkspaceModel.swift), [workspace loading tests](MonoDeckTests/WorkspaceLoadingTests.swift) |
| Workspace YAML import or retries | [YAMLService](MonoDeckCore/Workflows/YAMLService.swift), [import retry test](MonoDeckTests/WorkflowTests.swift) (`workspaceYAMLRetryRegistersRetainedWorktrees`) |
| Worktree deletion and authorization | [DeletionService](MonoDeckCore/Workflows/DeletionService.swift), [deletion preview and authorization tests](MonoDeckTests/DeletionPreviewTests.swift) |
| Automatic updates | [Automatic updates](DEVELOPMENT.md#automatic-updates) |
| Building, launching, or debugging the app | [Building, running, and debugging](DEVELOPMENT.md#building-running-and-debugging), [Cleaning up temporary instances](DEVELOPMENT.md#cleaning-up-temporary-instances) |
| Running tests or diagnosing failures | [Running and diagnosing tests](DEVELOPMENT.md#running-and-diagnosing-tests) |
| Quitting or cleaning up temporary instances | [Cleaning up temporary instances](DEVELOPMENT.md#cleaning-up-temporary-instances) |
| Changing versions, packaging, or releasing | [Packaging and releases](DEVELOPMENT.md#packaging-and-releases) |
| Editing documentation or prompts | [Maintaining documentation and prompts](DEVELOPMENT.md#maintaining-documentation-and-prompts) |
