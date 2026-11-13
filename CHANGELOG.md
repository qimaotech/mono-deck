# Changelog

## [2.1.4] - 2026-11-13

### Fixed

- Prevent workspace switches while a workspace management dialog is open.
- Fast-forward repository and worktree branches even when Git is configured to squash merges.

### Changed

- Check for app updates using a manifest bundled with each GitHub release, avoiding GitHub API rate limits for releases that include it.

## [2.1.3] - 2026-11-12

### Changed

- Clarify workspace setup and update instructions, and update the bundled agent workflow guide for creating groups, managing membership, and previewing deletions.

## [2.1.2] - 2026-11-12

### Fixed

- Show repository and worktree update results in the same table layout. Click a status for details. When nothing needs updating, show a brief confirmation in the toolbar.

### Changed

- Use consistent terms for repositories, worktree groups, and task worktrees across the app, CLI help, and bundled workflow guide. Clarify which worktrees and branches are removed when editing or deleting a group or repository.

## [2.1.1] - 2026-11-11

### Fixed

- Center Settings, Setup, Software Update, and About over the main window when it is visible.
- Use consistent workspace dividers and keep the toolbar background visible when moving the window between displays.
- Show paths and statuses in consistent columns in deletion previews and update results. Press Esc to close a details popover while keeping its dialog open.
- Show a concise message when Git Browser cannot read local changes, with diagnostic output available under Details.

## [2.1.0] - 2026-11-10

### Added

- Use **Update Worktrees** in the sidebar to fast-forward group roots and member worktrees using local Git data. Worktrees with uncommitted changes, diverged branches, or other blockers are skipped. Results are grouped by worktree group. Click a status to see the current branch, base branch, and outcome details. Cancellation keeps completed updates.

### Fixed

- Preserve worktree files if Git fails to remove a worktree. MonoDeck restores the files to their original path when possible and reports where they were kept otherwise. Unlock locked worktrees with Git before deleting them.
- Leave unrelated staged `.gitignore` edits alone when a YAML reimport has no repository ignore rules left to save.
- Keep sidebar update buttons available during workspace startup and explain when an update cannot start.
- Fix localization of Git status tooltips and operation details.

## [2.0.0] - 2026-11-09

### Changed

- **Manual upgrade from Modu.** Quit Modu, download and install `MonoDeck.app` from the new DMG, then use Setup to install `mono-deck` and select your existing workspace folder. App settings start fresh. Setup can rebuild the workspace record from local Git data, preserving branches and changes in recognized repositories and worktrees. Use `$mono-deck-workflow` in your agent prompts.
- **Breaking CLI changes.** Replace `modu-cli workspace inspect` with `mono-deck workspace tree`. Use `group list`, `group create`, and `group edit` in place of `worktree list`, `worktree create`, and `worktree update`. Use `group delete`, `group member delete`, and `repo delete` for removals, and `repo add --display-name` in place of `--name`. Use `--dry-run` to preview writes and `--yes` to authorize deletions in JSON or non-interactive calls. `group edit --repo` supplies the full desired member list, so omitted members are deleted.
- **Breaking CLI JSON and workspace YAML changes.** CLI JSON uses a `schema-version: 2` operation result, including for successful tree queries. Read the tree from `data.tree` and use `repository-id` and `group-name` to identify resources in results. Export a fresh version 2 YAML file after recovering your workspace. To convert an existing export, set `version` to `2` and rename repository `name` to `display-name`. For each group, rename `repositories` to `repository-ids`, remove `created-at`, and set `branch-name` to the intended initial branch.
- Git Browser refreshes local changes and commit lists on demand, including when you switch selections or return to the app. Press `⌘R` to refresh while staying on the same selection.
- Deleting linked worktrees removes them from their original paths and updates Git registration and branches before returning. File cleanup and disk space reclamation can finish in the background.

### Added

- Import workspace YAML into an existing workspace to add missing repositories and groups. Matching repositories and registered groups are kept. A repository ID with a different remote URL is reported as a conflict. Retrying can reuse verified worktrees retained from an earlier attempt.
- Set an initial branch independently of the group name, including names like `feature/checkout`. New members use the saved branch name. The CLI can also add specific members with `group member add` while keeping the others.
- Click a repository's update status to see details about the result.

### Fixed

- Keep Setup responsive during CLI checks. Selecting an existing workspace in Settings can recover a missing workspace record, and Settings closes after a successful switch.
- Show saved Git details sooner at startup and preserve the current workspace view when record validation fails.

## [1.8.0] - 2026-11-03

### Added

- Git details show how many commits the current checkout is behind the local base branch. Click the count to see the full list. The unique commits list also shows all entries at once.
- Restore the last selected repository, group, member, or workspace home for each workspace, along with sidebar expansion and file tree collapse states. Also restore the main window position and size, sidebar width, and Git pane proportions.
- The app automatically reflects CLI changes to the active workspace record after repositories, groups, or members are added or removed.

### Changed

