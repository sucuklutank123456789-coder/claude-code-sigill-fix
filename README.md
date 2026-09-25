# claude-code-sigill-fix

Run Claude Code on old x86-64 CPUs that lack **AVX / AVX2 / SSE4.2** (Core 2 Duo, early Core i / Phenom and similar) on Linux.

Since v2.1.113, Claude Code ships as a native binary built with instructions these CPUs don't have. On such a machine every Claude Code surface dies immediately with:

```
Illegal instruction (core dumped)
```

That crash is a `SIGILL`. This script works around it by running those binaries under [Intel SDE](https://www.intel.com/content/www/us/en/download/684897/intel-software-development-emulator.html), which emulates the missing instructions in software.

> **Not an official Anthropic tool.** It modifies installed files of Claude Code and related apps. Use at your own risk.

## What it fixes

| # | Target | What the script does |
|---|--------|----------------------|
| 1 | **Claude Code CLI**: npm install and the native installer | Wraps the binary with SDE |
| 2 | **Claude Desktop**: embedded CLI and Cowork | Wraps the embedded CLI and raises Cowork's 30 s `installSdk` timeout to 900 s (needs `sudo`) |
| 3 | **VS Code extension**, also Insiders, VSCodium, Cursor, Windsurf and Flatpak builds | Wraps the bundled binary and raises the 60 s startup timeout to 900 s |
| 4 | **Zed Claude Agent** (ACP) | Wraps the agent binary |
| 5 | **Droid** (Factory AI CLI) | Wraps the binary |
| 6 | All of the above | |

## How it works

Each native binary is renamed to `<name>.realbinary` and replaced with a small wrapper script:

```bash
#!/usr/bin/env bash
exec intel-sde -hsw -- /path/to/claude.realbinary "$@"
```

`-hsw` makes SDE emulate a Haswell CPU, which has every instruction the binary needs.

Emulation is **slow**: even `claude --version` can take about a minute. The IDE integrations would otherwise hit their startup timeouts, so the script raises those timeouts too.

## Requirements

- Linux on x86-64
- `bash`, plus `python3` for the Cowork patch
- **Intel SDE.** If it's missing, the script offers to install it:
  - on Arch-based distros, through the AUR (`paru -S intel-sde` or `yay -S intel-sde`)
  - elsewhere, by downloading Intel's Linux tarball into `~/.local/opt/intel-sde` (needs `curl` or `wget`, and `tar` with `xz` support)

  SDE is Intel software under Intel's own license and is not included in this repository.
- For the npm install of the CLI: Node.js 22 or newer. The official prebuilt Node.js binaries run fine on these CPUs.

## Usage

```bash
git clone https://github.com/sucuklutank123456789-coder/claude-code-sigill-fix.git
cd claude-code-sigill-fix
chmod +x claude-sigill-fix.sh
./claude-sigill-fix.sh
```

The script asks which targets to fix. Type the numbers separated by spaces and press Enter:

```
Which one do you want to fix?
  1: Claude Code CLI (terminal)
  2: Claude Desktop app
  3: VS Code extension (also Cursor, Windsurf, VSCodium)
  4: Zed Claude Agent (ACP)
  5: Droid (Factory AI CLI)
  6: All
Enter numbers separated by spaces (e.g. 4 1):
```

You can also skip the menu:

```bash
./claude-sigill-fix.sh 4 1        # fix Zed and the CLI
./claude-sigill-fix.sh 6          # fix everything
./claude-sigill-fix.sh --help
```

After patching, **fully close and reopen** VS Code, Zed or Claude Desktop.

The script is safe to re-run. It only touches what is not patched yet, and reports every step as `[OK]`, `[PATCHED]`, `[SKIP]` or `[ERROR]`.

If your CPU does support AVX2, the script warns you and stops unless you confirm. On such a CPU Claude Code runs natively, and wrapping it would only make it much slower.

## ⚠️ Re-run the script after every update

Every update replaces the patched files with fresh native binaries, which crash with `SIGILL` again. This happens for Claude Code itself, the VS Code extension, Zed's agent, Claude Desktop and Droid.

**Whenever something is updated, run the script again:**

```bash
./claude-sigill-fix.sh
```

## ⚠️ Updating the Claude Code CLI

**Do not use `claude update`.** It does not work on these machines; it fails with `Unable to fetch latest version from npm registry`. Update with the same method you installed with, then re-run the script.

**Installed with npm:**

```bash
npm install -g --allow-scripts=@anthropic-ai/claude-code @anthropic-ai/claude-code@latest
./claude-sigill-fix.sh 1
```

Recent npm versions block install scripts by default. `--allow-scripts` lets the package fetch its native binary. If your npm doesn't know that flag, drop it.

**Installed with the native installer:**

```bash
curl -fsSL https://claude.ai/install.sh | bash
./claude-sigill-fix.sh 1
```

The native installer runs the freshly downloaded binary as part of installing. On these CPUs that step can itself crash with `SIGILL`. If it does, use the npm method instead.

## Undoing the fix

```bash
./claude-sigill-fix.sh --restore        # menu
./claude-sigill-fix.sh --restore 1 3    # only the CLI and VS Code
```

This puts the original binaries back, resets the timeouts to their defaults and restores `cowork-linux-helper` from the backup the script made.

## Troubleshooting

- **`Subprocess initialization did not complete within 60000ms` in VS Code.** The extension was updated. Re-run the script and restart VS Code.
- **`Illegal instruction` again.** Something was updated. Re-run the script.
- **Cowork: `request req-2 (installSdk) timed out after 30s`.** Run option 2. Claude Desktop installed as an AppImage can't be patched in place; its image must be extracted and rebuilt.
- **Flatpak editors.** A Flatpak sandbox can't see `/usr/bin/intel-sde`. Install SDE into `~/.local/opt/intel-sde` instead: remove the system package, or just download Intel's tarball there.
- **`timeout setting not found in extension.js`.** The extension's code changed and the script no longer recognizes the timeout. Please open an issue.

## Tested on

- Intel Core 2 Duo E8400, Garuda Linux (Arch-based)

Other distributions should work the same way but have not been tested yet. Reports are welcome.
