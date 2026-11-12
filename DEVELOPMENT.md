# Development Guide

## Feature models and asynchronous coordination

### Model responsibilities and lifecycle

- Before writing, pause related reads and wait for cancellation to finish so reads and writes cannot overlap. When switching workspaces or quitting, cancel tasks tied to the current context as needed and wait for cleanup to prevent stale results from being published. See [WorkspaceModel](MonoDeck/Features/Workspace/WorkspaceModel.swift) and [AppModel](MonoDeck/App/AppModel.swift).
- Repository addition and worktree group creation forms stay bound to the workspace that was current when they opened. When creating a group, Core revalidates the selected repository identities under the lock to catch stale selections. See [ManagementModel](MonoDeck/Features/Management/ManagementModel.swift) and [WorktreeGroupService](MonoDeckCore/Workflows/WorktreeGroupService.swift).

### Git reads and caching

- Git Browser and CLI queries read only local data. The app's submodule visibility rules apply to browsing. Write safety checks use live Git state. See [GitInspection](MonoDeckCore/Infrastructure/Git/GitInspection.swift).
- Prioritize the currently selected detail view so background queries do not slow navigation. Display a disk snapshot first when available, then read the current local state. See [GitBrowserModel](MonoDeck/Features/GitBrowser/GitBrowserModel.swift) for scheduling and invalidation, and [RepositoryDiskCache](MonoDeckCore/Infrastructure/Persistence/RepositoryDiskCache.swift) and [RepositoryHistoryCache](MonoDeckCore/Workflows/RepositoryHistoryCache.swift) for persistence and history reuse.
- Set `MONO_DECK_READ_DIAGNOSTICS=1` in the target process's environment to see read phases, command counts, and cache statistics on stderr. See [RepositoryReadDiagnostics](MonoDeckCore/Models/RepositoryReadDiagnostics.swift).

### Workspace loading and maintenance

