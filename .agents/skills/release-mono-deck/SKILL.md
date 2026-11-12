---
name: release-mono-deck
description: Prepare a local MonoDeck release commit and annotated tag. Runs only when explicitly invoked as $release-mono-deck.
---

# Release MonoDeck

Run from the MonoDeck source repository root. Review `Version.xcconfig` and `.github/workflows/release.yml`. A request to run the full release authorizes staging and committing only `Version.xcconfig` and `CHANGELOG.md` and creating the local tag.

## 1. Check the working tree and resume state

- Confirm the intended release branch and that no merge, rebase, or similar operation is in progress. Record the starting HEAD. For a new release, require empty output from `git status --porcelain=v1 --untracked-files=all`. If the tree is dirty, list the changes and stop.
- On failure, preserve state and report completed and pending work. To resume, verify the branch, starting HEAD, version, both release files, and any release commit or tag. Continue from the first unfinished step. Stop if unrelated changes appear or ownership is uncertain.

## 2. Choose the version

- Use the highest local stable `vX.Y.Z` tag by semantic version as the baseline. If it is outside the starting HEAD's ancestry, wait for the user to choose a baseline. For a first release, tell the user and use all history through the starting HEAD. Review commits and relevant diffs in that range.
- Accept `X.Y.Z` with an optional `v` prefix and three nonnegative integers without leading zeros. The version must exceed the baseline, be at least `MARKETING_VERSION`, and have an unused tag.
- If the user gives no version, recommend a patch for compatible fixes, a minor for compatible features, or a major for breaking changes. Ask one interactive question with the recommendation first and briefly explain the valid options. Use chat if the choice UI is unavailable. If the UI requires a second option and only one version fits, offer to defer. Wait for an explicit choice and validate it before editing.
- Recheck the clean tree, branch, and starting HEAD. In `Version.xcconfig`, change only `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`, incrementing the build number by one. If the build number is not an integer, ask how to proceed.

## 3. Update the changelog

- Add `## [X.Y.Z] - YYYY-MM-DD` using the user's local date and existing English category headings. Place it after Unreleased, if present, and before older releases. Start a missing `CHANGELOG.md` with `# Changelog`. Move this release's entries out of Unreleased and verify the origin of any existing section for the target version before editing it.
- Write concise English notes on completed changes users will notice. Merge duplicates and cover installation, upgrade, and compatibility changes, including any required migration or recovery steps. For an internal-only release, use one short maintenance note.
- Run `python3 script/release_notes.py v<version>` and review the notes CI will use. Resolve validation failures before committing.

## 4. Commit and tag

- Preview the version, build number change, changelog summary, and tag. Run `git diff --check` and review the full diff. Confirm the branch and HEAD still match the starting state, the tag is unused, and only the two release files changed.
- Run `task test TEST_FILTER=MonoDeckTests/VersionTests`. Proceed only after tests pass and `run_tests.py` confirms the test environment exited and was cleaned up.
- Stage with `git add -- Version.xcconfig CHANGELOG.md`. Run `git diff --cached --check` and review the staged diff. Verify only those two files are staged. Commit with a Conventional Commits message in the language of the five latest commits, such as `chore(release): vX.Y.Z`. Verify the parent is the starting HEAD and the commit contains only the two release files.
- Create the annotated tag with `git tag -a "v<version>" -m "v<version>" <release-commit>`. Verify `git rev-parse "v<version>^{commit}"` matches the release commit, the committed version fields and changelog heading match the release, and the tree is clean.
- Report the version, build number, commit SHA, local tag, and verification results.
