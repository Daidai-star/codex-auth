# Codex Auth Menu

macOS menu bar companion for `codex-auth`.

## Run From Source

```shell
swift build --package-path apps/macos/CodexAuthMenu --scratch-path /tmp/codex-auth-menubar/swift-build
/tmp/codex-auth-menubar/swift-build/debug/CodexAuthMenu
```

## Build An App Bundle

```shell
bash apps/macos/CodexAuthMenu/Scripts/build-app.sh
open apps/macos/CodexAuthMenu/build/CodexAuthMenu.app
```

## Test

```shell
swift test --package-path apps/macos/CodexAuthMenu --scratch-path /tmp/codex-auth-menubar/swift-test
```

## CLI Discovery

The app resolves `codex-auth` in this order:

1. `defaults read dev.loongphy.codex-auth-menu codexAuthCLIPath`
2. `CODEX_AUTH_CLI_PATH`
3. `NVM_BIN/codex-auth`
4. `PATH`
5. `/bin/zsh -lc 'command -v codex-auth'`

Set an explicit path when you want to pin the CLI binary:

```shell
defaults write dev.loongphy.codex-auth-menu codexAuthCLIPath /absolute/path/to/codex-auth
```

The app starts a local web control server on `127.0.0.1` with a random launch token. Use the menu item `Open Web Control` to open the authorized URL.

The app does not read or write Codex auth files directly. Account listing, usage refresh, and switching all go through the `codex-auth` CLI JSON commands.