- Automatic refreshes and workspace record change notifications trigger read-only synchronization. Maintenance handles directory repair, workspace record cleanup, and bundled workflow synchronization. See [WorkspaceModel](MonoDeck/Features/Workspace/WorkspaceModel.swift) for refresh scheduling and failure recovery, and [Workspace files and automatic commits](README.md#workspace-files-and-automatic-commits) for the impact on users.
- Automatic commits require a local branch and include only the specified files, preserving the user's other staged changes. Adding a repository rechecks commit prerequisites before moving the repository into the workspace to avoid leaving partial changes when the branch is unsuitable. See [RepositoryService](MonoDeckCore/Workflows/RepositoryService.swift) and [GitWorkspace](MonoDeckCore/Infrastructure/Git/GitWorkspace.swift).

### Startup and settings

- At startup, restore the saved workspace and current detail view through read-only operations before running maintenance, so browsing can begin sooner. See [AppModel](MonoDeck/App/AppModel.swift) and [AppDelegate](MonoDeck/App/AppDelegate.swift) for startup and shutdown coordination.
- Initialize or recover a missing workspace record only after onboarding confirmation or a manual workspace switch in Settings. Preserve corrupt records and records with unsupported versions. See [SetupModel](MonoDeck/Features/Setup/SetupModel.swift) and [WorkspaceRecovery](MonoDeckCore/Workflows/WorkspaceRecovery.swift).

### Automatic updates

- Download and install updates after user confirmation. The app completes shutdown preparation and confirms that the independent installer is ready before quitting. The installer then replaces and relaunches the app. See [AppUpdateModel](MonoDeck/Features/Updates/AppUpdateModel.swift), [AppUpdateInstaller](MonoDeckCore/Infrastructure/AppUpdateInstaller.swift), and [CI and package requirements](#ci-and-package-requirements).

### CLI and domain contracts

- See [External data and CLI contract](GLOSSARY.md#external-data-and-cli-contract) for public formats, previews, and confirmation rules.
- Workspace YAML import clones outside the workspace lock so network waits do not hold it. Revalidate the workspace record and target paths under the lock before publishing changes. Retries can reuse verified worktrees. See [YAMLService](MonoDeckCore/Workflows/YAMLService.swift) and [WorktreeGroupService](MonoDeckCore/Workflows/WorktreeGroupService.swift).
- During deletion, revalidate Git ownership and authorized targets under the lock to prevent accidental deletion based on a stale preview. When eligible, defer physical file cleanup to the background to shorten the synchronous wait. See [DeletionService](MonoDeckCore/Workflows/DeletionService.swift) and [WorktreeCleanup](MonoDeckCore/Infrastructure/FileSystem/WorktreeCleanup.swift).

## Building, running, and debugging

Run these commands from the repository root with a full Xcode installation, including the command line tools, and Task 3. See [CI](.github/workflows/ci.yml) and the [Xcode project](MonoDeck.xcodeproj/project.pbxproj) for the toolchain and deployment target.

| Purpose | Command |
| --- | --- |
| Launch and activate an isolated temporary Git scenario | `task mock` |
| Verify startup in isolation, print the PID, and leave the instance running | `task verify -- --mock linked-worktree-selected` |
| Launch the development build | `task run` |
| Clear the saved workspace selection and launch the development build | `task run -- --reset` |

- Startup verification only checks that the app process launches. Before launching, review [Key risks](AGENTS.md#key-risks). After verification, follow [Cleaning up temporary instances](#cleaning-up-temporary-instances).
- Append `-- --mock linked-worktree-selected` to `task debug`, `task logs`, or `task telemetry` to use the mock scenario. Enter `run` in LLDB to launch. Logs are scoped to the current instance's PID. Once collection starts, Ctrl-C stops only the log stream. For full build output, pass `--verbose` after the Task argument separator, as in `task debug -- --mock linked-worktree-selected --verbose`.
- Mock launches reuse development build artifacts by default. Set `MONO_DECK_DERIVED_DATA_PATH` to a dedicated path when you need separate artifacts. Use `task --dry --verbose <task>` to inspect the command. See [Taskfile.yml](Taskfile.yml) and [build_and_run.sh](script/build_and_run.sh) for tasks and arguments.

## Formatting Swift code

Use `task format` to format all Swift source directories, or `task format -- <path>` to format a specific file or directory. Both use the default `swift-format` settings from the selected Xcode toolchain.

Run `task format:check` to check Swift files in `MonoDeck`, `MonoDeckCore`, `MonoDeckCLI`, `MonoDeckTests`, and `script`. The `Format` job runs the same check on pull requests.

## Running and diagnosing tests

See [Verification and delivery](AGENTS.md#verification-and-delivery) for test scope and isolation. Reuse [Fixture](MonoDeckTests/MonoDeckTests.swift) for test setup.

| Purpose | Command |
| --- | --- |
| Filter by test class | `task test TEST_FILTER=MonoDeckTests/VersionTests` |
| List test identifiers for filtering by method | `task test -- -enumerate-tests` |
| Save the result bundle to a new path | `task test TEST_FILTER=MonoDeckTests/VersionTests -- -resultBundlePath "/tmp/MonoDeck Tests.xcresult"` |
| Run the standard suite | `task test` |
| Run the opt-in Git read and cache benchmarks | `TEST_RUNNER_MONO_DECK_READ_BENCHMARK=1 task test TEST_FILTER=MonoDeckTests/RepositoryReadPerformanceTests` |

- In the sandbox, use read-only checks to verify write access to the user-level SwiftPM cache. If elevated permissions are required, request them on the first test run.
- A run fails if it finds no tests or skips every test, except when enumerating tests. On failure, check the full log at the path reported in the output. Append `-- --verbose` to stream the log. The runner removes result bundles by default. If it cannot verify test environment cleanup, it preserves the artifacts and returns a failure. See [run_tests.py](script/run_tests.py).
- The benchmarks write `BENCHMARK` records with timings, Git command counts, and cache statistics to the test log.

## Cleaning up temporary instances

1. Record existing instances before launching. After launch, record the current instance's PID, executable path, arguments, start time, temporary directory, and helper processes.
2. Verify the current instance's identity. Resume it first if a debugger paused it. Use `task quit PID=<pid>` to quit gracefully, then confirm the PID has exited. If quitting fails, verify the identity again before terminating that specific process. See [quit_app.swift](script/quit_app.swift) and [find_mock_app.py](script/find_mock_app.py).
3. After confirming exit, stop this instance's helper processes, check its data and preferences, and clean up logs and temporary scripts by exact path. Use `task mock:cleanup DIRECTORY="<temporary-directory>"` to remove leftover mock data. See [Key risks](AGENTS.md#key-risks) for process ownership and retention rules.

## Packaging and releases

- Maintain the product version and build number in [Version.xcconfig](Version.xcconfig). `task package` builds and packages the arm64 DMG and opens it automatically when `CI` is unset or empty. See [generate_version.sh](script/generate_version.sh) and [package_app.sh](script/package_app.sh).
- Run `task package` on Apple Silicon. On macOS 27 and later, it uses `diskutil image create` because macOS 27 deprecates `hdiutil create`. On macOS 26, it uses `hdiutil create`.
- Explicitly invoking the release skill and requesting the full workflow authorizes staging and committing only `Version.xcconfig` and `CHANGELOG.md`, and creating the corresponding local tag. Pushing a branch or tag and creating a GitHub Release require separate explicit authorization. See the [release skill](.agents/skills/release-mono-deck/SKILL.md) for the workflow and validation commands.

### CI and package requirements

- The [macOS CI workflow](.github/workflows/ci.yml) runs `Format`, `Test`, and `Build` in parallel on pull requests. `Build` uploads the arm64 DMG to the workflow run. To run CI manually, select `all`, `test`, or `build` in the Actions tab. The default is `all`.
- Push a `v*` tag to the upstream repository to trigger the [Release workflow](.github/workflows/release.yml). It validates the tag against the product version and changelog, then packages the app and tests the tagged commit in parallel. When both jobs succeed, it publishes `MonoDeck-<version>-arm64.dmg` to GitHub Releases.
- The update check queries GitHub's latest release and accepts only newer stable releases. Automatic installation requires a valid SHA-256 digest for the asset and verifies the downloaded file's size and digest. See [AppUpdateService](MonoDeckCore/Infrastructure/AppUpdateService.swift) and [AppUpdateInstaller](MonoDeckCore/Infrastructure/AppUpdateInstaller.swift).

## Maintaining documentation and prompts

- Write repository documentation and prompts in English. Retain the glossary's Simplified Chinese term column alongside the English definitions. Keep [README.md](README.md) and its Simplified Chinese counterpart [README_CN.md](README_CN.md) in sync, with language links near the top of both.
- Document product usage and user-facing risks in the README files, domain terms and public fields in [GLOSSARY.md](GLOSSARY.md), and repository collaboration conventions in [AGENTS.md](AGENTS.md). Use this guide for development entry points and cross-module constraints. Refer to the implementation and tests for specific rules and arguments.
- When changing the CLI contract, review the usage docs, bundled workflow, and [CLIContractTests](MonoDeckTests/CLIContractTests.swift). When changing prompts, review the description, default prompt, and invocation policy together. See the [bundled workflow](MonoDeck/Resources/mono-deck-workflow/SKILL.md), [bundled workflow configuration](MonoDeck/Resources/mono-deck-workflow/agents/openai.yaml), and [release skill configuration](.agents/skills/release-mono-deck/agents/openai.yaml).
- For documentation-only changes, verify paths, commands, section links, and `git diff --check`.
