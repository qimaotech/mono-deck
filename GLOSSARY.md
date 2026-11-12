# Domain Glossary

Use these terms in product discussions, UI copy, documentation, and code. English terms are canonical; the Chinese column provides their Chinese names. Short forms are appropriate when the surrounding context is unambiguous.

The implementation defines business rules, serialized formats, and command arguments. Product workflows are described in [README.md](README.md). Development workflows and engineering constraints are described in [DEVELOPMENT.md](DEVELOPMENT.md).

## Workspace structure

Sources: [workspace models](MonoDeckCore/Models/WorkspaceModels.swift), [resources](MonoDeckCore/Models/Resource.swift), and [workspace tree](MonoDeckCore/Workflows/WorkspaceTree.swift).

MonoDeck manages multiple repositories in a workspace and groups their task checkouts. The product terms describe each entity's role in the workspace. Git worktree terms describe how those roles are implemented on disk.

| English term | Chinese name | Definition and usage | Current code / path |
| --- | --- | --- | --- |
| Workspace | 工作区 | The top-level unit managed by MonoDeck. It includes the workspace root, shared workspace files, registered member repositories, and task worktree groups. | `WorkspaceRecord`; `WorkspaceService`; `Resource.workspace()` |
| Member repository (Repository) | 成员仓库（仓库） | A business repository registered with the workspace by remote URL. Its local clone lives at `repositories/<repositoryID>`. Each group that includes the repository has a task member worktree for it. | `Repository`; `WorkspaceRecord.repositories`; `Resource.repository(id)` |
| Task worktree group (Group) | 任务工作树分组（分组） | A named task context that brings together shared workspace files and the selected repositories' task member worktrees. Creating a group requires at least one member. YAML import can create a group with only its root, and removing all members leaves the group root intact. | `WorktreeGroup`; `WorkspaceRecord.groups`; `worktrees/<groupName>` |
| Task member worktree (Member) | 任务成员工作树（成员） | A member repository's checkout for a particular task group. The group name and repository ID together identify the member. A member repository can participate in multiple groups. | `Resource.member(groupName: groupName, repositoryID: repositoryID)`; `WorktreeGroup.repositoryIDs`; `worktrees/<groupName>/<repositoryID>` |
| Resource | 资源 | The common operation target or inspection identity. It can represent the workspace, CLI installation, a member repository, a task group at its root, or a task member worktree. | `Resource`; `Resource.Kind` |
| Auxiliary directory | 辅助目录 | A structural container for repositories or groups. The `repositories/` and `worktrees/` folders are not Git worktrees themselves. | `WorkspaceTreeNode.Kind.auxiliaryDirectory` |
| Workspace tree | 工作区目录树 | The structural view returned in `data.tree` by `workspace tree`. It shows the workspace root, auxiliary directories, and registered repositories, groups, and members whose directories and `.git` entry types exist as expected. Its scope is the workspace layout. Git health, remotes, worktree ownership, and file changes are checked separately. | `WorkspaceTreeNode`; `workspaceTree`; CLI `workspace tree` |

### Git implementation

| Example directory | Product role | Git identity |
| --- | --- | --- |
| `example-workspace/` | Workspace | Main worktree of the workspace repository |
| `repositories/order-service/` | Member repository | Main worktree of the `order-service` repository |
| `worktrees/feature-checkout/` | Task worktree group | Linked worktree of the workspace repository |
| `worktrees/feature-checkout/order-service/` | Task member worktree | Linked worktree of the `order-service` repository |

