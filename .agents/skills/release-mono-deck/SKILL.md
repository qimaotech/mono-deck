---
name: release-mono-deck
description: Prepare a MonoDeck release pull request with version and changelog updates. Runs only when explicitly invoked as $release-mono-deck.
---

# Release MonoDeck

From the MonoDeck repository root, review `Version.xcconfig` and `.github/workflows/release.yml`. A full release PR request authorizes creating a release branch, staging and committing only `Version.xcconfig` and `CHANGELOG.md`, pushing that branch to a verified writable remote, and opening a PR against `qimaotech/mono-deck:main`. For a local-only request, stop after the local commit. Do not merge the PR, create or push a tag, or publish a Release. Explain that merging the release PR into upstream `main` automatically runs the Release workflow, which tags the final merged commit and publishes after packaging and tests pass.

## 1. Check the repository and resume state

- Verify the upstream repository and writable push remote from `git remote -v`; do not assume `origin` is the main repository. A fork is a valid push remote. Fetch upstream `main` and tags without changing the working tree. Check GitHub authentication before attempting PR operations.
- For a new release, confirm a local branch with no merge, rebase, or similar operation in progress. Record the original branch and HEAD, and require `git status --porcelain=v1 --untracked-files=all` to be empty. List any changes and stop if it is nonempty. Use the fetched upstream `main` commit as the release base; do not include unrelated local commits.
- On failure, preserve state and report the original branch and HEAD, upstream base, release branch, baseline, selected version, and completed and pending work. On resume, verify ownership and intended changes against prior results and Git history. Stop on unrelated changes, uncertain ownership, or an upstream version/build change that invalidates the plan.
  - **Uncommitted edits.** Verify the base, unused release tag, and expected edits in the working tree and index. Keep completed edits, including the verified build increment, and continue validation and commit.
  - **Committed, awaiting PR.** Verify the release commit as described below and a clean tree. Push the verified branch and open the PR when authorized.
  - **PR already open.** Verify its head repository, branch, commit, base repository, and `main` target. Reuse it rather than creating a duplicate.
  - **PR already merged.** Report the merged commit and Release workflow status. Do not recreate the old branch's commit or tag; use the workflow's retry path if publication failed.

## 2. Choose the version and branch

- Use the highest stable upstream `vX.Y.Z` tag by semantic version as the changelog baseline. Verify it is an ancestor of the release base; otherwise wait for the user to choose the baseline. For a first release, tell the user and review all history through the release base. On resume, reuse the verified baseline and selected version. Review the commits and relevant diffs in that range.
- Accept three nonnegative integers without leading zeros in `X.Y.Z` format, with an optional `v` prefix. Require a version above both the baseline and `MARKETING_VERSION` at the release base. Require the tag to be unused locally and upstream for a new release.
- If the user gives no version, recommend a patch for compatible fixes, a minor for compatible features, or a major for breaking changes. Ask once with the recommendation and brief reasoning. Wait for and validate the user's explicit choice before editing.
- Create an unused `codex/release/vX.Y.Z` branch from the verified upstream base. On resume, reuse the owned release branch. Never force-push or replace an unrelated existing branch.
- Before editing, recheck the branch, base, working tree, and index. Change only `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `Version.xcconfig`. Set the build number to the value at the release base plus one. Ask how to proceed if the original build number is not an integer.

## 3. Update the changelog

- Add `## [X.Y.Z] - YYYY-MM-DD` with the user's local date and existing English category headings. Place it after Unreleased, if present, and before older releases. Move this release's entries from Unreleased and verify the origin of any existing section for the target version before editing it. Start a missing `CHANGELOG.md` with `# Changelog`.
- Write concise English notes on completed changes users will notice. Merge duplicates and cover installation, upgrades, compatibility, and any required migration or recovery steps. Use one short maintenance note for a release with only internal changes.
- Set `tag` to the intended `vX.Y.Z` and run `python3 script/release_notes.py "$tag"`. This validates the intended tag name without creating a tag. Review the notes and resolve failures before committing.

## 4. Validate and commit

- Preview the version, build change, changelog summary, release branch, and PR target. Run `git diff --check` and review the full release diff, including staged edits or a new `CHANGELOG.md`. Before testing, staging, and committing, verify the release branch, base, unused tag, and that the working tree and index contain only the reviewed changes to the two release files.
- Run `task test TEST_FILTER=MonoDeckTests/VersionTests`. Continue once tests pass and `run_tests.py` confirms test environment exit and cleanup.
- After tests and the pre-staging checks, stage with `git add -- Version.xcconfig CHANGELOG.md`. Before committing, run `git diff --cached --check` and require the reviewed diff to be fully staged with no unstaged or untracked changes.
- Commit using Conventional Commits in the predominant language of the five latest commits, for example `chore(release): vX.Y.Z`. Verify the release commit is HEAD on the intended branch, has the verified base as its parent, and changes only the two release files with the expected version, build number, and changelog. Require a clean tree.

## 5. Open the release PR

- For a local-only request, report the verified local commit and remaining push/PR steps. Otherwise recheck upstream `main`, the unused tag, release branch, and commit. If upstream advanced, stop and report that the release branch needs reconciliation; do not silently overwrite the release plan.
- Push only the release branch to the verified writable remote, without force or tags. Open or reuse a PR against `qimaotech/mono-deck:main`; for a fork, identify the head as `<fork-owner>:<release-branch>`. With `gh`, use an explicit `--repo`, `--base main`, `--head`, and `--body-file` containing actual newlines.
- Describe the version/build change, user-facing notes, validation, and automatic publication on merge. Verify the PR URL, head commit, and base. Do not bypass checks or merge it.
- Report the version, build number, release commit, branch, PR URL, and checks actually run. State that no local tag was created and that merging starts automatic publication. Packaging/test failures can be retried from the original Release workflow run; a retained tag or draft Release is expected after a partial publishing failure. A conflicting tag requires investigation, not replacement.
