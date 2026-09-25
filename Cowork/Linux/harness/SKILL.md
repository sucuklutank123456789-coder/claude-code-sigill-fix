---
name: cowork-fix
description: Get Claude Desktop's Cowork feature working on Linux. Use when Cowork shows "Cowork requires QEMU", fails with "request req-2 (installSdk) timed out after 30s", its VM CLI crashes with SIGILL / "Illegal instruction" on a CPU without AVX2, or after Claude Desktop was updated on a machine where Cowork was fixed before.
---

# Cowork fix (Linux)

## For humans: adding this skill to your agent

This file is a ready-made skill in the common `SKILL.md` format (YAML frontmatter plus Markdown instructions). Hermes Agent, Claude Code and most other agent harnesses that support skills can load it.

1. Create a folder named `cowork-fix` in your harness's skills directory.
2. Copy this file into it as `SKILL.md`.
3. Restart the agent, or reload its skills.

| Harness | Skills directory |
|---------|------------------|
| Hermes Agent | `~/.hermes/skills/`. Check your Hermes version's docs if it uses another location. |
| Claude Code | `~/.claude/skills/` |
| Other harnesses | See their documentation. If they have no skill support, paste the "Instructions for the agent" section below into the system prompt or instructions file. |

For example:

```bash
mkdir -p ~/.hermes/skills/cowork-fix
cp SKILL.md ~/.hermes/skills/cowork-fix/SKILL.md
```

**The agent never uses `sudo`.** Most Cowork fixes need root: installing packages, creating system symlinks, joining the `kvm` group and patching `cowork-linux-helper`. For these, the agent runs the script without a terminal, so the script only prints the `sudo` commands. The agent then gives you the commands to run yourself, or tells you to run the script in your own terminal, where it asks before each command.

---

## Instructions for the agent

### Background

Cowork runs a small QEMU/KVM virtual machine. The fix script handles three separate problems:

| # | Problem | Needs root |
|---|---------|------------|
| 1 | **"Cowork requires QEMU"**: QEMU, OVMF or virtiofsd is missing, or sits where Claude Desktop doesn't look (Debian paths are hardcoded), or the user can't access `/dev/kvm`. | yes |
| 2 | **Cowork VM CLI crashes with SIGILL** on CPUs without AVX2. It is wrapped with Intel SDE. | no |
| 3 | **`installSdk timed out after 30s`**: slow machines need more than the 30 s compiled into `cowork-linux-helper`. It is raised to 900 s. | yes |

Target 4 runs all three.

Every Claude Desktop update replaces `cowork-linux-helper` and downloads a new VM CLI. After an update, steps 2 and 3 must run again. The script is idempotent: it only touches what isn't fixed yet.

### Rules

- **Never use `sudo`** and never ask for the user's password.
- **Always run the script without a terminal** (stdin from `/dev/null`). It then never runs a root command itself. It prints each one as `Command: sudo ...`, followed by `[WARN] no terminal to ask for confirmation`. Collect those lines for the user.
- **Do not create the symlinks, install packages or patch files by hand.** Leave that to the script or the user.
- **Do not run `--restore` unless the user asks for it.**
- **Do not quit or restart Claude Desktop yourself.** Tell the user to.

### Step 1: get or update the script (no sudo)

```bash
REPO="$HOME/.local/share/claude-code-sigill-fix"
if [ -d "$REPO/.git" ]; then
    git -C "$REPO" pull --ff-only
else
    git clone https://github.com/sucuklutank123456789-coder/claude-code-sigill-fix.git "$REPO"
fi
FIX="$REPO/Cowork/Linux/fix/cowork-fix.sh"
```

### Step 2: run it

Use the target the user's error points to, or `4` for everything:

```bash
bash "$FIX" 4 </dev/null
```

### Step 3: read the result

- **Exit code:** `0` means nothing failed; `1` means at least one `[ERROR]`.
- **Status lines:**
  - `[OK]`: already fine.
  - `[PATCHED]`: fixed now.
  - `[SKIP]`: not applicable. For example, the CPU has AVX2, the VM CLI isn't downloaded yet, or Claude Desktop is an AppImage.
  - `[ERROR]`: report the line to the user verbatim.
- **Root commands:** Each `Command: sudo ...` line followed by `no terminal to ask for confirmation` is a root command that was **not** run. Give the user those commands in order, or tell them to run the script themselves in a terminal, where it asks before each command:

  ```bash
  ~/.local/share/claude-code-sigill-fix/Cowork/Linux/fix/cowork-fix.sh 4
  ```

  After a step is done, re-run step 2 to check it. Later root commands (the symlinks, for example) often depend on earlier ones (installing the packages).
- **Specific errors:**
  - **`CPU virtualization (VT-x / AMD-V) is not available`:** tell the user to enable VT-x or AMD-V in the BIOS/UEFI. Nothing else fixes this.
  - **`Intel SDE not found`:** SDE is needed for target 2. Ask for the user's consent (SDE is under Intel's own license). Then install it without sudo with the Claude Code fix script, and re-run step 2:

    ```bash
    bash "$REPO/Claude-Code/Linux/fix/claude-code-fix.sh" --no-sudo --install-sde 1 </dev/null
    ```

  - **`Log out and back in (or reboot)` in the summary:** the `kvm` group change only takes effect after that.

When the output shows `[PATCHED]` or all root commands were done, tell the user to fully quit Claude Desktop and start it again.

### Automating it

After Claude Desktop updates, target 2 can be re-applied without root. The `installSdk` timeout (target 3) needs the user.

Run this daily, or after Claude Desktop updates, with the harness's scheduler:

```bash
bash "$HOME/.local/share/claude-code-sigill-fix/Cowork/Linux/fix/cowork-fix.sh" 2 3 </dev/null
```

Only notify the user when the output contains `[PATCHED]`, `[ERROR]` or a `Command: sudo` line.

### Undoing the fix (only when the user asks)

```bash
bash "$FIX" --restore 4 </dev/null
```

The VM CLI wrapper is removed directly. Removing the symlinks and restoring `cowork-linux-helper` from its backup need root: pass the printed commands to the user. Installed packages and `kvm` group membership are kept.