- **Breaking CLI change.** `workspace inspect` now returns a read-only directory tree. A successful `--json` call returns a node with `type`, `path`, and `children` directly. The root path is absolute, child paths are relative to their immediate parents, and the `children` field is `null` for worktree leaves. Invalid resources are omitted silently. Update scripts to read the root path from the root node's `path` and get repository and group IDs, per-item status, and errors from `items` in `repo list --json` and `worktree list --json`, respectively. Failures still use the operation result envelope.
- Git browsing, CLI queries, and YAML export now read only local data and run without taking or waiting for the workspace lock. If the base ref is missing, local changes remain visible. Update the main repository or sync the remote with an external Git tool, then refresh. Workspace record cleanup and bundled workflow synchronization run when the app starts, switches workspaces, or reloads manually.
- Cache the latest successful Git details and preload expanded resources while idle to make switching faster and reduce repeated reads. Watch for file and Git state changes, keep previous results visible during refresh, and show a retry message on failure. Press `⌘R` to retry.
- Restore the previous view at startup before running workspace maintenance and show maintenance progress in the title bar. If maintenance fails, read-only browsing remains available and users can inspect the failure and retry.
- Prepare clones outside the workspace lock when adding or importing repositories. YAML import into an empty workspace begins publishing only after all repositories are prepared successfully. Preparation failure or cancellation leaves repositories unregistered. Changes already published are retained if a later step fails. Writes to the same workspace retry briefly on lock contention and return `workspace-lock-timeout` if the lock remains unavailable.
- The app's local changes list hides changes inside submodules and changes to their recorded commits. It still shows `.gitmodules` changes, type changes, and conflicts. CLI queries and operation safety checks use the full Git status.
- Deletion previews now summarize risk. They skip separate counts for ignored files and unpushed commits, as well as checks for additional nested repositories in a group. Deletion still permanently removes the worktree and its current branch. Back up any content you want to keep.

### Fixed

- Restore the main window position and size before it first appears to prevent a visible jump. Finish initial setup checks before showing the setup window to reduce flicker.
- Fix missed workspace record synchronization and Git cache invalidation that could leave stale data visible after management operations or external changes.

## [1.7.6] - 2026-10-28

### Added

- Open the current workspace in a Git GUI directly from the workspace home.

### Changed

- Changing the app language asks for restart confirmation before saving the setting and restarting automatically. If the restart fails, the app prompts the user to restart manually.
- Improve button widths and spacing on the workspace home, show external tools in a consistent order, and align repository and group icons in the sidebar.

## [1.7.5] - 2026-10-28

### Changed

- Keep the software update window a fixed size so the layout stays steady while checking, downloading, verifying, and preparing to install an update.
- Distinguish failures during checks, downloads, and installation, and show retry guidance for each stage. Open the Details popover to view and copy diagnostic information.
- Once an update is ready, explain that users should wait for the current operation to finish or address its result before restarting.

## [1.7.4] - 2026-10-28

### Added

- Automatically check for updates by default when the app launches or becomes active, with at least 24 hours between checks. Users can turn off automatic checks in the update window. Background checks stay silent on failure or when the app is up to date. If an update is available, the window appears when the app is in the foreground and the current operation has finished. Download and installation still require confirmation.

### Changed

- Click the target version number in the update window to read its release notes. The window explains that Install and Restart downloads and installs the update, then restarts the app.
- Remove the redundant Close button from the update window. Press Esc to cancel the active operation or close the idle window.

## [1.7.3] - 2026-10-27

### Changed

- Stabilize the software update window layout and improve status messages, retry controls, and accessibility announcements.

### Fixed

- Keep previously loaded commits visible when loading more commits fails.

## [1.7.2] - 2026-10-27

### Changed

- Show a progress bar, percentage, and downloaded size while downloading an update, then show installer verification status.
- Use closed-folder icons throughout the sidebar and update disclosure arrows with a rotation animation that respects the system Reduce Motion setting.

## [1.7.1] - 2026-10-27

### Changed

- Allow automatic invocation of the bundled `mono-deck-workflow` skill when the task calls for it.
- Expand new worktree groups by default and preserve the expansion state of existing groups.
- Store update installers in the app cache. Remove the current download after installation preparation succeeds, or when the user cancels, checks again, or quits.

### Fixed

- Show an explicit error when Git details fail to load initially or when loading more commits fails.
- Limit YAML nesting depth and alias expansion during repository import. If the input is too complex, ask the user to reduce nesting or repeated aliases before retrying.

## [1.7.0] - 2026-10-27

### Added

- Add Follow System to language settings. Menus, system dialogs, and app text consistently use the selected language, Simplified Chinese or English, after a restart. Upgrading to this release resets the language setting to Follow System. Select a language again in Settings to keep it fixed.

### Changed

- Simplify setup and show the CLI installation location and workspace path directly. If an existing CLI installation is unusable, show its status and provide a reinstall action.
- Improve Simplified Chinese copy for operation results, configuration errors, and update failures. Expand Details to see the original diagnostics.

### Fixed