| English term | Chinese name | Definition and usage | Current code / path |
| --- | --- | --- | --- |
| Workspace root | 工作区根目录 | The canonical absolute directory to which a workspace record is bound. It is the workspace repository's main worktree. | `WorkspaceRecord.root`, `rootURL` |
| Workspace repository | 工作区仓库 | The Git repository that stores shared documents, prompts, and workflow files. It provides the workspace root and each group's root worktree. | Git repository at `WorkspaceRecord.rootURL` |
| Group root worktree | 分组根工作树 | The workspace repository's linked worktree at `worktrees/<groupName>`. Selecting a task group targets this directory for Git inspection and external tools. | `Resource.group(name)`; `WorkspaceRecord.groupURL(name)` |
| Worktree | 工作树 | A Git checkout with its own `HEAD`, index, and working files. Use `worktree` for the checkout and keep `working tree` in existing Git state labels and APIs. | Main worktrees and linked worktrees |
| Main worktree | 主工作树 | The primary checkout created by `git init` or `git clone`. MonoDeck requires a `.git` directory at its managed main worktree roots. The worktree keeps this role when it checks out a different branch. | Workspace root; `repositories/<repositoryID>`; tree type `main-worktree` for repository leaves |
| Linked worktree | 链接工作树 | An additional checkout that shares Git objects and branch refs with its owning repository. Each group root belongs to the workspace repository, and each task member worktree belongs to its member repository. | `WorktreeRegistration`; `worktrees/<groupName>`; `worktrees/<groupName>/<repositoryID>` |

The configured initial branch name is used in separate repositories when setting up a group. Each worktree can subsequently switch branches independently.

## Identity and persisted structure

Sources: [repository identity](MonoDeckCore/Models/RepositoryIdentity.swift), [workspace store](MonoDeckCore/Infrastructure/Persistence/WorkspaceStore.swift), and [YAML workflows](MonoDeckCore/Workflows/YAMLService.swift).

| English term | Chinese name | Definition and usage | Current code / field |
| --- | --- | --- | --- |
| Repository ID | 仓库标识 | The final component of the repository URL path with a trailing `.git` removed. Used for directory names, member references, and CLI `--repo` values. IDs must be unique within a workspace, ignoring case. | `Repository.id`; `RepositoryIdentity.id`; `Resource.repositoryID` |
| Repository URL | 仓库 URL | The remote URL used to clone and validate a registered repository. It is distinct from the local repository path. | `Repository.url`; UI `Repository URL` |
| Display name | 显示名称 | An optional human-readable repository label. It falls back to the repository ID and does not change identity, paths, or CLI arguments. | `Repository.displayNameOverride`, `displayName`; CLI `repo add --display-name` |
| Group name | 分组名称 | The group key and directory name, also used as the default initial branch name when none is specified at creation. It must be a single directory component and a valid Git branch name. Editing membership does not rename the group. | Key in `WorkspaceRecord.groups`; UI `Group Name`; CLI `<group-name>` |
| Initial branch name | 初始分支名 | The literal local branch name used to create a group root and its members, and later members added to that group. Defaults to the group name, permits valid Git branch slashes, and is read-only after creation. It does not track subsequent checkout changes. Recovery uses the group root’s current branch, falling back to the group name for detached HEAD. | `WorktreeGroup.branchName`; JSON/YAML `branch-name`; CLI `group create --branch` |
| Workspace record | 工作区登记 | The local persisted registration binding a canonical workspace root to repository declarations and group membership. Stored in MonoDeck application support, outside the workspace Git repository. Keep this local registration distinct from portable workspace configuration. | `WorkspaceRecord`; `WorkspaceStore`; `WorkspaceDocumentValidation.validateRecordDocument` |
| Workspace record entry | 工作区登记项 | A repository declaration, group declaration, or member ID stored in the local workspace record. A worktree is registered in a group when the group's record lists its repository ID. Git worktree registration and the files on disk track separate state. | `WorkspaceRecord`; `WorktreeGroup.repositoryIDs`; `Resource`; effect `remove-record-entry` |
| Git worktree registration | Git 工作树注册 | Git's record associating a worktree path, HEAD, branch, and lock state with its owning repository. This is separate from MonoDeck's workspace record; a worktree may exist in Git without being managed by MonoDeck. | `WorktreeRegistration`; `Git.registrations` |
| Workspace configuration (YAML) | 工作区配置（YAML） | Portable repository URLs and optional display names, plus group names, initial branch names and member repository IDs. A newly imported group receives a creation time in the local workspace record. Use **record** for local registration and **configuration** for this portable structure. | `YAMLService.swift`; `WorkspaceDocumentValidation.validateConfigurationDocument`; UI `Configuration` |

## Git inspection

