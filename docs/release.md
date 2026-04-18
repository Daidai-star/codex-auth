# Release and CI

This document describes the repository's macOS-only CI, preview artifact publishing, and tag-driven release automation.

## Version Source of Truth

- The CLI binary version is defined in `src/version.zig`.
- The root npm package version in `package.json` must match `src/version.zig`.
- Release tags must use the same version with a leading `v`.
  - Example: `src/version.zig = 0.2.2-alpha.1`
  - Matching tag: `v0.2.2-alpha.1`

## Manual Release Checklist

1. Sync `main` and confirm CI is green before changing any versioned file.
   - Run `git fetch origin main --tags`.
   - Run `git switch main`.
   - Run `git pull --ff-only origin main`.
   - Confirm the latest completed `CI` run for `main` succeeded. If the latest `CI` run failed or is still in progress, stop and do not cut a release yet.
2. Decide the next version.
   - For a stable release, require the requester to provide the exact version. Do not infer stable versions automatically.
   - For a prerelease or test release, inspect the latest reachable release tag from `main`.
   - If the latest reachable tag is a stable tag such as `v0.2.2`, bump the patch version and start a new alpha line: `0.2.3-alpha.1`.
   - If the latest reachable tag is already an alpha prerelease such as `v0.2.3-alpha.1`, keep the same core version and bump the alpha suffix: `0.2.3-alpha.2`.
3. Update the local version files.
   - Update `src/version.zig`.
   - Update `package.json`.
   - Update every platform package version under `package.json.optionalDependencies` to the same version.
4. Validate the version change before committing.
   - Keep the version values aligned across `src/version.zig`, `package.json`, and the release tag you intend to create.
   - Because `src/version.zig` changes, run `zig build run -- list` before release.
   - If the local macOS Zig `0.15.1` build runner fails before project code executes, run `PATH="$PWD/scripts:$PATH" zig build run -- list` or `bash scripts/validate-zig.sh` and record that the compatible build path succeeded.
   - Run side-effecting validation from an isolated directory under `/tmp/<task-name>` with `HOME=/tmp/<task-name>`.
5. Commit and push `main`.
   - Commit with a release message such as `chore: release v0.2.3-alpha.1`.
   - Push the commit to `origin/main`.
6. Wait for the post-push `CI` run for that exact `main` commit.
   - Do not create the release tag until the latest `CI` run for the pushed release commit succeeds.
   - If that `CI` run fails or terminates unexpectedly before any release tag is pushed, fix the problem and push a new commit that keeps the same target version.
   - Re-run the validation steps, push `main`, and wait for `CI` again.
7. Create and push the release tag.
   - Create an annotated tag named `v<version>`.
   - Push that tag to `origin`.
   - The tag push triggers the release workflow in `.github/workflows/release.yml`.
   - After a release tag has been pushed, do not reuse that version number. If the tag-driven release workflow later fails and you need another attempt, prepare and publish a new version instead.

## CI Workflow

- Branch and pull request validation runs in `.github/workflows/ci.yml`.
- The `package-metadata` job checks the root npm package name, `package.json` version, platform optional dependency versions, and `src/version.zig`.
- The `macOS CLI Smoke` job runs on `macos-latest`.
- CI installs Zig `0.15.1`, prints `zig version` and `zig env`, builds the native binary, and smoke-runs `codex-auth list` through `scripts/validate-zig.sh`.
- The `macos-menu-app` job runs on `macos-latest`, executes the Swift test suite, and builds the menu bar app bundle with its bundled CLI.

## Preview Artifacts for Pull Requests

- Pull request previews are built by `.github/workflows/preview-release.yml`.
- The workflow runs on `macos-latest`, builds the native CLI for the runner architecture, packages the menu bar app, and uploads the resulting archive as a workflow artifact.
- Preview builds do not publish npm packages.

## Tag Release Workflow

- Tag pushes matching `v*` run `.github/workflows/release.yml`.
- The release workflow first validates the code on `macos-latest`.
- It then builds release assets for macOS CLI binaries on Ubuntu.
- The same release workflow also builds the macOS menu bar app on Intel and Apple Silicon runners and attaches zipped `.app` bundles to the GitHub release.
- Release notes are generated from git tags and commit history.
- GitHub releases are published automatically from the tag pipeline.
- Stable tags create normal GitHub releases.
- Prerelease tags such as `v0.2.0-rc.1`, `v0.2.0-beta.1`, and `v0.2.0-alpha.1` create GitHub releases marked as prereleases, not drafts.
