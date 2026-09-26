# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

Every release is a git tag `vX.Y.Z` on `main`. The agent skills (`*/*/harness/SKILL.md`) check out the newest tag rather than the tip of `main`, so unreleased changes don't reach agents.

## Releasing a new version

1. Update the version in all three scripts: `VERSION="X.Y.Z"` in `Claude-Code/Linux/fix/claude-code-fix.sh` and `Cowork/Linux/fix/cowork-fix.sh`, and `$ScriptVersion = "X.Y.Z"` in `Claude-Code/Windows/fix/claude-code-fix.ps1`.
2. Move the entries under [Unreleased] into a new `## [X.Y.Z] - YYYY-MM-DD` section.
3. Merge to `main`, then tag that commit: `git tag vX.Y.Z && git push origin vX.Y.Z`, or create a GitHub release with that tag.

## [Unreleased]

### Added

#### `Claude-Code/Windows/fix/claude-code-fix.ps1`

The Windows version of the Claude Code fix, with the same menu. Targets:

- the CLI: the npm shims (`claude.cmd`, `claude.ps1`, `claude`) start `claude.exe` through SDE; the native installer's `claude.exe` is replaced with a wrapper
- Claude Desktop's embedded CLI (Store / MSIX and regular installs)
- the VS Code extension (also Insiders, VSCodium, Cursor and Windsurf), including the startup timeout patch
- the Zed Claude Agent (ACP)

Other features:

- Wrappers are compiled with .NET Framework's `csc.exe`. VS Code and Zed get a wrapper that copies stdin/stdout/stderr itself, and their original binaries are kept outside the app folders, in `%LOCALAPPDATA%\claude-sigill-fix\real-bin`.
- Installs Intel SDE 9.48.0 when it's missing (newer releases crash on CPUs without SSE4.2), and offers to install 7-Zip and the Visual C++ runtime with `winget`.
- Tests SDE with a real program before using it.
- `-Restore`, `-Sde`, `-InstallSde`, `-NoAdmin`, `-Version` and `-Help`.
- `claude-code-fix.cmd`, a double-click launcher.

#### Other

- `Claude-Code/Windows/harness/SKILL.md`, the matching agent skill.
- `harness/SKILL.md`, a single entry-point skill: it detects the operating system and follows the Linux, Windows or Cowork instructions, and stops on macOS and ARM machines.
- README: a note that the repository is not for macOS (Apple Silicon or Intel Macs).
- README: Windows section and a Windows "Am I affected?" check.
- The bug report form asks about Windows too.
- CI runs PSScriptAnalyzer on the PowerShell script.

## [1.0.0] - 2026-09-25

First release.

### Added

#### `Claude-Code/Linux/fix/claude-code-fix.sh`

Wraps Claude Code's native binaries with Intel SDE (`-hsw`) so they run on CPUs without AVX2. Targets:

- the CLI (npm and native installer)
- Claude Desktop's embedded CLI
- the VS Code extension (also Insiders, VSCodium, Cursor, Windsurf and Flatpak builds)
- the Zed Claude Agent (ACP)
- Droid

Other features:

- An interactive menu, or target numbers given as arguments.
- `--restore`, `--no-sudo`, `--install-sde` and `--version`.
- Exit code `1` when any step fails.
- Offers to install Intel SDE when it's missing: from the AUR on Arch-based systems, otherwise from Intel's tarball into `~/.local/opt/intel-sde`.
- Warns and stops when the CPU already has AVX2.
- Raises only the two VS Code extension startup timeouts, 60 s → 900 s.

#### `Cowork/Linux/fix/cowork-fix.sh`

Handles three things:

- **QEMU / KVM setup:** installs QEMU, OVMF and virtiofsd with pacman, apt, dnf or zypper. Symlinks them to the Debian paths Claude Desktop expects and adds the user to the `kvm` group.
- **Cowork VM CLI:** wraps it with SDE.
- **`installSdk` timeout:** patches `cowork-linux-helper` from 30 s to 900 s.

Every `sudo` command is shown and confirmed first. `--restore` undoes the changes.

#### Agent skills

`Claude-Code/Linux/harness/SKILL.md` and `Cowork/Linux/harness/SKILL.md` are drop-in skills for Hermes and other agent harnesses. The agent never uses `sudo`.

#### Repository

- README sections: "Am I affected?", notes on scope and VMs, and "Related issues".
- A bug report issue form.
- A ShellCheck GitHub Actions workflow.
- This changelog.

[Unreleased]: https://github.com/sucuklutank123456789-coder/claude-code-sigill-fix/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/sucuklutank123456789-coder/claude-code-sigill-fix/releases/tag/v1.0.0