Sources: [Git models](MonoDeckCore/Models/GitModels.swift), [Git inspection](MonoDeckCore/Infrastructure/Git/GitInspection.swift), and [detail view](MonoDeck/Features/GitBrowser/GitBrowserView.swift).

| English term | Chinese name | Definition and usage | Current code / UI |
| --- | --- | --- | --- |
| HEAD / Head branch | HEAD／当前分支 | HEAD identifies the selected worktree's current checkout; when attached, it points to the current local branch. A detached HEAD is displayed using a commit ID rather than a branch name. | `GitWorkingState.branch`, `head`, `headOID`; `GitSummary.head`; UI `Head branch` |
| Base branch | 基准分支 | The locally known remote-tracking branch referenced by `refs/remotes/origin/HEAD`, such as `origin/main`, used for Git Browser comparisons. It is not necessarily the current branch's upstream or a creation starting point. It may be unavailable. | `GitSummary.base`, `baseOID`; UI `Base branch` |
| Remote default branch | 远端默认分支 | The default branch advertised by the remote. Adding a repository checks it online; later browsing uses the local `origin/HEAD` record, which may be stale. Never assume its name is `main` or `master`. | `WorkspaceService.remoteDefault`; local `refs/remotes/origin/HEAD` |
| Local changes | 本地更改 | Uncommitted file changes in the selected worktree, including staged, unstaged, untracked, and conflicting entries. The App hides submodule-only changes; CLI inspection and operation safety checks use full Git status. | `[FileChange]`; `GitChangeVisibility`; UI `local changes` |
| Staged changes / Index | 已暂存更改／暂存区 | The staged side of a file's Git status, comparing the index with HEAD. Do not confuse staging with saving to a Git stash. | `FileChange.index`; UI `Staged` |
| Unstaged changes / Working tree | 未暂存更改／工作树 | The working-file side of a file's Git status, comparing working files with the index. Untracked files are represented on this side. | `FileChange.workingTree`; UI `Unstaged` |
| Unique commits | 独有提交 | Commits reachable from the selected worktree's HEAD but not from the base (`base..HEAD`). This list is neither all repository history nor a list of uncommitted changes. | `GitBrowserState.uniqueCommits`; UI `unique commits` |
| Behind commits | 落后提交 | Commits reachable from the base but not from the selected HEAD (`HEAD..base`). Shown through a behind-count button and popover, separately from unique commits. They do not necessarily correspond to commits never fetched locally. | `GitBrowserState.behindCommits`; `BehindCommitsButton`, `BehindCommitsPopover` |
| Starting commit | 分支起点提交 | The commit used to create a new group branch. A new group root branch starts at the workspace HEAD, with a locally known same-name remote branch preferred during YAML import. A new member branch starts at the locally known same-name remote branch or falls back to the locally known remote default branch. Reusing an existing local branch preserves its tip. | `WorktreeCreation.oid`; `creationPlan`; distinct from `GitSummary.baseOID` |
| Branch reuse | 分支复用 | Checking out an available existing local branch with the configured initial branch name instead of creating a new branch. Its commits are kept; a comparison warning does not update or merge that branch. | `WorktreeCreation.reused`; item data `reused-branch` only when a reuse warning is reported |
| Git details snapshot / Cache | Git 详情快照／缓存 | A previously read view of local changes, summary, and comparison commits, reused to display details quickly. It can be stale and is distinct from the workspace record or a backup. | `GitDetailSnapshot`; `ResourceDetailCacheIdentity`; `RepositoryDiskCache`; UI `Showing previous results.` |

## UI elements

These are names for discussing existing UI elements, including elements without a visible title. Literal English labels retain their current spelling and casing. Dialog titles use sentence case. Operation result titles describe outcomes; progress titles identify the action and target. Chinese names describe the element; where it has a localized label, they follow that label.

Sources: [workspace UI](MonoDeck/Features/Workspace/), [Git Browser UI](MonoDeck/Features/GitBrowser/), [management UI](MonoDeck/Features/Management/), and [localized copy](MonoDeck/Resources/Localizable.xcstrings).