- Canceling or closing setup returns to the main window if it is still open and quits the app otherwise.
- Fix an issue that could stall Install and Restart during shutdown and prevent the update from completing.

## [1.6.1] - 2026-10-26

### Changed

- Remove duplicate titles from the setup and update windows.

### Fixed

- Complete the Simplified Chinese translations for setup, operation results, repository status, and update errors.
- Distinguish a missing command on PATH, a command conflict, and shell startup failure when checking the CLI. Show guidance for each case and list both the current command path and the expected path when they conflict.

## [1.6.0] - 2026-10-26

### Added

- After checking for updates, click Install and Restart to download and verify the installer. Once the app has finished shutting down, the installer replaces it and launches the new version while preserving workspace data. The app's folder must be writable by the current user. Rolling back requires manual action. If the new version fails to launch, reopen it manually from the original installation location.

### Changed

- Give the workspace path more room in setup to reduce truncation.

### Fixed

- Keep the CLI in sync with the app version. `~/.local/bin/mono-deck` now links directly to the CLI bundled in the current app, so updates and rollbacks switch the CLI automatically as long as the app path stays the same. Reinstall the CLI in setup when migrating a legacy installation or after moving the app to repair the link.

## [1.5.0] - 2026-10-26

### Added

- Add a link to the project's GitHub repository in the About MonoDeck panel.

### Changed

- Show a loading dialog with the destination path when switching workspaces in Settings. Cancellation is disabled during loading. On success, Settings closes and the main window appears.
- Open the workspace picker at the parent of the current workspace to make it easier to switch to a sibling folder.
- Use system folder icons for sidebar directories and worktree groups, with icons that reflect their expansion state.
- Use a consistent typography hierarchy and path style across setup, management forms, progress views, and results.

### Fixed

- Clear the old workspace path, candidates, and errors from setup after switching workspaces.

## [1.4.0] - 2026-10-24

### Added

- Choose Check for Updates… from the MonoDeck menu to check the latest stable GitHub release, then download and open its installer. Quit the app and drag the new version into Applications to replace it. Workspace data is preserved.

### Changed

- Refresh the workspace silently when the app becomes active.
- Opening or reloading a workspace replaces the bundled workflow's `SKILL.md` and `agents/openai.yaml`, discarding uncommitted changes in both the working tree and the index. Move any customizations into a separate `.agents/skills/mono-deck-workflow-addon/SKILL.md` before upgrading.

## [1.3.0] - 2026-10-22

### Added

- Scan one or more local folders for Git repositories, then select repositories to clone from their remotes into the workspace. The results include only repositories with a reachable remote and a valid default branch. Local development environments and uncommitted changes stay in their original folders.
- Select individual repositories or all repositories before importing from YAML.

### Changed

- Show hidden files by default in the YAML file picker to make configurations in hidden folders easier to select.
- Add the MIT license covering use and distribution of the project.

### Fixed

- Fix an unexpected app exit when closing Settings after initial workspace setup.

## [1.2.0] - 2026-10-21

### Added

- Show or hide MonoDeck with a global shortcut, `⌃⌥Z` by default. Showing the app restores a minimized window or reopens a closed window. Holding the shortcut triggers a single toggle.
- Record, change, or remove the global shortcut in Settings. The app saves it automatically and reports when the shortcut is unavailable.

## [1.1.1] - 2026-10-20

### Changed

- Standardize the Simplified Chinese term for Worktree Group across menus, the sidebar, and operation messages.
- Open the generated DMG automatically after local packaging.
- Use concise logs for development builds by default and show timings for the build, mock data preparation, and launch. Pass `--verbose` for full logs. A normal mock launch verifies and activates the new instance.

### Fixed

- Accept cancellation requests during non-interruptible phases of operations such as deletion and import. Finish the current item, skip the remaining items, and show that cancellation is pending.
- Treat canceled workspace checks during repository addition or import as cancellations and restore cancellation handling when workspace import reaches group checks.
- Try fetching to recover a missing remote default branch ref in Git details. If the comparison base is unavailable or reading commits fails, hide the commits pane and keep available worktree changes visible.

## [1.1.0] - 2026-10-19

### Added

- Open repositories and worktrees in iTerm2, Xcode, and GitHub Desktop. Xcode prefers a workspace, project, or Swift package in the directory.

### Changed

- Rearrange actions and external tools on the workspace home, use consistent button widths based on selected tool names, and improve how long names appear in menus.
- Share status reads between workspace refresh and Git details preloading to reduce duplicate checks.
- Require explicit invocation of the bundled `mono-deck-workflow` skill and confirm the group name and full repository list before creating a group.
- Add the `Auto-committed-by: MonoDeck` trailer to automatic workspace commits so they are easy to identify.

### Fixed

- Size the changes and commits panes in Git details to their content. Allow the divider to move when the content exceeds the available space.
- Remove an extra focus ring from external tool dropdown buttons.
- Preserve completed items and earlier failures in the summary when a workspace check is canceled, and return the correct cancellation status.
