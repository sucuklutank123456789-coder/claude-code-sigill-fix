# claude-code-sigill-fix

Run Claude Code on Linux and Windows on x86-64 CPUs that lack **AVX2**. This includes older CPUs without any AVX or SSE4.2 (Core 2 Duo, first-generation Core i, Phenom and similar), and CPUs that have AVX but no AVX2 (Sandy Bridge and Ivy Bridge).

Claude Code's native binaries are built with instructions these CPUs don't have:

- **Native installer:** the standalone binary broke first, in v2.1.15, which moved to Bun 1.3.6 ([anthropics/claude-code#20116](https://github.com/anthropics/claude-code/issues/20116)).
- **npm package:** it stayed pure JavaScript up to v2.1.112. Since v2.1.113 it also ships a native binary.

On such a machine every Claude Code surface dies immediately. On Linux it prints:

```
Illegal instruction (core dumped)
```

That crash is a `SIGILL`. On Windows, the same crash shows up as exception code `0xc000001d` (`STATUS_ILLEGAL_INSTRUCTION`) in the Application event log, or as an editor panel that never finishes loading. The Claude Code fix scripts work around it by running those binaries under [Intel SDE](https://www.intel.com/content/www/us/en/download/684897/intel-software-development-emulator.html), which emulates the missing instructions in software.

> **Not for macOS.** This repository only covers x86-64 Linux and Windows. Apple Silicon Macs (M-series) run Claude Code as a native ARM program and don't hit this crash; if Claude Code crashes there, the cause is something else. Older Intel Macs without AVX2 may crash the same way, but there is no macOS fix here.

> **Not an official Anthropic tool.** It modifies installed files of Claude Code and related apps. Use at your own risk.

> ⚠️ **Expect Claude Code to run much slower than normal.** Every instruction the CPU lacks is emulated in software, so startup can take about a minute (even `claude --version`), and commands, tool calls and the IDE integrations respond noticeably slower than on a modern CPU. This fix makes Claude Code *work* on old hardware; it cannot make it fast.

## Am I affected?

On Linux:

```bash
grep -qw avx2 /proc/cpuinfo && echo "has AVX2: fix NOT needed" || echo "no AVX2: fix needed"
```

On Windows, in PowerShell:

```powershell
Add-Type -Namespace Cpu -Name K32 -MemberDefinition '[DllImport("kernel32.dll")] public static extern bool IsProcessorFeaturePresent(uint f);'
if ([Cpu.K32]::IsProcessorFeaturePresent(40)) { "has AVX2: fix NOT needed" } else { "no AVX2: fix needed" }
```

If in doubt, the "Instructions" field of [CPU-Z](https://www.cpuid.com/softwares/cpu-z.html) lists AVX2 when the CPU has it.

If your CPU has AVX2, this fix is not for you: a `SIGILL` there has a different cause.

The check is for AVX2, so CPUs that have AVX but no AVX2 (Sandy Bridge and Ivy Bridge) are covered too.

### Running Claude Code in a virtual machine?

Try this first. A physical CPU with AVX2 can still look like it lacks AVX2 inside a VM. Proxmox, VMware, VirtualBox and other hypervisors often give guests a generic virtual CPU model without AVX, which causes exactly this crash ([anthropics/claude-code#20019](https://github.com/anthropics/claude-code/issues/20019)).

**The real fix is to set the VM's CPU type to `host`** (host passthrough), so the guest sees every instruction the physical CPU has. For example:

- **Proxmox:** Hardware → Processors → Type: `host`
- **libvirt / virt-manager:** CPU model `host-passthrough`

Claude Code then runs natively at full speed. Only use the SDE workaround in this repository if the host CPU itself has no AVX2, or if you can't change the VM's CPU type.

## Repository layout

```
harness/                     SKILL.md              single entry-point skill for AI agent harnesses
Claude-Code/Linux/fix/       claude-code-fix.sh    Claude Code SIGILL fix (Linux)
Claude-Code/Linux/harness/   SKILL.md              skill for AI agent harnesses
Claude-Code/Windows/fix/     claude-code-fix.ps1   Claude Code fix (Windows)
                             claude-code-fix.cmd   double-click launcher for the .ps1
Claude-Code/Windows/harness/ SKILL.md              skill for AI agent harnesses
Cowork/Linux/fix/            cowork-fix.sh         Cowork fix
Cowork/Linux/harness/        SKILL.md              skill for AI agent harnesses
```

The sections below up to [Windows](#windows) describe the Linux script. For Windows, see [Windows](#windows).

Cowork, Claude Desktop's workspace feature, has its own separate issues. They are handled by a separate script, see [Cowork](#cowork) below. The Claude Code script does not touch Cowork.

## What it fixes (Linux)

| # | Target | What the script does |
|---|--------|----------------------|
| 1 | **Claude Code CLI**: npm install and the native installer | Wraps the binary with SDE |
| 2 | **Claude Desktop**: embedded Claude Code CLI | Wraps the embedded CLI |
| 3 | **VS Code extension**, also Insiders, VSCodium, Cursor, Windsurf and Flatpak builds | Wraps the bundled binary and raises the 60 s startup timeout to 900 s |
| 4 | **Zed Claude Agent** (ACP) | Wraps the agent binary |
| 5 | **Droid** (Factory AI CLI) | Wraps the binary |
| 6 | All of the above | |

## How it works (Linux)

Each native binary is renamed to `<name>.realbinary` and replaced with a small wrapper script:

```bash
#!/usr/bin/env bash
exec intel-sde -hsw -- /path/to/claude.realbinary "$@"
```

`-hsw` makes SDE emulate a Haswell CPU, which has every instruction the binary needs.

Emulation is **slow**: even `claude --version` can take about a minute. The IDE integrations would otherwise hit their startup timeouts, so the script raises those timeouts too.

## Requirements (Linux)

- Linux on x86-64
- `bash`
- **Intel SDE.** If it's missing, the script offers to install it:
  - on Arch-based distros, through the AUR (`paru -S intel-sde` or `yay -S intel-sde`)
  - elsewhere, by downloading Intel's Linux tarball into `~/.local/opt/intel-sde` (needs `curl` or `wget`, and `tar` with `xz` support)

  SDE is Intel software under Intel's own license and is not included in this repository.
- For the npm install of the CLI: Node.js 22 or newer. The official prebuilt Node.js binaries run fine on these CPUs.

## Usage (Linux)

```bash
git clone https://github.com/sucuklutank123456789-coder/claude-code-sigill-fix.git
cd claude-code-sigill-fix/Claude-Code/Linux/fix
chmod +x claude-code-fix.sh
./claude-code-fix.sh
```

The commands below assume you are in `Claude-Code/Linux/fix`.

The script asks which targets to fix. Type the numbers separated by spaces and press Enter:

```
Which one do you want to fix?
  1: Claude Code CLI (terminal)
  2: Claude Desktop (embedded Claude Code CLI)
  3: VS Code extension (also Cursor, Windsurf, VSCodium)
  4: Zed Claude Agent (ACP)
  5: Droid (Factory AI CLI)
  6: All
Enter numbers separated by spaces (e.g. 4 1):
```

You can also skip the menu:

```bash
./claude-code-fix.sh 4 1        # fix Zed and the CLI
./claude-code-fix.sh 6          # fix everything
./claude-code-fix.sh --help
```

For unattended runs (cron, systemd timers, AI agents):

```bash
./claude-code-fix.sh --no-sudo --install-sde 6 </dev/null
```

- `--no-sudo` never calls `sudo`, so SDE is never installed from the AUR.
- `--install-sde` installs SDE without asking if it is missing. Together with `--no-sudo`, it downloads SDE into `~/.local/opt/intel-sde`.
- The exit code is `1` if any step failed.

After patching, **fully close and reopen** VS Code, Zed or Claude Desktop.

The script is safe to re-run. It only touches what is not patched yet, and reports every step as `[OK]`, `[PATCHED]`, `[SKIP]` or `[ERROR]`.

If your CPU does support AVX2, the script warns you and stops unless you confirm. On such a CPU Claude Code runs natively, and wrapping it would only make it much slower.

## Using it from an AI agent (Hermes and others)

Install [`harness/SKILL.md`](harness/SKILL.md): one skill for every platform. It detects the operating system, follows the matching Linux, Windows or Cowork instructions from the newest release, and on macOS tells the user that this repository doesn't apply.

The per-platform skills can also be installed on their own. [`Claude-Code/Linux/harness/SKILL.md`](Claude-Code/Linux/harness/SKILL.md) is the Linux one. With it, an agent harness such as Hermes Agent can:

- detect the problem
- apply the fix without `sudo`
- update Claude Code the right way
- re-apply the fix automatically after updates

The file also explains how to install it as a skill.

## ⚠️ Re-run the script after every update

Every update replaces the patched files with fresh native binaries, which crash with `SIGILL` again. This happens for Claude Code itself, the VS Code extension, Zed's agent, Claude Desktop and Droid.

**Whenever something is updated, run the script again:**

```bash
./claude-code-fix.sh
```

## ⚠️ Updating the Claude Code CLI

**Do not use `claude update`.** It does not work on these machines; it fails with `Unable to fetch latest version from npm registry`. Update with the same method you installed with, then re-run the script.

**Installed with npm:**

```bash
npm install -g --allow-scripts=@anthropic-ai/claude-code @anthropic-ai/claude-code@latest
./claude-code-fix.sh 1
```

Recent npm versions block install scripts by default. `--allow-scripts` lets the package fetch its native binary. If your npm doesn't know that flag, drop it.

**Installed with the native installer:**

```bash
curl -fsSL https://claude.ai/install.sh | bash
./claude-code-fix.sh 1
```

The native installer runs the freshly downloaded binary as part of installing. On these CPUs that step can itself crash with `SIGILL`. If it does, use the npm method instead.

## Undoing the fix

```bash
./claude-code-fix.sh --restore        # menu
./claude-code-fix.sh --restore 1 3    # only the CLI and VS Code
```

This puts the original binaries back and resets the timeouts to their defaults.

## Troubleshooting

- **`Subprocess initialization did not complete within 60000ms` in VS Code.** The extension was updated. Re-run the script and restart VS Code.
- **`Illegal instruction` again.** Something was updated. Re-run the script.
- **Flatpak editors.** A Flatpak sandbox can't see `/usr/bin/intel-sde`. Install SDE into `~/.local/opt/intel-sde` instead: remove the system package, or just download Intel's tarball there.
- **`timeout setting not found in extension.js`.** The extension's code changed and the script no longer recognizes the timeout. Please open an issue.

## Windows

`Claude-Code/Windows/fix/claude-code-fix.ps1` does the same job on Windows (x64, Windows 10 or newer).

| # | Target | What the script does |
|---|--------|----------------------|
| 1 | **Claude Code CLI**: npm install and the native installer | npm: edits the npm shims (`claude.cmd`, `claude.ps1`, `claude`) to start `claude.exe` through SDE. Native installer (`%USERPROFILE%\.local\bin\claude.exe`): replaces it with a wrapper |
| 2 | **Claude Desktop**: embedded Claude Code CLI | Replaces the embedded `claude.exe` with a wrapper |
| 3 | **VS Code extension**, also Insiders, VSCodium, Cursor and Windsurf | Replaces the bundled `claude.exe` with a wrapper and raises the 60 s startup timeout to 900 s |
| 4 | **Zed Claude Agent** (ACP) | Replaces the agent's `claude.exe` with a wrapper |
| 5 | All of the above | |

### How it works on Windows

On Linux a wrapper can be a shell script. On Windows, a `claude.exe` must be a real executable, so the script compiles a small C# wrapper with the C# compiler that comes with .NET Framework 4 (`csc.exe`, part of every Windows 10 and 11). The wrapper starts the original binary under `sde.exe -hsw --` and passes on all arguments.

- **Where the originals go.** VS Code and Zed silently delete unknown files from their own folders. The originals of the VS Code, Zed and native-installer binaries are therefore kept outside them, in `%LOCALAPPDATA%\claude-sigill-fix\real-bin`. Claude Desktop keeps its original next to the wrapper, as `claude.realbinary.exe`. Originals of app versions that were deleted by an update are cleaned up on the next run.
- **Two kinds of wrapper.** VS Code and Zed talk to Claude Code over pipes, and with a plain wrapper their panel hangs forever on the first answer. For them, the wrapper copies stdin, stdout and stderr itself. The CLI and Claude Desktop use the plain version.
- **Where everything lives.** `%LOCALAPPDATA%\claude-sigill-fix` holds SDE, the originals and the compiled wrappers. Nothing needs administrator rights, except installing 7-Zip and the Visual C++ runtime (see below).

### Requirements (Windows)

- Windows 10 or 11, x64, with Windows PowerShell 5.1 (built in) or PowerShell 7.
- **Intel SDE 9.48.0.** Newer SDE releases (10.x) crash inside SDE itself on CPUs without SSE4.2, such as Core 2 Duo; 9.48.0 works on all of them. If SDE is missing, the script offers to download 9.48.0 into `%LOCALAPPDATA%\claude-sigill-fix\sde`. If the download link can't be found, it tells you how to download it by hand and asks for the file.

  Before using an SDE, the script runs a test program under it (`sde.exe -hsw -- cmd.exe /c exit 0`): `sde.exe -version` alone works even where SDE is broken.
- **7-Zip**, to extract SDE's `.tar.xz` package. Windows' own `tar.exe` can't open `.xz`.
- **Visual C++ Redistributable 2015+, both x64 and x86.** SDE 9.48.0's launcher is 32-bit.

The script offers to install 7-Zip and the Visual C++ runtime with `winget`, which can show an administrator (UAC) prompt:

```powershell
winget install -e --id 7zip.7zip
winget install -e --id Microsoft.VCRedist.2015+.x64
winget install -e --id Microsoft.VCRedist.2015+.x86
```

### Usage (Windows)

Download or clone the repository, open `Claude-Code\Windows\fix` and double-click **`claude-code-fix.cmd`**. It runs the PowerShell script without changing PowerShell's execution policy and shows the same menu as on Linux:

```
Which one do you want to fix?
  1: Claude Code CLI (terminal)
  2: Claude Desktop (embedded Claude Code CLI)
  3: VS Code extension (also Cursor, Windsurf, VSCodium)
  4: Zed Claude Agent (ACP)
  5: All
Enter numbers separated by spaces (e.g. 4 1):
```

From a terminal:

```powershell
cd claude-code-sigill-fix\Claude-Code\Windows\fix
.\claude-code-fix.cmd 4 1              # fix Zed and the CLI
.\claude-code-fix.cmd 5                # fix everything
.\claude-code-fix.cmd -Restore 1 3     # undo, only the CLI and VS Code
.\claude-code-fix.cmd -Help
```

Or call the script directly: `powershell -ExecutionPolicy Bypass -File .\claude-code-fix.ps1 5`.

Options:

- `-Sde <path>`: use this `sde.exe`, or install SDE from a `.tar.xz` / `.zip` package you downloaded yourself.
- `-InstallSde`: install SDE and its requirements without asking if they are missing.
- `-NoAdmin`: never run `winget`; missing 7-Zip or Visual C++ runtime are reported as errors with the commands to run instead.
- The exit code is `1` if any step failed.

After patching, **fully close and reopen** VS Code, Zed or Claude Desktop, and open a new terminal for the CLI. A running app keeps its `claude.exe` locked; if the script says a file is in use, close that app and run the script again.

[`Claude-Code/Windows/harness/SKILL.md`](Claude-Code/Windows/harness/SKILL.md) is the matching skill for AI agent harnesses. It runs the script without administrator rights and can schedule it with Task Scheduler.

### Updating on Windows

As on Linux, every update brings fresh binaries, and `npm install -g` rewrites the shims. **Re-run the script after every update.** Do not use `claude update`.

**Installed with npm:**

```powershell
npm install -g --allow-scripts=@anthropic-ai/claude-code @anthropic-ai/claude-code@latest
.\claude-code-fix.cmd 1
```

If PowerShell refuses to run `npm` because of the execution policy, use `npm.cmd` instead, or allow local scripts once with `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

**Installed with the native installer:**

```powershell
irm https://claude.ai/install.ps1 | iex
.\claude-code-fix.cmd 1
```

The native installer runs the freshly downloaded binary, so on these CPUs it can crash itself. If it does, use the npm method instead.

VS Code keeps the old extension folder next to the new one after an update. The script always patches the newest one.

### Troubleshooting (Windows)

- **Is it really this crash?** Look for exception code `0xc000001d` in the Application log:

  ```powershell
  Get-WinEvent -LogName Application -MaxEvents 50 |
      Where-Object { $_.Id -in 1000, 1001 -and $_.Message -like "*claude*" } |
      Format-List TimeCreated, Message
  ```
- **`Intel SDE could not run a test program`.** Usually an SDE newer than 9.48.0 on a CPU without SSE4.2 (it crashes in `pinvm.dll`), or a missing x86 Visual C++ runtime (`VCRUNTIME140.dll was not found`).
- **The VS Code or Zed panel never finishes loading.** Re-run the script: after an update the binary isn't wrapped yet, or the timeout patch is missing.
- **The Claude Code interface looks broken in the old console window.** Use Windows Terminal with PowerShell 7 (`winget install Microsoft.WindowsTerminal` and `winget install Microsoft.PowerShell`).
- **`timeout setting not found in extension.js`.** The extension's code changed and the script no longer recognizes the timeout. Please open an issue.

## Cowork

`Cowork/Linux/fix/cowork-fix.sh` fixes the problems that keep Claude Desktop's Cowork feature from starting on Linux:

| # | Problem | What the script does |
|---|---------|----------------------|
| 1 | **"Cowork requires QEMU"** | Installs QEMU, OVMF (UEFI firmware) and virtiofsd with your package manager (pacman, apt, dnf or zypper). Symlinks them to the Debian-style paths Claude Desktop looks for (`/usr/share/OVMF/OVMF_CODE_4M.fd`, `OVMF_VARS_4M.fd`, `/usr/libexec/virtiofsd`). Adds you to the `kvm` group. |
| 2 | **Cowork VM CLI crashes with `SIGILL`** (CPUs without AVX2 only) | Wraps `~/.config/Claude/claude-code-vm/<version>/claude` with Intel SDE |
| 3 | **`request req-2 (installSdk) timed out after 30s`** on slow machines | Raises the 30 s timeout compiled into `cowork-linux-helper` to 900 s (keeps a `.orig.bak` backup) |
| 4 | All of the above | |

```bash
cd claude-code-sigill-fix/Cowork/Linux/fix
chmod +x cowork-fix.sh
./cowork-fix.sh             # menu
./cowork-fix.sh 1 3         # run targets 1 and 3 without the menu
./cowork-fix.sh --restore   # undo (installed packages stay)
```

- **sudo:** Steps 1 and 3 need root. The script shows every `sudo` command and asks before running it. Without a terminal it only prints the commands.
- **Virtualization:** VT-x or AMD-V must be enabled in the BIOS.
- **kvm group:** After being added to it, log out and back in (or reboot).
- **Target 2** needs Intel SDE. The Claude Code script can install it with `--install-sde`.
- **AppImage installs:** The timeout patch doesn't work on the AppImage version of Claude Desktop. The image would have to be extracted and rebuilt by hand.
- **Updates:** Re-run the script after Claude Desktop updates. An update restores the original `cowork-linux-helper` and brings a new VM CLI.
- **AI agents:** [`Cowork/Linux/harness/SKILL.md`](Cowork/Linux/harness/SKILL.md) is the matching skill. The agent runs the script without `sudo` and hands the root commands to you.
- **Tested on:** Arch-based systems only (Garuda). The apt, dnf and zypper package names and firmware paths are best guesses and are untested. Reports are welcome.

## Related issues

AVX-related crash reports in [anthropics/claude-code](https://github.com/anthropics/claude-code):

- [#20116](https://github.com/anthropics/claude-code/issues/20116): the native installer's binary breaks on CPUs without AVX since v2.1.15 (Bun 1.3.6)
- [#20019](https://github.com/anthropics/claude-code/issues/20019): the same crash inside VMs whose virtual CPU type has no AVX
- [#24562](https://github.com/anthropics/claude-code/issues/24562)
- [#37919](https://github.com/anthropics/claude-code/issues/37919)
- [#10408](https://github.com/anthropics/claude-code/issues/10408)

Reports of `SIGILL` on CPUs that *do* have AVX2 have a different cause. This repository does not help with those.

## Tested on

- Intel Core 2 Duo E8400, Garuda Linux (Arch-based)
- Intel Core 2 Duo E8400, Windows 10: the Windows method (SDE 9.48.0, npm shims, compiled wrappers, timeout patch) was worked out and tested by hand for the CLI, Claude Desktop, VS Code and Zed. The script that automates it is new; reports are welcome.

Other distributions should work the same way but have not been tested yet. Reports are welcome.

## Versions

Releases are tagged `vX.Y.Z`; see [CHANGELOG.md](CHANGELOG.md). To stay on the latest release instead of the tip of `main`:

```bash
git fetch --tags
git checkout "$(git tag --list 'v*' --sort=-v:refname | head -n 1)"
```

`./claude-code-fix.sh --version`, `.\claude-code-fix.cmd -Version` and `./cowork-fix.sh --version` print the script version. Please include it in [bug reports](https://github.com/sucuklutank123456789-coder/claude-code-sigill-fix/issues/new?template=bug_report.yml).

## License

[MIT](LICENSE)