| English term | Chinese name | Element and scope | Current implementation / label |
| --- | --- | --- | --- |
| Workspace sidebar | 工作区侧栏 | The resource navigation area. Its section headers are containers, not selectable workspace resources. | `WorkspaceSidebar` |
| Repositories section | 仓库区 | Sidebar collection of registered member repositories. | Literal sidebar header `repositories` |
| Worktrees section | 工作树区 | Sidebar collection of groups with nested member rows. Use **group row** and **member row** to distinguish the two levels. | Literal sidebar header `worktrees`; `Resource.group`, `.member` |
| Workspace home | 工作区首页 | The start view shown when no sidebar resource is selected. External tools opened here target the workspace root. It is not a group or Git Browser selection. | `ContentView` with `WorkspaceModel.selection == nil`; `Let’s start` |
| Git Browser (Resource details) | Git 浏览器（资源详情） | The detail pane for a selected member repository, task group, or task member worktree. It reads local Git data from the selected resource's checkout. Development, commits, and merges happen in external tools. | `GitBrowserView`; `GitBrowserModel` |
| Git summary | Git 摘要 | The card showing the resource path, base branch, current branch, and branch-comparison availability or behind count. | `GitBrowserView.summary`; `GitSummary` |
| Local changes tree | 本地更改树 | The file tree under `local changes`, with staged and unstaged status indicators. Directory rows group changed paths. | `ChangeNode`; `GitBrowserSections.localChangesSection` |
| Unique commits list | 独有提交列表 | The list under `unique commits`, displaying subject, author, date, and abbreviated commit ID. | `GitBrowserSections.uniqueCommitsSection` |
| Behind commits popover | 落后提交弹出面板 | The list opened from the behind-count button beside the branch summary. | `BehindCommitsPopover`; `N commits behind {base}` |
| External tool toolbar | 外部工具栏 | Tool buttons and their tool-selection menus. Categories are `Git GUI`, `Terminal`, `Editor`, and `Agent`; the target is the current directory. Opening the workspace explicitly targets its root. | `ToolBarView`; `ExternalTool`; `WorkspaceModel.currentURL` |
| Management sheet | 管理表单 | The sheet for adding or importing repositories, creating or editing groups, or previewing deletion. **Sheet** describes the presentation; use the operation's name in user-facing copy. | `ManagementView`; `ManagementSheet` |
| Repository filter | 仓库筛选 | Narrows the available repository list by display name in group creation and editing sheets. Filtering and clearing the filter preserve selected members. | `RepositoryFilterField`; UI `Filter repositories`, `Clear filter` |
| Operation progress / Result | 操作进度／操作结果 | Progress identifies the active phase and completed items; results describe per-resource outcomes, warnings, and effects. A result is not a promise that all resources changed together. | `OperationProgressView`; `ResultView`; `UpdateResultsView` |
| Setup window | 初始设置窗口 | The `MonoDeck Setup` flow for CLI installation and workspace selection. Choosing a directory sets a candidate; `Continue` validates and opens, initializes, or recovers it. | `SetupView`; `SetupModel` |
| Settings window | 设置窗口 | The preferences window containing general preferences, global shortcut, workspace selection, and YAML configuration actions. Distinguish it from Setup. | `SettingsView`; `Settings`, `Configuration` |
| Software Update window | 软件更新窗口 | The flow for checking, downloading, and installing a new MonoDeck release. It is separate from updating Git repositories. | `AppUpdateView`; `AppUpdateModel`; `Software Update` |

## Operations and boundaries

Sources: [workspace workflows](MonoDeckCore/Workflows/WorkspaceService.swift), [repository workflows](MonoDeckCore/Workflows/RepositoryService.swift), [group workflows](MonoDeckCore/Workflows/WorktreeGroupService.swift), [deletion](MonoDeckCore/Workflows/DeletionService.swift), and [YAML workflows](MonoDeckCore/Workflows/YAMLService.swift).

