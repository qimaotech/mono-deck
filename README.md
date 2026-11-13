# MonoDeck

**English** | [简体中文](README_CN.md)

MonoDeck is a native macOS app for managing multiple repositories in one workspace, coordinating tasks across them, and building AI workflows tailored to your projects.

## Features

- Add and update repositories in batches. Create, edit, and clean up worktree groups.
- Review local changes and see which commits are unique to a worktree or missing from it. Open a group or member directory in an external tool.
- AI agents can manage repositories and groups using the `mono-deck` CLI and the `mono-deck-workflow` skill.

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

Shared prompts, skills, and project documentation live at the workspace root, which is the workspace repository's main worktree. Each group root is a linked worktree of that repository. Each member repository has its own main worktree under `repositories/`. The worktrees inside each task group are linked worktrees of their respective member repositories.

![MonoDeck workspace with a task worktree group, local changes, and unique commits](./.github/assets/1-workspace-overview.png)

## Download and install

MonoDeck requires an Apple Silicon Mac running macOS 26.5 or later. Download the DMG from [Releases](https://github.com/qimaotech/mono-deck/releases) and drag `MonoDeck.app` into Applications.

The app in the DMG has an ad hoc signature and ships without Apple notarization. If macOS blocks the app because of its quarantine attribute, make sure you trust the download source. You can then run the following command and try opening MonoDeck again.

```bash
xattr -dr com.apple.quarantine /Applications/MonoDeck.app
```

## Getting started

1. Launch MonoDeck and follow the setup prompts to install the CLI and choose a workspace directory. For your first workspace, you can use a dedicated empty directory.
2. In **Add Repository**, enter a repository URL or use the **Import** menu to scan for local repositories. MonoDeck uses your local Git credentials to clone each repository from its remote.
3. Choose **Create Worktree Group** and select the repositories you need for the task. Pick a group name that works as both a single directory name and a Git branch name, such as `feature-checkout`. The initial branch takes the group name by default. You can also enter a branch name such as `feature/checkout`. MonoDeck creates the group from local Git refs and reuses a local branch with the chosen name if one is available. The same initial branch name and selection rules apply when you add members later.

   ![Worktree group creation dialog with a group name, an initial branch, and two selected repositories](./.github/assets/2-create-worktree-group.png)

4. Select a group or member and use the toolbar to open its directory in an installed agent, editor, terminal, or Git tool. Make changes, commit, and merge in your external tools.
5. Use Git Browser to review local changes and see which commits are unique to the selected checkout and which commits it is missing. The commit lists compare the checkout with the locally recorded remote default branch.
6. Update repositories or worktrees as needed.

   - Click the update icon in the `repositories` section to **update repositories**. MonoDeck fetches the branch that each repository's local `origin/HEAD` points to, then attempts a fast-forward-only merge in its main worktree. The main worktree must be clean and have the corresponding local branch checked out.
   - Click the update icon in the `worktrees` section to **update worktrees**. MonoDeck uses local Git data to fast-forward the current branches of registered group roots and their member worktrees. For a member worktree, the base is its repository's local `origin/HEAD`. For a group root, the base is the workspace repository's local `origin/HEAD`, or the branch checked out at the workspace root if that reference is missing. MonoDeck skips a worktree if its base is unavailable, its HEAD is detached, it has uncommitted changes, a Git operation is in progress, or its branch has diverged from the base.

   ![Worktree update results with updated and skipped items organized by group](./.github/assets/3-worktree-update-results.png)

## CLI and agents

After you install the CLI during setup, you can run `mono-deck` commands from the workspace root.

```bash
# Show the workspace structure
mono-deck workspace tree
# Create a worktree group
mono-deck group create '<group>' --repo '<repo1>' --repo '<repo2>'
```

Once you've installed the bundled workflow skill, start your agent from the workspace root. The agent can use `mono-deck-workflow` automatically for tasks that involve managing repositories or worktree groups. To call the skill explicitly, include `$mono-deck-workflow` in your prompt.

When you're ready to start development, you can tell your agent “Create a worktree group for me.” Based on your discussion, the agent suggests a group name, an initial branch, and which repositories to include. After you confirm the details, the agent runs `mono-deck` to create the group and its worktrees. The new group then appears in MonoDeck.

### Workspace files and automatic commits

MonoDeck maintains the following files and commits them to the workspace repository as needed.

- **`.gitignore`** gets new rules as needed, mainly to keep Git from tracking member repositories in the workspace repository. Each automatic commit of `.gitignore` includes the entire file and may pick up your own edits.
- MonoDeck syncs the **`mono-deck-workflow`** skill when you open or reload the workspace. This discards local edits to the skill. For custom workflows, create a separate skill at `.agents/skills/mono-deck-workflow-addon/SKILL.md`.

## Usage notes

- **Share a workspace configuration.** Export it as YAML from Settings, then import it into the target workspace. MonoDeck adds missing repositories and groups. It skips repositories that match on both ID and remote URL, as well as groups with matching names. If an existing repository has the same ID but a different remote URL, MonoDeck reports a conflict.
- **Deleting a worktree or group in `worktrees`** permanently removes the affected worktrees and their current local branches. Deleting the worktrees discards uncommitted changes, and you may lose unmerged commits. When you delete a repository, MonoDeck removes its managed worktrees across groups and their current local branches before moving the local clone to the Trash. Unlock any locked worktrees with Git before deleting. Before confirming, check what will be deleted and whether it contains work you need to keep.

  ![Worktree deletion preview showing its path and Dirty status](./.github/assets/4-delete-member-worktree.png)

- If you **cancel an operation or it fails partway through**, completed changes may remain in place. Check the results to see what finished and what still needs attention.
- You can only create a task member worktree from a commit without **Git submodules**.

## Development and releases

- **Contributors:** Fork the repository, create a feature or fix branch, and open a PR to the repository. CI runs automatically; maintainers review and merge the changes.
- **Maintainers:** Invoke [`$release-mono-deck`](.agents/skills/release-mono-deck/SKILL.md), confirm the version, and let the skill update the version, build number, and changelog and open a release PR. After CI passes and a maintainer merges it, the Release workflow builds and tests the merged commit, then creates its tag and publishes the GitHub Release.

Changes without a product version increase do not publish a release. See the [changelog](CHANGELOG.md) for release changes and the [development guide](DEVELOPMENT.md) for build and test instructions.
