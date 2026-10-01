# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

Every release is a git tag `vX.Y.Z` on `main`. The agent skills (`*/*/harness/SKILL.md`) check out the newest tag rather than the tip of `main`, so unreleased changes don't reach agents.

## Releasing a new version

1. Update the version in all three scripts: `VERSION="X.Y.Z"` in `Claude-Code/Linux/fix/claude-code-fix.sh` and `Cowork/Linux/fix/cowork-fix.sh`, and `$ScriptVersion = "X.Y.Z"` in `Claude-Code/Windows/fix/claude-code-fix.ps1`.
2. Move the entries under [Unreleased] into a new `## [X.Y.Z] - YYYY-MM-DD` section.
3. Merge to `main`, then tag that commit: `git tag vX.Y.Z && git push origin vX.Y.Z`, or create a GitHub release with that tag.

## [Unreleased]

### Added

- Linux wrappers check that their emulator still exists. If QEMU or SDE was removed or moved, starting Claude Code prints `claude-code-sigill-fix: emulator ... not found` and how to fix it, instead of a bare "No such file or directory". Wrappers from 1.1.0 are rewritten in the new form on the next run.
- `claude-code-fix.sh` checks the SHA-256 of the Intel SDE Linux package it downloads against a list of known hashes and refuses a package that doesn't match. Packages not on the list are installed with a warning that shows their hash. The list is still empty, so for now every package gets that warning.
- `tests/linux-fix.sh` and a `linux-fix` CI job: run `claude-code-fix.sh` with a real QEMU against fake installs (wrapping, argument / stdin / exit code passthrough, re-runs, SDE-to-QEMU rewrite, updated binaries, `--engine=sde`, a missing emulator, no QEMU without a terminal, `--restore`).
- `SECURITY.md`: how to report security problems privately.

## [1.1.0] - 2026-10-01

### Changed

- `Claude-Code/Linux/fix/claude-code-fix.sh` now runs Claude Code under QEMU's user-mode emulator (`qemu-x86_64 -cpu max`) instead of Intel SDE. It is much faster: `claude --version` takes a few seconds instead of about 30 seconds. Tested by hand on a Core 2 Duo E8400 for the CLI, Claude Desktop, VS Code and Zed.
  - If QEMU is missing, the script offers to install it with pacman, apt, dnf or zypper (needs sudo).
  - QEMU is checked with a real program before use.
  - Intel SDE stays as an optional fallback when QEMU can't be used. The script asks first and notes that SDE is much slower; without a terminal it stops unless `--engine=sde` is given.
  - Existing SDE wrappers are rewritten to use QEMU on the next run, and back again with `--engine=sde`.
- Linux skill, README and bug report form describe QEMU first and SDE as the fallback.
- The Cowork skill, and `cowork-fix.sh`'s "Intel SDE not found" message, install SDE with `--engine=sde --setup-only --install-sde`, without touching Claude Code targets.
- Windows and Cowork scripts are unchanged apart from the version number.

### Added

- `claude-code-fix.sh` options: `--engine=qemu`, `--engine=sde`, `--install-qemu` and `--setup-only`.

## [1.0.0] - 2026-09-26

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

#### `Claude-Code/Windows/fix/claude-code-fix.ps1`

The Windows version of the Claude Code fix, with the same menu. Targets:

- the CLI: the npm shims (`claude.cmd`, `claude.ps1`, `claude`) start `claude.exe` through SDE; the native installer's `claude.exe` is replaced with a wrapper
- Claude Desktop's embedded CLI (Store / MSIX and regular installs)
- the VS Code extension (also Insiders, VSCodium, Cursor and Windsurf), including the startup timeout patch
- the Zed Claude Agent (ACP)

Other features:

- Wrappers are compiled with .NET Framework's `csc.exe`. VS Code and Zed get a wrapper that copies stdin/stdout/stderr itself, and their original binaries are kept outside the app folders, in `%LOCALAPPDATA%\claude-sigill-fix\real-bin`.
- Installs Intel SDE 9.48.0 when it's missing (newer releases crash on CPUs without SSE4.2), and offers to install 7-Zip and the Visual C++ runtime with `winget`.
- Tests SDE with a real program before using it, and remembers a passed test until `sde.exe` changes.
- Prints the SHA-256 of an SDE package before extracting it, and rejects a 9.48.0 package whose hash differs from the pinned one (once a hash is pinned).
- `-Restore`, `-Sde`, `-InstallSde`, `-NoAdmin`, `-Version` and `-Help`.
- `claude-code-fix.cmd`, a double-click launcher.

#### Agent skills

Drop-in skills for Hermes and other agent harnesses. The agent never uses `sudo` or administrator rights.

- `harness/SKILL.md`: a single entry point. It detects the operating system and follows the Linux, Windows or Cowork instructions, and stops on macOS and ARM machines.
- `Claude-Code/Linux/harness/SKILL.md`, `Claude-Code/Windows/harness/SKILL.md` and `Cowork/Linux/harness/SKILL.md`: the per-platform skills.

#### Repository

- README: "Am I affected?" (Linux and Windows), notes on scope, VMs and macOS, a Windows section, how to remove everything, and "Related issues".
- A bug report issue form, including the SDE version.
- A Lint GitHub Actions workflow: ShellCheck, PSScriptAnalyzer, and a Windows job that builds the wrapper with `csc.exe` and tests it against a fake SDE.
- This changelog.

[Unreleased]: https://github.com/sucuklutank123456789-coder/claude-code-sigill-fix/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/sucuklutank123456789-coder/claude-code-sigill-fix/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/sucuklutank123456789-coder/claude-code-sigill-fix/releases/tag/v1.0.0