| English term | Chinese name | Meaning and boundary | Current code / UI / command |
| --- | --- | --- | --- |
| Add repository | 添加仓库 | Clone a remote repository into the workspace and register it. An optional display name does not change its ID. The operation also maintains the workspace ignore file and may automatically commit that file, including when the repository already exists. | `addRepository`; `Add Repository`; CLI `repo add` |
| Import repositories | 导入仓库 | Select remote URLs extracted from YAML or discovered by scanning local repositories, then clone them into the workspace. Local scanning does not move the source directories or import their uncommitted changes. | `importRepositories`; `Import repositories`; result command `repo.import` covers both import sources |
| Import / Export workspace configuration | 导入／导出工作区配置 | Share repository and group structure using YAML. Import adds missing items and skips repositories with matching IDs and URLs and registered groups with matching names. A repository ID mapped to a different URL is a conflict. An imported group is registered once its root and all members are ready. Import can reuse verified existing worktrees, including those kept after failure or cancellation. | `importWorkspaceYAML`, `exportYAML`; Settings `Import YAML…`, `Export YAML…` |
| Create group | 创建分组 | Create the group root and selected members using the configured initial branch name, reusing available local branches when present. Use a new group name for creation and member addition to extend an existing group. Creation uses only locally known commits. MonoDeck checks and creates resources one at a time, and later failures retain completed roots and members. | `createGroup(repositoryIDs:)`; UI `Create Worktree Group`; CLI `group create` |
| Add group members | 添加分组成员 | Add missing member worktrees to an existing group, preserving all current members and the group root. Existing members are validated and kept. | `addGroupMembers`; CLI `group member add` |
| Edit group | 编辑分组 | Change group membership by creating added members and deleting removed members. It keeps the group root and name; it does not synchronize branches or workspace documents. | `editGroup(repositoryIDs:)`; UI `Edit Worktree Group…`; CLI `group edit` |
| Update repositories | 更新仓库 | For each eligible member repository, fetch the branch recorded by local `origin/HEAD` and attempt a fast-forward-only merge in its main worktree. The main worktree must be clean and have the corresponding local branch checked out. | `updateRepositories`; UI `Update Repositories`; result command `repo.update` |
| Update worktrees | 更新工作树 | Use local Git data to fast-forward eligible current branches at registered group roots and task member worktrees. The base is the owning repository's local `origin/HEAD`. When that reference is absent in the workspace repository, group roots use the branch checked out at the workspace root. | `updateWorktrees`; UI `Update Worktrees`; result command `worktree.update` |
| Refresh Git details | 刷新 Git 详情 | Re-read local Git state for the current selection. It does not fetch, merge, or perform workspace maintenance. | `refreshDetail`; UI `Refresh Git Details` (`⌘R`) |
| Workspace maintenance / Reload | 工作区维护／重新加载 | Validate and clean local registration, maintain managed workspace files, and commit them when needed. Opening or manually reloading a workspace can perform maintenance; automatic record refresh is read-only. | `openWorkspaceWithRecord`; `maintainWorkspace`; `Reload`, `Retry Maintenance` |
| Workspace recovery | 工作区登记恢复 | Rebuild a missing local workspace record from recognized repositories and worktrees using local Git data during Setup or manual workspace selection in Settings. It preserves existing branches and changes; it is separate from YAML import or restoring a backup. | `recoverWorkspaceRecord`; Setup `Continue`; `AppModel.changeWorkspace` |
| Delete member / Group | 删除成员／分组 | Permanently remove the target linked worktrees and their current local branches, including reused branches. Deleting a branch can make unmerged commits unreachable. Success completes original-path removal, Git deregistration, and current-branch handling. File cleanup and space reclamation may still await best-effort background cleanup. Deleting a member keeps the group root. Deleting a group includes its root and members. | `DeleteRequest.member`, `.group`; UI `Delete worktree?`, `Delete worktree group?`; CLI `group delete` or `group member delete` |
| Delete repository | 删除仓库 | Delete the member repository's managed task member worktrees and their current branches, then move its local clone directory to Trash. | `DeleteRequest.repository`; CLI `repo delete` |
| Dry run / Operation plan | 预演／操作计划 | Validate local prerequisites and describe planned actions without applying effects. Deletion targets include their current branches, `git-registered` state, and risks. Git registration is separate from the workspace record entry. The plan is an unlocked snapshot, not a reservation. | `OperationPlan`; `PlannedAction`; `OperationResult.dryRun`; `--dry-run` |
| Deletion preview | 删除预览 | A snapshot of targets, current branches, status, and risks before destructive execution. Unreadable status remains unknown and does not block linked worktree deletion. Execution validates Git ownership and any authorized targets and branches; it does not require matching remotes or readable commits for linked worktrees. | `DeletionTarget`; `previewDelete`; `OperationResult.plan` |
| Remove workspace record entry | 移除工作区登记项 | Remove a resource's local registration entry. This describes a metadata effect and is distinct from deleting files or branches. | Effect action `remove-record-entry` |
| Workflow skill | 工作流技能 | The bundled `mono-deck-workflow` instructions installed into a workspace for an Agent to discover and use. Managed copies are maintained by MonoDeck. | `.agents/skills/mono-deck-workflow/`; `InstallationService` |
| Software update | 软件更新 | Install a newer version of MonoDeck and restart the application. Always qualify **update** with its target when repository updates could also be meant. | `AppUpdateService`; `Check for Updates…`, `Install and Restart` |

