---
name: pr-to-monodeck
description: Verify that the current branch is already pushed, then open or reuse a PR against qimaotech/mono-deck:main and return its URL. Runs only when explicitly invoked as $pr-to-monodeck.
---

# Create MonoDeck PR

Create a PR from the current branch's already-pushed commits into `qimaotech/mono-deck:main`. Explicit invocation authorizes creating the PR. Do not run local tests, builds, linters, or formatters. Do not stage, commit, push, create forks, switch branches, merge, or modify repository files or Git configuration. Uncommitted changes are outside the PR and do not need to be cleaned up.

## 1. Verify the pushed branch

- Resolve the current worktree root, local branch, and HEAD SHA. Stop on detached HEAD or an unfinished merge, rebase, or cherry-pick.
- Inspect the branch's upstream and remote URLs to identify the source repository and remote branch. Use the configured upstream when available; the remote branch name can differ from the local branch name. Do not assume `origin` is the main repository. If no upstream exists, inspect configured remotes for the same branch name and use a unique branch whose remote tip equals HEAD. Ask only if the source remains ambiguous.
- Check the actual remote branch using `git ls-remote --heads <remote-url> "refs/heads/<remote-branch>"` or the GitHub API. Require the full remote tip SHA to equal the recorded local HEAD; cached remote-tracking refs alone are insufficient. If the branch is missing or differs, stop and report that the branch must be pushed or reconciled first. Never push automatically.
- Confirm GitHub authentication and verify that the source repository is `qimaotech/mono-deck` or belongs to its fork network. Do not expose credentials from remote URLs or authentication output.

## 2. Prepare the PR

- Find an open PR with the exact source repository and remote branch targeting `qimaotech/mono-deck:main`. Verify its head SHA matches the recorded HEAD and return its URL if it exists; do not edit it or create a duplicate.
- Read the committed changes relative to the target's current `main` using GitHub's comparison API or fetched Git history. Stop if there are no changes to propose. Base the title and description on the full PR change, excluding uncommitted edits.
- Write a concise English title and description explaining the resulting behavior and relevant validation. Honor the repository's PR template if present. Include only confirmed test results from the current context; otherwise state `Local tests not run (as requested).` Do not infer that CI passed.

## 3. Open and verify

- Immediately before creation, recheck the current branch, local HEAD, and actual remote tip. Stop if they changed.
- Prefer `gh pr create` with explicit `--repo qimaotech/mono-deck`, `--base main`, `--head`, `--title`, and `--body-file`. Write the body to a temporary file with real newlines and remove it afterward. Always specify `--head` to prevent implicit pushing or forking; do not use `--dry-run`, which may still push.
- For a source branch in the target repository, use the remote branch name as `--head`. For a personal fork, use `<fork-owner>:<remote-branch>`. For an organization-owned fork that the CLI cannot address unambiguously, use the GitHub REST API with the exact head repository and branch instead of guessing or changing the source.
- Do not merge the PR or enable auto-merge. If creation fails or times out, check once for an exact matching open PR before reporting failure; do not blindly retry creation.
- Verify the returned PR's base repository and branch, head repository and branch, and head SHA. Report its clickable URL. If verification fails, report the created URL and discrepancy without claiming success or deleting the PR.
