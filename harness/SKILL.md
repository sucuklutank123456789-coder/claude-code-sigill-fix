---
name: claude-sigill-fix
description: Entry point for keeping Claude Code (CLI, Claude Desktop's embedded CLI and Cowork, VS Code / Cursor / Windsurf extension, Zed agent) running on x86-64 Linux or Windows machines whose CPU (or virtual CPU) lacks AVX2, where they crash with "Illegal instruction" / SIGILL (Linux) or exception code 0xc000001d (Windows). Detects the operating system and follows the matching instructions from the repository; on macOS it explains that the fix does not apply. Use when Claude Code or one of these apps crashes right at startup or never finishes loading, after any of them was updated, or when asked to update Claude Code on such a machine.
---

# Claude Code no-AVX2 fix: entry point (Linux, Windows; not macOS)

## For humans: adding this skill to your agent

This file is the one skill to install. It works out which operating system the agent runs on and then follows the instructions for that system, which it reads from the repository at the newest release. You don't need to install the per-platform skills (`Claude-Code/Linux/harness`, `Claude-Code/Windows/harness`, `Cowork/Linux/harness`) as well; they are what this skill reads.

1. Create a folder named `claude-sigill-fix` in your harness's skills directory.
2. Copy this file into it as `SKILL.md`.
3. Restart the agent, or reload its skills.

| Harness | Skills directory |
|---------|------------------|
| Hermes Agent | `~/.hermes/skills/` (Windows: `%USERPROFILE%\.hermes\skills\`). Check your Hermes version's docs if it uses another location. |
| Claude Code | `~/.claude/skills/` (Windows: `%USERPROFILE%\.claude\skills\`) |
| Other harnesses | See their documentation. If they have no skill support, paste the "Instructions for the agent" section below into the system prompt or instructions file. |

The agent never uses `sudo` or administrator rights. Steps that need them are handed to you as exact commands.

**This repository is not for macOS**, neither Apple Silicon nor Intel Macs. On a Mac, the skill only explains that and stops.

---

## Instructions for the agent

### Step 1: find the operating system and CPU architecture

In a POSIX shell (Linux, macOS, Git Bash / MSYS2 / Cygwin on Windows):

```bash
uname -s; uname -m
```

In PowerShell:

```powershell
[Environment]::OSVersion.Platform; $env:PROCESSOR_ARCHITECTURE
```

Then:

| Result | What to do |
|--------|------------|
| `Darwin` (macOS), any architecture | **Stop.** See "macOS" below. |
| Architecture `arm64` / `aarch64` / `ARM64` on any system | **Stop.** Claude Code runs as a native ARM build there; the AVX2 problem only exists on x86-64 CPUs. Look for another cause of the crash. |
| `Linux` with `x86_64` (also inside WSL) | Go to step 2, platform **Linux**. |
| `MINGW*`, `MSYS*`, `CYGWIN*`, or PowerShell reporting `Win32NT`, with `x86_64` / `AMD64` | Go to step 2, platform **Windows**. Use PowerShell for all commands from then on. |

Inside WSL, Claude Code is a Linux program: the Linux instructions fix the copy installed in WSL, not the Windows apps. If the user's problem is with Windows apps (Claude Desktop for Windows, VS Code on Windows, a `claude` started from PowerShell), use the Windows instructions from a Windows shell instead.

### Step 2: get the repository at the newest release (no sudo, no admin)

**Linux:**

```bash
REPO="$HOME/.local/share/claude-code-sigill-fix"
if [ -d "$REPO/.git" ]; then
    git -C "$REPO" fetch --quiet --tags --force origin
else
    git clone --quiet https://github.com/sucuklutank123456789-coder/claude-code-sigill-fix.git "$REPO"
fi
TAG="$(git -C "$REPO" tag --list 'v*' --sort=-v:refname | head -n 1)"
git -C "$REPO" -c advice.detachedHead=false checkout --quiet "${TAG:-origin/main}"
echo "using ${TAG:-main (no release tag yet)}"
```

**Windows (PowerShell):**

```powershell
$Repo = "$env:LOCALAPPDATA\claude-sigill-fix\repo"
if (Test-Path "$Repo\.git") {
    git -C $Repo fetch --quiet --tags --force origin
} else {
    git clone --quiet https://github.com/sucuklutank123456789-coder/claude-code-sigill-fix.git $Repo
}
$Tag = git -C $Repo tag --list 'v*' --sort=-v:refname | Select-Object -First 1
if (-not $Tag) { $Tag = "origin/main" }
git -C $Repo -c advice.detachedHead=false checkout --quiet $Tag
"using $Tag"
```

If `git` is missing on Windows, ask the user to install Git for Windows (`winget install -e --id Git.Git`, which may ask for administrator rights).

### Step 3: follow the platform instructions

Read the matching file from the checked-out repository and follow its **"Instructions for the agent"** section exactly, including its rules. Its "get or update the script" step uses the same folder as step 2 above, so it only re-checks the release and sets the variables the later steps need; run it as written.

| Platform | Problem | File to read |
|----------|---------|--------------|
| Linux | Claude Code: CLI, Claude Desktop's embedded CLI, VS Code and forks, Zed agent, Droid | `$REPO/Claude-Code/Linux/harness/SKILL.md` |
| Linux | Claude Desktop's **Cowork** feature ("Cowork requires QEMU", VM CLI crash, `installSdk` timeout) | `$REPO/Cowork/Linux/harness/SKILL.md` |
| Windows | Claude Code: CLI, Claude Desktop's embedded CLI, VS Code and forks, Zed agent | `$Repo\Claude-Code\Windows\harness\SKILL.md` |
| Windows | Cowork | Not covered by this repository. Tell the user. |

If the user's request covers both Claude Code and Cowork on Linux, follow both files, Claude Code first.

The Claude Code files start with a check that the CPU really lacks AVX2, and a check for virtual machines, where setting the VM's CPU type to `host` is the real fix. Never skip those checks.

### macOS

Do not clone the repository or run anything from it on a Mac. Tell the user:

- This repository only fixes Claude Code on **x86-64 Linux and Windows** CPUs without AVX2. It has nothing for macOS.
- **Apple Silicon Macs** (M-series) run Claude Code as a native ARM program, so a missing-AVX2 crash can't happen there. If Claude Code crashes, the cause is something else. If an x86-64 build is being run under Rosetta, switch to the native Apple Silicon build.
- **Older Intel Macs** without AVX2 may hit the same crash, but this repository has no fix for macOS.

Then help with the crash as an ordinary problem, without this repository.
