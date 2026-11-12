# MonoDeck

**English** | [简体中文](README_CN.md)

MonoDeck is a native macOS app that helps developers manage multiple repositories in one workspace, organize cross-repository tasks, and build AI workflows tailored to their work.

## Features

- Add and update repositories in batches. Create, edit, and clean up worktree groups.
- Inspect local changes, unique commits, and behind commits. Open a group or member directory in an external tool.
- Let agents manage repositories and groups through the `mono-deck` CLI and the `mono-deck-workflow` skill.

## Workspace structure

A workspace contains shared files, member repositories, and task worktree groups. Each group brings together worktrees from the repositories needed for a task.

```text
example-workspace/               # Workspace
├── repositories/
│   ├── order-service/           # Member repository
│   └── storefront-web/          # Member repository
└── worktrees/
    └── feature-checkout/        # Task worktree group
        ├── order-service/       # Task member worktree
        └── storefront-web/      # Task member worktree
```

The workspace root is the main worktree of the workspace repository, which stores shared prompts, skills, and documentation. Each group root is a linked worktree of that repository. Each member repository has its main worktree under `repositories/`, and its task member worktrees are linked worktrees of that same member repository.

![MonoDeck workspace with a task worktree group, local changes, and unique commits](./.github/assets/1-workspace-overview.png)

## Getting started

MonoDeck requires an Apple Silicon Mac running macOS 26.5 or later. Download the DMG from [Releases](https://github.com/qimaotech/mono-deck/releases) and drag `MonoDeck.app` into Applications.

The `MonoDeck.app` inside the DMG is signed ad hoc and ships without Apple notarization. If macOS quarantine prevents the app from opening, verify the download source before running this command and opening the app again.

```bash
xattr -dr com.apple.quarantine /Applications/MonoDeck.app
```

1. Launch MonoDeck, then follow Setup to install the CLI and select a workspace directory. For your first workspace, you can use a dedicated empty directory.
2. Add repositories by URL or use the **Import** menu in the **Add Repository** sheet to scan local repositories. Both methods clone from the remote using your local Git credentials. Uncommitted changes in local repositories stay in their original directories.
3. Choose **Create Worktree Group** and select the repositories for the task. A group name must be a single directory component that is also a valid Git branch name, such as `feature-checkout`. The initial branch name defaults to the group name and can be set to a name like `feature/checkout`. Group creation uses local Git references and reuses an existing local branch of the chosen name when available. Members added later use the same initial branch name and branch selection rules.

   ![Worktree group creation dialog with a group name, an initial branch, and two selected repositories](./.github/assets/2-create-worktree-group.png)

4. Select a group or a member, then use the toolbar to open it in an installed agent, editor, terminal, or Git tool. Develop, commit, and merge in the external tool.
5. Use Git Browser to inspect local changes, unique commits, and behind commits. Comparisons use the locally recorded remote default branch as their base.

- **Update Repositories** is the update icon in the `repositories` section. MonoDeck fetches the branch recorded by each repository's local `origin/HEAD` and attempts a fast-forward-only merge in its main worktree. The main worktree must be clean and have the corresponding local branch checked out.
- **Update Worktrees** is the update icon in the `worktrees` section. MonoDeck uses local Git data to fast-forward the current branches of registered group roots and their worktrees. Each worktree uses its repository's local `origin/HEAD` as the base. Group roots use the workspace repository's local `origin/HEAD`, falling back to the branch checked out at the workspace root only when that reference is absent. MonoDeck skips worktrees with an unavailable base, a detached HEAD, uncommitted changes, an ongoing Git operation, or a diverged branch.

Cancellation keeps completed updates.

![Worktree update results with updated and skipped items organized by group](./.github/assets/3-worktree-update-results.png)

After reinstalling, you can select the original workspace in Setup or Settings. If its workspace record is missing, MonoDeck attempts to rebuild it from local Git data, preserving branches and changes in the repositories and worktrees it recognizes.

## CLI and agents

After installing the CLI through Setup, run these commands from the workspace directory. This example assumes you have already added `order-service` and `storefront-web`.

```bash
mono-deck workspace tree --json
mono-deck group create feature-checkout --branch feature/checkout --repo order-service --repo storefront-web
mono-deck group delete feature-checkout --dry-run
```

Pass a repository ID to `--repo`. The ID is the last component of the repository URL with any trailing `.git` removed. When running outside the workspace, use `--workspace` to specify the root directory. For arguments, see each subcommand's `--help`. For the JSON output format, see the [CLI contract](GLOSSARY.md#external-data-and-cli-contract).

`group edit --repo` specifies the complete desired member set. MonoDeck deletes omitted members. Use `--dry-run` to preview the deletion and run the preview again if the targets change. By default, the CLI asks for confirmation in an interactive terminal. When using `--json` or running non-interactively, pass `--yes` to authorize the deletion targets of that command.

After installing the bundled workflow skill, start your agent from the workspace root and invoke `$mono-deck-workflow` to manage repositories and groups.

### Workspace files and automatic commits

MonoDeck maintains the following files and commits them to the workspace repository as needed.

- **`.gitignore`** receives additional ignore rules as needed. An automatic commit includes the entire file and may include your manual edits.
- **`mono-deck-workflow`** is synchronized when you open or reload the workspace. Synchronization discards local edits to the skill. For custom workflows, create a separate skill at `.agents/skills/mono-deck-workflow-addon/SKILL.md`.

## Usage notes

- **Share configuration.** Export the workspace configuration as YAML from Settings, then import it into the target workspace. Import adds missing repositories and groups. It skips repositories whose IDs and remote URLs match and groups whose names match. If a repository ID matches but the remote URL differs, the import reports a conflict.
- **Deleting a worktree or group in `worktrees`** permanently removes the affected worktrees and their current local branches. Uncommitted changes are removed with the worktrees, and unmerged commits may be lost. Deleting a repository first removes its managed worktrees in groups and their current local branches, then moves its local clone directory to Trash. Unlock any locked worktrees with Git before deleting. Review the scope and any work you need to keep before confirming.

  ![Worktree deletion preview showing its path and Dirty status](./.github/assets/4-delete-member-worktree.png)

- **Cancellation or partial failure** can leave completed changes in place. Check the results for items that completed and those that still need attention.
- A task member worktree cannot start from a commit that contains **Git submodules**.

See the [changelog](CHANGELOG.md) for release changes and the [development guide](DEVELOPMENT.md) for build and test instructions.