## Status and outcomes

Sources: [operation statuses](MonoDeckCore/Models/OperationStatus.swift), [operation results](MonoDeckCore/Models/OperationModels.swift), and [UI status mappings](MonoDeck/SharedUI/InterfaceText.swift).

| English term | Chinese name | Meaning | Current code / UI |
| --- | --- | --- | --- |
| Clean / Dirty | 无更改／有更改 | Whether the inspected worktree has uncommitted changes under the applicable visibility policy. Clean does not mean merged, pushed, or safe to delete. | `ResourceState.dirty`; `Clean`, `Dirty`; sidebar change dot |
| Unset | 未加入 | A repository is not currently a member of the group being edited. It does not mean the repository is missing or unconfigured. | Group editor `Unset` |
| Unavailable | 不可用 | A resource cannot be validated or its state cannot be read. Unknown status must not be treated as clean. | `ResourceState.available`; UI `Unavailable` |
| Operation result / Item result | 操作结果／单项结果 | The overall operation outcome and the outcome for an individual resource. Either may report completed effects even when its status is failed or cancelled. | `OperationResult`; `ItemResult` |
| Completed | 已完成 | A successful operation or item. Additional warnings may still be present. | `OperationStatus.success`; UI `Completed` |
| Partially completed | 部分完成 | A mix of successful items and failed or skipped items. Inspect item results to understand the actual effects. | `OperationStatus.partialSuccess`; JSON `partial-success` |
| Skipped / Not processed | 已跳过／未处理 | Skipped describes a resource action that was unnecessary or could not proceed; related maintenance effects may still be reported. Not processed identifies remaining work that was not attempted after the operation stopped. Inspect item effects separately from status. | `OperationStatus.skipped`; reason `not-processed`; UI `Skipped`, `Not processed` |
| Failed / Cancelled | 失败／已取消 | Failure reports an error; cancellation reports a stopped operation. Neither guarantees a rollback of completed effects. | `OperationStatus.failed`, `.cancelled` |
| Warning | 提示 | Additional information attached to a successful item, such as a reused branch being behind the base. It does not by itself change success into failure. | Item data `warning-code`; UI `Warnings`, `Completed with warnings` |
| Confirmation required | 需要确认 | A plan has been produced and destructive execution still requires authorization. No part of the pending mutation has executed. | `OperationStatus.confirmationRequired`; JSON `confirmation-required` |
| Effect | 操作效果 | A reported action and target with an observed state: applied, reverted, or unknown. Unknown means the outcome could not be confirmed; retained paths and completed effects must be reported accurately. | `Effect`; UI `Applied`, `Cleaned up`, `Unconfirmed` |

## External data and CLI contract

Workspace records, exported YAML, and CLI JSON use schema version 2. Cache entries and their storage directory also use v2. Old formats, fields, commands, and flags are not migrated or accepted as aliases. Format versions are independent of the product version.

