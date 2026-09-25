---
name: claude-code-fix
description: Keep Claude Code (CLI, Claude Desktop's embedded CLI, VS Code / Cursor / Windsurf extension, Zed agent) and Droid running on Linux machines whose CPU lacks AVX/AVX2/SSE4.2, where they crash with "Illegal instruction" (SIGILL). Use when one of them fails to start with SIGILL or "Illegal instruction (core dumped)", after any of them was updated, or when asked to update Claude Code on such a machine.
---

# Claude Code SIGILL fix (Linux, no-AVX CPUs)

## For humans: adding this skill to your agent

This file is a ready-made skill in the common `SKILL.md` format (YAML frontmatter plus Markdown instructions). Hermes Agent, Claude Code and most other agent harnesses that support skills can load it.

1. Create a folder named `claude-code-fix` in your harness's skills directory.
2. Copy this file into it as `SKILL.md`.
3. Restart the agent, or reload its skills.

| Harness | Skills directory |
|---------|------------------|
| Hermes Agent | `~/.hermes/skills/`. Check your Hermes version's docs if it uses another location. |
| Claude Code | `~/.claude/skills/` |
| Other harnesses | See their documentation. If they have no skill support, paste the "Instructions for the agent" section below into the system prompt or instructions file. |

For example:

```bash
mkdir -p ~/.hermes/skills/claude-code-fix
cp SKILL.md ~/.hermes/skills/claude-code-fix/SKILL.md
```

Nothing below needs `sudo`, except installing Intel SDE as a system package. That step is optional and the agent leaves it to you.

This skill does not cover Claude Desktop's Cowork feature. For Cowork, use `Cowork/Linux/harness/SKILL.md` from the same repository.

---

## Instructions for the agent

### Background

On CPUs without AVX2 (for example Core 2 Duo), Claude Code's native binaries crash with `SIGILL`. The fix script wraps every such binary so that it runs under Intel SDE, which emulates the missing instructions.

Every update of Claude Code, the editor extensions, Zed's agent, Claude Desktop or Droid replaces a wrapped binary with a fresh one. After any update, the script must run again. The script is idempotent: it only touches what isn't patched yet, so running it when nothing changed is harmless.

### Rules

- **Never use `sudo`** and never ask for the user's password. If a step needs root, stop and give the user the exact command to run themselves.
- **Always run the script non-interactively.** Pass the target numbers as arguments, add `--no-sudo`, and redirect stdin from `/dev/null` so no prompt can block you.
- **Do not edit, move or delete the patched files by hand.** Leave the `*.realbinary` files, the wrapper scripts, and `extension.js` to the script.
- **Never run `claude update`.** It does not work on these machines. See "Updating Claude Code" below.
- **Do not run `--restore` unless the user asks for it.**
- **Do not close or kill the user's editors or apps.** After patching, tell the user which apps to fully restart.

### Step 1: confirm the machine needs the fix

```bash
grep -qw avx2 /proc/cpuinfo && echo "has AVX2: fix NOT needed" || echo "no AVX2: fix needed"
```

If the CPU has AVX2, stop and tell the user this fix is not for their machine: the crash has another cause. The script would refuse anyway.

### Step 2: get or update the script (no sudo)

```bash
REPO="$HOME/.local/share/claude-code-sigill-fix"
if [ -d "$REPO/.git" ]; then
    git -C "$REPO" pull --ff-only
else
    git clone https://github.com/sucuklutank123456789-coder/claude-code-sigill-fix.git "$REPO"
fi
FIX="$REPO/Claude-Code/Linux/fix/claude-code-fix.sh"
```

### Step 3: make sure Intel SDE is available

The script looks for `intel-sde`, `sde64` or `sde` on `PATH`, and also for `~/.local/opt/intel-sde/sde64`.

If SDE is missing:

1. Tell the user that Intel SDE is Intel software under Intel's own license.
2. Ask for their consent before the **first** install.
3. Once they agree, add `--install-sde` to the run in step 4. Together with `--no-sudo`, this downloads Intel's Linux tarball into `~/.local/opt/intel-sde`, with no root needed.

If the user would rather have a system package (Arch: `paru -S intel-sde`), that needs sudo: give them the command and let them run it.

If the automatic download fails because the link can't be found, give the user this page to download the Linux `.tar.xz` from manually, and ask them to extract it into `~/.local/opt/intel-sde`:

https://www.intel.com/content/www/us/en/download/684897/intel-software-development-emulator.html

### Step 4: run the fix

```bash
bash "$FIX" --no-sudo 6 </dev/null
# add --install-sde only after the user agreed to install SDE (step 3)
```

The target numbers are:

| # | Target |
|---|--------|
| 1 | Claude Code CLI |
| 2 | Claude Desktop |
| 3 | VS Code, Cursor, Windsurf and VSCodium extensions |
| 4 | Zed agent |
| 5 | Droid |
| 6 | All |

Use `6` unless the user asked for specific targets.

### Step 5: read the result

- **Exit code:** `0` means no step failed; `1` means at least one `[ERROR]`.
- **Status lines:**
  - `[OK]`: already patched.
  - `[PATCHED]`: fixed now. Tell the user to fully restart that app.
  - `[SKIP]`: not installed.
  - `[ERROR]`: report the line to the user verbatim.
- **`timeout setting not found in ... extension.js`:** the extension changed in a way the script doesn't recognize. Tell the user; do not patch the file yourself.

### Updating Claude Code

`claude update` does not work on these machines. Update the same way Claude Code was installed, then run step 4 again.

To see which install method was used:

```bash
readlink -f "$(command -v claude)"
# contains node_modules/@anthropic-ai/claude-code  -> npm install
# contains .local/share/claude/versions            -> native installer
```

**npm install:**

```bash
npm install -g --allow-scripts=@anthropic-ai/claude-code @anthropic-ai/claude-code@latest
```

- **`EACCES` error:** the global npm prefix is root-owned. Do **not** use sudo. Move npm's prefix into the home directory instead, then retry:

  ```bash
  npm config set prefix "$HOME/.npm-global"
  ```

  After that, `~/.npm-global/bin` must be on `PATH`. Tell the user to add it to their shell config.
- **Unknown `--allow-scripts` flag:** retry without it.

**Native installer:**

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

This installer runs the downloaded native binary, so on these CPUs it may crash with `SIGILL` itself. If it does, tell the user and suggest switching to the npm install.

### Automating it

Because every update undoes the fix, re-run step 4 on a schedule. Pick one of these; neither needs root.

**A) The harness's own scheduler** (for example a Hermes cron job). Run this once a day and after every update you perform:

