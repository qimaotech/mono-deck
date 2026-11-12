---
name: mono-deck-workflow
description: Inspect and manage MonoDeck workspaces, repositories, worktree groups, and worktrees with the mono-deck CLI.
---

# MonoDeck workspace management

## Domain essentials

- **Workspace:** The shared files, member repositories, and task worktree groups managed together by MonoDeck. The workspace root is the main worktree of the workspace repository, which holds shared documents and workflows.
- **Member repository (repository):** A business repository registered with the workspace by remote URL. Its main worktree is at `repositories/<repository-id>`.
- **Task worktree group (group):** A named task context with one worktree per selected repository. The root at `worktrees/<group-name>` is a linked worktree of the workspace repository and is included automatically.
- **Task member worktree (member):** A linked worktree of a member repository at `worktrees/<group-name>/<repository-id>`, with its own `HEAD`, index, and working files.
- **Workspace record / Git worktree registration:** The workspace record stores MonoDeck's repository and membership data. Git worktree registration and directories on disk track separate state.
- Use **workspace**, **repository**, **worktree group**, and **worktree** in user-facing descriptions. Include the group or path when it clarifies the target.

## Context and commands

- Start with `mono-deck workspace tree --json` inside the workspace or add `--workspace <root>`. Use the tree root's absolute `path` as `--workspace <root>` on subsequent calls. Use `--json` for version 2 operation results and subcommand `--help` for syntax.
- Each node in `data.tree` has `type`, `path`, and `children`. Child paths are relative to their parent. `main-worktree` and `linked-worktree` nodes have `children: null`. `workspace`, `auxiliary-directory` (`repositories` and `worktrees`), and `group` nodes have arrays, including `[]` when empty.
- Queries read snapshots without taking the workspace lock, editing the record, or fetching. The tree checks directory and `.git` entry types. Missing, mistyped, and symlink paths are omitted even when registered. Use per-resource status or operation checks for Git health, remotes, and ownership. Refresh the relevant list if state may have changed.
- In `repo list --json`, read `resource["repository-id"]` on `repository` items. In `group list --json`, read `resource["group-name"]` on `group` items, alongside `member` items. Use these IDs and names as arguments and `resource.path` for paths relative to the workspace. Repository IDs come from URL basenames with trailing `.git` removed, are unique ignoring case, and stay the same when `--display-name` is set.
- The `repo add` plan action `maintain-workspace-ignore` can commit the entire workspace `.gitignore` when it differs from HEAD, including manual edits. Automatic commits require HEAD to resolve to a local branch.
- Use the App to initialize or recover a workspace, scan local repositories, import or export YAML, update repositories, or update worktrees.

## Planning and execution

- Every write accepts `--dry-run`, which takes precedence over `--yes` and checks local prerequisites without mutating resources, cloning, or fetching. A successful dry run has `status: "success"` and `dry-run: true`. Read `plan.actions` and `plan.deletions` as an unlocked snapshot of planned changes.
- For deletions, review the paths, current branches, risks, and warnings in `plan.deletions` from `--dry-run`. Preview again after a delay, external changes, or `confirmation-changed`. Pass `--yes` only when the user has authorized the current targets and risks. Reuse that authorization while the scope and risks match.
- The CLI executes commands with no deletion targets immediately after validation. Without `--yes`, it prompts for deletions in interactive mode and returns `confirmation-required` for JSON or non-interactive calls before applying any changes, including additions in the same edit. `group delete <group-name> --yes` skips the risk and local-change preview and resolves current targets under the lock. Ownership, target, and current-branch checks still apply.

## Creating groups

- Use a new group name that is both a single directory name and a valid Git branch name. If the user leaves it open, propose `<type>-<task>` in their language. Explain invalid names and confirm alternatives. `--branch` permits Git branch names with `/` and defaults to the group name. The initial branch setting stays fixed and applies to future members even after a worktree switches branches.
- Confirm the workspace root, group name, initial branch, and repository IDs before running `group create <group-name> [--branch <branch-name>] --repo <repository-id> [--repo <repository-id> ...]`. Reuse confirmation for the same inputs. Pass one `--repo` per repository ID, with at least one repository. Creation and member addition process resources in order. Use `group member add` to extend or complete an existing group.
- Creation uses local refs. Group roots reuse the matching available local branch or start from workspace HEAD. Members try the matching local branch, the locally known matching `origin` branch, then the locally recorded remote default branch. Report branch-reuse warnings and preserve reused branches.

## Editing membership

- `group edit <group-name> --repo <repository-id> [--repo <repository-id> ...]` takes the full desired repository set and deletes omitted worktrees and their current local branches. Use `group edit <group-name> --clear-members` on its own to remove all registered worktrees in the group. Both forms keep the group root and name.
- `group member add <group-name> <repository-id>...` adds missing worktrees and preserves existing ones. Both it and `group edit` use the saved initial branch for additions. `group member delete <group-name> <repository-id>...` removes the named worktrees and their current local branches.

## Destructive changes

- `group delete <group-name>` deletes the group root and all task member worktrees. `repo delete <repository-id>` deletes the member repository's managed task member worktrees and their current local branches, then moves its local clone directory to Trash.
- Report preview read warnings when local-change status is unknown. Authorized linked worktree cleanup can proceed when ownership and target checks pass.
- Linked worktree deletion permanently removes its files and current local branch, including ignored files, reused branches, and unmerged commits. A detached HEAD has no branch to delete. Success completes original-path removal, Git deregistration, and branch handling. Physical cleanup and disk space reclamation can continue in the background.
- When a worktree directory and its Git registration are missing, deletion may only remove the workspace record entry.

## Results and failures

- Judge completion from the final JSON on stdout, even on nonzero exit. Progress goes to stderr.
- Report completed and unfinished items, warnings even on success, and effects as applied, reverted, or unknown. Cancellation or partial failure can leave completed changes in place.
- Wait for the active write to finish. On `workspace-lock-timeout`, resolve contention and refresh the state and plan before retrying.
- Stop actions that depend on unavailable resources. For `cleanup-failed` or `save-outcome-unknown`, report causes, retained paths, and unknown effects. Preserve retained data and resolve the cause before retrying. Base recovery claims on observed effects.
- Use the CLI for managed changes. Keep private workspace records read-only and resolve CLI rejections through supported MonoDeck operations.

## Custom workflows

- Put workspace-specific instructions in `.agents/skills/mono-deck-workflow-addon/SKILL.md` under the workspace root. Opening or manually reloading the workspace replaces local edits to the bundled `SKILL.md` and `agents/openai.yaml` in both the working tree and index.
- A new group includes addon content from its group root commit. Existing groups keep their own checkout. Commit custom workflow changes only with the user's authorization.