| Canonical concept | Chinese name | External form | Meaning |
| --- | --- | --- | --- |
| Repository ID | 仓库标识 | Resource `repository-id`; `--repo <repository-id>`; member command arguments | Identifies a repository independently of its display name. |
| Display name | 显示名称 | Repository JSON/YAML `display-name`; `repo add --display-name` | Maps to `displayNameOverride`; `displayName` resolves the fallback. |
| Group name | 分组名称 | Resource `group-name`; CLI `<group-name>` | Identifies the group and its root worktree. |
| Initial branch name | 初始分支名 | Required group JSON/YAML `branch-name`; `group create --branch <branch-name>` | The creation and future-member default, independent of the current branch. |
| Group membership | 分组成员关系 | Group JSON/YAML `repository-ids` | Stores repository IDs. Workspace-level `repositories` contains repository declarations. |
| Unique commits | 独有提交 | Cache field `unique-commits` | Maps to `GitDetailSnapshot.uniqueCommits`. |
| Workspace record persistence | 工作区登记持久化 | Effect `save-workspace-record`; errors `workspace-record-missing`, `invalid-workspace-record`, `workspace-record-write-failed` | Portable YAML validation uses `invalid-workspace-configuration` instead. |
| Resource entry removal | 资源登记项移除 | Effect `remove-record-entry` | Removes metadata from the workspace record, separately from deleting files or Git branches. |
| Group operations | 分组操作 | `group list/create/edit/delete`; `group member add/delete` | Creation requires a new name. Editing replaces the complete member set; member commands change only the named members. |
| Repository import | 仓库导入 | Result command `repo.import` | Covers repository imports from YAML and locally discovered remote URLs. |
| Operation result | 操作结果 | `schema-version`, `command`, `workspace`, `status`, `reason-code`, `message`, `items`, `plan`, `data`, `dry-run` | Every CLI JSON response uses the same envelope, including errors. Absent optional top-level values are encoded as `null`. Directory trees are in `data.tree`. |
| Operation plan | 操作计划 | `plan.actions`, `plan.deletions` | Planned actions and deletion risks are separate from observed item effects. |

All write commands accept `--dry-run`. A successful dry run returns a local plan without changing workspace resources, cloning, or fetching. `--dry-run` takes precedence over `--yes`.

For writes with deletion targets, `--yes` authorizes the targets of the current command, subject to execution-time validation. Without `--yes`, an interactive terminal prompts for confirmation unless `--json` is set. JSON and non-interactive calls without `--yes` return `confirmation-required` before applying changes. `group delete --yes` determines and deletes the current targets under lock without an unlocked risk or status preview.

## Naming and wording rules

- Use **workspace**, **member repository**, **task worktree group**, and **task member worktree** for the product roles. Use **repository**, **group**, and **member** as short forms when the context is clear. Use **project** only when referring to an external tool's own concept.
- Use **workspace** (工作区), **repository** (仓库), **worktree group** (工作树分组), and **worktree** (工作树) in user-facing copy. Use these names in actions, confirmations, progress, results, and usage instructions. Include the group or path when it clarifies the target of an operation.
- Use **main worktree** and **linked worktree** to describe Git checkout roles. Use **group root worktree** when referring specifically to the checkout at a task group's root. `Resource.group` targets that directory for resource operations.
- Distinguish **repository ID**, **display name**, **group name**, and **branch** in new names and APIs. Use `repositoryID` for identity, `displayNameOverride` for the optional label, `displayName` for the resolved label, `groupName` for a group key, and `branchName` for the configured initial branch name.
- Name an operation by its target and effect. Use **update repositories** for fetching and fast-forwarding member repositories in their main worktrees, and **update worktrees** for fast-forwarding task checkouts using local Git data. Use **refresh Git details** for reading the selected resource's local state. Avoid an unqualified **sync** that could imply fetching, merging, or updating every group.
- Use the established Swift vocabulary and casing, such as `WorktreeGroup`, `Repository`, `member`, `baseOID`, and `headOID`. Use canonical CLI commands and serialized names; do not add legacy aliases when renaming internal symbols.
- When introducing a new business concept, propose its English term, Chinese name, semantics, and code mapping here. Keep operational procedures in README or DEVELOPMENT and implementation details in code.
