---
name: claude-code-fix-windows
description: Keep Claude Code (CLI, Claude Desktop's embedded CLI, VS Code / Cursor / Windsurf extension, Zed agent) running on Windows machines whose CPU (or virtual CPU) lacks AVX2, where they crash with exception code 0xc000001d (STATUS_ILLEGAL_INSTRUCTION). Use when one of them crashes right at startup or never finishes loading, after any of them was updated, or when asked to update Claude Code on such a machine.
---

# Claude Code illegal-instruction fix (Windows, no-AVX2 CPUs)

## For humans: adding this skill to your agent

This file is a ready-made skill in the common `SKILL.md` format (YAML frontmatter plus Markdown instructions). Hermes Agent, Claude Code and most other agent harnesses that support skills can load it.

1. Create a folder named `claude-code-fix-windows` in your harness's skills directory.
2. Copy this file into it as `SKILL.md`.
3. Restart the agent, or reload its skills.

| Harness | Skills directory |
|---------|------------------|
| Hermes Agent | `%USERPROFILE%\.hermes\skills\`. Check your Hermes version's docs if it uses another location. |
| Claude Code | `%USERPROFILE%\.claude\skills\` |
| Other harnesses | See their documentation. If they have no skill support, paste the "Instructions for the agent" section below into the system prompt or instructions file. |

For example, in PowerShell:

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.claude\skills\claude-code-fix-windows" | Out-Null
Copy-Item SKILL.md "$env:USERPROFILE\.claude\skills\claude-code-fix-windows\SKILL.md"
```

Nothing below needs administrator rights. Installing 7-Zip and the Visual C++ runtime with `winget` can ask for them; the agent leaves those two steps to you.

---

## Instructions for the agent

All commands are PowerShell. If your shell tool is bash (for example Git Bash), run each block with `powershell -NoProfile -Command '...'` or save it to a `.ps1` file first.

### Background

On CPUs without AVX2 (for example Core 2 Duo), Claude Code's native binaries crash with exception code `0xc000001d` (`STATUS_ILLEGAL_INSTRUCTION`). The fix script makes every such binary run under Intel SDE, which emulates the missing instructions:

- For an **npm install**, it edits the npm shims (`claude.cmd`, `claude.ps1`, `claude`) so they start `claude.exe` through SDE.
- For **everything else**, it replaces `claude.exe` with a small compiled wrapper and keeps the original under `%LOCALAPPDATA%\claude-sigill-fix\real-bin` (or next to the wrapper, for Claude Desktop).

Every update of Claude Code, the editor extensions, Zed's agent or Claude Desktop brings a fresh binary, and `npm install -g` rewrites the shims. After any update, the script must run again. The script is idempotent: it only touches what isn't patched yet, so running it when nothing changed is harmless.

### Rules

- **Never elevate.** Do not use `Start-Process -Verb RunAs`, `runas` or `gsudo`, and never ask for an administrator password. Always pass `-NoAdmin` so the script doesn't start `winget` installs that can show an administrator prompt. If a step needs one, stop and give the user the exact command to run themselves.
- **Always run the script non-interactively.** Pass the target numbers as arguments and start PowerShell with `-NonInteractive`, so no prompt can block you.
- **Do not edit, move or delete the patched files by hand.** Leave the shims, the wrapper `claude.exe` files, `%LOCALAPPDATA%\claude-sigill-fix` and `extension.js` to the script.
- **Never run `claude update`.** It does not work on these machines. See "Updating Claude Code" below.
- **Do not run `-Restore` unless the user asks for it.**
- **Do not close or kill the user's editors or apps.** After patching, tell the user which apps to fully restart. If the script reports that a file is in use, ask the user to close that app, then run it again.

### Step 1: confirm the machine needs the fix

```powershell
Add-Type -Namespace Cpu -Name K32 -MemberDefinition '[DllImport("kernel32.dll")] public static extern bool IsProcessorFeaturePresent(uint f);'
if ([Cpu.K32]::IsProcessorFeaturePresent(40)) { "has AVX2: fix NOT needed" } else { "no AVX2: fix needed" }
```

If the CPU has AVX2, stop and tell the user this fix is not for their machine: the crash has another cause. The script would refuse anyway.

To confirm that a crash really is this one, look for exception code `0xc000001d` in the Application log:

```powershell
Get-WinEvent -LogName Application -MaxEvents 50 |
    Where-Object { $_.Id -in 1000, 1001 -and $_.Message -like "*claude*" } |
    Format-List TimeCreated, Message
```

If there is no AVX2, check whether this is a virtual machine:

```powershell
Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer, Model
```

A model such as `Virtual Machine`, `VMware...`, `VirtualBox`, `KVM` or `Standard PC (...)` means a VM. Hypervisors often give guests a generic CPU model without AVX, even when the physical CPU has it. In that case, tell the user **first** to set the VM's CPU type to `host` (Proxmox: Hardware → Processors → Type `host`; libvirt: `host-passthrough`). This is a hypervisor setting you cannot change from inside the VM. After the change, Claude Code runs natively at full speed. Only continue with the steps below if the user says the host CPU itself lacks AVX2, or that they can't change the CPU type.

### Step 2: get or update the script

```powershell
$Repo = "$env:LOCALAPPDATA\claude-sigill-fix\repo"
if (Test-Path "$Repo\.git") {
    git -C $Repo fetch --quiet --tags --force origin
} else {
    git clone --quiet https://github.com/sucuklutank123456789-coder/claude-code-sigill-fix.git $Repo
}
# Use the newest release tag, not the tip of main (see CHANGELOG.md).
$Tag = git -C $Repo tag --list 'v*' --sort=-v:refname | Select-Object -First 1
if (-not $Tag) { $Tag = "origin/main" }
git -C $Repo -c advice.detachedHead=false checkout --quiet $Tag
"using $Tag"
$Fix = "$Repo\Claude-Code\Windows\fix\claude-code-fix.ps1"
```

This needs Git for Windows. If `git` is not installed, ask the user to install it (`winget install -e --id Git.Git`, which may ask for administrator rights).

The script is pinned to the newest release tag (`vX.Y.Z`). Only the step above moves it to a newer release: scheduled runs keep using the checked-out version until this step runs again.

Run the script like this, so PowerShell's execution policy doesn't block it and no prompt can appear:

```powershell
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Fix -Version
```

### Step 3: make sure Intel SDE is available

The script looks for `sde.exe` under `%LOCALAPPDATA%\claude-sigill-fix\sde`, `C:\intel-sde-old` and on `PATH`.

It needs **SDE 9.48.0**. Newer SDE releases crash inside SDE itself on CPUs without SSE4.2 (such as Core 2 Duo). The script checks every SDE it finds by running a test program under it, so a broken SDE is reported instead of used.

If SDE is missing:

1. Tell the user that Intel SDE is Intel software under Intel's own license.
2. Ask for their consent before the **first** install.
3. Once they agree, add `-InstallSde` to the run in step 4. It downloads SDE 9.48.0 into `%LOCALAPPDATA%\claude-sigill-fix\sde`, with no administrator rights needed.

SDE's requirements need `winget`, which can show an administrator prompt. With `-NoAdmin`, the script only reports them with `[ERROR]` lines that contain the `winget` commands. Give those commands to the user:

- **7-Zip** (to extract the download): `winget install -e --id 7zip.7zip`
- **Visual C++ runtime, both x64 and x86**: `winget install -e --id Microsoft.VCRedist.2015+.x64` and `winget install -e --id Microsoft.VCRedist.2015+.x86`

If the automatic download fails because the link can't be found, ask the user to download it by hand:

1. Open https://www.intel.com/content/www/us/en/download/684897/intel-software-development-emulator.html
2. Select version 9.48.0, accept the license and download the Windows package (`.tar.xz`).
3. Tell you where they saved it.

Then add `-Sde "<path of that file>"` to the run in step 4.

### Step 4: run the fix

```powershell
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Fix -NoAdmin 5
# add -InstallSde only after the user agreed to install SDE (step 3)
```

The target numbers are:

| # | Target |
|---|--------|
| 1 | Claude Code CLI (npm install and native installer) |
| 2 | Claude Desktop's embedded CLI |
| 3 | VS Code, Cursor, Windsurf and VSCodium extensions |
| 4 | Zed agent |
| 5 | All |

Use `5` unless the user asked for specific targets.

### Step 5: read the result

- **Exit code:** `0` means no step failed; `1` means at least one `[ERROR]`.
- **Status lines:**
  - `[OK]`: already patched.
  - `[PATCHED]`: fixed now. Tell the user to fully restart that app (for the CLI: open a new terminal).
  - `[SKIP]`: not installed.
  - `[ERROR]`: report the line to the user verbatim.
- **`could not replace ... (close the app that uses it and re-run)`:** the app is running. Ask the user to close it, then run step 4 again.
- **`timeout setting not found in ... extension.js`:** the extension changed in a way the script doesn't recognize. Tell the user; do not patch the file yourself.

### Updating Claude Code

`claude update` does not work on these machines. Update the same way Claude Code was installed, then run step 4 again.

To see which install method was used:

```powershell
Get-Command claude -All | Select-Object CommandType, Source
# claude.cmd / claude.ps1 in the npm folder (usually %APPDATA%\npm) -> npm install
# %USERPROFILE%\.local\bin\claude.exe                                -> native installer
```

**npm install:**

```powershell
npm install -g --allow-scripts=@anthropic-ai/claude-code @anthropic-ai/claude-code@latest
```

- **Unknown `--allow-scripts` flag:** retry without it.
- **npm is blocked by the execution policy** (`npm.ps1 cannot be loaded`): use `npm.cmd` instead of `npm`.

**Native installer:**

```powershell
irm https://claude.ai/install.ps1 | iex
```

This installer runs the downloaded native binary, so on these CPUs it may crash itself. If it does, tell the user and suggest switching to the npm install.

### Automating it

Because every update undoes the fix, re-run step 4 on a schedule. Pick one of these; neither needs administrator rights.

**A) The harness's own scheduler** (for example a Hermes cron job). Run this once a day and after every update you perform:

```powershell
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\claude-sigill-fix\repo\Claude-Code\Windows\fix\claude-code-fix.ps1" -NoAdmin 5
```

Only notify the user when the output contains `[PATCHED]` or `[ERROR]`.

**B) A Task Scheduler task** for the current user, every hour:

```powershell
$fixPath = "$env:LOCALAPPDATA\claude-sigill-fix\repo\Claude-Code\Windows\fix\claude-code-fix.ps1"
schtasks /Create /F /SC HOURLY /TN "claude-code-fix" /TR "powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$fixPath`" -NoAdmin 5"
```

A console window may flash briefly when it runs. Check the last result with `schtasks /Query /TN claude-code-fix /V /FO LIST` (`Last Result: 0` means no step failed). To remove the task:

```powershell
schtasks /Delete /F /TN "claude-code-fix"
```

### Undoing the fix (only when the user asks)

```powershell
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Fix -Restore 5
```

This restores every original binary, shim and timeout. The files in `%LOCALAPPDATA%\claude-sigill-fix` (SDE and the compiled wrappers) stay; the user can delete that folder afterwards if they no longer need SDE.