```bash
bash "$HOME/.local/share/claude-code-sigill-fix/Claude-Code/Linux/fix/claude-code-fix.sh" --no-sudo 6 </dev/null
```

Only notify the user when the output contains `[PATCHED]` or `[ERROR]`.

**B) A systemd user timer.** This runs at login and every hour, independent of the agent:

```bash
mkdir -p ~/.config/systemd/user

cat > ~/.config/systemd/user/claude-code-fix.service <<'EOF'
[Unit]
Description=Re-apply the Claude Code SIGILL fix

[Service]
Type=oneshot
ExecStart=/usr/bin/env bash %h/.local/share/claude-code-sigill-fix/Claude-Code/Linux/fix/claude-code-fix.sh --no-sudo 6
StandardInput=null
EOF

cat > ~/.config/systemd/user/claude-code-fix.timer <<'EOF'
[Unit]
Description=Re-apply the Claude Code SIGILL fix periodically

[Timer]
OnStartupSec=2min
OnUnitActiveSec=1h

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now claude-code-fix.timer
```

Check the results with:

```bash
journalctl --user -u claude-code-fix.service -n 50
```

To remove the timer:

```bash
systemctl --user disable --now claude-code-fix.timer
rm ~/.config/systemd/user/claude-code-fix.{service,timer}
```

### Undoing the fix (only when the user asks)

```bash
bash "$FIX" --no-sudo --restore 6 </dev/null
```

This restores every original binary and timeout.
